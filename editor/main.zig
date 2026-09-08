const std = @import("std");
const builtin = @import("builtin");
const Webview = @import("Webview");
const known_folders = @import("known-folders");
const filesystem_dialog = @import("filesystem-dialog");

const clipboard = @import("clipboard");

const app_html = @embedFile("index.html");
const inject_editor_css = @embedFile("inject/editor.css");
const inject_editor_js = @embedFile("inject/editor.js");
const quill_snow_css = @embedFile("quill.snow.css");

const State = struct {
    // main thread deinitializes, server thread appends, server-client threads remove

    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    mutex: std.Io.Mutex = .init,
    clients: std.ArrayList(struct { stream: std.Io.net.Stream, thread: std.Thread, id: usize }) = .empty,

    // used by main thread only
    thread: ?std.Thread,

    // used by server-thread only
    tcp_server: std.Io.net.Server,

    // used by server-client threads
    site_dir: ?[]const u8,

    // used by all threads
    gpa: std.mem.Allocator,
    shutdown: std.atomic.Value(bool) = .init(false),

    site_mode: enum { editor, production },
};

fn copyDirectory(io: std.Io, gpa: std.mem.Allocator, source: std.Io.Dir, dest_parent: std.Io.Dir, dest_subdir: []const u8) !void {
    copyDirectory2(io, gpa, source, dest_parent, dest_subdir) catch |e| {
        dest_parent.deleteTree(io, dest_subdir) catch |e2| {
            std.debug.print("error creating tree & error deleting tree: {t} {t}\n", .{ e, e2 });
        };
        return e;
    };
}
fn copyDirectory2(io: std.Io, gpa: std.mem.Allocator, source: std.Io.Dir, dest_parent: std.Io.Dir, dest_subdir: []const u8) !void {
    var dest = try dest_parent.createDirPathOpen(io, dest_subdir, .{});
    defer dest.close(io);

    var walker = try source.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                entry.dir.copyFile(entry.basename, dest, entry.path, io, .{}) catch |e| {
                    std.debug.print("failed to copy file '{s}' {t}\n", .{ entry.path, e });
                    return e;
                };
            },
            .directory => {
                dest.createDir(io, entry.path, .default_dir) catch |e| {
                    std.debug.print("failed to make directory '{s}' {t}\n", .{ entry.path, e });
                    return e;
                };
            },
            else => continue,
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    defer clipboard.deinit();

    try filesystem_dialog.init();
    defer filesystem_dialog.deinit();

    const webview = Webview.init(builtin.mode == .debug, null) orelse return error.FailedToCreateWebview;
    defer webview.destroy();

    try webview.setTitle("Montecito Site Editor");
    try webview.setSize(1024, 720, .none);
    try webview.setHtml(app_html);

    const site_dir: ?[]const u8 = blk: {
        const generic_data_path = (known_folders.getPath(io, gpa, init.environ_map, .data) catch break :blk null) orelse break :blk null;
        defer gpa.free(generic_data_path);

        var generic_data_folder = std.Io.Dir.cwd().createDirPathOpen(io, generic_data_path, .{}) catch break :blk null;
        defer generic_data_folder.close(io);

        generic_data_folder.access(io, "montecito-site-backups/master-copy", .{ .read = true, .write = true }) catch |e| switch (e) {
            error.FileNotFound => {
                const self_dir = std.process.executableDirPathAlloc(io, gpa) catch break :blk null;
                defer gpa.free(self_dir);

                const site_build_path = try std.fs.path.join(gpa, &.{ self_dir, "site-build" });
                defer gpa.free(site_build_path);

                var site_dir = std.Io.Dir.cwd().openDir(io, site_build_path, .{ .iterate = true }) catch break :blk null;
                defer site_dir.close(io);

                copyDirectory(io, gpa, site_dir, generic_data_folder, "montecito-site-backups/master-copy") catch break :blk null;
            },
            else => break :blk null,
        };
        break :blk try std.fs.path.join(gpa, &.{ generic_data_path, "montecito-site-backups", "master-copy" });
    };

    var state: State = .{
        .io = io,
        .environ_map = init.environ_map,
        .thread = null,
        .tcp_server = undefined,
        .site_mode = undefined,
        .gpa = gpa,
        .site_dir = site_dir,
    };
    defer if (state.site_dir) |s| gpa.free(s);
    defer state.clients.deinit(state.gpa);

    const host_site = try webview.bind(gpa, "backendHostSite", &hostSite, .{&state});
    defer host_site.deinit();

    const stop_hosting = try webview.bind(gpa, "backendStopHosting", &stopHosting, .{&state});
    defer stop_hosting.deinit();

    const copy_to_clipboard = try webview.bind(gpa, "backendCopyToClipboard", &copyToClipboard, .{});
    defer copy_to_clipboard.deinit();

    const retrieve_backups = try webview.bind(gpa, "backendRetrieveBackups", &retrieveBackups, .{ io, gpa, init.environ_map });
    defer retrieve_backups.deinit();

    const make_backup = try webview.bind(gpa, "backendMakeBackup", &makeBackup, .{&state});
    defer make_backup.deinit();

    const restore_backup = try webview.bind(gpa, "backendRestoreBackup", &restoreBackup, .{&state});
    defer restore_backup.deinit();

    const delete_backup = try webview.bind(gpa, "backendDeleteBackup", &deleteBackup, .{&state});
    defer delete_backup.deinit();

    const rename_backup = try webview.bind(gpa, "backendRenameBackup", &renameBackup, .{&state});
    defer rename_backup.deinit();

    const import_website_copy = try webview.bind(gpa, "backendImportWebsiteCopy", &importWebsiteCopy, .{&state});
    defer import_website_copy.deinit();

    const export_website = try webview.bind(gpa, "backendExportWebsite", &exportWebsite, .{&state});
    defer export_website.deinit();

    try webview.run();
}

fn copyToClipboard(_: Webview.BindContext, text: []const u8) void {
    clipboard.write(text) catch |e| std.debug.print("error copying to clipboard: {t}\n", .{e});
}

fn hostSite(context: Webview.BindContext, site_type: []const u8, state: *State) void {
    if (state.thread) |_| {
        return;
    }

    if (state.site_dir == null) {
        context.returnError("No site build or master copy found. A copy of the site build is needed to view and edit the site.") catch |e| {
            std.debug.panic("unrecoverable error: {t}\n", .{e});
        };
    }

    state.site_mode = if (std.mem.eql(u8, site_type, "editor")) blk: {
        break :blk .editor;
    } else if (std.mem.eql(u8, site_type, "production")) blk: {
        break :blk .production;
    } else {
        std.debug.panic("unexpected site type '{s}'", .{site_type});
    };

    const address: std.Io.net.IpAddress = .fromIp6(.loopback(8192));
    state.tcp_server = address.listen(state.io, .{ .reuse_address = true }) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("unrecoverable error: {t}\n", .{e2});
        };
        return;
    };
    std.debug.print("port: {}\n", .{state.tcp_server.socket.address.getPort()});
    std.debug.print("site type: {s}\n", .{site_type});

    state.thread = std.Thread.spawn(.{}, serverThread, .{state}) catch |e| std.debug.panic("{t}", .{e});

    context.returnValue(.{ .port = state.tcp_server.socket.address.getPort() }) catch |e| std.debug.panic("{t}", .{e});
}

fn serverThread(state: *State) void {
    state.shutdown.store(false, .monotonic);

    defer {
        std.debug.print("server shutdown\n", .{});
        state.mutex.lock(state.io) catch unreachable;
        for (state.clients.items) |client| {
            if (0 == std.posix.system.shutdown(client.stream.socket.handle, 2)) {
                client.thread.join();
                client.stream.close(state.io);
            } else {
                std.debug.print("error shutting down client\n", .{});
                client.thread.detach();
            }
        }
        state.clients.clearRetainingCapacity();
        state.mutex.unlock(state.io);

        state.tcp_server.deinit(state.io);
    }

    var id: usize = 0;
    while (true) {
        if (state.shutdown.load(.monotonic)) {
            return;
        }
        const client = state.tcp_server.accept(state.io) catch |e| {
            // after calling netShutdown, SocketNotListening is thrown, so this code path will run
            if (state.shutdown.load(.monotonic)) {
                return;
            }
            std.debug.print("error accepting client: {t}\n", .{e});
            continue;
        };
        std.debug.print("client: {}\n", .{id});

        const thread = std.Thread.spawn(.{}, serverThread2, .{ client, id, state }) catch |e| std.debug.panic("{t}", .{e});

        state.mutex.lock(state.io) catch unreachable;
        state.clients.append(state.gpa, .{
            .stream = client,
            .thread = thread,
            .id = id,
        }) catch |e| {
            state.mutex.unlock(state.io);
            std.debug.panic("{t}", .{e});
        };
        state.mutex.unlock(state.io);

        id += 1;
    }
}
fn serverThread2(client: std.Io.net.Stream, id: usize, state: *State) void {
    serverThread3(client, id, state) catch |e| std.debug.print("server error: {t}\n client id: {}\n", .{ e, id });
}
fn serverThread3(client: std.Io.net.Stream, id: usize, state: *State) !void {
    defer {
        std.debug.print("client disconnect {}\n", .{id});

        if (!state.shutdown.load(.monotonic)) {
            state.mutex.lock(state.io) catch unreachable;
            const index: usize = blk: for (0..state.clients.items.len) |i| {
                if (state.clients.items[i].id == id) {
                    break :blk i;
                }
            } else unreachable;
            _ = state.clients.swapRemove(index);
            client.close(state.io);
            state.mutex.unlock(state.io);
        }
    }

    var http_in_buffer: [1024 * 8]u8 = undefined;
    var http_out_buffer: [1024 * 32]u8 = undefined;
    var http_writer = client.writer(state.io, &http_out_buffer);
    var http_reader = client.reader(state.io, &http_in_buffer);

    var http_server = std.http.Server.init(&http_reader.interface, &http_writer.interface);
    while (true) {
        var request = try http_server.receiveHead();

        if (request.head.method == .POST and std.mem.eql(u8, request.head.target, "/post")) {
            handlePost(&request, state) catch |e| {
                std.debug.print("error handling post: {t}\n", .{e});
                try request.respond("", .{ .status = .bad_request });
            };
            continue;
        } else if (request.head.method != .GET) {
            std.debug.print("404: unexpected request method {t}\n", .{request.head.method});
            try request.respond("404 not found", .{ .status = .not_found });
            continue;
        }

        try handleGet(&request, state);
    }
}

fn handlePost(request: *std.http.Server.Request, state: *State) !void {
    std.debug.print("recieved POST\n", .{});
    var buffer: [1024]u8 = undefined;
    const body_reader = request.server.reader.bodyReader(&buffer, .none, request.head.content_length);
    const body = try body_reader.allocRemaining(state.gpa, .limited(1024 * 1024));
    defer state.gpa.free(body);

    std.debug.print("{s}\n", .{body});

    // replace-element: location and html
    // add-element: location and html
    // remove-element: location ONLY
    // move-element: location, before/after, and location

    var body_iter = std.mem.splitScalar(u8, body, '\n');
    const command = body_iter.next() orelse return error.InvalidPost;
    const get_path = body_iter.next() orelse return error.InvalidPost;
    const location = decodeElementLocation(&body_iter) orelse return error.invalidPost;

    const file_in, const path = findHtml(state.io, state.gpa, state.site_dir.?, get_path[1..]) catch |e| switch (e) {
        error.NotFound => return error.InvalidPost,
        error.UnsafePath => return error.InvalidPost,
        error.OutOfMemory => return e,
    };
    defer state.gpa.free(path);

    const file_contents = blk: {
        defer file_in.close(state.io);
        var reader = file_in.reader(state.io, &.{});
        break :blk try reader.interface.allocRemaining(state.gpa, .limited(1024 * 1024 * 64));
    };
    defer state.gpa.free(file_contents);

    const file = try std.Io.Dir.cwd().createFile(state.io, path, .{});
    defer file.close(state.io);

    // body_reader is no longer being used; buffer is safe to overwrite
    var writer = file.writer(state.io, &buffer);

    if (std.mem.eql(u8, command, "add-element")) {
        const html_start = body_iter.index orelse return error.InvalidPost;
        // note: has a trailing newline
        const html = body_iter.buffer[html_start..body_iter.buffer.len];

        const start_index = findNthTagIndex(file_contents, location.element_tag, location.element_index) orelse return error.InvalidPost;
        const closing_index = findClosingTag(file_contents, location.element_tag, start_index) orelse return error.MalformedHtml;
        const indentation = leadingSpaces(file_contents, start_index);

        if (location.is_alert) {
            // add inside the alert; before the closing tag
            const closing_tag_length = location.element_tag.len + "</>".len;
            try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[0 .. closing_index - closing_tag_length]));
        } else {
            try writer.interface.writeAll(file_contents[0..closing_index]);
        }

        try writer.interface.writeByte('\n');

        try writeIndented(&writer.interface, html, (if (location.is_alert) indentation + 4 else indentation), null);

        if (location.is_alert) {
            const closing_tag_length = location.element_tag.len + "</>".len;
            try writer.interface.splatByteAll(' ', indentation);
            try writer.interface.writeAll(file_contents[closing_index - closing_tag_length ..]);
        } else {
            try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[closing_index..]));
        }
    } else if (std.mem.eql(u8, command, "replace-element")) {
        const html_start = body_iter.index orelse return error.InvalidPost;
        // note: has a trailing newline
        const html = body_iter.buffer[html_start..body_iter.buffer.len];

        const start_index = findNthTagIndex(file_contents, location.element_tag, location.element_index) orelse return error.InvalidPost;
        const closing_index = findClosingTag(file_contents, location.element_tag, start_index) orelse return error.MalformedHtml;
        const indentation = leadingSpaces(file_contents, start_index);

        // 2 cases
        //
        // old0 <p>old1</p> old2
        // ->
        // old0
        // <p>
        //     new1
        // </p>
        // old2
        //
        // ---
        //
        // old0
        // <p>
        //     old1
        // </p>
        // old2
        // ->
        // old0
        // <p>
        //     new1
        // </p>
        // old2

        try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[0..start_index]));
        try writer.interface.writeByte('\n');

        try writeIndented(&writer.interface, html, indentation, null);

        try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[closing_index..]));
    } else if (std.mem.eql(u8, command, "remove-element")) {
        const start_index = findNthTagIndex(file_contents, location.element_tag, location.element_index) orelse return error.InvalidPost;
        const closing_index = findClosingTag(file_contents, location.element_tag, start_index) orelse return error.MalformedHtml;

        // cases
        //
        // content0
        // <p>old</p>
        // content1
        // ->
        // content0
        // content1
        //
        // ---
        //
        // content0 <p>old</p> content1
        // ->
        // content0
        // content1

        try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[0..start_index]));
        try writer.interface.writeByte('\n');
        try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[closing_index..]));
    } else if (std.mem.eql(u8, command, "move-element")) {
        const placement_string = body_iter.next() orelse return error.InvalidPost;
        const placement: enum { before, after, in_start, in_end } = blk: {
            if (std.mem.eql(u8, placement_string, "before")) {
                break :blk .before;
            } else if (std.mem.eql(u8, placement_string, "after")) {
                break :blk .after;
            } else if (std.mem.eql(u8, placement_string, "in-start")) {
                break :blk .in_start;
            } else if (std.mem.eql(u8, placement_string, "in-end")) {
                break :blk .in_end;
            } else {
                return error.InvalidPost;
            }
        };

        // cases
        //      <--- maybe here (before)
        // <p>
        //     <p>old</p>
        // </p>
        //      <--- maybe here (after)
        //
        // ---
        //
        // <p>
        //          <--- maybe here (before)
        //     <p>element0</p>
        //     <p>old</p>
        //     <p>element1</p>
        //          <--- maybe here (after)
        // </p>
        //
        // ---
        //
        // <p>
        //     <p>element0</p>
        //          <--- maybe here (in-end)
        // </p>
        // <p>old</p>
        // <p>
        //          <--- maybe here (in-start)
        //     <p>element1</p>
        // </p>

        const new_location = decodeElementLocation(&body_iter) orelse return error.InvalidPost;

        const old_start_index = findNthTagIndex(file_contents, location.element_tag, location.element_index) orelse return error.InvalidPost;
        const old_closing_index = findClosingTag(file_contents, location.element_tag, old_start_index) orelse return error.MalformedHtml;
        const old_indentation = leadingSpaces(file_contents, old_start_index);
        const old_html = file_contents[old_start_index..old_closing_index];

        const new_start_index = findNthTagIndex(file_contents, new_location.element_tag, new_location.element_index) orelse return error.InvalidPost;
        const new_closing_index = findClosingTag(file_contents, new_location.element_tag, new_start_index) orelse return error.MalformedHtml;
        const new_indentation = leadingSpaces(file_contents, new_start_index);

        switch (placement) {
            .before => {
                // new placement comes first
                try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[0..new_start_index]));
                try writer.interface.writeByte('\n');

                try writeIndented(&writer.interface, old_html, new_indentation, old_indentation);
                try writer.interface.splatByteAll(' ', new_indentation);

                // already trimmed before new_start_index, only trim before old_start_index
                try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[new_start_index..old_start_index]));
                try writer.interface.writeByte('\n');

                try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[old_closing_index..]));
            },
            .in_end => {
                // new placement comes first
                // only valid for non-void elements, but it's not possible to place an element inside of those so this is fine here
                const new_closing_tag_length = new_location.element_tag.len + "</>".len;
                try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[0 .. new_closing_index - new_closing_tag_length]));
                try writer.interface.writeByte('\n');

                try writeIndented(&writer.interface, old_html, new_indentation + 4, old_indentation);
                try writer.interface.splatByteAll(' ', new_indentation);

                // already trimmed before new_closing_index, only trim before old_start_index
                try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[new_closing_index - new_closing_tag_length .. old_start_index]));
                try writer.interface.writeByte('\n');

                try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[old_closing_index..]));
            },
            .after => {
                // old element comes first; remove it
                try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[0..old_start_index]));
                try writer.interface.writeByte('\n');
                try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[old_closing_index..new_closing_index]));

                try writer.interface.writeByte('\n');

                try writeIndented(&writer.interface, old_html, new_indentation, old_indentation);

                try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[new_closing_index..]));
            },
            .in_start => {
                // old element comes first; remove it
                const after_start = 1 + (std.mem.indexOfScalarPos(u8, file_contents, new_start_index, '>') orelse return error.MalformedHtml);

                try writer.interface.writeAll(trimLeadingEmptyLine(file_contents[0..old_start_index]));
                try writer.interface.writeByte('\n');
                try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[old_closing_index..after_start]));

                try writer.interface.writeByte('\n');

                try writeIndented(&writer.interface, old_html, new_indentation + 4, old_indentation);

                try writer.interface.writeAll(trimTrailingEmptyLine(file_contents[after_start..]));
            },
        }
    } else {
        return error.InvalidPost;
    }

    try writer.interface.flush();

    try request.respond("", .{ .status = .ok });
}

const SerializableLocation = struct {
    element_tag: []const u8,
    is_alert: bool,
    element_index: usize,
};
fn decodeElementLocation(iter: *std.mem.SplitIterator(u8, .scalar)) ?SerializableLocation {
    const element_tag = iter.next() orelse return null;
    const is_alert_string = iter.next() orelse return null;
    const element_index_string = iter.next() orelse return null;

    const is_alert = if (std.mem.eql(u8, is_alert_string, "alert")) blk: {
        break :blk true;
    } else if (std.mem.eql(u8, is_alert_string, "not-alert")) blk: {
        break :blk false;
    } else {
        return null;
    };

    const element_index = std.fmt.parseInt(usize, element_index_string, 10) catch return null;
    return .{
        .element_tag = element_tag,
        .is_alert = is_alert,
        .element_index = element_index,
    };
}

fn writeIndented(writer: *std.Io.Writer, text: []const u8, spaces: usize, skip_space: ?usize) !void {
    var iter = std.mem.splitScalar(u8, text, '\n');

    const skip = skip_space orelse 0;
    while (iter.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        try writer.splatByteAll(' ', spaces);

        if (skip < line.len and std.mem.allEqual(u8, line[0..skip], ' ')) {
            try writer.writeAll(line[skip..]);
        } else {
            // failsafe; skip_space would have deleted potentially important content
            try writer.writeAll(line);
        }
        try writer.writeByte('\n');
    }
}

/// removes leading spaces (at the end of the contents), a new line, and trailing spaces on the previous line
fn trimLeadingEmptyLine(contents: []const u8) []const u8 {
    const start = std.mem.trimEnd(u8, contents, " ");
    if (start[start.len - 1] == '\n') {
        // trim trailing whitespace
        return std.mem.trimEnd(u8, start[0 .. start.len - 1], " ");
    } else {
        return start[0..start.len];
    }
}
/// removes trailing spaces (at the start of the contents), and a newline if it exists
fn trimTrailingEmptyLine(contents: []const u8) []const u8 {

    // cases
    //
    // trailing space \n
    //
    // line then space\n
    // data
    //
    // trailing space and line \n
    // data

    const start = std.mem.trimStart(u8, contents, " ");
    if (start[0] == '\n') {
        // trim leading whitespace
        return start[1..];
    } else {
        return start;
    }
}

fn findNthTagIndex(contents: []const u8, tag: []const u8, n: usize) ?usize {
    std.debug.assert(tag.len <= 32 - 1);
    var buffer: [32]u8 = undefined;
    buffer[0] = '<';
    @memcpy(buffer[1..][0..tag.len], tag);
    const slice = buffer[0 .. tag.len + 1];

    var counter: usize = 0;
    var after_last: usize = 0;
    while (std.mem.indexOfPos(u8, contents, after_last, slice)) |index| {
        after_last = index + 1;
        if (contents[index + slice.len] != ' ' and contents[index + slice.len] != '>') {
            continue;
        }
        if (counter == n) {
            return index;
        }
        counter += 1;
    }
    return null;
}

fn isAnyString(str: []const u8, strings: []const []const u8) bool {
    for (strings) |str0| {
        if (std.mem.eql(u8, str, str0)) {
            return true;
        }
    }
    return false;
}

/// returns an index into contents exactly 1 byte after the `>` at the end of the closing tag
fn findClosingTag(contents: []const u8, tag: []const u8, tag_start: usize) ?usize {
    std.debug.assert(tag.len <= 32 - 3);

    // void elements
    // https://developer.mozilla.org/en-US/docs/Glossary/Void_element
    if (isAnyString(tag, &.{
        "area",
        "base",
        "br",
        "col",
        "embed",
        "hr",
        "img",
        "input",
        "link",
        "meta",
        "source",
        "track",
        "wbr",
    })) {
        return if (std.mem.indexOfScalarPos(u8, contents, tag_start + 1, '>')) |i| i + 1 else null;
    }

    var buffer0: [32]u8 = undefined;
    buffer0[0] = '<';
    @memcpy(buffer0[1..][0..tag.len], tag);
    const start_query = buffer0[0 .. tag.len + 1];

    var buffer1: [32]u8 = undefined;
    buffer1[0] = '<';
    buffer1[1] = '/';
    @memcpy(buffer1[2..][0..tag.len], tag);
    buffer1[2 + tag.len] = '>';
    const end_query = buffer1[0 .. tag.len + 3];

    return if (findClosingTag2(contents, tag_start + 1, start_query, end_query, 0)) |i| i + end_query.len else null;
}
fn findClosingTag2(contents: []const u8, start: usize, start_query: []const u8, end_query: []const u8, depth: usize) ?usize {
    const closing_tag = std.mem.indexOfPos(u8, contents, start, end_query) orelse return null;
    const start_tag_opt = std.mem.indexOfPos(u8, contents[0..closing_tag], start, start_query);
    if (start_tag_opt) |start_tag| {
        return findClosingTag2(contents, start_tag + 1, start_query, end_query, depth + 1);
    }
    if (depth > 0) {
        return findClosingTag2(contents, closing_tag + 1, start_query, end_query, depth - 1);
    }
    return closing_tag;
}

test findClosingTag {
    const case0 = "<p> <p> </p> </p>";
    const indx0 = "<p> <p> </p> </p>".len;
    try std.testing.expectEqual(indx0, findClosingTag(case0, "p", 0));

    const case1 = "<img-fitted> <img-fitted> <img-fitted></img-fitted> </img-fitted> </img-fitted>";
    const indx1 = "<img-fitted> <img-fitted> <img-fitted></img-fitted> </img-fitted> </img-fitted>".len;
    try std.testing.expectEqual(indx1, findClosingTag(case1, "img-fitted", 0));

    const case2 = "<p> <p> <p></p> </p> </p>";
    const indx2 = "<p> <p> <p></p> </p> </p>".len;
    try std.testing.expectEqual(indx2, findClosingTag(case2, "p", 0));

    const case3 = "<p> <p> </p> <p> </p> </p> - <p> </p>";
    const indx3 = "<p> <p> </p> <p> </p> </p>".len;
    try std.testing.expectEqual(indx3, findClosingTag(case3, "p", 0));

    const case4 = "<p> <p></p> <p>x</p> </p> - <p></p>";
    const indx4 = "<p> <p></p> <p>x</p> </p>".len;
    try std.testing.expectEqual(indx4, findClosingTag(case4, "p", 0));

    const case5 = "<p> </p> <p> </p>";
    const indx5 = "<p> </p>".len;
    try std.testing.expectEqual(indx5, findClosingTag(case5, "p", 0));

    const case6 = "<img src=\"file.png\">";
    const indx6 = "<img src=\"file.png\">".len;
    try std.testing.expectEqual(indx6, findClosingTag(case6, "img", 0));

    // <p> <p> </p> </p> - correct
    //  1   2   3   ^
    //  0   1   0
    // <p> <p> <p></p> </p> </p> - correct
    //  1   2   3   4    5    ^
    //  0   1   2   1    0
    // <p> <p> </p> <p> </p> </p> -
    // <p> </p> <p> </p> - correct
    //  ^ start
}

fn leadingSpaces(contents: []const u8, index: usize) usize {
    const line_start = if (std.mem.lastIndexOfScalar(u8, contents[0..index], '\n')) |i| i + 1 else 0;
    const spaces_end = std.mem.indexOfNonePos(u8, contents, line_start, " ") orelse contents.len;
    return spaces_end - line_start;
}

fn findHtml(io: std.Io, gpa: std.mem.Allocator, site_dir: []const u8, relative: []const u8) error{ UnsafePath, NotFound, OutOfMemory }!struct { std.Io.File, []const u8 } {
    if (hasDirectoryTraversal(relative)) {
        return error.UnsafePath;
    }

    const suffix = blk: {
        if (relative.len == 0 or relative[relative.len - 1] == '/')
            break :blk "index.html";
        if (std.fs.path.extension(relative).len == 0)
            break :blk ".html";
        break :blk "";
    };
    var path = try std.mem.join(gpa, "", &.{ site_dir, "/", relative, suffix });
    errdefer gpa.free(path);

    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| blk1: {
        if (relative.len == 0 or relative[relative.len - 1] == '/') {
            std.debug.print("404 not found ({t}) {s}\n", .{ e, path });

            return error.NotFound;
        }
        gpa.free(path);
        path = try std.mem.join(gpa, "", &.{ site_dir, "/", relative, "/index.html" });

        break :blk1 std.Io.Dir.cwd().openFile(io, path, .{}) catch |e1| {
            std.debug.print("404 not found ({t}, {t}) {s}\n", .{ e, e1, path });

            return error.NotFound;
        };
    };

    return .{ file, path };
}

fn handleGet(request: *std.http.Server.Request, state: *State) !void {
    if (request.head.target.len == 0 or request.head.target[0] != '/') {
        std.debug.print("404: no leading '/'\n", .{});
        try request.respond("404 not found", .{ .status = .not_found });

        return;
    }

    const page = request.head.target[1..]; // ignore leading `/`

    if (std.mem.eql(u8, page, "editor.css")) {
        try request.respond(inject_editor_css, .{
            .extra_headers = &.{
                .{
                    .name = "Content-Type",
                    .value = "text/css",
                },
            },
        });
        return;
    } else if (std.mem.eql(u8, page, "editor.js")) {
        try request.respond(inject_editor_js, .{
            .extra_headers = &.{
                .{
                    .name = "Content-Type",
                    .value = "text/javascript",
                },
            },
        });
        return;
    } else if (std.mem.eql(u8, page, "quill.snow.css")) {
        try request.respond(quill_snow_css, .{
            .extra_headers = &.{
                .{
                    .name = "Content-Type",
                    .value = "text/css",
                },
            },
        });
        return;
    }

    const file, const path = findHtml(state.io, state.gpa, state.site_dir.?, page) catch |e| switch (e) {
        error.UnsafePath => {
            std.debug.print("not sending; path failed hasDirectoryTraversal: {s}\n", .{page});
            try request.respond("404 not found", .{ .status = .not_found });

            return;
        },
        error.NotFound => {
            try request.respond("404 not found", .{ .status = .not_found });
            return;
        },
        error.OutOfMemory => {
            return e;
        },
    };
    defer file.close(state.io);
    defer state.gpa.free(path);

    std.debug.print("sending {s}\n", .{path});
    var reader = file.reader(state.io, &.{});
    // no file should be >64MB
    const file_contents = try reader.interface.allocRemaining(state.gpa, .limited(1024 * 1024 * 64));
    defer state.gpa.free(file_contents);

    const extension = std.fs.path.extension(path);
    const mime = blk: {
        if (std.mem.eql(u8, extension, ".html"))
            break :blk "text/html";
        if (std.mem.eql(u8, extension, ".css"))
            break :blk "text/css";
        if (std.mem.eql(u8, extension, ".js"))
            break :blk "text/javascript";
        if (std.mem.eql(u8, extension, ".svg"))
            break :blk "image/svg+xml";
        if (std.mem.eql(u8, extension, ".jpg"))
            break :blk "image/jpg";
        if (std.mem.eql(u8, extension, ".avif"))
            break :blk "image/avif";
        if (std.mem.eql(u8, extension, ".png"))
            break :blk "image/png";
        if (std.mem.eql(u8, extension, ".webp"))
            break :blk "image/webp";
        if (std.mem.eql(u8, extension, ".woff2"))
            break :blk "font/woff2";
        if (std.mem.eql(u8, extension, ".pdf"))
            break :blk "application/pdf";
        return error.UnknownFileExtension;
    };

    if (state.site_mode == .editor and std.mem.eql(u8, extension, ".html")) blk: {
        const index_start = std.mem.indexOf(u8, file_contents, "</title>\n") orelse {
            std.debug.print("unable to find end of title tag (cannot initialize editor)\n", .{});
            break :blk;
        };
        const index = index_start + "</title>\n".len;
        const append = (
            \\    <script type="module" src="/editor.js"></script>
            \\    <link rel="stylesheet" href="/editor.css">
            \\
        );
        const response = try std.mem.join(state.gpa, "", &.{ file_contents[0..index], append, file_contents[index..] });
        defer state.gpa.free(response);
        try request.respond(response, .{
            .extra_headers = &.{
                .{
                    .name = "Content-Type",
                    .value = mime,
                },
            },
        });
    } else {
        try request.respond(file_contents, .{
            .extra_headers = &.{
                .{
                    .name = "Content-Type",
                    .value = mime,
                },
            },
        });
    }
}

fn stopHosting(context: Webview.BindContext, state: *State) void {
    if (state.thread == null) {
        return;
    }

    state.shutdown.store(true, .monotonic);
    state.io.vtable.netShutdown(state.io.userdata, state.tcp_server.socket.handle, .both) catch |e| std.debug.panic("{t}", .{e});
    state.thread.?.join();
    state.thread = null;

    context.returnValue({}) catch |e| {
        std.debug.panic("unrecoverable error: {t}\n", .{e});
    };
}

// from https://github.com/ziglang/zig/pull/24729, MIT-licensed
/// Checks if a path contains directory traversal sequences that could escape
/// from a base directory. This includes:
/// - Paths starting with "/" (absolute paths on Unix)
/// - Paths starting with "\" (absolute paths on Windows)
/// - Paths containing ".." components that could traverse up directories
/// - On Windows: paths with drive letters (e.g., "C:")
/// - On Windows: UNC paths (e.g., "\\server\share")
/// - On Windows: reserved device names (CON, PRN, AUX, NUL, COM1-9, LPT1-9, etc.)
///
/// This function is useful for validating untrusted paths from archives (zip, tar),
/// network requests, or user input to prevent directory traversal attacks.
///
/// Returns true if the path is potentially dangerous, false if it's safe.
pub fn hasDirectoryTraversal(path: []const u8) bool {
    const native_os = builtin.target.os.tag;
    const mem = std.mem;

    // Empty paths are considered safe
    if (path.len == 0) return false;

    // Check for absolute paths
    if (path[0] == '/' or path[0] == '\\') return true;

    // Windows-specific checks
    if (native_os == .windows or native_os == .uefi) {
        // Check for drive letters
        if (path.len >= 2 and path[1] == ':') return true;

        // Check for Windows reserved device names
        // These names are reserved in all directories, with or without extensions
        var it = mem.tokenizeAny(u8, path, "/\\");
        while (it.next()) |component| {
            // Get the base name without extension
            const dot_index = mem.indexOfScalar(u8, component, '.');
            const base_name = if (dot_index) |idx| component[0..idx] else component;

            // Check if it's a reserved name (case-insensitive)
            if (isWindowsReservedName(base_name)) return true;
        }
    }

    // Check for ".." components in the path
    // We need to handle both forward and backward slashes
    for (0..path.len) |index| {
        // Check if we're at the start of a path component
        const is_start = index == 0 or path[index - 1] == '/' or path[index - 1] == '\\';

        if (is_start and index + 2 <= path.len and
            path[index] == '.' and path[index + 1] == '.')
        {
            // Check if ".." is the whole component
            const is_end = index + 2 == path.len or
                path[index + 2] == '/' or
                path[index + 2] == '\\';
            if (is_end) return true;
        }
    }

    return false;
}
fn isWindowsReservedName(name: []const u8) bool {
    // Windows reserved device names (case-insensitive)
    const reserved_names = [_][]const u8{
        "CON",  "PRN",  "AUX",  "NUL",
        "COM1", "COM2", "COM3", "COM4",
        "COM5", "COM6", "COM7", "COM8",
        "COM9", "LPT1", "LPT2", "LPT3",
        "LPT4", "LPT5", "LPT6", "LPT7",
        "LPT8", "LPT9",
    };

    for (reserved_names) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return true;
    }

    return false;
}

fn retrieveBackups(context: Webview.BindContext, io: std.Io, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) void {
    const listing = retrieveBackups2(io, gpa, environ_map) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };
    defer {
        for (listing) |entry| {
            gpa.free(entry);
        }
        gpa.free(listing);
    }
    context.returnValue(listing) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn retrieveBackups2(io: std.Io, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const []const u8 {
    const generic_data_folder = (known_folders.open(io, gpa, environ_map, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.createDirPathOpen(io, "montecito-site-backups", .{ .open_options = .{ .iterate = true } }) catch return error.FailedToOpenBackupsFolder;
    var iter = backups_folder.iterate();

    var listing: std.ArrayList([]const u8) = .empty;
    defer listing.deinit(gpa);
    errdefer {
        for (listing.items) |entry| {
            gpa.free(entry);
        }
    }

    while (try iter.next(io)) |backup| {
        if (backup.kind != .directory) {
            continue;
        }
        if (!std.mem.startsWith(u8, backup.name, "backup-")) {
            continue;
        }
        try listing.ensureUnusedCapacity(gpa, 1);
        listing.appendAssumeCapacity(try gpa.dupe(u8, backup.name));
    }

    std.mem.sortUnstable([]const u8, listing.items, {}, struct {
        fn inner(_: void, lhs: []const u8, rhs: []const u8) bool {
            // descending sort
            return !std.mem.lessThan(u8, lhs, rhs);
        }
    }.inner);

    return listing.toOwnedSlice(gpa);
}

fn makeBackup(context: Webview.BindContext, state: *State) void {
    if (state.site_dir == null) {
        context.returnError("No site build or master copy found; cannot backup.") catch |e| {
            std.debug.panic("unrecoverable error: {t}", .{e});
        };
        return;
    }

    makeBackup2(state) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue({}) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn makeBackup2(state: *State) !void {
    const time = std.Io.Timestamp.now(state.io, .real);
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @abs(time.toSeconds()) };
    const day_seconds = seconds.getDaySeconds();
    const epoch_day = seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var name: std.Io.Writer.Allocating = .init(state.gpa);
    defer name.deinit();

    try name.writer.print("backup-{}-{:0>2}-{:0>2}T{:0>2}.{:0>2}.{:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
    var source_dir = try std.Io.Dir.cwd().openDir(state.io, state.site_dir.?, .{ .iterate = true });
    defer source_dir.close(state.io);

    const generic_data_folder = (known_folders.open(state.io, state.gpa, state.environ_map, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir(state.io, "montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;
    try copyDirectory(state.io, state.gpa, source_dir, backups_folder, name.written());
}

fn restoreBackup(context: Webview.BindContext, name: []const u8, state: *State) void {
    restoreBackup2(state.io, state.gpa, state.environ_map, name) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue({}) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn restoreBackup2(io: std.Io, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map, name: []const u8) !void {
    const generic_data_folder = (known_folders.open(io, gpa, environ_map, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir(io, "montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;

    const backup = try backups_folder.openDir(io, name, .{ .iterate = true });

    try backups_folder.deleteTree(io, "master-copy-temp");
    try backups_folder.rename("master-copy", backups_folder, "master-copy-temp", io);
    try copyDirectory(io, gpa, backup, backups_folder, "master-copy");
}

fn deleteBackup(context: Webview.BindContext, name: []const u8, state: *State) void {
    deleteBackup2(state.io, state.gpa, state.environ_map, name) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue({}) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn deleteBackup2(io: std.Io, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map, name: []const u8) !void {
    const generic_data_folder = (known_folders.open(io, gpa, environ_map, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir(io, "montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;

    try backups_folder.deleteTree(io, name);
}

fn renameBackup(context: Webview.BindContext, args: struct { old_name: []const u8, new_name: []const u8 }, state: *State) void {
    renameBackup2(state.io, state.gpa, state.environ_map, args.old_name, args.new_name) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue({}) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn renameBackup2(io: std.Io, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map, old_name: []const u8, new_name: []const u8) !void {
    const generic_data_folder = (known_folders.open(io, gpa, environ_map, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir(io, "montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;

    const actual_new_name = try std.mem.join(gpa, "", &.{ "backup-", new_name });
    defer gpa.free(actual_new_name);
    try backups_folder.rename(old_name, backups_folder, actual_new_name, io);
}

fn importWebsiteCopy(context: Webview.BindContext, state: *State) void {
    const cancelled = importWebsiteCopy2(state.io, state.gpa, state.environ_map) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue(.{ .cancelled = cancelled }) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn importWebsiteCopy2(io: std.Io, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !bool {
    const self_dir: ?[]const u8 = std.process.executableDirPathAlloc(io, gpa) catch null;
    defer if (self_dir) |d| gpa.free(d);

    const default_dir: ?[:0]const u8 = if (self_dir) |d| blk: {
        var buf = try gpa.alloc(u8, d.len + 1);
        @memcpy(buf[0..d.len], d);
        buf[buf.len - 1] = 0;
        break :blk buf[0 .. buf.len - 1 :0];
    } else null;
    defer if (default_dir) |d| gpa.free(d);

    const picked = try filesystem_dialog.openDirectoryPicker(gpa, default_dir) orelse return true;
    defer gpa.free(picked);

    const generic_data_folder = (known_folders.open(io, gpa, environ_map, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    defer generic_data_folder.close(io);
    const backups_folder = generic_data_folder.openDir(io, "montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;
    defer backups_folder.close(io);

    var source = try std.Io.Dir.cwd().openDir(io, picked, .{ .iterate = true });
    defer source.close(io);

    // move master-copy into backup
    try backups_folder.deleteTree(io, "backup-master-copy-pre-import");
    backups_folder.rename("master-copy", backups_folder, "backup-master-copy-pre-import", io) catch |e| switch (e) {
        error.FileNotFound => {}, // master copy does not exist; not an error
        else => return e,
    };

    try copyDirectory(io, gpa, source, backups_folder, "master-copy");

    return false;
}


fn exportWebsite(context: Webview.BindContext, state: *State) void {
    const cancelled = exportWebsite2(state.io, state.gpa, state.environ_map) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue(.{ .cancelled = cancelled }) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn exportWebsite2(io: std.Io, gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) !bool {
    const picked = try filesystem_dialog.openDirectoryPicker(gpa, null) orelse return true;
    defer gpa.free(picked);

    const generic_data_folder = (known_folders.open(io, gpa, environ_map, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    defer generic_data_folder.close(io);
    const master_copy = generic_data_folder.openDir(io, "montecito-site-backups/master-copy", .{ .iterate = true }) catch return error.FailedToOpenMasterCopy;
    defer master_copy.close(io);

    var destination = try std.Io.Dir.cwd().openDir(io, picked, .{});
    defer destination.close(io);



    var walker = try master_copy.walk(gpa);
    defer walker.deinit();

    var buffer_reader: [1024]u8 = undefined;
    var buffer_writer: [1024]u8 = undefined;
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (std.mem.endsWith(u8, entry.basename, ".html")) {
                    const in = try entry.dir.openFile(io, entry.basename, .{});
                    var reader = in.reader(io, &buffer_reader);
                    const out = try destination.createFile(io, entry.path, .{});
                    defer out.close(io);
                    var writer = out.writer(io, &buffer_writer);

                    while (true) {
                        _ = reader.interface.streamDelimiter(&writer.interface, '<') catch |e| switch (e) {
                            error.EndOfStream => {
                                std.debug.print("MissingTitle: {s}\n", .{entry.path});
                                return error.MissingTitle;
                            },
                            else => return e,
                        };
                        const next = reader.interface.peek("<title>".len) catch |e| switch (e) {
                            error.EndOfStream => {
                                std.debug.print("MissingTitle 2: {s}\n", .{entry.path});
                                return error.MissingTitle;
                            },
                            else => return e,
                        };
                        if (std.mem.eql(u8, next, "<title>")) {
                            break;
                        }
                        try reader.interface.streamExact(&writer.interface, 1);
                    }
                    try writer.interface.writeAll("<meta name=\"robots\" content=\"noindex\">");
                    _ = try reader.interface.streamRemaining(&writer.interface);
                } else {
                    entry.dir.copyFile(entry.basename, destination, entry.path, io, .{}) catch |e| {
                        std.debug.print("failed to copy file '{s}' {t}\n", .{ entry.path, e });
                        return e;
                    };
                }
            },
            .directory => {
                destination.createDir(io, entry.path, .default_dir) catch |e| {
                    std.debug.print("failed to make directory '{s}' {t}\n", .{ entry.path, e });
                    return e;
                };
            },
            else => continue,
        }
    }

    return false;
}

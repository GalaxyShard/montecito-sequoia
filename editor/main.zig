const std = @import("std");
const builtin = @import("builtin");
const Webview = @import("Webview");
const known_folders = @import("known-folders");
const filesystem_dialog = @import("filesystem-dialog");

const clipboard = @import("clipboard");

const app_html = @embedFile("index.html");

const State = struct {
    // main thread deinitializes, server thread appends, server-client threads remove
    mutex: std.Thread.Mutex = .{},
    clients: std.ArrayList(struct { stream: std.net.Stream, thread: std.Thread, id: usize }) = .empty,

    // used by main thread only
    thread: ?std.Thread,

    // used by server-thread only
    tcp_server: std.net.Server,

    // used by server-client threads
    site_dir: ?[]const u8,

    // used by all threads
    alloc: std.mem.Allocator,
    shutdown: std.atomic.Value(bool) = .init(false),

    site_mode: enum { editor, production },
};

fn copyDirectory(alloc: std.mem.Allocator, source: std.fs.Dir, dest_parent: std.fs.Dir, dest_subdir: []const u8) !void {
    copyDirectory2(alloc, source, dest_parent, dest_subdir) catch |e| {
        dest_parent.deleteTree(dest_subdir) catch |e2| {
            std.debug.print("error creating tree & error deleting tree: {t} {t}\n", .{ e, e2 });
        };
        return e;
    };
}
fn copyDirectory2(alloc: std.mem.Allocator, source: std.fs.Dir, dest_parent: std.fs.Dir, dest_subdir: []const u8) !void {
    var dest = try dest_parent.makeOpenPath(dest_subdir, .{});
    defer dest.close();

    var walker = try source.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file => {
                entry.dir.copyFile(entry.basename, dest, entry.path, .{}) catch |e| {
                    std.debug.print("failed to copy file '{s}' {t}\n", .{ entry.path, e });
                    return e;
                };
            },
            .directory => {
                dest.makeDir(entry.path) catch |e| {
                    std.debug.print("failed to make directory '{s}' {t}\n", .{ entry.path, e });
                    return e;
                };
            },
            else => continue,
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const alloc = gpa.allocator();

    try filesystem_dialog.init();

    const webview = Webview.init(builtin.mode == .Debug, null) orelse return error.FailedToCreateWebview;
    defer webview.destroy();

    try webview.setTitle("Montecito Site Editor");
    try webview.setSize(1024, 720, .none);
    try webview.setHtml(app_html);

    const site_dir: ?[]const u8 = blk: {
        const generic_data_path = (known_folders.getPath(alloc, .data) catch break :blk null) orelse break :blk null;
        defer alloc.free(generic_data_path);

        var generic_data_folder = std.fs.cwd().makeOpenPath(generic_data_path, .{}) catch break :blk null;
        defer generic_data_folder.close();

        generic_data_folder.access("montecito-site-backups/master-copy", .{ .mode = .read_write }) catch |e| switch (e) {
            error.FileNotFound => {
                const self_dir = std.fs.selfExeDirPathAlloc(alloc) catch break :blk null;
                defer alloc.free(self_dir);

                const site_build_path = try std.fs.path.join(alloc, &.{ self_dir, "site-build" });
                defer alloc.free(site_build_path);

                var site_dir = std.fs.cwd().openDir(site_build_path, .{ .iterate = true }) catch break :blk null;
                defer site_dir.close();

                copyDirectory(alloc, site_dir, generic_data_folder, "montecito-site-backups/master-copy") catch break :blk null;
            },
            else => break :blk null,
        };
        break :blk try std.fs.path.join(alloc, &.{ generic_data_path, "montecito-site-backups", "master-copy" });
    };

    var state: State = .{
        .thread = null,
        .tcp_server = undefined,
        .site_mode = undefined,
        .alloc = alloc,
        .site_dir = site_dir,
    };
    defer if (state.site_dir) |s| alloc.free(s);
    defer state.clients.deinit(state.alloc);

    const host_site = try webview.bind(alloc, "backendHostSite", &hostSite, .{&state});
    defer host_site.deinit();

    const stop_hosting = try webview.bind(alloc, "backendStopHosting", &stopHosting, .{&state});
    defer stop_hosting.deinit();

    const copy_to_clipboard = try webview.bind(alloc, "backendCopyToClipboard", &copyToClipboard, .{});
    defer copy_to_clipboard.deinit();

    const retrieve_backups = try webview.bind(alloc, "backendRetrieveBackups", &retrieveBackups, .{alloc});
    defer retrieve_backups.deinit();

    const make_backup = try webview.bind(alloc, "backendMakeBackup", &makeBackup, .{&state});
    defer make_backup.deinit();

    const restore_backup = try webview.bind(alloc, "backendRestoreBackup", &restoreBackup, .{});
    defer restore_backup.deinit();

    const delete_backup = try webview.bind(alloc, "backendDeleteBackup", &deleteBackup, .{});
    defer delete_backup.deinit();

    const rename_backup = try webview.bind(alloc, "backendRenameBackup", &renameBackup, .{});
    defer rename_backup.deinit();

    const import_website_copy = try webview.bind(alloc, "backendImportWebsiteCopy", &importWebsiteCopy, .{});
    defer import_website_copy.deinit();

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

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 8192);
    state.tcp_server = address.listen(.{ .reuse_address = true, .force_nonblocking = true }) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("unrecoverable error: {t}\n", .{e2});
        };
        return;
    };
    std.debug.print("port: {}\n", .{state.tcp_server.listen_address.getPort()});
    std.debug.print("site type: {s}\n", .{site_type});

    state.thread = std.Thread.spawn(.{}, serverThread, .{state}) catch |e| std.debug.panic("{t}", .{e});

    context.returnValue(.{ .port = state.tcp_server.listen_address.getPort() }) catch |e| std.debug.panic("{t}", .{e});
}

fn serverThread(state: *State) void {
    state.shutdown.store(false, .monotonic);

    defer {
        std.debug.print("server shutdown\n", .{});
        state.mutex.lock();
        for (state.clients.items) |client| {
            if (std.posix.shutdown(client.stream.handle, .both)) {
                client.thread.join();
                client.stream.close();
            } else |e| {
                std.debug.print("error shutting down client: {t}\n", .{e});
                client.thread.detach();
            }
        }
        state.clients.clearRetainingCapacity();
        state.mutex.unlock();

        state.tcp_server.deinit();
    }

    var id: usize = 0;
    while (true) {
        if (state.shutdown.load(.monotonic)) {
            return;
        }
        const client = state.tcp_server.accept() catch |e| {
            if (state.shutdown.load(.monotonic)) {
                return;
            }
            if (e == error.WouldBlock) {
                // sleep for 10 ms
                std.Thread.sleep(std.time.ns_per_ms * 10);
                continue;
            }
            std.debug.print("error accepting client: {t}\n", .{e});
            continue;
        };
        std.debug.print("client: {}\n", .{id});

        const thread = std.Thread.spawn(.{}, serverThread2, .{ client, id, state }) catch |e| std.debug.panic("{t}", .{e});

        state.mutex.lock();
        state.clients.append(state.alloc, .{
            .stream = client.stream,
            .thread = thread,
            .id = id,
        }) catch |e| {
            state.mutex.unlock();
            std.debug.panic("{t}", .{e});
        };
        state.mutex.unlock();

        id += 1;
    }
}
fn serverThread2(client: std.net.Server.Connection, id: usize, state: *State) void {
    serverThread3(client, id, state) catch |e| std.debug.print("server error: {t}\n client id: {}\n", .{ e, id });
}
fn serverThread3(client: std.net.Server.Connection, id: usize, state: *State) !void {
    defer {
        std.debug.print("client disconnect {}\n", .{id});

        if (!state.shutdown.load(.monotonic)) {
            state.mutex.lock();
            const index: usize = blk: for (0..state.clients.items.len) |i| {
                if (state.clients.items[i].id == id) {
                    break :blk i;
                }
            } else unreachable;
            _ = state.clients.swapRemove(index);
            client.stream.close();
            state.mutex.unlock();
        }
    }

    var http_in_buffer: [1024 * 8]u8 = undefined;
    var http_out_buffer: [1024 * 32]u8 = undefined;
    var http_writer = client.stream.writer(&http_out_buffer);
    var http_reader = client.stream.reader(&http_in_buffer);

    var http_server = std.http.Server.init(http_reader.interface(), &http_writer.interface);
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
    const body = try body_reader.allocRemaining(state.alloc, .limited(1024 * 1024));
    defer state.alloc.free(body);

    std.debug.print("{s}\n", .{body});

    // replace-element: location and html
    // add-element: location and html
    // remove-element: location ONLY
    // move-element: location, before/after, and location

    var body_iter = std.mem.splitScalar(u8, body, '\n');
    const command = body_iter.next() orelse return error.InvalidPost;
    const get_path = body_iter.next() orelse return error.InvalidPost;
    const location = decodeElementLocation(&body_iter) orelse return error.invalidPost;

    const file_in, const path = findHtml(state.alloc, state.site_dir.?, get_path[1..]) catch |e| switch (e) {
        error.NotFound => return error.InvalidPost,
        error.UnsafePath => return error.InvalidPost,
        error.OutOfMemory => return e,
    };
    defer state.alloc.free(path);

    const file_contents = blk: {
        defer file_in.close();
        var reader = file_in.reader(&.{});
        break :blk try reader.interface.allocRemaining(state.alloc, .limited(1024 * 1024 * 64));
    };
    defer state.alloc.free(file_contents);

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();

    // body_reader is no longer being used; buffer is safe to overwrite
    var writer = file.writer(&buffer);

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

fn findHtml(alloc: std.mem.Allocator, site_dir: []const u8, relative: []const u8) error{ UnsafePath, NotFound, OutOfMemory }!struct { std.fs.File, []const u8 } {
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
    var path = try std.mem.join(alloc, "", &.{ site_dir, "/", relative, suffix });
    errdefer alloc.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch |e| blk1: {
        if (relative.len == 0 or relative[relative.len - 1] == '/') {
            std.debug.print("404 not found ({t}) {s}\n", .{ e, path });

            return error.NotFound;
        }
        alloc.free(path);
        path = try std.mem.join(alloc, "", &.{ site_dir, "/", relative, "/index.html" });

        break :blk1 std.fs.cwd().openFile(path, .{}) catch |e1| {
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
    const file, const path = findHtml(state.alloc, state.site_dir.?, page) catch |e| switch (e) {
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
    defer file.close();
    defer state.alloc.free(path);

    std.debug.print("sending {s}\n", .{path});
    var reader = file.reader(&.{});
    // no file should be >64MB
    const file_contents = try reader.interface.allocRemaining(state.alloc, .limited(1024 * 1024 * 64));
    defer state.alloc.free(file_contents);

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
        const response = try std.mem.join(state.alloc, "", &.{ file_contents[0..index], append, file_contents[index..] });
        defer state.alloc.free(response);
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
    state.thread.?.join();
    state.thread = null;

    context.returnValue(void{}) catch |e| {
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

fn retrieveBackups(context: Webview.BindContext, alloc: std.mem.Allocator) void {
    const listing = retrieveBackups2(alloc) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };
    defer {
        for (listing) |entry| {
            alloc.free(entry);
        }
        alloc.free(listing);
    }
    context.returnValue(listing) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn retrieveBackups2(alloc: std.mem.Allocator) ![]const []const u8 {
    const generic_data_folder = (known_folders.open(alloc, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.makeOpenPath("montecito-site-backups", .{ .iterate = true }) catch return error.FailedToOpenBackupsFolder;
    var iter = backups_folder.iterate();

    var listing: std.ArrayList([]const u8) = .empty;
    defer listing.deinit(alloc);
    errdefer {
        for (listing.items) |entry| {
            alloc.free(entry);
        }
    }

    while (try iter.next()) |backup| {
        if (backup.kind != .directory) {
            continue;
        }
        if (!std.mem.startsWith(u8, backup.name, "backup-")) {
            continue;
        }
        try listing.ensureUnusedCapacity(alloc, 1);
        listing.appendAssumeCapacity(try alloc.dupe(u8, backup.name));
    }

    std.mem.sortUnstable([]const u8, listing.items, {}, struct {
        fn inner(_: void, lhs: []const u8, rhs: []const u8) bool {
            // descending sort
            return !std.mem.lessThan(u8, lhs, rhs);
        }
    }.inner);

    return listing.toOwnedSlice(alloc);
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

    context.returnValue(void{}) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn makeBackup2(state: *State) !void {
    const time = std.time.timestamp();
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @abs(time) };
    const day_seconds = seconds.getDaySeconds();
    const epoch_day = seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    var name: std.Io.Writer.Allocating = .init(state.alloc);
    defer name.deinit();

    try name.writer.print("backup-{}-{:0>2}-{:0>2}T{:0>2}.{:0>2}.{:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
    var source_dir = try std.fs.cwd().openDir(state.site_dir.?, .{ .iterate = true });
    defer source_dir.close();

    const generic_data_folder = (known_folders.open(state.alloc, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir("montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;
    try copyDirectory(state.alloc, source_dir, backups_folder, name.written());
}

fn restoreBackup(context: Webview.BindContext, name: []const u8) void {
    restoreBackup2(context.alloc, name) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue(void{}) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn restoreBackup2(alloc: std.mem.Allocator, name: []const u8) !void {
    const generic_data_folder = (known_folders.open(alloc, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir("montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;

    const backup = try backups_folder.openDir(name, .{ .iterate = true });

    try backups_folder.deleteTree("master-copy-temp");
    try backups_folder.rename("master-copy", "master-copy-temp");
    try copyDirectory(alloc, backup, backups_folder, "master-copy");
}

fn deleteBackup(context: Webview.BindContext, name: []const u8) void {
    deleteBackup2(context.alloc, name) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue(void{}) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn deleteBackup2(alloc: std.mem.Allocator, name: []const u8) !void {
    const generic_data_folder = (known_folders.open(alloc, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir("montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;

    try backups_folder.deleteTree(name);
}

fn renameBackup(context: Webview.BindContext, args: struct { old_name: []const u8, new_name: []const u8 }) void {
    renameBackup2(context.alloc, args.old_name, args.new_name) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue(void{}) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn renameBackup2(alloc: std.mem.Allocator, old_name: []const u8, new_name: []const u8) !void {
    const generic_data_folder = (known_folders.open(alloc, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir("montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;

    const actual_new_name = try std.mem.join(alloc, "", &.{ "backup-", new_name });
    defer alloc.free(actual_new_name);
    try backups_folder.rename(old_name, actual_new_name);
}

fn importWebsiteCopy(context: Webview.BindContext) void {
    const cancelled = importWebsiteCopy2(context.alloc) catch |e| {
        context.returnError(e) catch |e2| {
            std.debug.panic("double error: {t}, {t}", .{ e, e2 });
        };
        return;
    };

    context.returnValue(.{ .cancelled = cancelled }) catch |e| {
        std.debug.panic("error returning: {t}", .{e});
    };
}
fn importWebsiteCopy2(alloc: std.mem.Allocator) !bool {
    const picked = try filesystem_dialog.openDirectoryPicker(alloc) orelse return true;
    defer alloc.free(picked);

    const generic_data_folder = (known_folders.open(alloc, .data, .{}) catch return error.FailedToOpenDataFolder) orelse return error.NoDataFolder;
    const backups_folder = generic_data_folder.openDir("montecito-site-backups", .{}) catch return error.FailedToOpenBackupsFolder;

    var source = try std.fs.cwd().openDir(picked, .{ .iterate = true });
    defer source.close();

    // move master-copy into backup
    try backups_folder.deleteTree("backup-master-copy-pre-import");
    backups_folder.rename("master-copy", "backup-master-copy-pre-import") catch |e| switch (e) {
        error.FileNotFound => {}, // master copy does not exist; not an error
        else => return e,
    };

    try copyDirectory(alloc, source, backups_folder, "master-copy");

    return false;
}

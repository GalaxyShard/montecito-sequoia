const std = @import("std");
const builtin = @import("builtin");
const Webview = @import("Webview");

const clipboard = @import("clipboard");

const html = @embedFile("index.html");

const State = struct {
    thread: ?std.Thread,
    tcp_server: std.net.Server,
    site_dir: []const u8,
    alloc: std.mem.Allocator,
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const alloc = gpa.allocator();

    const webview = Webview.init(builtin.mode == .Debug, null) orelse return error.FailedToCreateWebview;
    defer webview.destroy();

    try webview.setTitle("Montecito Site Editor");
    try webview.setSize(1024, 720, .none);
    try webview.setHtml(html);

    const self_dir = try std.fs.selfExeDirPathAlloc(alloc);
    defer alloc.free(self_dir);

    const site_dir = try std.fs.path.join(alloc, &.{ self_dir, "site-build" });
    defer alloc.free(site_dir);
    std.debug.print("site_dir: {s}\n", .{site_dir});

    var state: State = .{
        .thread = null,
        .tcp_server = undefined,
        .alloc = alloc,
        .site_dir = site_dir,
    };
    const host_site = try webview.bind(alloc, "backendHostSite", &hostSite, .{&state});
    defer host_site.deinit();

    const stop_hosting = try webview.bind(alloc, "backendStopHosting", &stopHosting, .{&state});
    defer stop_hosting.deinit();

    const copy_to_clipboard = try webview.bind(alloc, "backendCopyToClipboard", &copyToClipboard, .{});
    defer copy_to_clipboard.deinit();

    try webview.run();
}

fn copyToClipboard(context: Webview.BindContext, text: []const u8) void {
    _ = context;
    clipboard.write(text) catch |e| std.debug.print("error copying to clipboard: {t}\n", .{e});
}

fn hostSite(context: Webview.BindContext, site_type: []const u8, state: *State) void {
    if (state.thread) |_| {
        return;
    }
    const enable_editor: bool = if (std.mem.eql(u8, site_type, "editor")) blk: {
        break :blk true;
    } else if (std.mem.eql(u8, site_type, "production")) blk: {
        break :blk false;
    } else {
        std.debug.panic("unexpected site type '{s}'", .{site_type});
    };
    _ = enable_editor;

    const address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
    state.tcp_server = address.listen(.{ .reuse_address = true }) catch |e| {
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
    var id: u16 = 0;
    while (true) {
        const client = state.tcp_server.accept() catch |e| {
            std.debug.print("error accepting client: {t}\n", .{e});
            if (e == error.SocketNotListening) {
                break;
            }
            continue;
        };
        std.debug.print("client: {}\n", .{id});
        const thread = std.Thread.spawn(.{}, serverThread2, .{client, id, state}) catch |e| std.debug.panic("{t}", .{e});
        thread.detach();
        id += 1;
    }
}
fn serverThread2(client: std.net.Server.Connection, id: u16, state: *State) void {
    serverThread3(client, state) catch |e| std.debug.print("server error: {t}\n client id: {}\n", .{e, id});
}
fn serverThread3(client: std.net.Server.Connection, state: *State) !void {
    defer {
        std.debug.print("client disconnect\n", .{});
    }
    defer client.stream.close();

    var http_in_buffer: [1024 * 8]u8 = undefined;
    var http_out_buffer: [1024 * 32]u8 = undefined;
    var http_writer = client.stream.writer(&http_out_buffer);
    var http_reader = client.stream.reader(&http_in_buffer);

    var http_server = std.http.Server.init(http_reader.interface(), &http_writer.interface);

    while (true) {
        var request = try http_server.receiveHead();

        const page = request.head.target;
        const path = try std.mem.join(state.alloc, "", &.{ state.site_dir, page });
        defer state.alloc.free(path);

        std.debug.print("sending {s}\n", .{path});
        const file = try std.fs.cwd().openFile(path, .{});
        var reader = file.reader(&.{});
        // no file should be >64MB
        const file_contents = try reader.interface.allocRemaining(state.alloc, .limited(1024 * 1024 * 64));

        try request.respond(file_contents, .{});
    }
}

fn stopHosting(context: Webview.BindContext, state: *State) void {
    if (state.thread == null) {
        return;
    }

    // TODO: implement this function; stop the http server

    context.returnError(void{}) catch |e| {
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

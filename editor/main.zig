const std = @import("std");
const builtin = @import("builtin");
const Webview = @import("Webview");

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

    try webview.run();
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
    while (true) {
        serverThread2(state) catch |e| std.debug.print("server error: {t}\n", .{e});
        std.debug.print("client disconnect\n", .{});
    }
}
fn serverThread2(state: *State) !void {
    const client = try state.tcp_server.accept();
    defer client.stream.close();

    var http_in_buffer: [1024 * 8]u8 = undefined;
    var http_out_buffer: [1024 * 32]u8 = undefined;
    var http_writer = client.stream.writer(&http_out_buffer);
    var http_reader = client.stream.reader(&http_in_buffer);

    var http_server = std.http.Server.init(http_reader.interface(), &http_writer.interface);

    outer: while (true) {
        var request = try http_server.receiveHead();

        const page = request.head.target;
        const path = try std.mem.join(state.alloc, "", &.{ state.site_dir, page });
        defer state.alloc.free(path);

        std.debug.print("sending {s}\n", .{path});
        std.debug.print("allow? (y/n): ", .{});
        const stdin_file = std.fs.File.stdin();
        var stdin = stdin_file.reader(&.{});
        while (true) {
            var stdin_buf: [2]u8 = @splat(0);
            try stdin.interface.readSliceAll(&stdin_buf);
            if (stdin_buf[0] == 'y') {
                std.debug.print("allowed\n", .{});
                break;
            } else if (stdin_buf[0] == 'n') {
                std.debug.print("disallowed\n", .{});
                try request.respond("", .{ .status = .not_found });
                continue :outer;
            } else {
                std.debug.print("expected 'y' or 'n', found '{s}'\n", .{stdin_buf});
            }
        }
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

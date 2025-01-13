const std = @import("std");
const builtin = @import("builtin");
const Webview = @import("Webview");

const html = @embedFile("index.html");

const State = struct {
    thread: ?std.Thread,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const alloc = gpa.allocator();

    const webview = Webview.init(builtin.mode == .Debug, null) orelse return error.FailedToCreateWebview;
    defer webview.destroy();

    try webview.setTitle("Montecito Site Editor");
    try webview.setSize(1024, 720, .none);
    try webview.setHtml(html);

    var state: State = .{
        .thread = null,
    };
    const host_site = try webview.bind(alloc, "backendHostSite", &hostSite, &state);
    defer host_site.deinit();

    const stop_hosting = try webview.bind(alloc, "backendStopHosting", &stopHosting, &state);
    defer stop_hosting.deinit();

    try webview.run();
}

fn hostSite(context: Webview.BindContext, site_type: []const u8, state: *State) void {
    if (state.thread) |_| {
        return;
    }
    const address = std.net.Address.initIp4(.{127,0,0,1}, 0);
    var tcp_server = address.listen(.{ .reuse_address = true }) catch |e| {
        context.returnError(void{}) catch |e2| {
            std.debug.panic("error: {s}\n", .{@errorName(e2)});
        };
        std.debug.panic("error: {s}\n", .{@errorName(e)});
    };
    defer tcp_server.deinit();
    std.debug.print("port: {}\n", .{tcp_server.listen_address.getPort()});
    std.debug.print("site type: {s}\n", .{site_type});

    // TODO: implement http server
}
fn stopHosting(context: Webview.BindContext, state: *State) void {
    if (state.thread) |_| {
        return;
    }
    // TODO: implement this function; stop the http server

    context.returnError(void{}) catch |e| {
        std.debug.panic("error: {s}\n", .{@errorName(e)});
    };
}

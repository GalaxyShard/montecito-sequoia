const std = @import("std");
const generate_html = @import("generate-html.zig");

fn printHelp() void {
    const text = (
        \\Usage: generate-html <input-directory> <output-directory> [template-directories...]
        \\
    );
    std.debug.print(text, .{});
}
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();

    // skip executable path
    if (!args.skip()) {
        printHelp();
        return error.InvalidArguments;
    }

    const input_path = args.next() orelse {
        printHelp();
        return error.NoInputDirectory;
    };
    const output_path = args.next() orelse {
        printHelp();
        return error.NoOutputDirectory;
    };
    var template_paths: std.ArrayList([]const u8) = .empty;
    defer template_paths.deinit(gpa);
    while (args.next()) |arg| {
        try template_paths.append(gpa, arg);
    }

    var input_dir = try std.Io.Dir.cwd().openDir(io, input_path, .{ .iterate = true });
    defer input_dir.close(io);

    try std.Io.Dir.cwd().createDirPath(io, output_path);
    var output_dir = try std.Io.Dir.cwd().openDir(io, output_path, .{});
    defer output_dir.close(io);

    const template_map = try generate_html.generateTemplateMap(io, gpa, template_paths.items);
    defer generate_html.freeTemplateMap(gpa, template_map);

    var walker = try input_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or std.mem.containsAtLeast(u8, entry.path, 1, "template")) {
            continue;
        }

        if (std.fs.path.dirname(entry.path)) |dir| {
            try output_dir.createDirPath(io, dir);
        }

        if (!std.mem.endsWith(u8, entry.basename, ".html")) {
            try entry.dir.copyFile(entry.basename, output_dir, entry.path, io, .{});
            continue;
        }
        // no HTML files larger than 32 MiB
        const size_cap = 1024 * 1024 * 32;
        const file_contents = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(size_cap));
        defer gpa.free(file_contents);

        const output_file = try output_dir.createFile(io, entry.path, .{});
        defer output_file.close(io);

        var buffer: [4096]u8 = undefined;
        var writer = output_file.writer(io, &buffer);

        try generate_html.performReplacementStream(file_contents, .{
            .writer = &writer.interface,
            .template_map = template_map,
        });
    }
}

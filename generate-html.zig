const std = @import("std");

const TemplateMap = std.StringHashMap([]const u8);

const ExpansionError = error{
    UnterminatedExpansion,
    UnknownExpansion,
    WriteFailed
};

const ReplacementOptions = struct {
    writer: std.io.AnyWriter,
    template_map: TemplateMap,
};
const Directive = enum {
    base64,
};
const directive_map = std.StaticStringMap(Directive).initComptime(.{
    .{ "base64", .base64 },
});

fn expand(id: []const u8, options: ReplacementOptions, directive: ?Directive) ExpansionError!bool {
    const template = options.template_map.get(id) orelse {
        std.debug.print("Template not found: {s}\n", .{id});
        return false;
    };
    if (directive) |d| {
        switch (d) {
            .base64 => {
                std.base64.standard.Encoder.encodeWriter(options.writer, template) catch return error.WriteFailed;
            },
        }
    } else {
        options.writer.writeAll(template) catch return error.WriteFailed;
    }
    return true;
}

fn performReplacementStream(original: []const u8, options: ReplacementOptions) ExpansionError!void {
    var buffer: []const u8 = original;
    while (std.mem.indexOf(u8, buffer, "{{")) |start_index| {
        const end_marker_index = std.mem.indexOf(u8, buffer, "}}") orelse return error.UnterminatedExpansion;

        options.writer.writeAll(buffer[0..start_index]) catch return error.WriteFailed;
        var directives = std.mem.splitScalar(u8, buffer[start_index+2..end_marker_index], ':');


        const id = directives.first();
        const directive = blk: {
            const str = directives.next() orelse break :blk null;
            break :blk directive_map.get(str);
        };

        if (!try expand(id, options, directive)) {
            return error.UnknownExpansion;
        }

        buffer = buffer[end_marker_index + 2 ..];
    }
    options.writer.writeAll(buffer) catch return error.WriteFailed;
}

fn printHelp() void {
    const text = (
        \\Usage: generate-html <input-directory> <output-directory> [template-directories...]
        \\
    );
    std.debug.print(text, .{});
}
fn freeTemplateMap(alloc: std.mem.Allocator, map: TemplateMap) void {
    var m = map;
    var iter = m.iterator();
    while (iter.next()) |e| {
        alloc.free(e.key_ptr.*);
        alloc.free(e.value_ptr.*);
    }
    m.deinit();
}
fn generateTemplateMap(alloc: std.mem.Allocator, paths: []const []const u8) !TemplateMap {
    var map = TemplateMap.init(alloc);
    errdefer freeTemplateMap(alloc, map);

    // no files larger than 32 MiB
    const size_cap = 1024*1024*32;

    for (paths) |path| {
        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |e_dir| switch (e_dir) {
            error.NotDir => {
                const file_contents = std.fs.cwd().readFileAlloc(alloc, path, size_cap) catch |e_file| switch (e_file) {
                    error.FileNotFound => std.debug.panic("no file or directory: {s}", .{path}),
                    else => return e_file,
                };
                errdefer alloc.free(file_contents);

                const name = try alloc.dupe(u8, std.fs.path.basename(path));
                errdefer alloc.free(name);

                try map.put(name, file_contents);
                continue;
            },
            error.FileNotFound => std.debug.panic("no file or directory found: {s}", .{path}),
            else => return e_dir,
        };
        defer dir.close();

        var walker = try dir.walk(alloc);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }
            const file_contents = try entry.dir.readFileAlloc(alloc, entry.basename, size_cap);
            errdefer alloc.free(file_contents);

            const path_owned = try alloc.dupe(u8, entry.path);
            errdefer alloc.free(path_owned);

            try map.put(path_owned, file_contents);
        }
    }

    return map;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const alloc = gpa.allocator();
    var args = try std.process.argsWithAllocator(alloc);
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
    var template_paths = std.ArrayList([]const u8).init(alloc);
    defer template_paths.deinit();
    while (args.next()) |arg| {
        try template_paths.append(arg);
    }

    var input_dir = try std.fs.cwd().openDir(input_path, .{ .iterate = true });
    defer input_dir.close();

    try std.fs.cwd().makePath(output_path);
    var output_dir = try std.fs.cwd().openDir(output_path, .{});
    defer output_dir.close();

    const template_map = try generateTemplateMap(alloc, template_paths.items);
    defer freeTemplateMap(alloc, template_map);

    var walker = try input_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file or std.mem.containsAtLeast(u8, entry.path, 1, "template")) {
            continue;
        }

        if (std.fs.path.dirname(entry.path)) |dir| {
            try output_dir.makePath(dir);
        }

        if (!std.mem.endsWith(u8, entry.basename, ".html")) {
            try entry.dir.copyFile(entry.basename, output_dir, entry.path, .{});
            continue;
        }
        // no HTML files larger than 32 MiB
        const size_cap = 1024*1024*32;
        const file_contents = try entry.dir.readFileAlloc(alloc, entry.basename, size_cap);
        defer alloc.free(file_contents);

        const output_file = try output_dir.createFile(entry.path, .{});
        defer output_file.close();

        try performReplacementStream(file_contents, .{
            .writer = output_file.writer().any(),
            .template_map = template_map,
        });
    }
}

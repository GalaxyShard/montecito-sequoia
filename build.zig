const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const editor_step = b.step("editor", "Compile the editor executable");
    const run_editor_step = b.step("run-editor", "Run the editor executable");
    const pnpm_enabled = b.option(bool, "pnpm", "Run pnpm before compiling (default: false)") orelse false;



    const editor = b.addExecutable(.{
        .name = "montecito-site-editor",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("editor/main.zig"),
        }),
    });

    const pnpm = b.findProgram(&.{"pnpm"}, &.{}) catch {
        @panic("pnpm not found in PATH; pnpm is required to perform a full build");
    };
    const run_pnpm = b.addSystemCommand(&.{ pnpm, "run", "build" });



    const generate_html = b.addExecutable(.{
        .name = "generate-html",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
            .root_source_file = b.path("generate-html.zig"),
        }),
    });
    if (pnpm_enabled) {
        generate_html.step.dependOn(&run_pnpm.step);
    }
    b.installArtifact(generate_html);


    const webview = b.dependency("webview", .{
        .target = target,
        .optimize = optimize,
    });
    editor.root_module.addImport("webview", webview.module("webview"));
    editor.linkLibrary(webview.artifact("webview-static"));

    const run_editor = b.addRunArtifact(editor);
    run_editor_step.dependOn(&run_editor.step);

    editor_step.dependOn(&b.addInstallArtifact(editor, .{}).step);
}

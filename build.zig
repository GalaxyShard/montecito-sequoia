const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const editor_step = b.step("editor", "Compile the editor executable");
    const run_editor_step = b.step("run-editor", "Run the editor executable");
    const check_step = b.step("check", "Check for compile errors");
    const pnpm_enabled = b.option(bool, "pnpm", "Run pnpm before compiling (default: true)") orelse true;

    const editor = b.addExecutable(.{
        .name = "montecito-site-editor",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("editor/main.zig"),
        }),
    });
    const check_editor = b.addExecutable(.{
        .name = "check-montecito-site-editor",
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
    // Normally stdout is forwarded, causing errors with
    // the ZLS build runner.
    _ = run_pnpm.captureStdOut();

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

    const generate_site = b.addRunArtifact(generate_html);
    generate_site.addDirectoryArg(b.path("site"));
    const output_site = generate_site.addOutputDirectoryArg("site-build");
    generate_site.addDirectoryArg(b.path("site/template"));

    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = output_site,
        .install_dir = .bin,
        .install_subdir = "site-build",
    }).step);

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("editor/inject/editor.css"),
        .{ .custom = "bin/site-build" },
        "editor.css",
    ).step);

    // note: depends on `pnpm install` having been run
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("node_modules/bootstrap/dist/css/bootstrap.min.css"),
        .{ .custom = "bin/site-build" },
        "bootstrap.min.css",
    ).step);

    // note: depends on `pnpm install` having been run
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("node_modules/quill/dist/quill.snow.css"),
        .{ .custom = "bin/site-build" },
        "quill.snow.css",
    ).step);

    const generate_editor_app = b.addRunArtifact(generate_html);

    // TODO: remove this workaround
    // fixes changed files being used from cache
    // related issue: https://github.com/ziglang/zig/issues/21912
    generate_editor_app.has_side_effects = true;

    generate_editor_app.addDirectoryArg(b.path("editor"));
    const editor_output_files = generate_editor_app.addOutputDirectoryArg("editor-frontend");
    generate_editor_app.addDirectoryArg(b.path("editor"));
    generate_editor_app.addDirectoryArg(b.path("site/assets/logos/montecito.svg"));

    const editor_index_html = editor_output_files.path(b, "index.html");
    editor.root_module.addAnonymousImport("index.html", .{
        .root_source_file = editor_index_html,
    });
    check_editor.root_module.addAnonymousImport("index.html", .{
        // note: this file should normally be processed by generate-html,
        // but this step is only used for checking the Zig code so it doesn't matter
        .root_source_file = b.path("editor/index.html"),
    });

    b.installArtifact(generate_html);

    const webview = b.dependency("webview", .{
        .target = target,
        .optimize = optimize,
    });
    editor.root_module.addImport("clipboard", b.dependency("clipboard", .{}).module("clipboard"));
    editor.root_module.addImport("Webview", webview.module("Webview"));
    check_editor.root_module.addImport("clipboard", b.dependency("clipboard", .{}).module("clipboard"));
    check_editor.root_module.addImport("Webview", webview.module("Webview"));

    const run_editor = b.addRunArtifact(editor);
    run_editor_step.dependOn(&run_editor.step);

    const install_editor = b.addInstallArtifact(editor, .{});
    editor_step.dependOn(&install_editor.step);
    b.getInstallStep().dependOn(editor_step);
    run_editor.step.dependOn(&install_editor.step);

    check_step.dependOn(&check_editor.step);
}

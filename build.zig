const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const editor_step = b.step("editor", "Compile the editor executable");
    const run_editor_step = b.step("run-editor", "Run the editor executable");
    const check_step = b.step("check", "Check for compile errors");
    const test_step = b.step("test", "Test the editor executable");

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

    const generate_html = b.addExecutable(.{
        .name = "generate-html",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{}),
            .optimize = .debug,
            .root_source_file = b.path("generate-html-build.zig"),
        }),
    });

    const pnpm = b.findProgram(.{ .names = &.{"pnpm"} }) orelse {
        @panic("pnpm not found in PATH; pnpm is required to perform a full build");
    };
    const run_pnpm = b.addSystemCommand(&.{ pnpm, "exec", "rollup", "--config" });


    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("site"),
        .install_dir = .bin,
        .install_subdir = "site-build",
    }).step);
    editor.root_module.addAnonymousImport("inject/editor.css", .{
        .root_source_file = b.path("editor/inject/editor.css"),
    });

    // note: depends on `pnpm install` having been run
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("node_modules/bootstrap/dist/css/bootstrap.min.css"),
        .{ .custom = "bin/site-build" },
        "bootstrap.min.css",
    ).step);

    // note: depends on `pnpm install` having been run
    editor.root_module.addAnonymousImport("quill.snow.css", .{
        .root_source_file = b.path("node_modules/quill/dist/quill.snow.css"),
    });

    editor.root_module.addAnonymousImport("inject/editor.js", .{
        .root_source_file = run_pnpm.captureStdOut(.{}),
    });

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
    editor_index_html.addStepDependencies(&editor.step);
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
    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });
    const filesystem_dialog = b.dependency("filesystem_dialog", .{
        .target = target,
        .optimize = optimize,
    });

    inline for (&[_]*std.Build.Step.Compile{ editor, check_editor }) |e| {
        e.root_module.addImport("clipboard", b.dependency("clipboard", .{}).module("clipboard"));
        e.root_module.addImport("Webview", webview.module("Webview"));
        e.root_module.addImport("known-folders", known_folders.module("known-folders"));
        e.root_module.addImport("filesystem-dialog", filesystem_dialog.module("filesystem-dialog"));
    }

    const run_editor = b.addRunArtifact(editor);
    run_editor_step.dependOn(&run_editor.step);

    const editor_tests = b.addTest(.{
        .name = "test-editor",
        .root_module = editor.root_module,
    });
    const run_editor_tests = b.addRunArtifact(editor_tests);
    test_step.dependOn(&run_editor_tests.step);

    const install_editor = b.addInstallArtifact(editor, .{});
    editor_step.dependOn(&install_editor.step);
    b.getInstallStep().dependOn(editor_step);
    run_editor.step.dependOn(&install_editor.step);
    run_editor.step.dependOn(b.getInstallStep());

    check_step.dependOn(&check_editor.step);
}

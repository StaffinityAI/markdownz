const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_dvui = b.option(bool, "dvui", "Enable the DVUI compatibility module, viewer, and tests") orelse false;
    const enable_vaxis = b.option(bool, "vaxis", "Enable the Vaxis viewer and tests") orelse false;
    const enable_http = b.option(bool, "http", "Enable the http.zig web example") orelse false;
    // Off by default so parser-only consumers never fetch uucode. The Vaxis
    // viewer is built on markdown-term, so enabling it enables the module too.
    const enable_terminal = b.option(bool, "terminal", "Expose the markdown-term module, which depends on uucode") orelse enable_vaxis;
    const external_uucode = b.option(bool, "external_uucode", "Expose markdown-term without uucode; the consumer adds its own uucode import") orelse false;

    const markdown = b.addModule("markdown", .{
        .root_source_file = b.path("src/Parser.zig"),
        .target = target,
        .optimize = optimize,
    });
    const markdown_html = b.addModule("markdown-html", .{
        .root_source_file = b.path("src/HtmlRenderer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "markdown", .module = markdown },
        },
    });

    // An external uucode must provide the same fields. libvaxis needs them as
    // well and is built against this module so both measure text the same way.
    const uucode: ?*std.Build.Module = if (enable_terminal and !external_uucode) blk: {
        const uucode_dep = b.lazyDependency("uucode", .{
            .target = target,
            .optimize = optimize,
            .fields = @as([]const []const u8, &.{
                "east_asian_width",
                "grapheme_break",
                "general_category",
                "is_emoji_presentation",
            }),
        }) orelse break :blk null;
        break :blk uucode_dep.module("uucode");
    } else null;
    const markdown_term: ?*std.Build.Module = if (enable_terminal) blk: {
        const module = b.addModule("markdown-term", .{
            .root_source_file = b.path("src/TerminalRenderer.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "markdown", .module = markdown },
            },
        });
        if (uucode) |mod| module.addImport("uucode", mod);
        break :blk module;
    } else null;
    // Terminal tests and examples need the bundled uucode.
    const terminal_unavailable: ?[]const u8 = if (!enable_terminal)
        "markdown-term is disabled; rerun with -Dterminal=true"
    else if (external_uucode)
        "markdown-term uses an external uucode; rerun without -Dexternal_uucode"
    else
        null;
    const default_document = b.createModule(.{
        .root_source_file = b.path("examples/default_document.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .name = "markdown-tests",
        .root_module = markdown,
    });
    const fixture_tests = b.addTest(.{
        .name = "markdown-fixture-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/dvui/all-concepts_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "markdown", .module = markdown },
                .{ .name = "default_document", .module = default_document },
            },
        }),
    });
    const html_tests = b.addTest(.{
        .name = "markdown-html-tests",
        .root_module = markdown_html,
    });
    const test_step = b.step("test", "Run parser tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(fixture_tests).step);
    test_step.dependOn(&b.addRunArtifact(html_tests).step);
    const test_compile_step = b.step("test-compile", "Compile parser tests for the selected target");
    test_compile_step.dependOn(&tests.step);
    test_compile_step.dependOn(&fixture_tests.step);
    test_compile_step.dependOn(&html_tests.step);

    const cli_example_step = b.step("cli-example", "Build the terminal CLI example");
    const run_cli_example_step = b.step("run-cli", "Render markdown to the terminal with the CLI example");

    const viewer_step = b.step("dvui-viewer", "Build the DVUI markdown viewer example");
    const run_viewer_step = b.step("run-gui", "Run the DVUI markdown viewer example");
    const vaxis_viewer_step = b.step("vaxis-viewer", "Build the Vaxis markdown viewer example");
    const run_vaxis_viewer_step = b.step("run-tui", "Run the Vaxis markdown viewer example");
    const web_example_step = b.step("web-example", "Build the http.zig web example");
    const run_web_example_step = b.step("run-web", "Run the http.zig web example");

    if (!enable_dvui) {
        const disabled = b.addFail("DVUI support is disabled; rerun with -Ddvui=true");
        viewer_step.dependOn(&disabled.step);
        run_viewer_step.dependOn(&disabled.step);
    }
    if (!enable_vaxis or terminal_unavailable != null) {
        const disabled = b.addFail(if (enable_vaxis) terminal_unavailable.? else "Vaxis support is disabled; rerun with -Dvaxis=true");
        vaxis_viewer_step.dependOn(&disabled.step);
        run_vaxis_viewer_step.dependOn(&disabled.step);
    }
    if (terminal_unavailable) |message| {
        const disabled = b.addFail(message);
        cli_example_step.dependOn(&disabled.step);
        run_cli_example_step.dependOn(&disabled.step);
    } else if (uucode != null) {
        const term_tests = b.addTest(.{
            .name = "markdown-term-tests",
            .root_module = markdown_term.?,
        });
        test_step.dependOn(&b.addRunArtifact(term_tests).step);
        test_compile_step.dependOn(&term_tests.step);

        const cli_example = b.addExecutable(.{
            .name = "markdown-cli",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/cli/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "markdown-term", .module = markdown_term.? },
                    .{ .name = "default_document", .module = default_document },
                },
            }),
        });
        cli_example_step.dependOn(&cli_example.step);
        const run_cli_example = b.addRunArtifact(cli_example);
        run_cli_example.addPassthruArgs();
        run_cli_example_step.dependOn(&run_cli_example.step);
    }
    if (!enable_http) {
        const disabled = b.addFail("http.zig support is disabled; rerun with -Dhttp=true");
        web_example_step.dependOn(&disabled.step);
        run_web_example_step.dependOn(&disabled.step);
    }

    if (enable_dvui) {
        if (b.lazyDependency("dvui", .{
            .target = b.graph.host,
            .optimize = optimize,
            .backend = .testing,
        })) |dvui_test_dep| {
            const widget_tests = b.addTest(.{
                .name = "markdown-dvui-widget-tests",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/dvui/widget_test.zig"),
                    .target = b.graph.host,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "markdown", .module = markdown },
                        .{ .name = "dvui", .module = dvui_test_dep.module("dvui_testing") },
                    },
                }),
            });
            test_step.dependOn(&b.addRunArtifact(widget_tests).step);
        }
    }

    if (enable_dvui) {
        if (b.lazyDependency("dvui", .{
            .target = target,
            .optimize = optimize,
            .backend = .sdl3,
        })) |dvui_dep| {
            _ = b.addModule("lib", .{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
                    .{ .name = "markdown", .module = markdown },
                },
            });

            const viewer = b.addExecutable(.{
                .name = "markdown-viewer",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/dvui/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "markdown", .module = markdown },
                        .{ .name = "default_document", .module = default_document },
                        .{ .name = "dvui", .module = dvui_dep.module("dvui_sdl3") },
                        .{ .name = "sdl-backend", .module = dvui_dep.module("sdl3") },
                    },
                }),
            });

            viewer_step.dependOn(&viewer.step);

            const viewer_tests = b.addTest(.{
                .name = "markdown-dvui-viewer-tests",
                .root_module = viewer.root_module,
            });
            test_step.dependOn(&b.addRunArtifact(viewer_tests).step);

            const run_viewer = b.addRunArtifact(viewer);
            run_viewer.addPassthruArgs();
            run_viewer_step.dependOn(&run_viewer.step);
        }
    }

    if (enable_vaxis and uucode != null) {
        if (b.lazyDependency("vaxis", .{
            .target = target,
            .optimize = optimize,
            .external_uucode = true,
        })) |vaxis_dep| {
            const vaxis = vaxis_dep.module("vaxis");
            vaxis.addImport("uucode", uucode.?);
            const vaxis_viewer = b.addExecutable(.{
                .name = "markdown-vaxis-viewer",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/vaxis/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "markdown-term", .module = markdown_term.? },
                        .{ .name = "default_document", .module = default_document },
                        .{ .name = "vaxis", .module = vaxis },
                    },
                }),
            });

            vaxis_viewer_step.dependOn(&vaxis_viewer.step);

            const vaxis_tests = b.addTest(.{
                .name = "markdown-vaxis-viewer-tests",
                .root_module = vaxis_viewer.root_module,
            });
            test_step.dependOn(&b.addRunArtifact(vaxis_tests).step);

            const run_vaxis_viewer = b.addRunArtifact(vaxis_viewer);
            run_vaxis_viewer.addPassthruArgs();
            run_vaxis_viewer_step.dependOn(&run_vaxis_viewer.step);
        }
    }

    if (enable_http) {
        if (b.lazyDependency("httpz", .{
            .target = target,
            .optimize = optimize,
        })) |httpz_dep| {
            const web_example = b.addExecutable(.{
                .name = "markdown-web-example",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/web/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "markdown", .module = markdown },
                        .{ .name = "markdown-html", .module = markdown_html },
                        .{ .name = "default_document", .module = default_document },
                        .{ .name = "httpz", .module = httpz_dep.module("httpz") },
                    },
                }),
            });

            web_example_step.dependOn(&web_example.step);
            const run_web_example = b.addRunArtifact(web_example);
            run_web_example_step.dependOn(&run_web_example.step);
        }
    }

    // What CI runs, so `zig build ci` reproduces a CI run. The optional
    // modules sit behind options, so those builds run as nested `zig build`s,
    // one after another so they do not compete for the machine.
    const ci_step = b.step("ci", "Run what CI runs (formatting, then tests with every option)");
    {
        const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("examples") }, .check = true });
        ci_step.dependOn(&fmt.step);
        // Without options, so parser-only consumers never need a lazy dependency.
        ci_step.dependOn(test_step);

        var previous: *std.Build.Step = test_step;
        for ([_][]const []const u8{
            &.{ "test", "cli-example", "vaxis-viewer", "web-example", "dvui-viewer", "-Ddvui=true", "-Dvaxis=true", "-Dhttp=true" },
            &.{ "test", "-Dterminal=true", "-Doptimize=ReleaseSafe" },
            &.{ "test-compile", "-Dterminal=true", "-Dtarget=x86_64-linux-gnu" },
            &.{ "test-compile", "-Dterminal=true", "-Dtarget=aarch64-macos" },
            &.{ "test-compile", "-Dterminal=true", "-Dtarget=x86_64-windows" },
        }) |args| {
            const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build" });
            run.setName(b.fmt("zig build {s}", .{std.mem.join(b.allocator, " ", args) catch @panic("OOM")}));
            run.addArgs(args);
            run.setCwd(b.path("."));
            run.has_side_effects = true;
            run.step.dependOn(previous);
            ci_step.dependOn(&run.step);
            previous = &run.step;
        }
    }
}

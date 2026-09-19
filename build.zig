const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_dvui = b.option(bool, "dvui", "Enable the DVUI compatibility module, viewer, and tests") orelse false;
    const enable_vaxis = b.option(bool, "vaxis", "Enable the Vaxis viewer and tests") orelse false;

    const markdown = b.addModule("markdown", .{
        .root_source_file = b.path("src/Parser.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    const test_step = b.step("test", "Run parser tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(fixture_tests).step);
    const test_compile_step = b.step("test-compile", "Compile parser tests for the selected target");
    test_compile_step.dependOn(&tests.step);
    test_compile_step.dependOn(&fixture_tests.step);

    const viewer_step = b.step("dvui-viewer", "Build the DVUI markdown viewer example");
    const run_viewer_step = b.step("run-gui", "Run the DVUI markdown viewer example");
    const vaxis_viewer_step = b.step("vaxis-viewer", "Build the Vaxis markdown viewer example");
    const run_vaxis_viewer_step = b.step("run-tui", "Run the Vaxis markdown viewer example");

    if (!enable_dvui) {
        const disabled = b.addFail("DVUI support is disabled; rerun with -Ddvui=true");
        viewer_step.dependOn(&disabled.step);
        run_viewer_step.dependOn(&disabled.step);
    }
    if (!enable_vaxis) {
        const disabled = b.addFail("Vaxis support is disabled; rerun with -Dvaxis=true");
        vaxis_viewer_step.dependOn(&disabled.step);
        run_vaxis_viewer_step.dependOn(&disabled.step);
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
            if (b.args) |args| run_viewer.addArgs(args);
            run_viewer_step.dependOn(&run_viewer.step);
        }
    }

    if (enable_vaxis) {
        if (b.lazyDependency("vaxis", .{
            .target = target,
            .optimize = optimize,
        })) |vaxis_dep| {
            const vaxis_viewer = b.addExecutable(.{
                .name = "markdown-vaxis-viewer",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/vaxis/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "markdown", .module = markdown },
                        .{ .name = "default_document", .module = default_document },
                        .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
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
            if (b.args) |args| run_vaxis_viewer.addArgs(args);
            run_vaxis_viewer_step.dependOn(&run_vaxis_viewer.step);
        }
    }
}

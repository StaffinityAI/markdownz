const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

        const run_viewer = b.addRunArtifact(viewer);
        if (b.args) |args| run_viewer.addArgs(args);
        run_viewer_step.dependOn(&run_viewer.step);
    }

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

        const run_vaxis_viewer = b.addRunArtifact(vaxis_viewer);
        if (b.args) |args| run_vaxis_viewer.addArgs(args);
        run_vaxis_viewer_step.dependOn(&run_vaxis_viewer.step);
    }
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const markdown = b.addModule("markdown", .{
        .root_source_file = b.path("src/Parser.zig"),
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
            },
        }),
    });
    const test_step = b.step("test", "Run parser tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(fixture_tests).step);

    const viewer_step = b.step("viewer", "Build the DVUI markdown viewer example");
    const run_viewer_step = b.step("run-viewer", "Run the DVUI markdown viewer example");

    if (b.lazyDependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    })) |dvui_dep| {
        const viewer = b.addExecutable(.{
            .name = "markdown-viewer",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/dvui/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "markdown", .module = markdown },
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
}

const std = @import("std");
const dvui = @import("dvui");
const MarkdownWidget = @import("widget.zig");

var test_arena: ?*std.heap.ArenaAllocator = null;
var test_source: []const u8 = "";

fn missingImage(_: []const u8) dvui.Texture.ImageSource {
    return .{ .imageFile = .{ .bytes = &.{}, .name = "missing.png" } };
}

fn renderFrame() !dvui.App.Result {
    try MarkdownWidget.init(@src(), test_arena.?, test_source, .{
        .parser = .{ .underline_extension = true },
        .get_image = missingImage,
    });
    return .ok;
}

test "renderer handles edge cases across frames and source changes" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 600 } });
    defer testing.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    test_arena = &arena;
    defer test_arena = null;

    test_source =
        \\```
        \\```
        \\```zig
        \\const first = 1;
        \\const second = 2;
        \\- unordered
        \\1. ordered
        \\| A | B |
        \\| --- | --- |
        \\| one | two |
        \\before ![missing](missing.png) after
        \\__underline__
    ;
    try dvui.testing.settle(renderFrame);

    test_source = "replacement document";
    try dvui.testing.settle(renderFrame);
}

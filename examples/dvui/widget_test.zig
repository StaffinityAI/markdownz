const std = @import("std");
const dvui = @import("dvui");
const MarkdownWidget = @import("widget.zig");

var test_arena: ?*std.heap.ArenaAllocator = null;
var test_source: []const u8 = "";
var test_options: MarkdownWidget.InitOptions = .{ .get_image = missingImage };
var second_source: []const u8 = "second widget";

fn missingImage(_: []const u8) ?dvui.Texture.ImageSource {
    return null;
}

fn renderFrame() !dvui.App.Result {
    try MarkdownWidget.init(@src(), test_arena.?, test_source, .{
        .parser = test_options.parser,
        .get_image = test_options.get_image,
    });
    return .ok;
}

fn renderHash() !u64 {
    dvui.testing.widget_hasher = .init();
    defer dvui.testing.widget_hasher = null;
    _ = try dvui.testing.step(renderFrame);
    return dvui.testing.widget_hasher.?.final();
}

fn renderTwoWidgets() !dvui.App.Result {
    try MarkdownWidget.init(@src(), test_arena.?, test_source, .{ .get_image = missingImage });
    try MarkdownWidget.init(@src(), test_arena.?, second_source, .{ .get_image = missingImage });
    return .ok;
}

test "renderer handles edge cases across frames and source changes" {
    const previous_source = test_source;
    const previous_options = test_options;
    defer {
        test_source = previous_source;
        test_options = previous_options;
    }
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
        \\```
        \\- unordered
        \\1. ordered
        \\- separator
        \\1. ordered again
        \\| A | B |
        \\| --- | --- |
        \\| one | two |
        \\before ![missing](missing.png) after
        \\__underline__
    ;
    try dvui.testing.settle(renderFrame);
    const original_hash = try renderHash();

    test_source = "```\nreplacement code\n```\n";
    try dvui.testing.settle(renderFrame);
    const replacement_hash = try renderHash();
    try std.testing.expect(original_hash != replacement_hash);

    test_source = "[link](  /path  )";
    test_options.parser.mode = .loose;
    try dvui.testing.settle(renderFrame);
    const loose_hash = try renderHash();
    test_options.parser.mode = .strict;
    try dvui.testing.settle(renderFrame);
    _ = try renderHash();

    var parser_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parser_arena.deinit();
    const loose = try @import("markdown").parse(parser_arena.allocator(), test_source, .{ .mode = .loose });
    try std.testing.expect(loose[0].text[0] == .link);
    _ = parser_arena.reset(.retain_capacity);
    const strict = try @import("markdown").parse(parser_arena.allocator(), test_source, .{ .mode = .strict });
    try std.testing.expect(strict[0].text[0] == .default);
    try std.testing.expect(loose_hash != replacement_hash);
}

test "widgets sharing a backing arena keep independent graph generations" {
    const previous_source = test_source;
    const previous_second_source = second_source;
    defer {
        test_source = previous_source;
        second_source = previous_second_source;
    }
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 600 } });
    defer testing.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    test_arena = &arena;
    defer test_arena = null;

    test_source = "first widget";
    second_source = "second widget";
    try dvui.testing.settle(renderTwoWidgets);
    test_source = "updated first widget";
    try dvui.testing.settle(renderTwoWidgets);
    second_source = "updated second widget";
    try dvui.testing.settle(renderTwoWidgets);
}

test "empty unordered marker options use a fallback" {
    var testing = try dvui.testing.init(.{ .window_size = .{ .w = 800, .h = 600 } });
    defer testing.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    test_arena = &arena;
    defer test_arena = null;
    const previous_source = test_source;
    const previous_options = test_options;
    defer {
        test_source = previous_source;
        test_options = previous_options;
    }
    test_source = "- item";
    test_options.unordered_list_indicators = &.{};
    try dvui.testing.settle(renderFrame);
}

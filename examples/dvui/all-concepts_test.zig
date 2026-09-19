const std = @import("std");
const default_document = @import("default_document");
const markdown = @import("markdown");

test "default viewer document parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try markdown.parse(arena.allocator(), default_document.source, .{});
    try std.testing.expect(nodes.len > 0);
}

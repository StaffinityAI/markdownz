const std = @import("std");
const markdown = @import("markdown");

test "default viewer document parses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try markdown.parse(arena.allocator(), @embedFile("all-concepts.md"), .{});
    try std.testing.expect(nodes.len > 0);
}

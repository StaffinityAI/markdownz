const std = @import("std");
const default_document = @import("default_document");
const markdown = @import("markdown");

test "default viewer document exercises supported concepts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try markdown.parse(arena.allocator(), default_document.source, .{});
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expect(nodes[0].* == .heading);
    try std.testing.expectEqualStrings("Markdown concept gallery", nodes[0].heading.text[0].default);
    try std.testing.expectEqualStrings("Setext level one", nodes[1].heading.text[0].default);

    try std.testing.expect(countNodes(nodes, .heading) >= 10);
    try std.testing.expectEqual(@as(usize, 3), countNodes(nodes, .horizontal_rule));
    try std.testing.expectEqual(@as(usize, 1), countNodes(nodes, .table));
    try std.testing.expectEqual(@as(usize, 2), countNodes(nodes, .code_block));
    try std.testing.expectEqual(@as(usize, 2), countNodes(nodes, .block_quote));
    try std.testing.expectEqual(@as(usize, 1), countNodes(nodes, .list));

    try std.testing.expect(hasSection(nodes, .link));
    try std.testing.expect(hasSection(nodes, .image));
    try std.testing.expect(hasSection(nodes, .bold));
    try std.testing.expect(hasSection(nodes, .italic));
    try std.testing.expect(hasSection(nodes, .bold_italic));
    try std.testing.expect(hasSection(nodes, .strike_through));
    try std.testing.expect(hasSection(nodes, .highlight));
    try std.testing.expect(hasSection(nodes, .code));
    try std.testing.expect(hasSection(nodes, .emoji_shortcode));
    try std.testing.expect(hasStandaloneImage(nodes, default_document.image_name));

    const table = findFirstTable(nodes).?;
    try std.testing.expectEqual(@as(usize, 3), table.len);
    try std.testing.expectEqual(@as(usize, 4), table[0].values.len);
    try std.testing.expect(table[1].values[2][0] == .code);
}

fn countNodes(nodes: []const *markdown.Node, expected: std.meta.Tag(markdown.Node)) usize {
    var count: usize = 0;
    for (nodes) |node| {
        if (std.meta.activeTag(node.*) == expected) count += 1;
        switch (node.*) {
            .heading => |heading| count += countNodes(heading.children.items, expected),
            .block_quote => |quote| count += countNodes(quote.items, expected),
            else => {},
        }
    }
    return count;
}

fn hasSection(nodes: []const *markdown.Node, expected: std.meta.Tag(markdown.Node.Section)) bool {
    for (nodes) |node| {
        switch (node.*) {
            .heading => |heading| {
                if (hasSections(heading.text, expected) or hasSection(heading.children.items, expected)) return true;
            },
            .text => |text| if (hasSections(text, expected)) return true,
            .block_quote => |quote| if (hasSection(quote.items, expected)) return true,
            .list => |list| for (list.items) |item| {
                if (hasSections(item.text, expected) or hasElements(item.children.items, expected)) return true;
            },
            .table => |table| for (table) |column| {
                if (hasSections(column.header, expected)) return true;
                for (column.values) |value| if (hasSections(value, expected)) return true;
            },
            else => {},
        }
    }
    return false;
}

fn hasElements(elements: []const *markdown.Node.Element, expected: std.meta.Tag(markdown.Node.Section)) bool {
    for (elements) |element| {
        if (hasSections(element.text, expected) or hasElements(element.children.items, expected)) return true;
    }
    return false;
}

fn hasSections(sections: []const markdown.Node.Section, expected: std.meta.Tag(markdown.Node.Section)) bool {
    for (sections) |section| {
        if (std.meta.activeTag(section) == expected) return true;
        switch (section) {
            .bold_italic => |children| if (hasSections(children, expected)) return true,
            .bold => |children| if (hasSections(children, expected)) return true,
            .italic => |children| if (hasSections(children, expected)) return true,
            .underline => |children| if (hasSections(children, expected)) return true,
            .strike_through => |children| if (hasSections(children, expected)) return true,
            .highlight => |children| if (hasSections(children, expected)) return true,
            .link => |link| if (hasSections(link.title, expected)) return true,
            .image => |image| if (hasSections(image.alt_text, expected)) return true,
            else => {},
        }
    }
    return false;
}

fn findFirstTable(nodes: []const *markdown.Node) ?[]markdown.Node.Column {
    for (nodes) |node| {
        switch (node.*) {
            .table => |table| return table,
            .heading => |heading| if (findFirstTable(heading.children.items)) |table| return table,
            .block_quote => |quote| if (findFirstTable(quote.items)) |table| return table,
            else => {},
        }
    }
    return null;
}

fn hasStandaloneImage(nodes: []const *markdown.Node, expected_path: []const u8) bool {
    for (nodes) |node| switch (node.*) {
        .text => |sections| {
            if (sections.len == 1 and sections[0] == .image and std.mem.eql(u8, sections[0].image.path, expected_path)) return true;
        },
        .heading => |heading| if (hasStandaloneImage(heading.children.items, expected_path)) return true,
        .block_quote => |quote| if (hasStandaloneImage(quote.items, expected_path)) return true,
        else => {},
    };
    return false;
}

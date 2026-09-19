//! TODO: Support UTF-8 properly, all checks atm assume ascii encoding

const std = @import("std");

pub const Node = union(enum) {
    heading: struct {
        /// \# Heading {**custom-id**}
        id: ?[]const u8,
        level: u8,
        text: []Section,
        parent: ?*Node,
        children: std.ArrayList(*Node),
    },
    list: std.ArrayList(*Element),
    code_block: struct {
        language: []const u8,
        initial_indentation: usize,
        lines: std.ArrayList([]const u8),
        closed: bool,
    },
    text: []Section,
    line_break: void,
    horizontal_rule: void,
    block_quote: std.ArrayList(*Node),
    // TODO: All the bellow need to be implemented
    table: []Column,
    footnote: []Section,
    /// > [!x]
    /// >
    alert: void,
    /// ::: x
    ///
    /// :::
    container: void,

    pub const Element = struct {
        text: []Section,
        children: std.ArrayList(*Element),
        data: Data,

        const Data = union(Node.ListType) {
            ordered: usize,
            unordered: void,
            task: bool,
        };
    };

    const ListType = enum {
        ordered,
        unordered,
        task,
    };

    pub const Section = union(enum) {
        default: []const u8,
        code: []const u8,
        // This is just to make the matching logic easier
        bold_italic: []Section,
        bold: []Section,
        italic: []Section,
        underline: []Section,
        strike_through: []Section,
        highlight: []Section,
        subscript: []Section,
        superscript: []Section,
        emoji_shortcode: []const u8,
        /// Only present if `typographic_parsing` is enabled
        typographic: []const u8,
        link: struct {
            title: []Section,
            hover_text: []const u8,
            url: []const u8,
        },
        image: struct {
            alt_text: []Section,
            hover_text: []const u8,
            path: []const u8,
            /// Only available when image is embedded with `<img>` html tag
            size: ?struct {
                width: u32,
                height: u32,
            },
        },
    };

    pub const Column = struct {
        alignment: Alignment,
        header: []Section,
        values: [][]Section,

        pub const Alignment = enum { left, right, center };
    };
};

test "plain text and UTF-8 BOM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "\xEF\xBB\xBFhello", .{});
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try expectDefaultText(nodes[0], "hello");
}

test "CRLF preserves the final character" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "first\r\nsecond\r\n", .{});
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try expectDefaultText(nodes[0], "first");
    try expectDefaultText(nodes[1], "second");
}

test "ATX headings support all levels and custom ids" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(),
        \\# one
        \\## two
        \\### three
        \\#### four
        \\##### five
        \\###### six {custom-id}
    , .{});

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    var node = nodes[0];
    for (1..7) |level| {
        try std.testing.expect(node.* == .heading);
        try std.testing.expectEqual(@as(u8, @intCast(level)), node.heading.level);
        if (level == 6) {
            try std.testing.expectEqualStrings("custom-id", node.heading.id.?);
            try expectDefaultSection(node.heading.text, "six");
        } else {
            try std.testing.expectEqual(@as(usize, 1), node.heading.children.items.len);
            node = node.heading.children.items[0];
        }
    }
}

test "same-level headings are siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "# first\n# second\n", .{});
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expect(nodes[0].* == .heading);
    try std.testing.expect(nodes[1].* == .heading);
    try std.testing.expect(nodes[0].heading.parent == null);
    try std.testing.expect(nodes[1].heading.parent == null);
}

test "content belongs to its nearest heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "# parent\nintro\n## child\ndetail\n", .{});
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqual(@as(usize, 2), nodes[0].heading.children.items.len);
    try expectDefaultText(nodes[0].heading.children.items[0], "intro");
    const child = nodes[0].heading.children.items[1];
    try std.testing.expect(child.* == .heading);
    try std.testing.expect(child.heading.parent == nodes[0]);
    try std.testing.expectEqual(@as(usize, 1), child.heading.children.items.len);
    try expectDefaultText(child.heading.children.items[0], "detail");
}

test "blank line after heading text creates a line break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "# heading\nparagraph\n\nnext\n", .{});
    const children = nodes[0].heading.children.items;
    try std.testing.expectEqual(@as(usize, 3), children.len);
    try std.testing.expect(children[1].* == .line_break);
}

test "setext headings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const level_one = try parse(arena.allocator(), "title\n=====\n", .{});
    try std.testing.expect(level_one[0].* == .heading);
    try std.testing.expectEqual(@as(u8, 1), level_one[0].heading.level);
    try expectDefaultSection(level_one[0].heading.text, "title");

    const level_two = try parse(arena.allocator(), "subtitle\n-----\n", .{});
    try std.testing.expect(level_two[0].* == .heading);
    try std.testing.expectEqual(@as(u8, 2), level_two[0].heading.level);
    try expectDefaultSection(level_two[0].heading.text, "subtitle");
}

test "horizontal rules recognize supported markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "---\n***\n___\n", .{});
    try std.testing.expectEqual(@as(usize, 3), nodes.len);
    for (nodes) |node| try std.testing.expect(node.* == .horizontal_rule);
}

test "fenced code blocks preserve indentation language lines and closed state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const closed = try parse(arena.allocator(), "  ```zig extra\nconst x = 1;\n  ```\n", .{});
    try std.testing.expect(closed[0].* == .code_block);
    try std.testing.expectEqual(@as(usize, 2), closed[0].code_block.initial_indentation);
    try std.testing.expectEqualStrings("zig extra", closed[0].code_block.language);
    try std.testing.expectEqual(@as(usize, 1), closed[0].code_block.lines.items.len);
    try std.testing.expectEqualStrings("const x = 1;", closed[0].code_block.lines.items[0]);
    try std.testing.expect(closed[0].code_block.closed);

    const open = try parse(arena.allocator(), "```text\ncontent", .{});
    try std.testing.expect(!open[0].code_block.closed);
}

test "block quotes contain parsed nodes and preserve nesting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "> quoted **text**\n>> nested\n", .{});
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expect(nodes[0].* == .block_quote);
    try std.testing.expectEqual(@as(usize, 2), nodes[0].block_quote.items.len);
    const text = nodes[0].block_quote.items[0];
    try std.testing.expect(text.* == .text);
    try std.testing.expectEqual(@as(usize, 2), text.text.len);
    try std.testing.expect(text.text[1] == .bold);
    const nested = nodes[0].block_quote.items[1];
    try std.testing.expect(nested.* == .block_quote);
    try expectDefaultText(nested.block_quote.items[0], "nested");
}

test "unordered ordered and task lists" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const unordered = try parse(arena.allocator(), "- one\n- two\n", .{});
    try std.testing.expect(unordered[0].* == .list);
    try std.testing.expectEqual(@as(usize, 2), unordered[0].list.items.len);
    try std.testing.expect(unordered[0].list.items[0].data == .unordered);

    const ordered = try parse(arena.allocator(), "3. three\n4. four\n", .{});
    try std.testing.expectEqual(@as(usize, 3), ordered[0].list.items[0].data.ordered);
    try std.testing.expectEqual(@as(usize, 4), ordered[0].list.items[1].data.ordered);

    const tasks = try parse(arena.allocator(), "- [x] done\n- [ ] pending\n", .{});
    try std.testing.expect(tasks[0].list.items[0].data.task);
    try std.testing.expect(!tasks[0].list.items[1].data.task);
}

test "nested lists use two-space indentation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "- parent\n  - child\n    - grandchild\n", .{});
    const parent = nodes[0].list.items[0];
    try std.testing.expectEqual(@as(usize, 1), parent.children.items.len);
    try std.testing.expectEqual(@as(usize, 1), parent.children.items[0].children.items.len);
}

test "inline emphasis concepts support asterisk and underscore markers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "*italic* _italic_ **bold** __bold__ ***both*** ___both___ ~~strike~~ ==mark== `code` :sparkles:\n", .{});
    const sections = nodes[0].text;
    try expectSectionTag(sections, .italic);
    try std.testing.expectEqual(@as(usize, 2), countSectionTag(sections, .italic));
    try expectSectionTag(sections, .bold);
    try std.testing.expectEqual(@as(usize, 2), countSectionTag(sections, .bold));
    try expectSectionTag(sections, .bold_italic);
    try std.testing.expectEqual(@as(usize, 2), countSectionTag(sections, .bold_italic));
    try expectSectionTag(sections, .strike_through);
    try expectSectionTag(sections, .highlight);
    try expectSectionTag(sections, .code);
    try expectSectionTag(sections, .emoji_shortcode);
}

test "inline styles can nest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "**bold and *italic***", .{});
    try std.testing.expect(nodes[0].text[0] == .bold);
    try expectSectionTag(nodes[0].text[0].bold, .italic);
}

test "underline extension changes double underscore semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const bold = try parse(arena.allocator(), "__text__", .{});
    try std.testing.expect(bold[0].text[0] == .bold);

    const underline = try parse(arena.allocator(), "__text__", .{ .underline_extension = true });
    try std.testing.expect(underline[0].text[0] == .underline);
}

test "links parse title URL and hover text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "before [Zig](https://ziglang.org/ \"home\") after", .{});
    try std.testing.expectEqual(@as(usize, 3), nodes[0].text.len);
    const link = nodes[0].text[1].link;
    try expectDefaultSection(link.title, "Zig");
    try std.testing.expectEqualStrings("https://ziglang.org/", link.url);
    try std.testing.expectEqualStrings("home", link.hover_text);
}

test "links and images can omit hover text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const link_nodes = try parse(arena.allocator(), "[title](/docs)", .{});
    try std.testing.expectEqualStrings("/docs", link_nodes[0].text[0].link.url);
    try std.testing.expectEqual(@as(usize, 0), link_nodes[0].text[0].link.hover_text.len);

    const image_nodes = try parse(arena.allocator(), "![alt](image.png)", .{});
    try std.testing.expectEqualStrings("image.png", image_nodes[0].text[0].image.path);
    try std.testing.expectEqual(@as(usize, 0), image_nodes[0].text[0].image.hover_text.len);
}

test "images parse alt text path and hover text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "![alt **text**](image.png \"preview\")", .{});
    const image = nodes[0].text[0].image;
    try std.testing.expectEqualStrings("image.png", image.path);
    try std.testing.expectEqualStrings("preview", image.hover_text);
    try std.testing.expectEqual(@as(usize, 2), image.alt_text.len);
    try std.testing.expect(image.alt_text[1] == .bold);
    try std.testing.expect(image.size == null);
}

test "loose link mode trims padding while strict mode rejects links and images" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const loose = try parse(arena.allocator(), "[**link**](  /path  ) ![alt](  image.png  )", .{});
    try std.testing.expect(loose[0].text[0] == .link);
    try std.testing.expect(loose[0].text[0].link.title[0] == .bold);
    try std.testing.expectEqualStrings("/path", loose[0].text[0].link.url);
    try std.testing.expect(loose[0].text[2] == .image);
    try std.testing.expectEqualStrings("image.png", loose[0].text[2].image.path);

    const strict = try parse(arena.allocator(), "[link](  /path  ) ![alt](  image.png  )", .{ .mode = .strict });
    try expectDefaultText(strict[0], "[link](  /path  ) ![alt](  image.png  )");
}

test "malformed inline syntax falls back to text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "unclosed **bold and [link](", .{});
    try std.testing.expect(nodes[0].* == .text);
    try std.testing.expect(nodes[0].text.len > 0);
}

test "short marker-like lines do not panic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "#\n-\n1\n=\n>\n", .{});
    try std.testing.expect(nodes.len > 0);
}

test "tables parse headers alignments and body rows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(),
        \\| Name | Description | Count |
        \\| :--- | :---------: | ----: |
        \\| alpha | first | 1 |
        \\| beta | second | 2 |
    , .{});

    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expect(nodes[0].* == .table);
    const columns = nodes[0].table;
    try std.testing.expectEqual(@as(usize, 3), columns.len);
    try std.testing.expectEqual(.left, columns[0].alignment);
    try std.testing.expectEqual(.center, columns[1].alignment);
    try std.testing.expectEqual(.right, columns[2].alignment);
    try expectDefaultSection(columns[0].header, "Name");
    try expectDefaultSection(columns[1].header, "Description");
    try expectDefaultSection(columns[2].header, "Count");
    try std.testing.expectEqual(@as(usize, 2), columns[0].values.len);
    try expectDefaultSection(columns[0].values[0], "alpha");
    try expectDefaultSection(columns[1].values[1], "second");
    try expectDefaultSection(columns[2].values[1], "2");
}

test "tables allow omitted outer pipes and inline formatting" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(),
        \\Feature | Status
        \\--- | ---
        \\**bold** | `ready`
    , .{});

    const columns = nodes[0].table;
    try std.testing.expectEqual(@as(usize, 2), columns.len);
    try std.testing.expect(columns[0].values[0][0] == .bold);
    try std.testing.expect(columns[1].values[0][0] == .code);
}

test "table rows pad missing cells and ignore extra cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(),
        \\A | B
        \\--- | ---
        \\| one |
        \\two | value | ignored
    , .{});

    const columns = nodes[0].table;
    try std.testing.expectEqual(@as(usize, 2), columns[0].values.len);
    try expectDefaultSection(columns[0].values[0], "one");
    try std.testing.expectEqual(@as(usize, 0), columns[1].values[0].len);
    try expectDefaultSection(columns[1].values[1], "value");
}

test "a non-table line ends table body parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "A | B\n--- | ---\none | two\nafter table\n", .{});
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expect(nodes[0].* == .table);
    try expectDefaultText(nodes[1], "after table");
}

test "escaped and code-span pipes do not split table cells" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(),
        \\Expression | Meaning
        \\--- | ---
        \\left \| right | `a|b`
    , .{});

    const columns = nodes[0].table;
    try std.testing.expectEqual(@as(usize, 2), columns.len);
    try expectTextContentSections(columns[0].values[0], "left \\| right");
    try std.testing.expectEqual(@as(usize, 1), columns[1].values[0].len);
    try std.testing.expect(columns[1].values[0][0] == .code);
    try std.testing.expectEqualStrings("a|b", columns[1].values[0][0].code);
}

test "blank lines terminate table body parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "A | B\n--- | ---\none | two\n\nlater | text\n", .{});
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expectEqual(@as(usize, 1), nodes[0].table[0].values.len);
    try expectTextContent(nodes[1], "later | text");
}

test "invalid table delimiters remain text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const too_short = try parse(arena.allocator(), "A | B\n-- | ---\n", .{});
    try std.testing.expectEqual(@as(usize, 2), too_short.len);
    try expectTextContent(too_short[0], "A | B");
    try expectTextContent(too_short[1], "-- | ---");

    const wrong_count = try parse(arena.allocator(), "A | B\n--- | --- | ---\n", .{});
    try std.testing.expectEqual(@as(usize, 2), wrong_count.len);
    try expectTextContent(wrong_count[0], "A | B");
    try expectTextContent(wrong_count[1], "--- | --- | ---");
}

test "pipe text without a delimiter row is not a table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "left | right\nordinary text\n", .{});
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try expectTextContent(nodes[0], "left | right");
}

test "other unimplemented block concepts remain available as text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const nodes = try parse(arena.allocator(), "[^note]: footnote\n<em>html</em>\n", .{});
    try std.testing.expectEqual(@as(usize, 2), nodes.len);
    try std.testing.expect(nodes[0].* == .text);
    try expectTextContent(nodes[1], "<em>html</em>");
}

fn expectDefaultText(node: *Node, expected: []const u8) !void {
    try std.testing.expect(node.* == .text);
    try expectDefaultSection(node.text, expected);
}

fn expectDefaultSection(sections: []Node.Section, expected: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), sections.len);
    try std.testing.expect(sections[0] == .default);
    try std.testing.expectEqualStrings(expected, sections[0].default);
}

fn expectTextContent(node: *Node, expected: []const u8) !void {
    try std.testing.expect(node.* == .text);
    try expectTextContentSections(node.text, expected);
}

fn expectTextContentSections(sections: []Node.Section, expected: []const u8) !void {
    var offset: usize = 0;
    for (sections) |section| {
        try std.testing.expect(section == .default);
        const text = section.default;
        try std.testing.expect(offset + text.len <= expected.len);
        try std.testing.expectEqualStrings(expected[offset .. offset + text.len], text);
        offset += text.len;
    }
    try std.testing.expectEqual(expected.len, offset);
}

fn expectSectionTag(sections: []Node.Section, expected: std.meta.Tag(Node.Section)) !void {
    if (countSectionTag(sections, expected) > 0) return;
    return error.TestExpectedEqual;
}

fn countSectionTag(sections: []Node.Section, expected: std.meta.Tag(Node.Section)) usize {
    var count: usize = 0;
    for (sections) |section| {
        if (std.meta.activeTag(section) == expected) count += 1;
    }
    return count;
}

pub const Options = struct {
    mode: enum(u1) {
        /// Allow padding on contained elements
        loose,
        /// No padding strictly enforced in places like image urls
        strict,
    } = .loose,
    /// **NOT YET IMPLEMENTED**
    parse_arbitrary_urls: bool = false,
    /// Parse `__text__` as an `underline` node
    underline_extension: bool = false,
    /// **NOT YET IMPLEMENTED**
    /// Allows typographic replacement:
    /// (c), (C) => ©
    /// (tm), (TM) => ™
    /// (p), (P) => ℗
    /// ?? => ⁇
    /// ???(?) => ？？？
    /// !! => ‼
    /// !!!(!) => ！！！
    /// -- => –
    /// --- => —
    /// +- => ±
    /// "..." = > “...”
    /// '...' => ‘...’
    /// !..(.) => !..
    /// ?..(.) => ?..
    /// ..(.) => …
    typographic_replacement: bool = false,
};

pub fn parse(arena: std.mem.Allocator, buffer: []const u8, options: Options) ![]*Node {
    var ctx: Context = .{};
    var reader: std.Io.Reader = .fixed(if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) buffer[3..] else buffer);

    while (try reader.takeDelimiter('\n')) |line| {
        try ctx.parseLine(arena, line, options);
    }

    return ctx.graph.toOwnedSlice(arena);
}

const Context = struct {
    graph: std.ArrayList(*Node) = .empty,
    previous_node: ?*Node = null,
    previous_heading: ?*Node = null,
    previous_line: ?[]const u8 = null,

    fn skipBlank(line: []const u8) usize {
        var i: usize = 0;
        while (i < line.len and std.ascii.isWhitespace(line[i])) : (i += 1) {}
        return i;
    }

    fn findParentHadingNode(previous_node: ?*Node, level: u8) ?*Node {
        var n = previous_node orelse return null;

        while (n.heading.level >= level) {
            n = n.heading.parent orelse return null;
        }

        return n;
    }

    fn appendHeadingNode(ctx: *Context, arena: std.mem.Allocator, level: u8, line: []const u8, options: Options) !void {
        const bracket_index = std.mem.findScalarLast(u8, line, '{');
        const has_id = bracket_index != null and line.len > 1 and line[line.len - 1] == '}';
        const id: ?[]const u8 = if (has_id) line[bracket_index.? + 1 .. line.len - 1] else null;
        const text = if (has_id) std.mem.trimEnd(u8, line[0..bracket_index.?], " \t") else line;

        const parent_node = findParentHadingNode(ctx.previous_heading, level);

        const node = try arena.create(Node);
        node.* = .{
            .heading = .{
                .id = id,
                .level = level,
                .text = try parseLineText(arena, text, options),
                .parent = parent_node,
                .children = .empty,
            },
        };

        if (parent_node) |n|
            try n.heading.children.append(arena, node)
        else
            try ctx.graph.append(arena, node);
        ctx.previous_heading = node;
        ctx.previous_node = node;
    }

    fn innerAppendBlockQuoteNode(
        ctx: *Context,
        arena: std.mem.Allocator,
        block: *std.ArrayList(*Node),
        line: []const u8,
        options: Options,
    ) !void {
        _ = ctx;

        var inner_ctx: Context = .{ .graph = block.* };
        try inner_ctx.parseLine(arena, line, options);
        block.* = inner_ctx.graph;
    }

    fn appendBlockQuoteNode(ctx: *Context, arena: std.mem.Allocator, depth: u8, line: []const u8, options: Options) !void {
        if (ctx.previous_node) |previous_node| {
            switch (previous_node.*) {
                .block_quote => |*block_node| {
                    var i: usize = 1;
                    var n = block_node;
                    while (i < depth) : (i += 1) {
                        if (n.items.len > 0) {
                            const last = n.items[n.items.len - 1];
                            if (last.* == .block_quote) {
                                n = &last.block_quote;
                                continue;
                            }
                        }

                        const nested = try arena.create(Node);
                        nested.* = .{ .block_quote = .empty };
                        try n.append(arena, nested);
                        n = &nested.block_quote;
                    }

                    return try ctx.innerAppendBlockQuoteNode(arena, n, line, options);
                },
                else => {},
            }
        }

        const node = try arena.create(Node);
        node.* = .{ .block_quote = .empty };

        try ctx.innerAppendBlockQuoteNode(arena, &node.block_quote, line, options);
        return try ctx.appendNode(arena, node);
    }

    fn innerAppendListNode(
        ctx: *Context,
        arena: std.mem.Allocator,
        list: *std.ArrayList(*Node.Element),
        element_data: Node.Element.Data,
        line: []const u8,
        options: Options,
    ) !void {
        _ = ctx;

        const element = try arena.create(Node.Element);

        element.* = .{
            .text = try parseLineText(arena, line[skipBlank(line)..], options),
            .children = .empty,
            .data = element_data,
        };

        try list.append(arena, element);
    }

    fn appendListNode(
        ctx: *Context,
        arena: std.mem.Allocator,
        element_data: Node.Element.Data,
        depth: usize,
        line: []const u8,
        options: Options,
    ) !void {
        if (ctx.previous_node) |previous_node| {
            switch (previous_node.*) {
                .list => |*list_node| {
                    var i: usize = 0;
                    var n = list_node;
                    while (i < depth) : (i += 1) {
                        if (n.items.len == 0) return try ctx.innerAppendListNode(arena, n, element_data, line, options);
                        n = &n.getLast().children;
                    }

                    return try ctx.innerAppendListNode(arena, n, element_data, line, options);
                },
                else => {},
            }
        }

        const node = try arena.create(Node);
        node.* = .{ .list = .empty };

        try ctx.innerAppendListNode(arena, &node.list, element_data, line, options);
        return try ctx.appendNode(arena, node);
    }

    fn appendHorizontalRule(ctx: *Context, arena: std.mem.Allocator) !void {
        const node = try arena.create(Node);
        node.* = .horizontal_rule;

        try ctx.appendNode(arena, node);
    }

    fn appendCodeBlock(ctx: *Context, arena: std.mem.Allocator, skipped: usize, language: []const u8) !void {
        const node = try arena.create(Node);
        node.* = .{
            .code_block = .{
                .closed = false,
                .initial_indentation = skipped,
                .language = language,
                .lines = .empty,
            },
        };

        try ctx.appendNode(arena, node);
    }

    fn convertPreviousTextToTable(ctx: *Context, arena: std.mem.Allocator, delimiter_line: []const u8, options: Options) !bool {
        const previous_node = ctx.previous_node orelse return false;
        if (previous_node.* != .text) return false;
        const header_line = ctx.previous_line orelse return false;
        if (!containsTablePipe(header_line)) return false;

        const headers = try splitTableRow(arena, header_line);
        const delimiters = try splitTableRow(arena, delimiter_line);
        if (headers.len == 0 or delimiters.len != headers.len) return false;

        const columns = try arena.alloc(Node.Column, headers.len);
        for (columns, headers, delimiters) |*column, header, delimiter| {
            column.* = .{
                .alignment = parseTableAlignment(delimiter) orelse return false,
                .header = try parseLineText(arena, header, options),
                .values = &.{},
            };
        }

        previous_node.* = .{ .table = columns };
        return true;
    }

    fn appendTableRow(arena: std.mem.Allocator, columns: []Node.Column, line: []const u8, options: Options) !void {
        const cells = try splitTableRow(arena, line);
        for (columns, 0..) |*column, index| {
            const value = if (index < cells.len) try parseLineText(arena, cells[index], options) else try arena.alloc(Node.Section, 0);
            const values = try arena.alloc([]Node.Section, column.values.len + 1);
            @memcpy(values[0..column.values.len], column.values);
            values[column.values.len] = value;
            column.values = values;
        }
    }

    fn containsTablePipe(line: []const u8) bool {
        var escaped = false;
        var code = false;
        for (line) |byte| {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
            } else if (byte == '`') {
                code = !code;
            } else if (byte == '|' and !code) {
                return true;
            }
        }
        return false;
    }

    fn splitTableRow(arena: std.mem.Allocator, line: []const u8) ![][]const u8 {
        var cells: std.ArrayList([]const u8) = .empty;
        const trimmed = std.mem.trim(u8, line, " \t");
        const start: usize = @intFromBool(trimmed.len > 0 and trimmed[0] == '|');
        const end = trimmed.len - @intFromBool(trimmed.len > start and trimmed[trimmed.len - 1] == '|');

        var cell_start = start;
        var escaped = false;
        var code = false;
        var index = start;
        while (index < end) : (index += 1) {
            const byte = trimmed[index];
            if (escaped) {
                escaped = false;
                continue;
            }
            if (byte == '\\') {
                escaped = true;
            } else if (byte == '`') {
                code = !code;
            } else if (byte == '|' and !code) {
                try cells.append(arena, std.mem.trim(u8, trimmed[cell_start..index], " \t"));
                cell_start = index + 1;
            }
        }
        try cells.append(arena, std.mem.trim(u8, trimmed[cell_start..end], " \t"));
        return cells.toOwnedSlice(arena);
    }

    fn parseTableAlignment(cell: []const u8) ?Node.Column.Alignment {
        if (cell.len < 3) return null;
        const left = cell[0] == ':';
        const right = cell[cell.len - 1] == ':';
        const dashes = cell[@intFromBool(left) .. cell.len - @intFromBool(right)];
        if (dashes.len < 3 or !std.mem.allEqual(u8, dashes, '-')) return null;
        return if (left and right) .center else if (right) .right else .left;
    }

    fn appendTextNode(ctx: *Context, arena: std.mem.Allocator, line: []const u8, options: Options) !void {
        const node = try arena.create(Node);
        node.* = .{ .text = try parseLineText(arena, line, options) };

        try ctx.appendNode(arena, node);
    }

    fn makeDefaultSection(reader: *Reader) Node.Section {
        return .{ .default = reader.io_reader.buffer[reader.start..reader.io_reader.seek] };
    }

    const ParseLinkSectionError = error{ InvalidMarkdownFile, OutOfMemory } || std.Io.Reader.DelimiterError;

    fn parseLinkSection(arena: std.mem.Allocator, reader: *Reader, as: enum(u1) { image, link }, options: Options) ParseLinkSectionError!Node.Section {
        const alt_text = try reader.io_reader.takeDelimiterExclusive(']');
        reader.io_reader.toss(1);

        if (try reader.io_reader.takeByte() != '(') return error.InvalidMarkdownFile;

        const contents = try reader.io_reader.takeDelimiterExclusive(')');
        const content = switch (options.mode) {
            .loose => std.mem.trim(u8, contents, " \t"),
            .strict => strict: {
                if (!std.mem.eql(u8, contents, std.mem.trim(u8, contents, " \t"))) return error.InvalidMarkdownFile;
                break :strict contents;
            },
        };
        if (content.len == 0) return error.InvalidMarkdownFile;

        const separator = std.mem.indexOfAny(u8, content, " \t");
        const url = if (separator) |index| content[0..index] else content;
        if (url.len == 0) return error.InvalidMarkdownFile;
        const hover_text = if (separator) |index| hover: {
            const rest = std.mem.trim(u8, content[index..], " \t");
            if (rest.len == 0) break :hover &.{};
            if (rest.len < 2 or rest[0] != '"' or rest[rest.len - 1] != '"') return error.InvalidMarkdownFile;
            break :hover rest[1 .. rest.len - 1];
        } else &.{};

        reader.toss(1);

        return switch (as) {
            .image => .{
                .image = .{
                    .alt_text = try parseLineText(arena, alt_text, options),
                    .hover_text = hover_text,
                    .path = url,
                    .size = null,
                },
            },
            .link => .{
                .link = .{
                    .title = try parseLineText(arena, alt_text, options),
                    .hover_text = hover_text,
                    .url = url,
                },
            },
        };
    }

    const Reader = struct {
        start: usize,
        io_reader: std.Io.Reader,

        pub fn init(buffer: []const u8) Reader {
            return .{
                .start = 0,
                .io_reader = .fixed(buffer),
            };
        }

        pub fn isBlank(self: *Reader) !bool {
            return std.ascii.isWhitespace(try self.io_reader.peekByte());
        }

        pub fn skipBlank(self: *Reader) !void {
            while (try self.isBlank()) {
                self.io_reader.seek += 1;
            }
        }

        pub fn skip(self: *Reader, n: usize) void {
            self.start += n;
        }

        pub fn toss(self: *Reader, n: usize) void {
            if (self.io_reader.seek + n > self.io_reader.end) {
                self.io_reader.seek = self.io_reader.end;
                self.start = self.io_reader.end;
                return;
            }

            self.io_reader.toss(n);
            self.start = self.io_reader.seek;
        }

        pub fn peekInclusive(self: *Reader, needle: []const u8) ![]u8 {
            const contents = self.io_reader.buffer[0..self.io_reader.end];
            const seek = self.io_reader.seek;

            if (std.mem.findPos(u8, contents, seek, needle)) |end| {
                @branchHint(.likely);
                return contents[seek .. end + needle.len];
            }

            return error.EndOfStream;
        }

        pub fn peekExclusive(self: *Reader, needle: []const u8) ![]u8 {
            const result = try self.peekInclusive(needle);
            return result[0 .. result.len - needle.len];
        }

        pub fn takeExclusive(self: *Reader, needle: []const u8) ![]u8 {
            const result = try self.peekExclusive(needle);
            self.io_reader.toss(result.len);
            return result;
        }

        pub fn take(self: *Reader, end: usize) []u8 {
            const slice = self.io_reader.buffer[self.start..end];
            self.start = end;
            return slice;
        }
    };

    fn parseLineText(arena: std.mem.Allocator, line: []const u8, options: Options) ![]Node.Section {
        var arr: std.ArrayList(Node.Section) = try .initCapacity(arena, 2);
        errdefer arr.deinit(arena);

        var reader: Reader = .init(line);

        // Maybe empty line should error?
        loop: switch (reader.io_reader.takeByte() catch return &.{}) {
            '!' => {
                const section_start = reader.start;
                const next_byte = reader.io_reader.takeByte() catch {
                    try arr.append(arena, makeDefaultSection(&reader));
                    break :loop;
                };

                if (next_byte != '[') continue :loop next_byte;
                const seek_pos = reader.io_reader.seek;

                const section = parseLinkSection(arena, &reader, .image, options) catch {
                    reader.io_reader.seek = seek_pos;
                    const next_byte_inner = reader.io_reader.takeByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };
                    continue :loop next_byte_inner;
                };

                if (section_start != seek_pos - 2) {
                    try arr.append(arena, .{ .default = reader.io_reader.buffer[section_start .. seek_pos - 2] });
                }
                try arr.append(arena, section);
                continue :loop reader.io_reader.takeByte() catch break :loop;
            },
            '[' => {
                const section_start = reader.start;
                const seek_pos = reader.io_reader.seek;

                const section = parseLinkSection(arena, &reader, .link, options) catch {
                    reader.io_reader.seek = seek_pos;
                    const next_byte_inner = reader.io_reader.takeByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };
                    continue :loop next_byte_inner;
                };

                if (section_start != seek_pos - 1) {
                    try arr.append(arena, .{ .default = reader.io_reader.buffer[section_start .. seek_pos - 1] });
                }
                try arr.append(arena, section);
                continue :loop reader.io_reader.takeByte() catch break :loop;
            },
            '=', '~' => |c| {
                const next_byte = reader.io_reader.takeByte() catch {
                    try arr.append(arena, makeDefaultSection(&reader));
                    break :loop;
                };

                if (next_byte != c) continue :loop next_byte;
                const seek_pos = reader.io_reader.seek;

                const text = reader.takeExclusive(&@as([2]u8, @splat(c))) catch {
                    const next_byte_inner = reader.io_reader.takeByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };
                    continue :loop next_byte_inner;
                };

                if (reader.start != seek_pos - 2) {
                    try arr.append(arena, .{ .default = reader.take(seek_pos - 2) });
                }

                if (c == '=') {
                    try arr.append(arena, .{ .highlight = try parseLineText(arena, text, options) });
                } else {
                    try arr.append(arena, .{ .strike_through = try parseLineText(arena, text, options) });
                }

                reader.toss(2);
                continue :loop reader.io_reader.takeByte() catch break :loop;
            },
            '`', ':' => |c| {
                const seek_pos = reader.io_reader.seek;
                const text = reader.io_reader.takeDelimiterExclusive(c) catch {
                    const next_byte_inner = reader.io_reader.takeByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };
                    continue :loop next_byte_inner;
                };

                if (reader.start != seek_pos - 1) {
                    try arr.append(arena, .{ .default = reader.take(seek_pos - 1) });
                }

                if (c == '`') {
                    try arr.append(arena, .{ .code = text });
                } else {
                    try arr.append(arena, .{ .emoji_shortcode = text });
                }

                reader.toss(1);
                continue :loop reader.io_reader.takeByte() catch break :loop;
            },
            '*', '_' => |c| {
                const next_byte = reader.io_reader.peekByte() catch {
                    try arr.append(arena, makeDefaultSection(&reader));
                    break :loop;
                };

                if (next_byte == c) {
                    reader.io_reader.toss(1);

                    const next_byte_inner = reader.io_reader.peekByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };

                    if (next_byte_inner == c) {
                        reader.io_reader.toss(1);
                        const seek_pos = reader.io_reader.seek;

                        const text = reader.takeExclusive(&@as([2]u8, @splat(c))) catch {
                            const n_next_byte_inner = reader.io_reader.takeByte() catch {
                                try arr.append(arena, makeDefaultSection(&reader));
                                break :loop;
                            };
                            continue :loop n_next_byte_inner;
                        };

                        if (reader.start != seek_pos - 3) {
                            try arr.append(arena, .{ .default = reader.take(seek_pos - 3) });
                        }

                        try arr.append(arena, .{ .bold_italic = try parseLineText(arena, text, options) });

                        reader.toss(3);
                    } else {
                        const seek_pos = reader.io_reader.seek;
                        const text = reader.takeExclusive(&@as([2]u8, @splat(c))) catch continue :loop next_byte_inner;

                        if (reader.start != seek_pos - 2) {
                            try arr.append(arena, .{ .default = reader.take(seek_pos - 2) });
                        }

                        try arr.append(
                            arena,
                            if (options.underline_extension) .{
                                .underline = try parseLineText(arena, text, options),
                            } else .{
                                .bold = try parseLineText(arena, text, options),
                            },
                        );
                        reader.toss(2);
                    }
                } else {
                    const seek_pos = reader.io_reader.seek;

                    const text = reader.io_reader.takeDelimiterExclusive(c) catch {
                        continue :loop next_byte;
                    };

                    if (reader.start != seek_pos - 1) {
                        try arr.append(arena, .{ .default = reader.take(seek_pos - 1) });
                    }

                    try arr.append(arena, .{ .italic = try parseLineText(arena, text, options) });
                    reader.toss(1);
                }

                continue :loop reader.io_reader.takeByte() catch break :loop;
            },
            else => {
                continue :loop reader.io_reader.takeByte() catch {
                    try arr.append(arena, .{ .default = reader.io_reader.buffer[reader.start..] });
                    break :loop;
                };
            },
        }

        return arr.toOwnedSlice(arena);
    }

    fn appendNode(ctx: *Context, arena: std.mem.Allocator, node: *Node) !void {
        defer {
            if (node.* == .heading) ctx.previous_heading = node;
            ctx.previous_node = node;
        }

        if (ctx.previous_heading) |prev_node| {
            if (node.* == .heading) return;
            try prev_node.heading.children.append(arena, node);
        } else {
            try ctx.graph.append(arena, node);
        }
    }

    // TODO: This should use a Reader instead
    fn parseLine(ctx: *Context, arena: std.mem.Allocator, raw_line: []const u8, options: Options) std.mem.Allocator.Error!void {
        if (raw_line.len == 0) {
            ctx.previous_line = null;
            if (ctx.previous_node) |node| {
                if (node.* == .table) ctx.previous_node = null;
            }
            if (ctx.previous_heading) |heading| {
                if (ctx.previous_node) |node| {
                    switch (node.*) {
                        .text => {
                            const new_node = try arena.create(Node);
                            new_node.* = .line_break;
                            ctx.previous_node = new_node;
                            try heading.heading.children.append(arena, new_node);
                        },
                        else => {},
                    }
                }
            }

            return;
        }

        const line = if (raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len == 0) return;
        defer ctx.previous_line = line;

        // TODO: Completely rework `previous_node`
        if (ctx.previous_node) |node| {
            switch (node.*) {
                .code_block => |*block| {
                    if (!block.closed) {
                        if (std.mem.allEqual(u8, line[Context.skipBlank(line)..], '`')) {
                            block.closed = true;
                            return;
                        }

                        try block.lines.append(arena, line);
                        return;
                    }
                },
                else => {},
            }
        } else if (ctx.graph.items.len > 0 and ctx.graph.items[ctx.graph.items.len - 1].* == .code_block) {
            const block = &ctx.graph.items[ctx.graph.items.len - 1].code_block;
            if (!block.closed) {
                if (std.mem.allEqual(u8, line[Context.skipBlank(line)..], '`')) {
                    block.closed = true;
                    return;
                }

                try block.lines.append(arena, line);
                return;
            }
        }

        const skipped = skipBlank(line);
        const skipped_line = line[skipped..];

        if (ctx.previous_node) |previous_node| {
            if (previous_node.* == .table and containsTablePipe(skipped_line)) {
                return appendTableRow(arena, previous_node.table, skipped_line, options);
            }
        }

        if (try ctx.convertPreviousTextToTable(arena, skipped_line, options)) return;

        switch (line[skipped]) {
            '#' => {
                var pos: usize = 1;
                var level: u8 = 1;
                while (pos < skipped_line.len and skipped_line[pos] == '#') : (pos += 1) {
                    level += 1;
                }

                if (level > 6 or pos >= skipped_line.len or skipped_line[pos] != ' ') return ctx.appendTextNode(arena, skipped_line, options);
                pos += 1;

                return ctx.appendHeadingNode(arena, level, skipped_line[pos..], options);
            },
            '=' => {
                if (skipped_line.len > 1 and std.mem.allEqual(u8, skipped_line[1..], '=')) {
                    if (ctx.previous_node) |prev_node| switch (prev_node.*) {
                        .text => |copy| {
                            prev_node.* = .{
                                .heading = .{
                                    .id = null,
                                    .level = 1,
                                    .text = copy,
                                    .parent = ctx.previous_heading,
                                    .children = .empty,
                                },
                            };
                        },
                        else => return ctx.appendTextNode(arena, skipped_line, options),
                    };
                } else return ctx.appendTextNode(arena, skipped_line, options);
            },
            '-' => {
                if (skipped_line.len > 1 and skipped_line[1] == ' ') {
                    const is_task = skipped_line.len >= 6 and skipped_line[2] == '[' and skipped_line[4] == ']' and skipped_line[5] == ' ';

                    return try ctx.appendListNode(
                        arena,
                        if (is_task) .{ .task = skipped_line[3] == 'x' } else .unordered,
                        skipped / 2,
                        if (is_task) skipped_line[6..] else skipped_line[2..],
                        options,
                    );
                } else if (skipped_line.len > 1 and std.mem.allEqual(u8, skipped_line[1..], '-')) {
                    if (ctx.previous_node) |prev_node| switch (prev_node.*) {
                        .text => |copy| {
                            prev_node.* = .{
                                .heading = .{
                                    .id = null,
                                    .level = 2,
                                    .text = copy,
                                    .parent = ctx.previous_heading,
                                    .children = .empty,
                                },
                            };
                        },
                        else => return ctx.appendHorizontalRule(arena),
                    } else {
                        return ctx.appendHorizontalRule(arena);
                    }
                } else return ctx.appendTextNode(arena, skipped_line, options);
            },
            '*', '_' => |c| {
                if (std.mem.allEqual(u8, skipped_line, c)) {
                    return ctx.appendHorizontalRule(arena);
                }
                return ctx.appendTextNode(arena, skipped_line, options);
            },
            '`' => {
                if (std.mem.startsWith(u8, skipped_line, "```")) {
                    return ctx.appendCodeBlock(arena, skipped, skipped_line[3..]);
                }
            },
            '>' => {
                var depth: u8 = 1;
                while (depth < skipped_line.len and skipped_line[depth] == '>') {
                    depth += 1;
                }
                return ctx.appendBlockQuoteNode(arena, depth, skipped_line[depth..], options);
            },
            // '|' => {},
            // '[' => {},
            '0'...'9' => {
                const num_len = blk: {
                    var i: usize = 1;
                    while (i < skipped_line.len and std.ascii.isDigit(skipped_line[i])) : (i += 1) {}
                    break :blk i;
                };

                if (num_len + 1 < skipped_line.len and skipped_line[num_len] == '.' and skipped_line[num_len + 1] == ' ') {
                    return try ctx.appendListNode(
                        arena,
                        .{ .ordered = std.fmt.parseInt(usize, skipped_line[0..num_len], 10) catch unreachable },
                        skipped / 2,
                        skipped_line[num_len + 1 ..],
                        options,
                    );
                } else {
                    return ctx.appendTextNode(arena, skipped_line, options);
                }
            },
            else => {
                return ctx.appendTextNode(arena, skipped_line, options);
            },
        }
    }
};

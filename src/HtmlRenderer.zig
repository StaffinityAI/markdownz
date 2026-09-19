const std = @import("std");
const markdown = @import("markdown");

pub const Options = struct {
    document: bool = true,
    title: []const u8 = "Markdown document",
    language: []const u8 = "en",
};

pub fn render(writer: *std.Io.Writer, nodes: []const *markdown.Node, options: Options) !void {
    if (options.document) {
        try writer.writeAll("<!DOCTYPE html>\n<html lang=\"");
        try writeEscaped(writer, options.language, .attribute);
        try writer.writeAll("\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>");
        try writeEscaped(writer, options.title, .text);
        try writer.writeAll("</title>\n</head>\n<body>\n");
    }

    try renderNodes(writer, nodes);

    if (options.document) try writer.writeAll("</body>\n</html>\n");
}

pub fn renderAlloc(allocator: std.mem.Allocator, nodes: []const *markdown.Node, options: Options) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try render(&output.writer, nodes, options);
    return output.toOwnedSlice();
}

fn renderNodes(writer: *std.Io.Writer, nodes: []const *markdown.Node) std.Io.Writer.Error!void {
    for (nodes) |node| try renderNode(writer, node);
}

fn renderNode(writer: *std.Io.Writer, node: *markdown.Node) std.Io.Writer.Error!void {
    switch (node.*) {
        .heading => |heading| {
            try writer.print("<h{d}", .{heading.level});
            if (heading.id) |id| {
                try writer.writeAll(" id=\"");
                try writeEscaped(writer, id, .attribute);
                try writer.writeByte('"');
            }
            try writer.writeByte('>');
            try renderSections(writer, heading.text);
            try writer.print("</h{d}>\n", .{heading.level});
            try renderNodes(writer, heading.children.items);
        },
        .text => |sections| {
            try writer.writeAll("<p>");
            try renderSections(writer, sections);
            try writer.writeAll("</p>\n");
        },
        .line_break => try writer.writeAll("<br>\n"),
        .horizontal_rule => try writer.writeAll("<hr>\n"),
        .code_block => |block| {
            try writer.writeAll("<pre><code");
            if (block.language.len > 0) {
                const language = std.mem.trim(u8, block.language, " \t");
                const end = std.mem.indexOfAny(u8, language, " \t") orelse language.len;
                if (end > 0) {
                    try writer.writeAll(" class=\"language-");
                    try writeEscaped(writer, language[0..end], .attribute);
                    try writer.writeByte('"');
                }
            }
            try writer.writeByte('>');
            for (block.lines.items, 0..) |line, index| {
                if (index > 0) try writer.writeByte('\n');
                try writeEscaped(writer, line, .text);
            }
            try writer.writeAll("</code></pre>\n");
        },
        .list => |list| try renderList(writer, list.items),
        .block_quote => |quote| {
            try writer.writeAll("<blockquote>\n");
            try renderNodes(writer, quote.items);
            try writer.writeAll("</blockquote>\n");
        },
        .table => |columns| try renderTable(writer, columns),
        .footnote => |sections| {
            try writer.writeAll("<aside class=\"footnote\">");
            try renderSections(writer, sections);
            try writer.writeAll("</aside>\n");
        },
        .alert => try writer.writeAll("<aside class=\"alert\"></aside>\n"),
        .container => try writer.writeAll("<div class=\"container\"></div>\n"),
    }
}

fn renderList(writer: *std.Io.Writer, elements: []const *markdown.Node.Element) !void {
    var index: usize = 0;
    while (index < elements.len) {
        const tag: enum { ordered, unordered, task } = switch (elements[index].data) {
            .ordered => .ordered,
            .unordered => .unordered,
            .task => .task,
        };
        const start = index;
        while (index < elements.len and switch (elements[index].data) {
            .ordered => tag == .ordered,
            .unordered => tag == .unordered,
            .task => tag == .task,
        }) : (index += 1) {}

        switch (tag) {
            .ordered => {
                try writer.writeAll("<ol");
                const first = elements[start].data.ordered;
                if (first != 1) try writer.print(" start=\"{d}\"", .{first});
                try writer.writeAll(">\n");
            },
            .unordered => try writer.writeAll("<ul>\n"),
            .task => try writer.writeAll("<ul class=\"task-list\">\n"),
        }

        for (elements[start..index], 0..) |element, offset| {
            try writer.writeAll("<li");
            switch (element.data) {
                .ordered => |number| {
                    const expected = elements[start].data.ordered + offset;
                    if (number != expected) try writer.print(" value=\"{d}\"", .{number});
                },
                .task => try writer.writeAll(" class=\"task-list-item\""),
                .unordered => {},
            }
            try writer.writeByte('>');
            if (element.data == .task) {
                try writer.writeAll("<input type=\"checkbox\" disabled");
                if (element.data.task) try writer.writeAll(" checked");
                try writer.writeAll("> ");
            }
            try renderSections(writer, element.text);
            if (element.children.items.len > 0) {
                try writer.writeByte('\n');
                try renderList(writer, element.children.items);
            }
            try writer.writeAll("</li>\n");
        }

        try writer.writeAll(switch (tag) {
            .ordered => "</ol>\n",
            .unordered, .task => "</ul>\n",
        });
    }
}

fn renderTable(writer: *std.Io.Writer, columns: []const markdown.Node.Column) !void {
    try writer.writeAll("<table>\n");
    if (columns.len > 0) {
        try writer.writeAll("<thead>\n<tr>");
        for (columns) |column| {
            try writeTableCellStart(writer, "th", column.alignment);
            try renderSections(writer, column.header);
            try writer.writeAll("</th>");
        }
        try writer.writeAll("</tr>\n</thead>\n<tbody>\n");

        var row_count: usize = 0;
        for (columns) |column| row_count = @max(row_count, column.values.len);
        for (0..row_count) |row| {
            try writer.writeAll("<tr>");
            for (columns) |column| {
                try writeTableCellStart(writer, "td", column.alignment);
                if (row < column.values.len) try renderSections(writer, column.values[row]);
                try writer.writeAll("</td>");
            }
            try writer.writeAll("</tr>\n");
        }
        try writer.writeAll("</tbody>\n");
    }
    try writer.writeAll("</table>\n");
}

fn writeTableCellStart(writer: *std.Io.Writer, tag: []const u8, alignment: markdown.Node.Column.Alignment) !void {
    try writer.print("<{s} style=\"text-align: {s}\">", .{ tag, @tagName(alignment) });
}

fn renderSections(writer: *std.Io.Writer, sections: []const markdown.Node.Section) std.Io.Writer.Error!void {
    for (sections) |section| switch (section) {
        .default => |text| try writeEscaped(writer, text, .text),
        .code => |text| {
            try writer.writeAll("<code>");
            try writeEscaped(writer, text, .text);
            try writer.writeAll("</code>");
        },
        .bold_italic => |nested| try renderWrapped(writer, "<strong><em>", nested, "</em></strong>"),
        .bold => |nested| try renderWrapped(writer, "<strong>", nested, "</strong>"),
        .italic => |nested| try renderWrapped(writer, "<em>", nested, "</em>"),
        .underline => |nested| try renderWrapped(writer, "<u>", nested, "</u>"),
        .strike_through => |nested| try renderWrapped(writer, "<del>", nested, "</del>"),
        .highlight => |nested| try renderWrapped(writer, "<mark>", nested, "</mark>"),
        .subscript => |nested| try renderWrapped(writer, "<sub>", nested, "</sub>"),
        .superscript => |nested| try renderWrapped(writer, "<sup>", nested, "</sup>"),
        .emoji_shortcode => |name| {
            try writer.writeByte(':');
            try writeEscaped(writer, name, .text);
            try writer.writeByte(':');
        },
        .typographic => |text| try writeEscaped(writer, text, .text),
        .link => |link| {
            try writer.writeAll("<a href=\"");
            try writeEscaped(writer, link.url, .attribute);
            try writer.writeByte('"');
            if (link.hover_text.len > 0) {
                try writer.writeAll(" title=\"");
                try writeEscaped(writer, link.hover_text, .attribute);
                try writer.writeByte('"');
            }
            try writer.writeByte('>');
            try renderSections(writer, link.title);
            try writer.writeAll("</a>");
        },
        .image => |image| {
            try writer.writeAll("<img src=\"");
            try writeEscaped(writer, image.path, .attribute);
            try writer.writeAll("\" alt=\"");
            try renderPlainSections(writer, image.alt_text);
            try writer.writeByte('"');
            if (image.hover_text.len > 0) {
                try writer.writeAll(" title=\"");
                try writeEscaped(writer, image.hover_text, .attribute);
                try writer.writeByte('"');
            }
            if (image.size) |size| try writer.print(" width=\"{d}\" height=\"{d}\"", .{ size.width, size.height });
            try writer.writeByte('>');
        },
    };
}

fn renderWrapped(writer: *std.Io.Writer, open: []const u8, sections: []const markdown.Node.Section, close: []const u8) std.Io.Writer.Error!void {
    try writer.writeAll(open);
    try renderSections(writer, sections);
    try writer.writeAll(close);
}

fn renderPlainSections(writer: *std.Io.Writer, sections: []const markdown.Node.Section) std.Io.Writer.Error!void {
    for (sections) |section| switch (section) {
        .default, .code, .emoji_shortcode, .typographic => |text| try writeEscaped(writer, text, .attribute),
        .bold_italic, .bold, .italic, .underline, .strike_through, .highlight, .subscript, .superscript => |nested| try renderPlainSections(writer, nested),
        .link => |link| try renderPlainSections(writer, link.title),
        .image => |image| try renderPlainSections(writer, image.alt_text),
    };
}

const EscapeContext = enum { text, attribute };

fn writeEscaped(writer: *std.Io.Writer, value: []const u8, context: EscapeContext) !void {
    for (value) |byte| switch (byte) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => if (context == .attribute) try writer.writeAll("&quot;") else try writer.writeByte(byte),
        '\'' => if (context == .attribute) try writer.writeAll("&#39;") else try writer.writeByte(byte),
        else => try writer.writeByte(byte),
    };
}

test "full document metadata and text escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try markdown.parse(arena.allocator(), "<script>& text", .{});
    const html = try renderAlloc(std.testing.allocator, nodes, .{ .title = "A & <B>", .language = "en\"x" });
    defer std.testing.allocator.free(html);

    try std.testing.expectEqualStrings(
        "<!DOCTYPE html>\n<html lang=\"en&quot;x\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>A &amp; &lt;B&gt;</title>\n</head>\n<body>\n<p>&lt;script&gt;&amp; text</p>\n</body>\n</html>\n",
        html,
    );
}

test "headings blocks lists quotes code and tables" {
    const source =
        \\# Heading {custom}
        \\paragraph
        \\
        \\> quote
        \\- one
        \\  - nested
        \\3. three
        \\5. five
        \\- [x] done
        \\---
        \\```zig extra
        \\<tag>&
        \\```
        \\Name | Value
        \\:--- | ---:
        \\left | right
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try markdown.parse(arena.allocator(), source, .{});
    const html = try renderAlloc(std.testing.allocator, nodes, .{ .document = false });
    defer std.testing.allocator.free(html);

    try expectContains(html, "<h1 id=\"custom\">Heading</h1>");
    try expectContains(html, "<blockquote>\n<p>quote</p>\n</blockquote>");
    try expectContains(html, "<ul>\n<li>one\n<ul>\n<li>nested</li>");
    try expectContains(html, "<ol start=\"3\">\n<li>three</li>\n<li value=\"5\">five</li>");
    try expectContains(html, "<input type=\"checkbox\" disabled checked> done");
    try expectContains(html, "<hr>");
    try expectContains(html, "<pre><code class=\"language-zig\">&lt;tag&gt;&amp;</code></pre>");
    try expectContains(html, "<th style=\"text-align: left\">Name</th>");
    try expectContains(html, "<td style=\"text-align: right\">right</td>");
}

test "all inline concepts render recursively" {
    var plain = [_]markdown.Node.Section{.{ .default = "<&" }};
    var sections = [_]markdown.Node.Section{
        .{ .bold = &plain },
        .{ .italic = &plain },
        .{ .bold_italic = &plain },
        .{ .underline = &plain },
        .{ .strike_through = &plain },
        .{ .highlight = &plain },
        .{ .subscript = &plain },
        .{ .superscript = &plain },
        .{ .code = "<&" },
        .{ .emoji_shortcode = "sparkles" },
        .{ .typographic = "\xc2\xa9" },
        .{ .link = .{ .title = &plain, .url = "/a?x=1&y=\"2\"", .hover_text = "a'b" } },
        .{ .image = .{ .alt_text = &plain, .path = "x&\".png", .hover_text = "preview", .size = .{ .width = 10, .height = 20 } } },
    };
    var node: markdown.Node = .{ .text = &sections };
    const html = try renderAlloc(std.testing.allocator, &.{&node}, .{ .document = false });
    defer std.testing.allocator.free(html);

    inline for (.{ "<strong>&lt;&amp;</strong>", "<em>&lt;&amp;</em>", "<strong><em>&lt;&amp;</em></strong>", "<u>&lt;&amp;</u>", "<del>&lt;&amp;</del>", "<mark>&lt;&amp;</mark>", "<sub>&lt;&amp;</sub>", "<sup>&lt;&amp;</sup>", "<code>&lt;&amp;</code>", ":sparkles:", "\xc2\xa9" }) |expected| try expectContains(html, expected);
    try expectContains(html, "<a href=\"/a?x=1&amp;y=&quot;2&quot;\" title=\"a&#39;b\">&lt;&amp;</a>");
    try expectContains(html, "<img src=\"x&amp;&quot;.png\" alt=\"&lt;&amp;\" title=\"preview\" width=\"10\" height=\"20\">");
}

test "reserved block concepts have stable HTML" {
    var sections = [_]markdown.Node.Section{.{ .default = "note" }};
    var footnote: markdown.Node = .{ .footnote = &sections };
    var alert: markdown.Node = .alert;
    var container: markdown.Node = .container;
    const html = try renderAlloc(std.testing.allocator, &.{ &footnote, &alert, &container }, .{ .document = false });
    defer std.testing.allocator.free(html);
    try std.testing.expectEqualStrings("<aside class=\"footnote\">note</aside>\n<aside class=\"alert\"></aside>\n<div class=\"container\"></div>\n", html);
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

//! Terminal renderer for parsed markdown.
//!
//! `build` turns nodes into styled blocks, `Layout` measures blocks for a
//! terminal width and `paintBlock` draws them onto any cell `Surface`.
//! `render` combines these steps and writes ANSI-styled text for CLIs.

const std = @import("std");
const markdown = @import("markdown");
const uucode = @import("uucode");

pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    strikethrough: bool = false,
    reverse: bool = false,
};

pub const Span = struct {
    text: []const u8,
    style: Style = .{},
    link: ?[]const u8 = null,
};

pub const Table = struct {
    columns: []const Column,
    row_count: usize,

    pub const Column = struct {
        alignment: markdown.Node.Column.Alignment,
        header: []const Span,
        values: []const []const Span,
    };
};

pub const Block = struct {
    spans: []const Span = &.{},
    gap_before: u8 = 0,
    kind: Kind = .normal,

    pub const Kind = union(enum) {
        normal,
        heading: u8,
        code,
        /// A paragraph holding only an image, with this path. `spans` holds its caption.
        image: []const u8,
        table: Table,
        rule,
    };
};

pub const Document = struct {
    blocks: []const Block,
};

/// Builds styled blocks from `nodes`. Allocations are not freed individually,
/// so pass an arena. The result references the node text.
pub fn build(arena: std.mem.Allocator, nodes: []const *markdown.Node) !Document {
    var builder: Builder = .{ .allocator = arena };
    try builder.render(nodes, 0);
    return .{ .blocks = try builder.blocks.toOwnedSlice(arena) };
}

const ImageRef = struct {
    alt_text: []const markdown.Node.Section,
    path: []const u8,
};

const Builder = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,

    fn render(self: *Builder, nodes: []const *markdown.Node, quote_depth: usize) !void {
        for (nodes) |node| switch (node.*) {
            .heading => |heading| {
                var spans: std.ArrayList(Span) = .empty;
                try self.appendPrefix(&spans, quote_depth, "");
                try spans.append(self.allocator, .{
                    .text = headingMarker(heading.level),
                    .style = headingStyle(heading.level),
                });
                try self.appendSections(&spans, heading.text, headingStyle(heading.level), null);
                try self.addBlock(&spans, headingGap(heading.level), .{ .heading = heading.level });
                try self.render(heading.children.items, quote_depth);
            },
            .text => |sections| {
                if (standaloneImage(sections)) |image| {
                    var spans: std.ArrayList(Span) = .empty;
                    try spans.append(self.allocator, .{ .text = "Image: ", .style = .{ .bold = true, .fg = .{ .index = 6 } } });
                    try self.appendSections(&spans, image.alt_text, .{ .italic = true }, null);
                    try self.addBlock(&spans, 1, .{ .image = image.path });
                    continue;
                }

                var spans: std.ArrayList(Span) = .empty;
                try self.appendPrefix(&spans, quote_depth, "");
                try self.appendSections(&spans, sections, .{}, null);
                try self.addBlock(&spans, 0, .normal);
            },
            .line_break => try self.addTextBlock("", .{}),
            .horizontal_rule => try self.blocks.append(self.allocator, .{ .gap_before = 1, .kind = .rule }),
            .code_block => |block| {
                const label = if (block.language.len == 0) "code" else block.language;
                var header: std.ArrayList(Span) = .empty;
                try self.appendPrefix(&header, quote_depth, "");
                try header.append(self.allocator, .{ .text = "  " });
                try header.append(self.allocator, .{ .text = label, .style = .{ .bold = true, .fg = .{ .index = 6 } } });
                applyBackground(header.items, .{ .index = 0 });
                try self.addBlock(&header, 1, .code);
                for (block.lines.items) |line| {
                    var spans: std.ArrayList(Span) = .empty;
                    try self.appendPrefix(&spans, quote_depth, "    ");
                    try spans.append(self.allocator, .{ .text = line, .style = .{ .fg = .{ .index = 2 } } });
                    applyBackground(spans.items, .{ .index = 0 });
                    try self.addBlock(&spans, 0, .code);
                }
            },
            .list => |list| try self.renderList(list.items, 0, quote_depth),
            .block_quote => |nodes_in_quote| try self.render(nodes_in_quote.items, quote_depth + 1),
            .table => |columns| try self.renderTable(columns),
            .footnote => |sections| {
                var spans: std.ArrayList(Span) = .empty;
                try self.appendPrefix(&spans, quote_depth, "[^] ");
                try self.appendSections(&spans, sections, .{ .dim = true }, null);
                try self.addBlock(&spans, 0, .normal);
            },
            .alert => try self.addTextBlock("[alert]", .{ .bold = true, .fg = .{ .index = 3 } }),
            .container => try self.addTextBlock("[container]", .{ .dim = true }),
        };
    }

    fn renderList(self: *Builder, elements: []const *markdown.Node.Element, depth: usize, quote_depth: usize) !void {
        for (elements) |element| {
            var spans: std.ArrayList(Span) = .empty;
            try self.appendPrefix(&spans, quote_depth, "");
            const indent = try self.allocator.alloc(u8, depth * 2);
            @memset(indent, ' ');
            try spans.append(self.allocator, .{ .text = indent });

            const marker = switch (element.data) {
                .ordered => |number| try std.fmt.allocPrint(self.allocator, "{d}. ", .{number}),
                .unordered => "• ",
                .task => |done| if (done) "[x] " else "[ ] ",
            };
            try spans.append(self.allocator, .{ .text = marker, .style = .{ .bold = true, .fg = .{ .index = 6 } } });
            try self.appendSections(&spans, element.text, .{}, null);
            try self.addBlock(&spans, 0, .normal);
            try self.renderList(element.children.items, depth + 1, quote_depth);
        }
    }

    fn renderTable(self: *Builder, columns: []const markdown.Node.Column) !void {
        if (columns.len == 0) return;

        const rendered_columns = try self.allocator.alloc(Table.Column, columns.len);
        var row_count: usize = 0;
        for (rendered_columns, columns) |*rendered, column| {
            const header = try self.renderSections(column.header, .{ .bold = true, .fg = .{ .index = 15 }, .bg = .{ .index = 4 } });
            const values = try self.allocator.alloc([]const Span, column.values.len);
            for (values, column.values) |*value, sections| {
                value.* = try self.renderSections(sections, .{});
            }
            rendered.* = .{
                .alignment = column.alignment,
                .header = header,
                .values = values,
            };
            row_count = @max(row_count, values.len);
        }

        try self.blocks.append(self.allocator, .{
            .gap_before = 1,
            .kind = .{ .table = .{ .columns = rendered_columns, .row_count = row_count } },
        });
    }

    fn renderSections(self: *Builder, sections: []const markdown.Node.Section, style: Style) ![]const Span {
        var spans: std.ArrayList(Span) = .empty;
        try self.appendSections(&spans, sections, style, null);
        return spans.toOwnedSlice(self.allocator);
    }

    fn appendPrefix(self: *Builder, spans: *std.ArrayList(Span), quote_depth: usize, suffix: []const u8) !void {
        for (0..quote_depth) |_| {
            try spans.append(self.allocator, .{ .text = "│ ", .style = .{ .fg = .{ .index = 6 } } });
        }
        if (suffix.len > 0) try spans.append(self.allocator, .{ .text = suffix });
    }

    fn appendSections(
        self: *Builder,
        spans: *std.ArrayList(Span),
        sections: []const markdown.Node.Section,
        base_style: Style,
        link: ?[]const u8,
    ) !void {
        for (sections) |section| switch (section) {
            .default => |text| try spans.append(self.allocator, .{ .text = text, .style = base_style, .link = link }),
            .code => |text| {
                var style = base_style;
                style.fg = .{ .index = 2 };
                style.bg = .{ .index = 0 };
                try spans.append(self.allocator, .{ .text = text, .style = style, .link = link });
            },
            .bold => |nested| {
                var style = base_style;
                style.bold = true;
                try self.appendSections(spans, nested, style, link);
            },
            .italic => |nested| {
                var style = base_style;
                style.italic = true;
                try self.appendSections(spans, nested, style, link);
            },
            .bold_italic => |nested| {
                var style = base_style;
                style.bold = true;
                style.italic = true;
                try self.appendSections(spans, nested, style, link);
            },
            .underline => |nested| {
                var style = base_style;
                style.underline = true;
                try self.appendSections(spans, nested, style, link);
            },
            .strike_through => |nested| {
                var style = base_style;
                style.strikethrough = true;
                try self.appendSections(spans, nested, style, link);
            },
            .highlight => |nested| {
                var style = base_style;
                style.fg = .{ .index = 0 };
                style.bg = .{ .index = 3 };
                try self.appendSections(spans, nested, style, link);
            },
            .link => |value| {
                var style = base_style;
                style.fg = .{ .index = 4 };
                style.underline = true;
                try self.appendSections(spans, value.title, style, value.url);
            },
            .image => |image| {
                try spans.append(self.allocator, .{ .text = "[image: ", .style = .{ .dim = true } });
                try self.appendSections(spans, image.alt_text, .{ .dim = true }, null);
                try spans.append(self.allocator, .{ .text = "]", .style = .{ .dim = true } });
            },
            .emoji_shortcode => |name| {
                try spans.append(self.allocator, .{ .text = ":" });
                try spans.append(self.allocator, .{ .text = name, .style = .{ .fg = .{ .index = 5 } } });
                try spans.append(self.allocator, .{ .text = ":" });
            },
            .subscript => |nested| try self.appendSections(spans, nested, base_style, link),
            .superscript => |nested| try self.appendSections(spans, nested, base_style, link),
            .typographic => |text| try spans.append(self.allocator, .{ .text = text, .style = base_style, .link = link }),
        };
    }

    fn addTextBlock(self: *Builder, text: []const u8, style: Style) !void {
        const spans = try self.allocator.alloc(Span, 1);
        spans[0] = .{ .text = text, .style = style };
        try self.blocks.append(self.allocator, .{ .spans = spans });
    }

    fn addBlock(self: *Builder, spans: *std.ArrayList(Span), gap_before: u8, kind: Block.Kind) !void {
        try self.blocks.append(self.allocator, .{
            .spans = try spans.toOwnedSlice(self.allocator),
            .gap_before = gap_before,
            .kind = kind,
        });
    }
};

fn standaloneImage(sections: []const markdown.Node.Section) ?ImageRef {
    if (sections.len != 1) return null;
    return switch (sections[0]) {
        .image => |image| .{ .alt_text = image.alt_text, .path = image.path },
        else => null,
    };
}

fn applyBackground(spans: []Span, background: Color) void {
    for (spans) |*item| item.style.bg = background;
}

fn headingStyle(level: u8) Style {
    return switch (level) {
        1 => .{ .bold = true, .fg = .{ .index = 15 }, .bg = .{ .index = 5 } },
        2 => .{ .bold = true, .fg = .{ .index = 15 }, .bg = .{ .index = 4 } },
        3 => .{ .bold = true, .underline = true, .fg = .{ .index = 6 } },
        4 => .{ .bold = true, .fg = .{ .index = 3 } },
        5 => .{ .bold = true, .dim = true, .fg = .{ .index = 6 } },
        else => .{ .italic = true, .dim = true },
    };
}

fn headingMarker(level: u8) []const u8 {
    return switch (level) {
        1 => "  ◆  ",
        2 => "  ◇  ",
        3 => "▸ ",
        4 => "› ",
        5 => "· ",
        else => "  ",
    };
}

fn headingGap(level: u8) u8 {
    return switch (level) {
        1, 2 => 2,
        3, 4 => 1,
        else => 0,
    };
}

/// Measures the column width of a grapheme cluster.
pub const Measure = struct {
    context: ?*const anyopaque = null,
    widthFn: *const fn (context: ?*const anyopaque, grapheme: []const u8) u16 = unicodeWidth,

    /// Widths from Unicode properties, matching libvaxis' `.unicode` width method.
    pub const unicode: Measure = .{};

    pub fn width(self: Measure, grapheme: []const u8) u16 {
        return self.widthFn(self.context, grapheme);
    }

    pub fn textWidth(self: Measure, text: []const u8) usize {
        var total: usize = 0;
        var graphemes = uucode.grapheme.utf8Iterator(text);
        while (graphemes.nextGrapheme()) |grapheme| total += self.width(text[grapheme.start..grapheme.end]);
        return total;
    }

    fn unicodeWidth(_: ?*const anyopaque, grapheme: []const u8) u16 {
        return stringWidth(grapheme);
    }
};

/// Returns the column width of `text`. Ported from libvaxis' `gwidth` `.unicode` method.
pub fn stringWidth(text: []const u8) u16 {
    var total: u16 = 0;
    var graphemes = uucode.grapheme.utf8Iterator(text);
    while (graphemes.nextGrapheme()) |grapheme| {
        var code_points = uucode.utf8.Iterator.init(text[grapheme.start..grapheme.end]);
        var width: i16 = 0;
        var has_emoji_vs = false;
        var has_text_vs = false;
        var has_emoji_presentation = false;
        var regional_indicators: u8 = 0;
        while (code_points.next()) |cp| {
            if (cp == 0xfe0f) {
                has_emoji_vs = true;
                continue;
            }
            if (cp == 0xfe0e) {
                has_text_vs = true;
                continue;
            }
            if (uucode.get(.is_emoji_presentation, cp)) has_emoji_presentation = true;
            if (cp >= 0x1f1e6 and cp <= 0x1f1ff) regional_indicators += 1;
            width = @max(width, codePointWidth(cp));
        }

        if (has_text_vs) {
            width = @max(1, width);
        } else if (has_emoji_vs or has_emoji_presentation or regional_indicators == 2) {
            width = @max(2, width);
        }
        total +|= @intCast(@max(0, width));
    }
    return total;
}

fn codePointWidth(cp: u21) i16 {
    if (cp == 0) return 0;
    if (cp < 32 or (cp >= 0x7f and cp < 0xa0)) return -1;
    switch (uucode.get(.general_category, cp)) {
        .mark_nonspacing, .mark_enclosing => return 0,
        else => {},
    }
    switch (cp) {
        0x00ad, 0x200b, 0x200c, 0x200d, 0x2060, 0x034f, 0xfeff => return 0,
        0x180b...0x180d, 0xfe00...0xfe0f, 0xe0100...0xe01ef => return 0,
        else => {},
    }
    // Ambiguous characters are one column wide, as with glibc's wcwidth.
    return switch (uucode.get(.east_asian_width, cp)) {
        .fullwidth, .wide => 2,
        else => 1,
    };
}

/// Word-wraps `spans` to `width` columns and calls
/// `visitor.glyph(row, col, grapheme, width, span)` for every cell it fills.
/// Returns the number of rows used, at least one.
pub fn wrap(spans: []const Span, width: u16, measure: Measure, col_offset: u16, visitor: anytype) usize {
    if (spans.len == 0) return 1;
    var row: usize = 0;
    var col: usize = col_offset;
    var soft_wrapped = false;
    var in_word = false;
    for (spans) |span| {
        var lines: TextLineIterator = .{ .buf = span.text };
        while (lines.next()) |line| {
            var tokens: WordTokenizer = .{ .buf = line };
            while (tokens.next()) |token| switch (token) {
                .whitespace => |len| {
                    in_word = false;
                    if (soft_wrapped) continue;
                    for (0..len) |_| {
                        if (col >= width) {
                            col = 0;
                            row += 1;
                            break;
                        }
                        visitor.glyph(row, col, " ", 1, span);
                        col += 1;
                    }
                },
                .word => |word| {
                    const word_width = measure.textWidth(word);
                    if (!in_word and word_width + col > width and word_width <= width) {
                        row += 1;
                        col = 0;
                    }
                    in_word = true;
                    var graphemes = uucode.grapheme.utf8Iterator(word);
                    while (graphemes.nextGrapheme()) |grapheme| {
                        soft_wrapped = false;
                        const bytes = word[grapheme.start..grapheme.end];
                        const grapheme_width = measure.width(bytes);
                        if (grapheme_width == 0) continue;
                        if (grapheme_width > width) continue;
                        if (col != 0 and col + grapheme_width > width) {
                            row += 1;
                            col = 0;
                        }
                        visitor.glyph(row, col, bytes, grapheme_width, span);
                        col += grapheme_width;
                        if (col >= width) {
                            row += 1;
                            col = 0;
                            soft_wrapped = true;
                        }
                    }
                },
            };
            if (lines.has_break) {
                soft_wrapped = false;
                in_word = false;
                row += 1;
                col = 0;
            }
        }
    }
    return @max(row + @intFromBool(col > 0), 1);
}

/// Returns the rows `spans` take when wrapped to `width` columns.
pub fn measureHeight(spans: []const Span, width: u16, measure: Measure) usize {
    const Ignore = struct {
        fn glyph(_: @This(), _: usize, _: usize, _: []const u8, _: u16, _: Span) void {}
    };
    return wrap(spans, width, measure, 0, Ignore{});
}

const TextLineIterator = struct {
    buf: []const u8,
    index: usize = 0,
    has_break: bool = true,

    fn next(self: *TextLineIterator) ?[]const u8 {
        if (self.index >= self.buf.len) return null;
        const start = self.index;
        const end = std.mem.indexOfAnyPos(u8, self.buf, self.index, "\r\n") orelse {
            self.has_break = false;
            self.index = self.buf.len;
            return self.buf[start..];
        };
        self.index = end;
        if (self.index < self.buf.len and self.buf[self.index] == '\r') self.index += 1;
        if (self.index < self.buf.len and self.buf[self.index] == '\n') self.index += 1;
        return self.buf[start..end];
    }
};

const WordTokenizer = struct {
    buf: []const u8,
    index: usize = 0,

    const Token = union(enum) {
        whitespace: usize,
        word: []const u8,
    };

    fn next(self: *WordTokenizer) ?Token {
        if (self.index >= self.buf.len) return null;
        if (self.buf[self.index] == ' ' or self.buf[self.index] == '\t') {
            var len: usize = 0;
            while (self.index < self.buf.len) : (self.index += 1) switch (self.buf[self.index]) {
                ' ' => len += 1,
                '\t' => len += 8,
                else => break,
            };
            return .{ .whitespace = len };
        }
        const start = self.index;
        while (self.index < self.buf.len and self.buf[self.index] != ' ' and self.buf[self.index] != '\t') : (self.index += 1) {}
        return .{ .word = self.buf[start..self.index] };
    }
};

pub const LayoutOptions = struct {
    width: u16,
    measure: Measure = .unicode,
    /// Rows reserved for standalone images. Null measures their caption instead.
    image_height: ?usize = null,
};

/// Returns the rows `block` takes, not counting `gap_before`.
pub fn blockHeight(block: Block, options: LayoutOptions) usize {
    return switch (block.kind) {
        .rule => 1,
        .normal, .code => measureHeight(block.spans, options.width, options.measure),
        .image => options.image_height orelse measureHeight(block.spans, options.width, options.measure),
        .table => |table| tableHeight(table, options.width, options.measure),
        .heading => |level| measureHeight(block.spans, options.width, options.measure) + @as(usize, switch (level) {
            1 => 2,
            2 => 1,
            else => 0,
        }),
    };
}

/// Row positions of every block for one width, for scrolling views.
pub const Layout = struct {
    width: u16 = 0,
    starts: std.ArrayList(usize) = .empty,
    heights: std.ArrayList(usize) = .empty,
    total_rows: usize = 0,

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        self.starts.deinit(allocator);
        self.heights.deinit(allocator);
    }

    /// Recomputes the layout unless it already matches the width and block count.
    pub fn update(self: *Layout, allocator: std.mem.Allocator, blocks: []const Block, options: LayoutOptions) !void {
        if (self.width == options.width and self.starts.items.len == blocks.len) return;
        self.width = options.width;
        self.starts.clearRetainingCapacity();
        self.heights.clearRetainingCapacity();
        var total: usize = 0;
        for (blocks) |block| {
            total += block.gap_before;
            try self.starts.append(allocator, total);
            const height = blockHeight(block, options);
            try self.heights.append(allocator, height);
            total += height;
        }
        self.total_rows = total;
    }

    /// Returns the index of the first block that ends below row `scroll`.
    pub fn firstVisible(self: Layout, scroll: usize) usize {
        var low: usize = 0;
        var high = self.starts.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.starts.items[mid] + self.heights.items[mid] <= scroll) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }
};

const TableWidths = struct {
    total: u16,
    columns: usize,
    base: u16,
    remainder: u16,

    fn width(self: TableWidths, index: usize) u16 {
        return self.base + @intFromBool(index < self.remainder);
    }

    fn offset(self: TableWidths, index: usize) u16 {
        return @intCast(index * self.base + @min(index, self.remainder));
    }
};

fn tableColumnWidths(total_width: u16, columns: usize) TableWidths {
    const inner_width = total_width -| @as(u16, @intCast(columns + 1));
    return .{
        .total = total_width,
        .columns = columns,
        .base = @max(inner_width / @as(u16, @intCast(columns)), 3),
        .remainder = inner_width % @as(u16, @intCast(columns)),
    };
}

fn tableFits(table: Table, width: u16) bool {
    return table.columns.len > 0 and width >= table.columns.len * 4 + 1;
}

fn tableHeight(table: Table, width: u16, measure: Measure) usize {
    if (table.columns.len == 0) return 0;
    if (!tableFits(table, width)) return 1;
    const widths = tableColumnWidths(width, table.columns.len);
    var height: usize = 2;
    height += tableRowHeight(table, widths, null, measure);
    for (0..table.row_count) |row| height += tableRowHeight(table, widths, row, measure) + 1;
    return height;
}

fn tableRowHeight(table: Table, widths: TableWidths, row: ?usize, measure: Measure) usize {
    var height: usize = 1;
    for (table.columns, 0..) |column, index| {
        height = @max(height, measureHeight(tableCell(column, row), widths.width(index) -| 2, measure));
    }
    return height;
}

fn tableCell(column: Table.Column, row: ?usize) []const Span {
    const index = row orelse return column.header;
    return if (index < column.values.len) column.values[index] else &.{};
}

pub const Cell = struct {
    grapheme: []const u8 = " ",
    width: u8 = 1,
    style: Style = .{},
    link: ?[]const u8 = null,
    /// The text continues on the next row.
    wrapped: bool = false,
};

/// A destination for cells, such as a terminal screen or a `Grid`.
pub const Surface = struct {
    context: *anyopaque,
    writeCellFn: *const fn (context: *anyopaque, col: u16, row: u16, cell: Cell) void,
};

/// A clipped rectangle of a `Surface`.
pub const Region = struct {
    surface: Surface,
    x: u16 = 0,
    y: u16 = 0,
    width: u16,
    height: u16,

    pub const ChildOptions = struct {
        x_off: u16 = 0,
        y_off: u16 = 0,
        width: ?u16 = null,
        height: ?u16 = null,
    };

    /// Returns a sub-rectangle, clipped to this region.
    pub fn child(self: Region, options: ChildOptions) Region {
        const x_off = @min(options.x_off, self.width);
        const y_off = @min(options.y_off, self.height);
        return .{
            .surface = self.surface,
            .x = self.x + x_off,
            .y = self.y + y_off,
            .width = @min(options.width orelse std.math.maxInt(u16), self.width - x_off),
            .height = @min(options.height orelse std.math.maxInt(u16), self.height - y_off),
        };
    }

    pub fn writeCell(self: Region, col: u16, row: u16, cell: Cell) void {
        if (col >= self.width or row >= self.height) return;
        self.surface.writeCellFn(self.surface.context, self.x + col, self.y + row, cell);
    }

    pub fn fill(self: Region, cell: Cell) void {
        for (0..self.height) |row| {
            for (0..self.width) |col| self.writeCell(@intCast(col), @intCast(row), cell);
        }
    }
};

/// Paints the rows of `block` from `skipped_rows` on into `region`.
/// `height` is the block's height from `blockHeight`.
pub fn paintBlock(region: Region, block: Block, height: usize, skipped_rows: usize, measure: Measure) void {
    switch (block.kind) {
        .rule => if (skipped_rows == 0) paintRule(region),
        .heading => |level| {
            paintHeadingBackground(region, level);
            paintSpans(region, block.spans, skipped_rows, if (level == 1) 1 else 0, 0, measure);
            if (level == 2) paintHeadingDivider(region, height, skipped_rows);
        },
        .code => {
            region.fill(.{ .style = .{ .bg = .{ .index = 0 } } });
            paintSpans(region, block.spans, skipped_rows, 0, 0, measure);
        },
        .table => |table| paintTable(region, table, skipped_rows, measure),
        .image, .normal => paintSpans(region, block.spans, skipped_rows, 0, 0, measure),
    }
}

/// Paints wrapped `spans` into `region`, which shows them from row `skipped_rows` on.
/// The text starts `row_offset` rows down and its first row `col_offset` columns in.
pub fn paintSpans(region: Region, spans: []const Span, skipped_rows: usize, row_offset: usize, col_offset: u16, measure: Measure) void {
    const Painter = struct {
        region: Region,
        skipped_rows: usize,
        row_offset: usize,

        fn glyph(self: @This(), text_row: usize, col: usize, grapheme: []const u8, width: u16, span: Span) void {
            const row = text_row + self.row_offset;
            if (row < self.skipped_rows or row >= self.skipped_rows + self.region.height or col >= self.region.width) return;
            self.region.writeCell(@intCast(col), @intCast(row - self.skipped_rows), .{
                .grapheme = grapheme,
                .width = @intCast(width),
                .style = span.style,
                .link = span.link,
                .wrapped = col + width >= self.region.width,
            });
        }
    };
    _ = wrap(spans, region.width, measure, col_offset, Painter{
        .region = region,
        .skipped_rows = skipped_rows,
        .row_offset = row_offset,
    });
}

const border_style: Style = .{ .fg = .{ .index = 8 } };

fn paintRule(region: Region) void {
    for (0..region.width) |col| region.writeCell(@intCast(col), 0, .{ .grapheme = "─", .style = border_style });
}

fn paintHeadingBackground(region: Region, level: u8) void {
    if (level > 2) return;
    region.fill(.{ .style = headingStyle(level) });
}

fn paintHeadingDivider(region: Region, height: usize, skipped_rows: usize) void {
    if (height == 0 or height - 1 < skipped_rows or height - 1 >= skipped_rows + region.height) return;
    const row: u16 = @intCast(height - 1 - skipped_rows);
    for (0..region.width) |col| region.writeCell(@intCast(col), row, .{
        .grapheme = "─",
        .style = .{ .fg = .{ .index = 6 }, .bg = .{ .index = 4 } },
    });
}

const TableBorderKind = enum { top, middle, bottom };

fn paintTable(region: Region, table: Table, skipped_rows: usize, measure: Measure) void {
    if (!tableFits(table, region.width)) {
        if (skipped_rows == 0) paintSpans(region, &.{.{ .text = "[table too wide for terminal]", .style = .{ .dim = true } }}, 0, 0, 0, measure);
        return;
    }

    const widths = tableColumnWidths(region.width, table.columns.len);
    var block_row: usize = 0;
    paintVisibleTableBorder(region, block_row, skipped_rows, widths, .top);
    block_row += 1;
    const header_height = tableRowHeight(table, widths, null, measure);
    paintVisibleTableRow(region, block_row, skipped_rows, table, widths, null, header_height, measure);
    block_row += header_height;
    paintVisibleTableBorder(region, block_row, skipped_rows, widths, if (table.row_count == 0) .bottom else .middle);
    block_row += 1;
    for (0..table.row_count) |row_index| {
        if (block_row >= skipped_rows + region.height) break;
        const height = tableRowHeight(table, widths, row_index, measure);
        paintVisibleTableRow(region, block_row, skipped_rows, table, widths, row_index, height, measure);
        block_row += height;
        paintVisibleTableBorder(region, block_row, skipped_rows, widths, if (row_index + 1 == table.row_count) .bottom else .middle);
        block_row += 1;
    }
}

fn paintVisibleTableBorder(region: Region, block_row: usize, skipped_rows: usize, widths: TableWidths, kind: TableBorderKind) void {
    if (block_row < skipped_rows or block_row >= skipped_rows + region.height) return;
    paintTableBorder(region, @intCast(block_row - skipped_rows), widths, kind);
}

fn paintVisibleTableRow(
    region: Region,
    block_row: usize,
    skipped_rows: usize,
    table: Table,
    widths: TableWidths,
    row_index: ?usize,
    height: usize,
    measure: Measure,
) void {
    const row_end = block_row + height;
    if (row_end <= skipped_rows or block_row >= skipped_rows + region.height) return;
    const skipped = skipped_rows -| block_row;
    const screen_row = block_row -| skipped_rows;
    const row_region = region.child(.{
        .y_off = @intCast(screen_row),
        .height = @intCast(@min(height - skipped, region.height - screen_row)),
    });
    paintTableRow(row_region, table, widths, row_index, skipped, measure);
}

fn paintTableRow(region: Region, table: Table, widths: TableWidths, row_index: ?usize, skipped: usize, measure: Measure) void {
    const fill_style: Style = if (row_index) |index|
        if (index % 2 == 1) .{ .bg = .{ .index = 0 } } else .{}
    else
        .{ .fg = .{ .index = 15 }, .bg = .{ .index = 4 }, .bold = true };

    for (0..region.height) |line| {
        region.writeCell(0, @intCast(line), .{ .grapheme = "│", .style = border_style });
        for (0..table.columns.len) |index| {
            const cell_x = widths.offset(index) + @as(u16, @intCast(index + 1));
            region.writeCell(cell_x + widths.width(index), @intCast(line), .{ .grapheme = "│", .style = border_style });
        }
    }

    for (table.columns, 0..) |column, index| {
        const cell = region.child(.{
            .x_off = widths.offset(index) + @as(u16, @intCast(index + 1)),
            .width = widths.width(index),
        });
        cell.fill(.{ .style = fill_style });

        const spans = tableCell(column, row_index);
        const content = cell.child(.{ .x_off = 1, .width = cell.width -| 2 });
        const col_offset = tableTextOffset(content.width, spans, column.alignment, measure);
        paintSpans(content, spans, skipped, 0, col_offset, measure);
    }
}

fn tableTextOffset(width: u16, spans: []const Span, alignment: markdown.Node.Column.Alignment, measure: Measure) u16 {
    if (alignment == .left) return 0;
    const Extent = struct {
        end: usize = 0,

        fn glyph(self: *@This(), _: usize, col: usize, _: []const u8, glyph_width: u16, _: Span) void {
            self.end = @max(self.end, col + glyph_width);
        }
    };
    var extent: Extent = .{};
    if (wrap(spans, width, measure, 0, &extent) != 1) return 0;
    const remaining: u16 = @intCast(width -| extent.end);
    return switch (alignment) {
        .left => 0,
        .center => remaining / 2,
        .right => remaining,
    };
}

fn paintTableBorder(region: Region, row: u16, widths: TableWidths, kind: TableBorderKind) void {
    const left: []const u8, const join: []const u8, const right: []const u8 = switch (kind) {
        .top => .{ "┌", "┬", "┐" },
        .middle => .{ "├", "┼", "┤" },
        .bottom => .{ "└", "┴", "┘" },
    };
    region.writeCell(0, row, .{ .grapheme = left, .style = border_style });
    for (0..widths.columns) |index| {
        const start = widths.offset(index) + @as(u16, @intCast(index + 1));
        for (0..widths.width(index)) |offset| {
            region.writeCell(start + @as(u16, @intCast(offset)), row, .{ .grapheme = "─", .style = border_style });
        }
        region.writeCell(start + widths.width(index), row, .{
            .grapheme = if (index + 1 == widths.columns) right else join,
            .style = border_style,
        });
    }
}

/// An in-memory `Surface`. Cells covered by a wide grapheme have width 0.
pub const Grid = struct {
    width: u16,
    height: u16,
    cells: []Cell,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !Grid {
        const cells = try allocator.alloc(Cell, @as(usize, width) * height);
        @memset(cells, .{});
        return .{ .width = width, .height = height, .cells = cells };
    }

    pub fn deinit(self: *Grid, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }

    pub fn clear(self: *Grid) void {
        @memset(self.cells, .{});
    }

    pub fn region(self: *Grid) Region {
        return .{
            .surface = .{ .context = self, .writeCellFn = writeCell },
            .width = self.width,
            .height = self.height,
        };
    }

    pub fn row(self: Grid, index: u16) []const Cell {
        return self.cells[@as(usize, index) * self.width ..][0..self.width];
    }

    fn writeCell(context: *anyopaque, col: u16, row_index: u16, cell: Cell) void {
        const self: *Grid = @ptrCast(@alignCast(context));
        if (col >= self.width or row_index >= self.height) return;
        const index = @as(usize, row_index) * self.width + col;
        self.cells[index] = cell;
        for (1..cell.width) |offset| {
            if (col + offset >= self.width) break;
            self.cells[index + offset] = .{ .grapheme = "", .width = 0, .style = cell.style, .link = cell.link };
        }
    }
};

pub const Options = struct {
    width: u16 = 80,
    measure: Measure = .unicode,
    /// Emit SGR styles and OSC 8 hyperlinks. Disable for plain text.
    color: bool = true,
};

/// Rows painted at once, so tall blocks do not need a grid of their full height.
const chunk_rows = 256;

/// Writes `nodes` as terminal text, one line per row.
pub fn render(allocator: std.mem.Allocator, writer: *std.Io.Writer, nodes: []const *markdown.Node, options: Options) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try renderDocument(allocator, writer, try build(arena.allocator(), nodes), options);
}

pub fn renderAlloc(allocator: std.mem.Allocator, nodes: []const *markdown.Node, options: Options) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try render(allocator, &output.writer, nodes, options);
    return output.toOwnedSlice();
}

pub fn renderDocument(allocator: std.mem.Allocator, writer: *std.Io.Writer, document: Document, options: Options) !void {
    const width = @max(options.width, 1);
    var grid = try Grid.init(allocator, width, chunk_rows);
    defer grid.deinit(allocator);
    const layout_options: LayoutOptions = .{ .width = width, .measure = options.measure };
    for (document.blocks, 0..) |block, index| {
        if (index > 0) try writer.splatByteAll('\n', block.gap_before);
        const height = blockHeight(block, layout_options);
        var start: usize = 0;
        while (start < height) : (start += chunk_rows) {
            const rows: u16 = @intCast(@min(height - start, chunk_rows));
            grid.clear();
            paintBlock(grid.region().child(.{ .height = rows }), block, height, start, options.measure);
            for (0..rows) |row| try writeRow(writer, grid.row(@intCast(row)), options.color);
        }
    }
}

fn writeRow(writer: *std.Io.Writer, cells: []const Cell, color: bool) !void {
    var end = cells.len;
    while (end > 0 and isBlank(cells[end - 1], color)) end -= 1;

    var style: Style = .{};
    var link: ?[]const u8 = null;
    for (cells[0..end]) |cell| {
        if (cell.width == 0) continue;
        if (color) {
            if (!optionalEql(link, cell.link)) {
                try writeLink(writer, cell.link);
                link = cell.link;
            }
            if (!std.meta.eql(style, cell.style)) {
                try writeStyle(writer, cell.style);
                style = cell.style;
            }
        }
        try writer.writeAll(cell.grapheme);
    }
    if (link != null) try writeLink(writer, null);
    if (!std.meta.eql(style, Style{})) try writer.writeAll("\x1b[0m");
    try writer.writeByte('\n');
}

fn isBlank(cell: Cell, color: bool) bool {
    if (cell.width != 1 or !std.mem.eql(u8, cell.grapheme, " ")) return false;
    if (!color) return true;
    return cell.style.bg == .default and !cell.style.reverse and !cell.style.underline and !cell.style.strikethrough;
}

fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn writeLink(writer: *std.Io.Writer, uri: ?[]const u8) !void {
    try writer.print("\x1b]8;;{s}\x1b\\", .{uri orelse ""});
}

fn writeStyle(writer: *std.Io.Writer, style: Style) !void {
    try writer.writeAll("\x1b[0");
    if (style.bold) try writer.writeAll(";1");
    if (style.dim) try writer.writeAll(";2");
    if (style.italic) try writer.writeAll(";3");
    if (style.underline) try writer.writeAll(";4");
    if (style.reverse) try writer.writeAll(";7");
    if (style.strikethrough) try writer.writeAll(";9");
    try writeColor(writer, style.fg, 30);
    try writeColor(writer, style.bg, 40);
    try writer.writeByte('m');
}

/// `base` is 30 for foreground and 40 for background colors.
fn writeColor(writer: *std.Io.Writer, color: Color, base: u8) !void {
    switch (color) {
        .default => {},
        .index => |index| if (index < 8)
            try writer.print(";{d}", .{base + index})
        else if (index < 16)
            try writer.print(";{d}", .{base + 60 + index - 8})
        else
            try writer.print(";{d};5;{d}", .{ base + 8, index }),
        .rgb => |rgb| try writer.print(";{d};2;{d};{d};{d}", .{ base + 8, rgb[0], rgb[1], rgb[2] }),
    }
}

fn testGrid(width: u16, height: u16) !Grid {
    return Grid.init(std.testing.allocator, width, height);
}

fn gridText(grid: Grid, row: u16) []const u8 {
    return grid.row(row)[0].grapheme;
}

test "line measurement exceeds u16 row limits" {
    const text = try std.testing.allocator.alloc(u8, 70_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    try std.testing.expect(measureHeight(&.{.{ .text = text }}, 1, .unicode) > std.math.maxInt(u16));
}

test "wrapping handles wide zero-width and styled newline spans" {
    var grid = try testGrid(3, 4);
    defer grid.deinit(std.testing.allocator);
    const wide = &[_]Span{.{ .text = "ab😀" }};
    try std.testing.expectEqual(@as(usize, 2), measureHeight(wide, 3, .unicode));
    paintSpans(grid.region(), wide, 0, 0, 0, .unicode);
    try std.testing.expectEqualStrings("a", gridText(grid, 0));
    try std.testing.expectEqualStrings("😀", gridText(grid, 1));
    try std.testing.expectEqual(@as(u8, 0), grid.row(1)[1].width);

    const styled = &[_]Span{
        .{ .text = "a\nb", .style = .{ .bold = true } },
        .{ .text = "c", .style = .{ .italic = true } },
    };
    try std.testing.expectEqual(@as(usize, 2), measureHeight(styled, 3, .unicode));

    const zero_width = &[_]Span{.{ .text = "a\u{200b}b" }};
    try std.testing.expectEqual(@as(usize, 1), measureHeight(zero_width, 3, .unicode));
}

test "extreme table cells paint visible slices" {
    var grid = try testGrid(5, 3);
    defer grid.deinit(std.testing.allocator);

    const text = try std.testing.allocator.alloc(u8, 70_000);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    const values = [_][]const Span{&.{.{ .text = text }}};
    const columns = [_]Table.Column{.{
        .alignment = .left,
        .header = &.{.{ .text = "H" }},
        .values = &values,
    }};
    const table: Table = .{ .columns = &columns, .row_count = 1 };
    paintVisibleTableRow(grid.region(), 0, 65_536, table, tableColumnWidths(5, 1), 0, 70_000, .unicode);
    try std.testing.expectEqualStrings("a", grid.row(0)[2].grapheme);
}

test "layout caches heights and locates visible blocks" {
    const blocks = [_]Block{
        .{ .spans = &.{.{ .text = "first" }} },
        .{ .spans = &.{.{ .text = "second" }}, .gap_before = 2 },
    };
    var layout: Layout = .{};
    defer layout.deinit(std.testing.allocator);
    try layout.update(std.testing.allocator, &blocks, .{ .width = 10 });
    try std.testing.expectEqualSlices(usize, &.{ 0, 3 }, layout.starts.items);
    try std.testing.expectEqual(@as(usize, 4), layout.total_rows);
    try std.testing.expectEqual(@as(usize, 1), layout.firstVisible(2));
}

test "string width follows unicode properties" {
    try std.testing.expectEqual(@as(u16, 1), stringWidth("a"));
    try std.testing.expectEqual(@as(u16, 2), stringWidth("😀"));
    try std.testing.expectEqual(@as(u16, 2), stringWidth("日"));
    try std.testing.expectEqual(@as(u16, 2), stringWidth("👩🏽‍🚀"));
    try std.testing.expectEqual(@as(u16, 1), stringWidth("e\u{301}"));
}

fn expectRender(source: []const u8, options: Options, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try markdown.parse(arena.allocator(), source, .{});
    const output = try renderAlloc(std.testing.allocator, nodes, options);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(expected, output);
}

test "plain rendering wraps paragraphs and lists" {
    try expectRender(
        \\Some words that wrap here.
        \\
        \\- one
        \\- [x] done
    , .{ .width = 12, .color = false },
        \\Some words
        \\that wrap
        \\here.
        \\• one
        \\[x] done
        \\
    );
}

test "plain rendering draws tables and rules" {
    try expectRender(
        \\| A | B |
        \\| --- | ---: |
        \\| x | 1 |
        \\
        \\---
    , .{ .width = 11, .color = false },
        \\┌────┬────┐
        \\│ A  │  B │
        \\├────┼────┤
        \\│ x  │  1 │
        \\└────┴────┘
        \\
        \\───────────
        \\
    );
}

test "styled rendering emits SGR and hyperlinks" {
    try expectRender("**bold** [site](https://example.com)", .{ .width = 40 }, "\x1b[0;1mbold\x1b[0m \x1b]8;;https://example.com\x1b\\\x1b[0;4;34msite\x1b]8;;\x1b\\\x1b[0m\n");
}

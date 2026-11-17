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
    /// Drawn left of the first text row, such as quote bars and a list marker.
    prefix: []const Span = &.{},
    /// Drawn left of every other row, such as quote bars and a hanging indent.
    /// The text starts right of the wider of `prefix` and `continuation`.
    continuation: []const Span = &.{},
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
                try spans.append(self.allocator, .{
                    .text = headingMarker(heading.level),
                    .style = headingStyle(heading.level),
                });
                try self.appendSections(&spans, heading.text, headingStyle(heading.level), null);
                const bars = try self.quoteBars(quote_depth, "");
                try self.addBlock(&spans, .{ .prefix = bars, .continuation = bars, .gap_before = headingGap(heading.level), .kind = .{ .heading = heading.level } });
                try self.render(heading.children.items, quote_depth);
            },
            .text => |sections| {
                const bars = try self.quoteBars(quote_depth, "");
                var spans: std.ArrayList(Span) = .empty;
                if (standaloneImage(sections)) |image| {
                    try spans.append(self.allocator, .{ .text = "Image: ", .style = .{ .bold = true, .fg = .{ .index = 6 } } });
                    try self.appendSections(&spans, image.alt_text, .{ .italic = true }, null);
                    try self.addBlock(&spans, .{ .prefix = bars, .continuation = bars, .gap_before = 1, .kind = .{ .image = image.path } });
                    continue;
                }
                try self.appendSections(&spans, sections, .{}, null);
                try self.addBlock(&spans, .{ .prefix = bars, .continuation = bars });
            },
            .line_break => try self.addTextBlock(quote_depth, "", .{}),
            .horizontal_rule => try self.blocks.append(self.allocator, .{ .gap_before = 1, .kind = .rule }),
            .code_block => |block| {
                const label = if (block.language.len == 0) "code" else block.language;
                const header_bars = try self.quoteBars(quote_depth, "");
                applyBackground(header_bars, .{ .index = 0 });
                var header: std.ArrayList(Span) = .empty;
                try header.append(self.allocator, .{ .text = "  " });
                try header.append(self.allocator, .{ .text = label, .style = .{ .bold = true, .fg = .{ .index = 6 } } });
                applyBackground(header.items, .{ .index = 0 });
                try self.addBlock(&header, .{ .prefix = header_bars, .continuation = header_bars, .gap_before = 1, .kind = .code });
                const line_prefix = try self.quoteBars(quote_depth, "    ");
                applyBackground(line_prefix, .{ .index = 0 });
                for (block.lines.items) |line| {
                    var spans: std.ArrayList(Span) = .empty;
                    try spans.append(self.allocator, .{ .text = line, .style = .{ .fg = .{ .index = 2 }, .bg = .{ .index = 0 } } });
                    try self.addBlock(&spans, .{ .prefix = line_prefix, .continuation = line_prefix, .kind = .code });
                }
            },
            .list => |list| try self.renderList(list.items, 0, quote_depth),
            .block_quote => |nodes_in_quote| try self.render(nodes_in_quote.items, quote_depth + 1),
            .table => |columns| try self.renderTable(columns),
            .footnote => |sections| {
                var spans: std.ArrayList(Span) = .empty;
                try self.appendSections(&spans, sections, .{ .dim = true }, null);
                try self.addBlock(&spans, .{
                    .prefix = try self.quoteBars(quote_depth, "[^] "),
                    .continuation = try self.quoteBars(quote_depth, "    "),
                });
            },
            .alert => try self.addTextBlock(quote_depth, "[alert]", .{ .bold = true, .fg = .{ .index = 3 } }),
            .container => try self.addTextBlock(quote_depth, "[container]", .{ .dim = true }),
        };
    }

    fn renderList(self: *Builder, elements: []const *markdown.Node.Element, depth: usize, quote_depth: usize) !void {
        for (elements) |element| {
            const marker = switch (element.data) {
                .ordered => |number| try std.fmt.allocPrint(self.allocator, "{d}. ", .{number}),
                .unordered => "• ",
                .task => |done| if (done) "[x] " else "[ ] ",
            };
            const indent = try self.allocator.alloc(u8, depth * 2 + stringWidth(marker));
            @memset(indent, ' ');

            var prefix: std.ArrayList(Span) = .empty;
            try prefix.appendSlice(self.allocator, try self.quoteBars(quote_depth, indent[0 .. depth * 2]));
            try prefix.append(self.allocator, .{ .text = marker, .style = .{ .bold = true, .fg = .{ .index = 6 } } });

            var spans: std.ArrayList(Span) = .empty;
            try self.appendSections(&spans, element.text, .{}, null);
            try self.addBlock(&spans, .{
                .prefix = try prefix.toOwnedSlice(self.allocator),
                .continuation = try self.quoteBars(quote_depth, indent),
            });
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

    /// Returns one quote bar per level of `quote_depth`, followed by `suffix`.
    fn quoteBars(self: *Builder, quote_depth: usize, suffix: []const u8) ![]Span {
        const spans = try self.allocator.alloc(Span, quote_depth + @intFromBool(suffix.len > 0));
        @memset(spans[0..quote_depth], .{ .text = "│ ", .style = .{ .fg = .{ .index = 6 } } });
        if (suffix.len > 0) spans[quote_depth] = .{ .text = suffix };
        return spans;
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
                try self.appendSections(spans, value.title, style, try self.safeUrl(value.url));
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

    fn addTextBlock(self: *Builder, quote_depth: usize, text: []const u8, style: Style) !void {
        var spans: std.ArrayList(Span) = .empty;
        try spans.append(self.allocator, .{ .text = text, .style = style });
        const bars = try self.quoteBars(quote_depth, "");
        try self.addBlock(&spans, .{ .prefix = bars, .continuation = bars });
    }

    /// Returns `url` with control characters percent-encoded, so backends
    /// can write it into terminal escape sequences.
    fn safeUrl(self: *Builder, url: []const u8) ![]const u8 {
        if (isSafeUrl(url)) return url;
        var output: std.Io.Writer.Allocating = .init(self.allocator);
        writeUrl(&output.writer, url) catch return error.OutOfMemory;
        return output.toOwnedSlice();
    }

    /// Adds a block of `spans`, with the other fields from `block`.
    fn addBlock(self: *Builder, spans: *std.ArrayList(Span), block: Block) !void {
        var result = block;
        result.spans = try spans.toOwnedSlice(self.allocator);
        try self.blocks.append(self.allocator, result);
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

    /// Returns the width of `grapheme`, at most 255 columns.
    pub fn width(self: Measure, grapheme: []const u8) u16 {
        return @min(self.widthFn(self.context, grapheme), std.math.maxInt(u8));
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

/// A position in wrapped text, for resuming `wrap` partway through.
pub const WrapCursor = struct {
    span: usize = 0,
    /// Byte offset into the text of `span`, at a word or grapheme boundary.
    offset: usize = 0,
    row: usize = 0,
    col: usize = 0,
    soft_wrapped: bool = false,
    in_word: bool = false,
    /// The text moved to a new row because the last one was full, and nothing
    /// was written to the new row yet.
    pending_wrap: bool = false,
};

/// Shown in place of a grapheme wider than the available width.
const too_wide_marker = "…";

/// Word-wraps `spans` to `width` columns, starting at `start`. The visitor gets:
/// - `glyph(row, col, grapheme, width, span) bool` for every cell filled;
///   wrapping stops early once it returns false.
/// - `softWrap(row)` before the first glyph that continues the text of
///   `row` on the next row, unlike text after a hard line break.
/// - `checkpoint(cursor)` before each word and grapheme, so wrapping can
///   later resume there.
/// Returns the number of rows used, at least one.
pub fn wrap(spans: []const Span, width: u16, measure: Measure, start: WrapCursor, visitor: anytype) usize {
    if (spans.len == 0) return 1;
    var row = start.row;
    var col = start.col;
    var soft_wrapped = start.soft_wrapped;
    var in_word = start.in_word;
    var pending_wrap = start.pending_wrap;
    for (spans[start.span..], start.span..) |span, span_index| {
        var lines: TextLineIterator = .{
            .buf = span.text,
            .index = if (span_index == start.span) start.offset else 0,
        };
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
                            pending_wrap = true;
                            break;
                        }
                        if (pending_wrap) visitor.softWrap(row - 1);
                        pending_wrap = false;
                        if (!visitor.glyph(row, col, " ", 1, span)) return row + 1;
                        col += 1;
                    }
                },
                .word => |word| {
                    const word_offset = @intFromPtr(word.ptr) - @intFromPtr(span.text.ptr);
                    visitor.checkpoint(.{
                        .span = span_index,
                        .offset = word_offset,
                        .row = row,
                        .col = col,
                        .soft_wrapped = soft_wrapped,
                        .in_word = in_word,
                        .pending_wrap = pending_wrap,
                    });
                    if (!in_word) {
                        const word_width = measure.textWidth(word);
                        if (word_width + col > width and word_width <= width) {
                            row += 1;
                            col = 0;
                            pending_wrap = true;
                        }
                    }
                    in_word = true;
                    var graphemes = uucode.grapheme.utf8Iterator(word);
                    var first = true;
                    while (graphemes.nextGrapheme()) |grapheme| {
                        if (!first) visitor.checkpoint(.{
                            .span = span_index,
                            .offset = word_offset + grapheme.start,
                            .row = row,
                            .col = col,
                            .soft_wrapped = soft_wrapped,
                            .in_word = true,
                            .pending_wrap = pending_wrap,
                        });
                        first = false;
                        var bytes = word[grapheme.start..grapheme.end];
                        var grapheme_width = measure.width(bytes);
                        if (grapheme_width == 0) continue;
                        soft_wrapped = false;
                        if (grapheme_width > width) {
                            if (width == 0) continue;
                            bytes = too_wide_marker;
                            grapheme_width = 1;
                        }
                        if (col != 0 and col + grapheme_width > width) {
                            row += 1;
                            col = 0;
                            pending_wrap = true;
                        }
                        if (pending_wrap) visitor.softWrap(row - 1);
                        pending_wrap = false;
                        if (!visitor.glyph(row, col, bytes, grapheme_width, span)) return row + 1;
                        col += grapheme_width;
                        if (col >= width) {
                            row += 1;
                            col = 0;
                            soft_wrapped = true;
                            pending_wrap = true;
                        }
                    }
                },
            };
            if (lines.has_break) {
                // A full row already moved the text to a new one.
                if (!pending_wrap) row += 1;
                pending_wrap = false;
                soft_wrapped = false;
                in_word = false;
                col = 0;
            }
        }
    }
    return @max(row + @intFromBool(col > 0), 1);
}

/// Returns the rows `spans` take when wrapped to `width` columns.
pub fn measureHeight(spans: []const Span, width: u16, measure: Measure) usize {
    const Ignore = struct {
        fn glyph(_: @This(), _: usize, _: usize, _: []const u8, _: u16, _: Span) bool {
            return true;
        }
        fn softWrap(_: @This(), _: usize) void {}
        fn checkpoint(_: @This(), _: WrapCursor) void {}
    };
    return wrap(spans, width, measure, .{}, Ignore{});
}

/// Text rows between the wrap checkpoints a `BlockLayout` keeps.
const checkpoint_rows = 64;

/// Wraps `spans` like `measureHeight`, also returning a checkpoint about every
/// `checkpoint_rows` rows.
fn measureCheckpoints(allocator: std.mem.Allocator, spans: []const Span, width: u16, measure: Measure) !struct { usize, []WrapCursor } {
    const Recorder = struct {
        allocator: std.mem.Allocator,
        checkpoints: std.ArrayList(WrapCursor) = .empty,
        next_row: usize = checkpoint_rows,
        failed: bool = false,

        fn glyph(self: *@This(), _: usize, _: usize, _: []const u8, _: u16, _: Span) bool {
            return !self.failed;
        }

        fn softWrap(_: *@This(), _: usize) void {}

        fn checkpoint(self: *@This(), cursor: WrapCursor) void {
            if (cursor.row < self.next_row) return;
            self.checkpoints.append(self.allocator, cursor) catch {
                self.failed = true;
                return;
            };
            self.next_row = cursor.row + checkpoint_rows;
        }
    };
    var recorder: Recorder = .{ .allocator = allocator };
    errdefer recorder.checkpoints.deinit(allocator);
    const height = wrap(spans, width, measure, .{}, &recorder);
    if (recorder.failed) return error.OutOfMemory;
    return .{ height, try recorder.checkpoints.toOwnedSlice(allocator) };
}

/// Returns the last checkpoint above text row `row`, so every row from `row`
/// on is painted completely when wrapping resumes there.
fn resumeCursor(checkpoints: []const WrapCursor, row: usize, col_offset: u16) WrapCursor {
    var low: usize = 0;
    var high = checkpoints.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (checkpoints[mid].row < row) low = mid + 1 else high = mid;
    }
    return if (low == 0) .{ .col = col_offset } else checkpoints[low - 1];
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

/// The measured rows of one block, for painting it with `paintBlock`.
pub const BlockLayout = struct {
    width: u16,
    height: usize,
    /// Where wrapping can resume, about every 64 text rows.
    checkpoints: []const WrapCursor = &.{},
    /// For tables, the first row of the header and each body row, then the
    /// table height.
    table_rows: []const usize = &.{},
    /// For tables, the checkpoints of every cell, header row first.
    table_cells: []const []const WrapCursor = &.{},

    pub fn deinit(self: BlockLayout, allocator: std.mem.Allocator) void {
        allocator.free(self.checkpoints);
        allocator.free(self.table_rows);
        for (self.table_cells) |checkpoints| allocator.free(checkpoints);
        allocator.free(self.table_cells);
    }
};

/// Measures `block` for painting. Free the result with `BlockLayout.deinit`.
pub fn layoutBlock(allocator: std.mem.Allocator, block: Block, options: LayoutOptions) !BlockLayout {
    switch (block.kind) {
        .rule => return .{ .width = options.width, .height = 1 },
        .table => |table| return layoutTable(allocator, table, options),
        .image => if (options.image_height) |height| return .{ .width = options.width, .height = height },
        .normal, .code, .heading => {},
    }
    const text_width = options.width -| prefixWidth(block, options.measure);
    const text_height, const checkpoints = try measureCheckpoints(allocator, block.spans, text_width, options.measure);
    return .{
        .width = options.width,
        .height = text_height + headingExtraRows(block.kind),
        .checkpoints = checkpoints,
    };
}

fn layoutTable(allocator: std.mem.Allocator, table: Table, options: LayoutOptions) !BlockLayout {
    if (table.columns.len == 0) return .{ .width = options.width, .height = 0 };
    if (!tableFits(table, options.width)) return .{ .width = options.width, .height = 1 };
    const widths = tableColumnWidths(options.width, table.columns.len);

    const rows = try allocator.alloc(usize, table.row_count + 2);
    errdefer allocator.free(rows);
    const cells = try allocator.alloc([]const WrapCursor, (table.row_count + 1) * table.columns.len);
    @memset(cells, &.{});
    errdefer {
        for (cells) |checkpoints| allocator.free(checkpoints);
        allocator.free(cells);
    }

    var row: usize = 1;
    for (rows[0 .. table.row_count + 1], 0..) |*start, index| {
        start.* = row;
        var height: usize = 1;
        for (table.columns, cells[index * table.columns.len ..][0..table.columns.len], 0..) |column, *checkpoints, column_index| {
            const cell_height, checkpoints.* = try measureCheckpoints(
                allocator,
                tableCell(column, if (index == 0) null else index - 1),
                widths.width(column_index) -| 2,
                options.measure,
            );
            height = @max(height, cell_height);
        }
        row += height + 1;
    }
    rows[table.row_count + 1] = row;
    return .{ .width = options.width, .height = row, .table_rows = rows, .table_cells = cells };
}

/// Returns the columns left of the text of `block`.
fn prefixWidth(block: Block, measure: Measure) u16 {
    const width = @max(spansWidth(block.prefix, measure), spansWidth(block.continuation, measure));
    return @intCast(@min(width, std.math.maxInt(u16)));
}

fn spansWidth(spans: []const Span, measure: Measure) usize {
    var width: usize = 0;
    for (spans) |span| width += measure.textWidth(span.text);
    return width;
}

/// Returns the block row of the first text row.
fn textRowOffset(kind: Block.Kind) usize {
    return switch (kind) {
        .heading => |level| @intFromBool(level == 1),
        else => 0,
    };
}

fn headingExtraRows(kind: Block.Kind) usize {
    return switch (kind) {
        .heading => |level| switch (level) {
            1 => 2,
            2 => 1,
            else => 0,
        },
        else => 0,
    };
}

/// Row positions of every block for one width, for scrolling views.
pub const Layout = struct {
    starts: std.ArrayList(usize) = .empty,
    blocks: std.ArrayList(BlockLayout) = .empty,
    total_rows: usize = 0,
    key: ?Key = null,

    const Key = struct {
        blocks: [*]const Block,
        block_count: usize,
        width: u16,
        image_height: ?usize,
        measure_context: ?*const anyopaque,
        measure_fn: *const fn (context: ?*const anyopaque, grapheme: []const u8) u16,
    };

    pub fn deinit(self: *Layout, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.starts.deinit(allocator);
        self.blocks.deinit(allocator);
    }

    /// Forces the next `update` to recompute, for example after block contents
    /// or the measure's results changed.
    pub fn invalidate(self: *Layout) void {
        self.key = null;
    }

    /// Recomputes the layout unless the blocks and options are the ones it was
    /// last computed for.
    pub fn update(self: *Layout, allocator: std.mem.Allocator, blocks: []const Block, options: LayoutOptions) !void {
        const key: Key = .{
            .blocks = blocks.ptr,
            .block_count = blocks.len,
            .width = options.width,
            .image_height = options.image_height,
            .measure_context = options.measure.context,
            .measure_fn = options.measure.widthFn,
        };
        if (self.key) |current| if (std.meta.eql(current, key)) return;
        self.key = null;
        self.clear(allocator);
        try self.starts.ensureTotalCapacity(allocator, blocks.len);
        try self.blocks.ensureTotalCapacity(allocator, blocks.len);
        var total: usize = 0;
        for (blocks) |block| {
            total += block.gap_before;
            const block_layout = try layoutBlock(allocator, block, options);
            self.starts.appendAssumeCapacity(total);
            self.blocks.appendAssumeCapacity(block_layout);
            total += block_layout.height;
        }
        self.total_rows = total;
        self.key = key;
    }

    /// Returns the index of the first block that ends below row `scroll`.
    pub fn firstVisible(self: Layout, scroll: usize) usize {
        var low: usize = 0;
        var high = self.starts.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.starts.items[mid] + self.blocks.items[mid].height <= scroll) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    fn clear(self: *Layout, allocator: std.mem.Allocator) void {
        for (self.blocks.items) |block_layout| block_layout.deinit(allocator);
        self.starts.clearRetainingCapacity();
        self.blocks.clearRetainingCapacity();
        self.total_rows = 0;
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
/// `block_layout` comes from `layoutBlock` or `Layout` for `region.width`.
pub fn paintBlock(region: Region, block: Block, block_layout: BlockLayout, skipped_rows: usize, measure: Measure) void {
    const fits = block_layout.width == region.width;
    const checkpoints = if (fits) block_layout.checkpoints else &.{};
    switch (block.kind) {
        .rule => if (skipped_rows == 0) paintRule(region),
        .table => |table| paintTable(
            region,
            table,
            if (fits) block_layout.table_rows else &.{},
            if (fits) block_layout.table_cells else &.{},
            skipped_rows,
            measure,
        ),
        .heading => |level| {
            paintHeadingBackground(region, level);
            const text = paintPrefix(region, block, skipped_rows, measure);
            paintSpansFrom(text, block.spans, checkpoints, skipped_rows, textRowOffset(block.kind), 0, measure);
            if (level == 2) paintHeadingDivider(text, block_layout.height, skipped_rows);
        },
        .code => {
            region.fill(.{ .style = .{ .bg = .{ .index = 0 } } });
            paintSpansFrom(paintPrefix(region, block, skipped_rows, measure), block.spans, checkpoints, skipped_rows, 0, 0, measure);
        },
        .image, .normal => paintSpansFrom(paintPrefix(region, block, skipped_rows, measure), block.spans, checkpoints, skipped_rows, 0, 0, measure),
    }
}

/// Paints `block.prefix` and `block.continuation` down the left of `region`,
/// which shows the block from row `skipped_rows` on. Returns the region
/// right of them, where the text of the block goes.
pub fn paintPrefix(region: Region, block: Block, skipped_rows: usize, measure: Measure) Region {
    const width = prefixWidth(block, measure);
    if (width == 0) return region;
    const first_row = textRowOffset(block.kind);
    const column = region.child(.{ .width = width });
    for (0..column.height) |screen_row| {
        const spans = if (skipped_rows + screen_row == first_row) block.prefix else block.continuation;
        paintSpans(column.child(.{ .y_off = @intCast(screen_row), .height = 1 }), spans, 0, 0, 0, measure);
    }
    return region.child(.{ .x_off = width });
}

/// Paints wrapped `spans` into `region`, which shows them from row `skipped_rows` on.
/// The text starts `row_offset` rows down and its first row `col_offset` columns in.
pub fn paintSpans(region: Region, spans: []const Span, skipped_rows: usize, row_offset: usize, col_offset: u16, measure: Measure) void {
    paintSpansFrom(region, spans, &.{}, skipped_rows, row_offset, col_offset, measure);
}

/// Like `paintSpans`, resuming from the last of `checkpoints` above the
/// first visible row instead of wrapping from the start.
fn paintSpansFrom(
    region: Region,
    spans: []const Span,
    checkpoints: []const WrapCursor,
    skipped_rows: usize,
    row_offset: usize,
    col_offset: u16,
    measure: Measure,
) void {
    const Painter = struct {
        region: Region,
        skipped_rows: usize,
        row_offset: usize,
        /// The last cell written, which `softWrap` marks as continuing.
        last: ?struct { col: u16, row: u16, text_row: usize, cell: Cell } = null,

        fn glyph(self: *@This(), text_row: usize, col: usize, grapheme: []const u8, width: u16, span: Span) bool {
            const row = text_row + self.row_offset;
            if (row >= self.skipped_rows + self.region.height) return false;
            if (row < self.skipped_rows or col >= self.region.width) return true;
            const cell: Cell = .{ .grapheme = grapheme, .width = @intCast(width), .style = span.style, .link = span.link };
            self.last = .{ .col = @intCast(col), .row = @intCast(row - self.skipped_rows), .text_row = text_row, .cell = cell };
            self.region.writeCell(@intCast(col), @intCast(row - self.skipped_rows), cell);
            return true;
        }

        fn softWrap(self: *@This(), text_row: usize) void {
            const last = self.last orelse return;
            if (last.text_row != text_row or last.col + last.cell.width < self.region.width) return;
            var cell = last.cell;
            cell.wrapped = true;
            self.region.writeCell(last.col, last.row, cell);
        }

        fn checkpoint(_: *@This(), _: WrapCursor) void {}
    };
    var painter: Painter = .{
        .region = region,
        .skipped_rows = skipped_rows,
        .row_offset = row_offset,
    };
    _ = wrap(spans, region.width, measure, resumeCursor(checkpoints, skipped_rows -| row_offset, col_offset), &painter);
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

/// `rows` and `cells` come from `layoutBlock`, or are empty to measure while painting.
fn paintTable(region: Region, table: Table, rows: []const usize, cells: []const []const WrapCursor, skipped_rows: usize, measure: Measure) void {
    if (!tableFits(table, region.width)) {
        if (skipped_rows == 0) paintSpans(region, &.{.{ .text = "[table too wide for terminal]", .style = .{ .dim = true } }}, 0, 0, 0, measure);
        return;
    }

    const widths = tableColumnWidths(region.width, table.columns.len);
    const measured = rows.len == table.row_count + 2 and cells.len == (table.row_count + 1) * table.columns.len;
    paintVisibleTableBorder(region, 0, skipped_rows, widths, .top);
    var index: usize = if (measured) firstTableRow(rows, skipped_rows) else 0;
    var block_row: usize = if (measured) rows[index] else 1;
    while (index <= table.row_count) : (index += 1) {
        if (block_row >= skipped_rows + region.height) break;
        const row_index: ?usize = if (index == 0) null else index - 1;
        const height = if (measured) rows[index + 1] - rows[index] - 1 else tableRowHeight(table, widths, row_index, measure);
        const row_cells = if (measured) cells[index * table.columns.len ..][0..table.columns.len] else &.{};
        paintVisibleTableRow(region, block_row, skipped_rows, table, widths, row_index, row_cells, height, measure);
        block_row += height;
        paintVisibleTableBorder(region, block_row, skipped_rows, widths, if (index == table.row_count) .bottom else .middle);
        block_row += 1;
    }
}

/// Returns the first table row whose rows or bottom border reach `skipped_rows`.
fn firstTableRow(rows: []const usize, skipped_rows: usize) usize {
    var low: usize = 0;
    var high = rows.len - 1;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (rows[mid + 1] <= skipped_rows) low = mid + 1 else high = mid;
    }
    return low;
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
    /// The checkpoints of each cell in the row, or empty.
    row_cells: []const []const WrapCursor,
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
    paintTableRow(row_region, table, widths, row_index, row_cells, skipped, measure);
}

fn paintTableRow(
    region: Region,
    table: Table,
    widths: TableWidths,
    row_index: ?usize,
    row_cells: []const []const WrapCursor,
    skipped: usize,
    measure: Measure,
) void {
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
        paintSpansFrom(content, spans, if (row_cells.len > 0) row_cells[index] else &.{}, skipped, 0, col_offset, measure);
    }
}

fn tableTextOffset(width: u16, spans: []const Span, alignment: markdown.Node.Column.Alignment, measure: Measure) u16 {
    const Extent = struct {
        end: usize = 0,
        multiline: bool = false,

        fn glyph(self: *@This(), row: usize, col: usize, _: []const u8, glyph_width: u16, _: Span) bool {
            if (row > 0) {
                self.multiline = true;
                return false;
            }
            self.end = @max(self.end, col + glyph_width);
            return true;
        }

        fn softWrap(_: *@This(), _: usize) void {}
        fn checkpoint(_: *@This(), _: WrapCursor) void {}
    };
    if (alignment == .left) return 0;
    var extent: Extent = .{};
    _ = wrap(spans, width, measure, .{}, &extent);
    if (extent.multiline) return 0;
    const remaining: u16 = @intCast(width -| extent.end);
    return if (alignment == .center) remaining / 2 else remaining;
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

/// Bounds on the rows painted at once, so tall or wide blocks do not need a
/// grid of their full size.
const max_chunk_rows = 256;
const max_chunk_cells = 16 * 1024;

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
    const chunk_rows: u16 = @intCast(std.math.clamp(max_chunk_cells / width, 1, max_chunk_rows));
    var grid = try Grid.init(allocator, width, chunk_rows);
    defer grid.deinit(allocator);
    const layout_options: LayoutOptions = .{ .width = width, .measure = options.measure };
    for (document.blocks, 0..) |block, index| {
        if (index > 0) try writer.splatByteAll('\n', block.gap_before);
        const block_layout = try layoutBlock(allocator, block, layout_options);
        defer block_layout.deinit(allocator);
        var start: usize = 0;
        while (start < block_layout.height) : (start += chunk_rows) {
            const rows: u16 = @intCast(@min(block_layout.height - start, chunk_rows));
            grid.clear();
            paintBlock(grid.region().child(.{ .height = rows }), block, block_layout, start, options.measure);
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
    try writer.writeAll("\x1b]8;;");
    if (uri) |text| try writeUrl(writer, text);
    try writer.writeAll("\x1b\\");
}

/// Writes `url`, percent-encoding C0 and C1 control characters so it cannot
/// end the escape sequence it is written into.
fn writeUrl(writer: *std.Io.Writer, url: []const u8) !void {
    var index: usize = 0;
    while (index < url.len) : (index += 1) {
        const byte = url[index];
        if (byte < 0x20 or byte == 0x7f) {
            try writer.print("%{X:0>2}", .{byte});
        } else if (byte == 0xc2 and index + 1 < url.len and url[index + 1] >= 0x80 and url[index + 1] < 0xa0) {
            try writer.print("%{X:0>2}%{X:0>2}", .{ byte, url[index + 1] });
            index += 1;
        } else {
            try writer.writeByte(byte);
        }
    }
}

fn isSafeUrl(url: []const u8) bool {
    for (url, 0..) |byte, index| {
        if (byte < 0x20 or byte == 0x7f) return false;
        if (byte == 0xc2 and index + 1 < url.len and url[index + 1] >= 0x80 and url[index + 1] < 0xa0) return false;
    }
    return true;
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
    paintVisibleTableRow(grid.region(), 0, 65_536, table, tableColumnWidths(5, 1), 0, &.{}, 70_000, .unicode);
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

test "link urls cannot inject escape sequences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const nodes = try markdown.parse(arena.allocator(), "[x](http://a\x1b]0;title\x07\u{9c}b)", .{});
    const output = try renderAlloc(std.testing.allocator, nodes, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "http://a%1B]0;title%07%C2%9Cb\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b]0;") == null);

    const document = try build(arena.allocator(), nodes);
    try std.testing.expectEqualStrings("http://a%1B]0;title%07%C2%9Cb", document.blocks[0].spans[0].link.?);
}

test "layout recomputes when blocks or options change" {
    const short = [_]Block{.{ .spans = &.{.{ .text = "a" }} }};
    const long = [_]Block{.{ .spans = &.{.{ .text = "a b c d" }} }};
    const image = [_]Block{.{ .spans = &.{.{ .text = "Image: a" }}, .kind = .{ .image = "a.png" } }};
    var layout: Layout = .{};
    defer layout.deinit(std.testing.allocator);
    try layout.update(std.testing.allocator, &short, .{ .width = 1 });
    try std.testing.expectEqual(@as(usize, 1), layout.total_rows);
    try layout.update(std.testing.allocator, &long, .{ .width = 1 });
    try std.testing.expectEqual(@as(usize, 4), layout.total_rows);
    try layout.update(std.testing.allocator, &image, .{ .width = 20 });
    try std.testing.expectEqual(@as(usize, 1), layout.total_rows);
    try layout.update(std.testing.allocator, &image, .{ .width = 20, .image_height = 14 });
    try std.testing.expectEqual(@as(usize, 14), layout.total_rows);
}

fn expectSameRows(block: Block, width: u16, skipped_rows: usize, rows: u16) !void {
    const block_layout = try layoutBlock(std.testing.allocator, block, .{ .width = width });
    defer block_layout.deinit(std.testing.allocator);
    var resumed = try testGrid(width, rows);
    defer resumed.deinit(std.testing.allocator);
    var full = try testGrid(width, rows);
    defer full.deinit(std.testing.allocator);
    paintBlock(resumed.region(), block, block_layout, skipped_rows, .unicode);
    paintBlock(full.region(), block, .{ .width = width, .height = block_layout.height }, skipped_rows, .unicode);
    for (resumed.cells, full.cells) |a, b| {
        try std.testing.expectEqualStrings(b.grapheme, a.grapheme);
        try std.testing.expectEqual(b.width, a.width);
    }
}

test "painting from checkpoints matches painting from the start" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    for (0..2000) |index| try text.print(std.testing.allocator, "{s}word{d} ", .{ if (index % 7 == 0) "\t" else "", index });
    const paragraph: Block = .{ .spans = &.{ .{ .text = text.items }, .{ .text = "tail😀😀", .style = .{ .bold = true } } } };
    for ([_]usize{ 0, 63, 64, 65, 300, 1777 }) |skipped| try expectSameRows(paragraph, 9, skipped, 40);

    const word = try std.testing.allocator.alloc(u8, 5_000);
    defer std.testing.allocator.free(word);
    @memset(word, 'a');
    const long_word: Block = .{ .spans = &.{.{ .text = word }} };
    const block_layout = try layoutBlock(std.testing.allocator, long_word, .{ .width = 3 });
    defer block_layout.deinit(std.testing.allocator);
    try std.testing.expect(block_layout.checkpoints.len > 10);
    for ([_]usize{ 0, 64, 1000, 1666 }) |skipped| try expectSameRows(long_word, 3, skipped, 10);

    const values = try std.testing.allocator.alloc([]const Span, 500);
    defer std.testing.allocator.free(values);
    for (values, 0..) |*value, index| value.* = if (index % 3 == 0) &.{.{ .text = "two lines" }} else &.{.{ .text = "x" }};
    const columns = [_]Table.Column{
        .{ .alignment = .left, .header = &.{.{ .text = "H" }}, .values = values },
        .{ .alignment = .right, .header = &.{.{ .text = "I" }}, .values = values[0..10] },
    };
    const table: Block = .{ .kind = .{ .table = .{ .columns = &columns, .row_count = values.len } } };
    for ([_]usize{ 0, 1, 2, 3, 4, 500, 1201 }) |skipped| try expectSameRows(table, 15, skipped, 7);
}

test "images and line breaks keep their quote prefix" {
    try expectRender(
        \\> ![alt](pic.png)
    , .{ .width = 20, .color = false },
        \\│ Image: alt
        \\
    );
}

test "graphemes wider than the region are shown as an ellipsis" {
    try std.testing.expectEqual(@as(usize, 2), measureHeight(&.{.{ .text = "日本" }}, 1, .unicode));
    var grid = try testGrid(1, 2);
    defer grid.deinit(std.testing.allocator);
    paintSpans(grid.region(), &.{.{ .text = "日本" }}, 0, 0, 0, .unicode);
    try std.testing.expectEqualStrings("…", gridText(grid, 0));
    try std.testing.expectEqualStrings("…", gridText(grid, 1));
}

test "measured widths are clamped to cell widths" {
    const Wide = struct {
        fn width(_: ?*const anyopaque, _: []const u8) u16 {
            return 300;
        }
    };
    const measure: Measure = .{ .widthFn = Wide.width };
    try std.testing.expectEqual(@as(u16, 255), measure.width("a"));
    var grid = try testGrid(400, 1);
    defer grid.deinit(std.testing.allocator);
    paintSpans(grid.region(), &.{.{ .text = "a" }}, 0, 0, 0, measure);
    try std.testing.expectEqual(@as(u8, 255), grid.row(0)[0].width);
}

test "wide renders allocate a bounded grid" {
    try expectRender("hi", .{ .width = std.math.maxInt(u16), .color = false }, "hi\n");
}

test "a full row before a hard break does not add a blank row" {
    try std.testing.expectEqual(@as(usize, 2), measureHeight(&.{.{ .text = "abc\nd" }}, 3, .unicode));
    try std.testing.expectEqual(@as(usize, 2), measureHeight(&.{.{ .text = "ab  \nd" }}, 3, .unicode));
    try std.testing.expectEqual(@as(usize, 3), measureHeight(&.{.{ .text = "abc\n\nd" }}, 3, .unicode));
    try std.testing.expectEqual(@as(usize, 1), measureHeight(&.{.{ .text = "abc" }}, 3, .unicode));
}

test "only rows that continue are marked as wrapped" {
    var grid = try testGrid(3, 3);
    defer grid.deinit(std.testing.allocator);
    paintSpans(grid.region(), &.{.{ .text = "abcdef\nghi" }}, 0, 0, 0, .unicode);
    try std.testing.expect(grid.row(0)[2].wrapped);
    try std.testing.expect(!grid.row(1)[2].wrapped);
    try std.testing.expect(!grid.row(2)[2].wrapped);
    try std.testing.expectEqualStrings("g", gridText(grid, 2));
}

test "layout stays consistent when measuring fails" {
    var text: [400]u8 = undefined;
    for (&text, 0..) |*byte, index| byte.* = if (index % 2 == 0) 'a' else ' ';
    const blocks = [_]Block{
        .{ .spans = &.{.{ .text = &text }} },
        .{ .spans = &.{.{ .text = &text }} },
    };
    var failures: usize = 0;
    for (0..12) |fail_index| {
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = fail_index });
        var layout: Layout = .{};
        defer layout.deinit(failing.allocator());
        layout.update(failing.allocator(), &blocks, .{ .width = 1 }) catch {
            failures += 1;
            try std.testing.expectEqual(layout.starts.items.len, layout.blocks.items.len);
            _ = layout.firstVisible(1_000);
        };
    }
    try std.testing.expect(failures > 2);
}

test "tall table cells paint from checkpoints" {
    const word = try std.testing.allocator.alloc(u8, 5_000);
    defer std.testing.allocator.free(word);
    @memset(word, 'a');
    const values = [_][]const Span{&.{.{ .text = word }}};
    const columns = [_]Table.Column{.{ .alignment = .center, .header = &.{.{ .text = "H" }}, .values = &values }};
    const table: Block = .{ .kind = .{ .table = .{ .columns = &columns, .row_count = 1 } } };
    const block_layout = try layoutBlock(std.testing.allocator, table, .{ .width = 7 });
    defer block_layout.deinit(std.testing.allocator);
    try std.testing.expect(block_layout.table_cells[1].len > 10);
    for ([_]usize{ 0, 3, 64, 1000, 1667 }) |skipped| try expectSameRows(table, 7, skipped, 10);
}

test "wrapped rows keep quote bars and list indents" {
    try expectRender(
        \\> aaa bbb ccc
    , .{ .width = 7, .color = false },
        \\│ aaa
        \\│ bbb
        \\│ ccc
        \\
    );
    try expectRender(
        \\- aaa bbb
        \\  - ccc ddd
    , .{ .width = 7, .color = false },
        \\• aaa
        \\  bbb
        \\  • ccc
        \\    ddd
        \\
    );
}

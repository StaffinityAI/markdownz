const std = @import("std");
const default_document = @import("default_document");
const markdown = @import("markdown");
const vaxis = @import("vaxis");

pub const panic = vaxis.Panic.call;

const max_markdown_size = 64 * 1024 * 1024;
const default_markdown = default_document.source;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const ImageBlock = struct {
    path: []const u8,
    image: ?vaxis.Image = null,
};

const ImageRef = struct {
    alt_text: []markdown.Node.Section,
    path: []const u8,
};

const TableColumn = struct {
    alignment: markdown.Node.Column.Alignment,
    header: []const vaxis.Segment,
    values: []const []const vaxis.Segment,
};

const TableBlock = struct {
    columns: []const TableColumn,
    row_count: usize,
};

const TableBorderKind = enum { top, middle, bottom };

const LineKind = union(enum) {
    normal,
    heading: u8,
    code,
    image: ImageBlock,
    table: TableBlock,
    rule,
};

const Line = struct {
    segments: []const vaxis.Segment,
    gap_before: u8 = 0,
    kind: LineKind = .normal,
};

const Document = struct {
    lines: std.ArrayList(Line) = .empty,

    fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.lines.items) |line| allocator.free(line.segments);
        self.lines.deinit(allocator);
    }
};

const Renderer = struct {
    allocator: std.mem.Allocator,
    document: *Document,

    fn render(self: *Renderer, nodes: []*markdown.Node, quote_depth: usize) !void {
        for (nodes) |node| switch (node.*) {
            .heading => |heading| {
                var segments: std.ArrayList(vaxis.Segment) = .empty;
                try self.appendPrefix(&segments, quote_depth, "");
                try segments.append(self.allocator, .{
                    .text = headingMarker(heading.level),
                    .style = headingStyle(heading.level),
                });
                try self.appendSections(&segments, heading.text, headingStyle(heading.level), null);
                try self.addLine(&segments, headingGap(heading.level), .{ .heading = heading.level });
                try self.render(heading.children.items, quote_depth);
            },
            .text => |sections| {
                if (standaloneImage(sections)) |image| {
                    var segments: std.ArrayList(vaxis.Segment) = .empty;
                    try segments.append(self.allocator, .{ .text = "Image: ", .style = .{ .bold = true, .fg = .{ .index = 6 } } });
                    try self.appendSections(&segments, image.alt_text, .{ .italic = true }, null);
                    try self.addLine(&segments, 1, .{ .image = .{ .path = image.path } });
                    continue;
                }

                var segments: std.ArrayList(vaxis.Segment) = .empty;
                try self.appendPrefix(&segments, quote_depth, "");
                try self.appendSections(&segments, sections, .{}, null);
                try self.addLine(&segments, 0, .normal);
            },
            .line_break => try self.addTextLine("", .{}),
            .horizontal_rule => try self.addSpecialLine(.rule, 1),
            .code_block => |block| {
                const label = if (block.language.len == 0) "code" else block.language;
                var header: std.ArrayList(vaxis.Segment) = .empty;
                try self.appendPrefix(&header, quote_depth, "");
                try header.append(self.allocator, .{ .text = "  " });
                try header.append(self.allocator, .{ .text = label, .style = .{ .bold = true, .fg = .{ .index = 6 } } });
                applyBackground(header.items, .{ .index = 0 });
                try self.addLine(&header, 1, .code);
                for (block.lines.items) |line| {
                    var segments: std.ArrayList(vaxis.Segment) = .empty;
                    try self.appendPrefix(&segments, quote_depth, "    ");
                    try segments.append(self.allocator, .{ .text = line, .style = .{ .fg = .{ .index = 2 } } });
                    applyBackground(segments.items, .{ .index = 0 });
                    try self.addLine(&segments, 0, .code);
                }
            },
            .list => |list| try self.renderList(list, 0, quote_depth),
            .block_quote => |nodes_in_quote| try self.render(nodes_in_quote.items, quote_depth + 1),
            .table => |columns| try self.renderTable(columns),
            .footnote => |sections| {
                var segments: std.ArrayList(vaxis.Segment) = .empty;
                try self.appendPrefix(&segments, quote_depth, "[^] ");
                try self.appendSections(&segments, sections, .{ .dim = true }, null);
                try self.addLine(&segments, 0, .normal);
            },
            .alert => try self.addTextLine("[alert]", .{ .bold = true, .fg = .{ .index = 3 } }),
            .container => try self.addTextLine("[container]", .{ .dim = true }),
        };
    }

    fn renderList(self: *Renderer, list: std.ArrayList(*markdown.Node.Element), depth: usize, quote_depth: usize) !void {
        for (list.items) |element| {
            var segments: std.ArrayList(vaxis.Segment) = .empty;
            try self.appendPrefix(&segments, quote_depth, "");
            const indent = try self.allocator.alloc(u8, depth * 2);
            @memset(indent, ' ');
            try segments.append(self.allocator, .{ .text = indent });

            const marker = switch (element.data) {
                .ordered => |number| try std.fmt.allocPrint(self.allocator, "{d}. ", .{number}),
                .unordered => "• ",
                .task => |done| if (done) "[x] " else "[ ] ",
            };
            try segments.append(self.allocator, .{ .text = marker, .style = .{ .bold = true, .fg = .{ .index = 6 } } });
            try self.appendSections(&segments, element.text, .{}, null);
            try self.addLine(&segments, 0, .normal);
            try self.renderList(element.children, depth + 1, quote_depth);
        }
    }

    fn renderTable(self: *Renderer, columns: []markdown.Node.Column) !void {
        if (columns.len == 0) return;

        const rendered_columns = try self.allocator.alloc(TableColumn, columns.len);
        var row_count: usize = 0;
        for (rendered_columns, columns) |*rendered, column| {
            const header = try self.renderSections(column.header, .{ .bold = true, .fg = .{ .index = 15 }, .bg = .{ .index = 4 } });
            const values = try self.allocator.alloc([]const vaxis.Segment, column.values.len);
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

        try self.document.lines.append(self.allocator, .{
            .segments = &.{},
            .gap_before = 1,
            .kind = .{ .table = .{ .columns = rendered_columns, .row_count = row_count } },
        });
    }

    fn renderSections(self: *Renderer, sections: []markdown.Node.Section, style: vaxis.Style) ![]const vaxis.Segment {
        var segments: std.ArrayList(vaxis.Segment) = .empty;
        try self.appendSections(&segments, sections, style, null);
        return segments.toOwnedSlice(self.allocator);
    }

    fn appendPrefix(self: *Renderer, segments: *std.ArrayList(vaxis.Segment), quote_depth: usize, suffix: []const u8) !void {
        for (0..quote_depth) |_| {
            try segments.append(self.allocator, .{ .text = "│ ", .style = .{ .fg = .{ .index = 6 } } });
        }
        if (suffix.len > 0) try segments.append(self.allocator, .{ .text = suffix });
    }

    fn appendSections(
        self: *Renderer,
        segments: *std.ArrayList(vaxis.Segment),
        sections: []markdown.Node.Section,
        base_style: vaxis.Style,
        link: ?[]const u8,
    ) !void {
        for (sections) |section| switch (section) {
            .default => |text| try segments.append(self.allocator, segment(text, base_style, link)),
            .code => |text| {
                var style = base_style;
                style.fg = .{ .index = 2 };
                style.bg = .{ .index = 0 };
                try segments.append(self.allocator, segment(text, style, link));
            },
            .bold => |nested| {
                var style = base_style;
                style.bold = true;
                try self.appendSections(segments, nested, style, link);
            },
            .italic => |nested| {
                var style = base_style;
                style.italic = true;
                try self.appendSections(segments, nested, style, link);
            },
            .bold_italic => |nested| {
                var style = base_style;
                style.bold = true;
                style.italic = true;
                try self.appendSections(segments, nested, style, link);
            },
            .underline => |nested| {
                var style = base_style;
                style.ul_style = .single;
                try self.appendSections(segments, nested, style, link);
            },
            .strike_through => |nested| {
                var style = base_style;
                style.strikethrough = true;
                try self.appendSections(segments, nested, style, link);
            },
            .highlight => |nested| {
                var style = base_style;
                style.fg = .{ .index = 0 };
                style.bg = .{ .index = 3 };
                try self.appendSections(segments, nested, style, link);
            },
            .link => |value| {
                var style = base_style;
                style.fg = .{ .index = 4 };
                style.ul_style = .single;
                try self.appendSections(segments, value.title, style, value.url);
            },
            .image => |image| {
                try segments.append(self.allocator, .{ .text = "[image: ", .style = .{ .dim = true } });
                try self.appendSections(segments, image.alt_text, .{ .dim = true }, null);
                try segments.append(self.allocator, .{ .text = "]", .style = .{ .dim = true } });
            },
            .emoji_shortcode => |name| {
                try segments.append(self.allocator, .{ .text = ":" });
                try segments.append(self.allocator, .{ .text = name, .style = .{ .fg = .{ .index = 5 } } });
                try segments.append(self.allocator, .{ .text = ":" });
            },
            .subscript => |nested| try self.appendSections(segments, nested, base_style, link),
            .superscript => |nested| try self.appendSections(segments, nested, base_style, link),
            .typographic => |text| try segments.append(self.allocator, segment(text, base_style, link)),
        };
    }

    fn addTextLine(self: *Renderer, text: []const u8, style: vaxis.Style) !void {
        const segments = try self.allocator.alloc(vaxis.Segment, 1);
        segments[0] = .{ .text = text, .style = style };
        try self.document.lines.append(self.allocator, .{ .segments = segments });
    }

    fn addSpecialLine(self: *Renderer, kind: LineKind, gap_before: u8) !void {
        try self.document.lines.append(self.allocator, .{ .segments = &.{}, .gap_before = gap_before, .kind = kind });
    }

    fn addLine(self: *Renderer, segments: *std.ArrayList(vaxis.Segment), gap_before: u8, kind: LineKind) !void {
        try self.document.lines.append(self.allocator, .{
            .segments = try segments.toOwnedSlice(self.allocator),
            .gap_before = gap_before,
            .kind = kind,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) {
        std.debug.print("usage: {s} [markdown-file]\n", .{args[0]});
        return error.InvalidArguments;
    }

    const source = if (args.len == 2)
        try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .limited(max_markdown_size))
    else
        default_markdown;
    defer if (args.len == 2) init.gpa.free(source);

    var parse_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer parse_arena.deinit();
    const graph = try markdown.parse(parse_arena.allocator(), source, .{ .underline_extension = true });

    var render_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer render_arena.deinit();
    var document: Document = .{};
    var renderer: Renderer = .{ .allocator = render_arena.allocator(), .document = &document };
    try renderer.render(graph, 0);

    var tty_buffer: [1024]u8 = undefined;
    var tty: vaxis.Tty = try .init(init.io, &tty_buffer);
    defer tty.deinit();

    var vx = try vaxis.init(init.io, init.gpa, init.environ_map, .{});
    defer vx.deinit(init.gpa, tty.writer());

    var loop: vaxis.Loop(Event) = .init(init.io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    loadDocumentImages(
        &document,
        &vx,
        tty.writer(),
        init.gpa,
        if (args.len == 2) std.fs.path.dirname(args[1]) orelse "." else null,
    ) catch |err| {
        freeDocumentImages(document.lines.items, vx, tty.writer());
        return err;
    };
    defer freeDocumentImages(document.lines.items, vx, tty.writer());

    const title = if (args.len == 2) std.fs.path.basename(args[1]) else "Markdown concepts";
    var scroll: usize = 0;
    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{})) break;
                if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) scroll +|= 1;
                if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) scroll -|= 1;
                if (key.matches(vaxis.Key.page_down, .{}) or key.matches('d', .{ .ctrl = true })) scroll +|= @max(vx.window().height / 2, 1);
                if (key.matches(vaxis.Key.page_up, .{}) or key.matches('u', .{ .ctrl = true })) scroll -|= @max(vx.window().height / 2, 1);
                if (key.matches(vaxis.Key.home, .{}) or key.matches('g', .{})) scroll = 0;
                if (key.matches(vaxis.Key.end, .{}) or key.matches('G', .{})) scroll = std.math.maxInt(usize);
            },
            .winsize => |winsize| try vx.resize(init.gpa, tty.writer(), winsize),
        }

        const win = vx.window();
        win.clear();
        win.hideCursor();

        if (win.width < 12 or win.height < 5) {
            _ = win.printSegment(.{ .text = "Terminal too small", .style = .{ .bold = true } }, .{ .wrap = .none });
            try vx.render(tty.writer());
            try tty.writer().flush();
            continue;
        }

        drawBar(win.child(.{ .height = 1 }), title, .top);
        drawBar(win.child(.{ .y_off = @intCast(win.height - 1), .height = 1 }), "↑↓/jk scroll  PgUp/PgDn page  g/G top/bottom  q quit", .bottom);

        const outer_margin: u16 = if (win.width >= 100) @min((win.width - 84) / 2, 8) else 1;
        const body_width = win.width -| (outer_margin * 2) -| 1;
        const content_height = win.height -| 2;
        const measure = win.child(.{ .width = body_width, .height = std.math.maxInt(u16) });
        const total_rows = documentHeight(measure, document.lines.items);
        const max_scroll = total_rows -| content_height;
        scroll = @min(scroll, max_scroll);

        const viewport = win.child(.{
            .x_off = @intCast(outer_margin),
            .y_off = 1,
            .width = body_width,
            .height = content_height,
        });
        drawDocument(viewport, document.lines.items, scroll);
        drawScrollbar(win, scroll, total_rows, content_height);

        var status_buffer: [512]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, " {d: >3}% ", .{
            if (max_scroll == 0) 100 else @min(scroll * 100 / max_scroll, 100),
        });
        _ = win.printSegment(.{ .text = status, .style = .{ .bold = true, .reverse = true } }, .{
            .row_offset = win.height -| 1,
            .col_offset = win.width -| @as(u16, @intCast(status.len)),
            .wrap = .none,
        });

        try vx.render(tty.writer());
        try tty.writer().flush();
    }
}

fn loadDocumentImages(
    document: *Document,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    markdown_dir: ?[]const u8,
) !void {
    if (!vx.caps.kitty_graphics) return;

    for (document.lines.items) |*line| switch (line.kind) {
        .image => |*image| {
            image.image = if (markdown_dir) |dir| blk: {
                const path = if (std.fs.path.isAbsolute(image.path))
                    image.path
                else
                    try std.fs.path.join(allocator, &.{ dir, image.path });
                defer if (path.ptr != image.path.ptr) allocator.free(path);
                break :blk vx.loadImage(allocator, tty, .{ .path = path }) catch |err| {
                    std.log.warn("unable to load image '{s}': {s}", .{ image.path, @errorName(err) });
                    continue;
                };
            } else if (std.mem.eql(u8, image.path, default_document.image_name))
                vx.loadImage(allocator, tty, .{ .mem = default_document.image }) catch |err| {
                    std.log.warn("unable to load embedded image '{s}': {s}", .{ image.path, @errorName(err) });
                    continue;
                }
            else
                continue;
        },
        else => {},
    };
}

fn freeDocumentImages(lines: []const Line, vx: vaxis.Vaxis, tty: *std.Io.Writer) void {
    for (lines) |line| switch (line.kind) {
        .image => |image| if (image.image) |loaded| vx.freeImage(tty, loaded.id),
        else => {},
    };
}

fn standaloneImage(sections: []markdown.Node.Section) ?ImageRef {
    if (sections.len != 1) return null;
    return switch (sections[0]) {
        .image => |image| .{ .alt_text = image.alt_text, .path = image.path },
        else => null,
    };
}

fn documentHeight(measure: vaxis.Window, lines: []const Line) usize {
    var total: usize = 0;
    for (lines) |line| {
        total += line.gap_before;
        total += lineHeight(measure, line);
    }
    return total;
}

fn lineHeight(measure: vaxis.Window, line: Line) usize {
    return switch (line.kind) {
        .rule => 1,
        .normal, .code => measuredLineHeight(measure, line.segments),
        .image => 14,
        .table => |table| tableHeight(measure, table),
        .heading => |level| measuredLineHeight(measure, line.segments) + @as(usize, switch (level) {
            1 => 2,
            2 => 1,
            else => 0,
        }),
    };
}

fn tableHeight(measure: vaxis.Window, table: TableBlock) usize {
    if (table.columns.len == 0) return 0;
    if (measure.width < table.columns.len * 4 + 1) return 1;
    const widths = tableColumnWidths(measure.width, table.columns.len);
    var height: usize = 2;
    height += tableRowHeight(measure, table, widths, null);
    for (0..table.row_count) |row| height += tableRowHeight(measure, table, widths, row) + 1;
    return height;
}

fn tableRowHeight(measure: vaxis.Window, table: TableBlock, widths: TableWidths, row: ?usize) usize {
    var height: usize = 1;
    for (table.columns, 0..) |column, index| {
        const segments = if (row) |row_index|
            if (row_index < column.values.len) column.values[row_index] else &.{}
        else
            column.header;
        const cell_width = widths.width(index) -| 2;
        const cell_window = measure.child(.{ .width = cell_width, .height = std.math.maxInt(u16) });
        height = @max(height, measuredLineHeight(cell_window, segments));
    }
    return height;
}

fn measuredLineHeight(measure: vaxis.Window, segments: []const vaxis.Segment) usize {
    if (segments.len == 0) return 1;
    var row: usize = 0;
    var col: usize = 0;
    var soft_wrapped = false;
    for (segments) |text_segment| {
        var lines: TextLineIterator = .{ .buf = text_segment.text };
        while (lines.next()) |line| {
            var tokens: WordTokenizer = .{ .buf = line };
            while (tokens.next()) |token| switch (token) {
                .whitespace => |len| {
                    if (soft_wrapped) continue;
                    for (0..len) |_| {
                        if (col >= measure.width) {
                            col = 0;
                            row += 1;
                            break;
                        }
                        col += 1;
                    }
                },
                .word => |word| {
                    const width = measure.gwidth(word);
                    if (width + col > measure.width and width < measure.width) {
                        row += 1;
                        col = 0;
                    }
                    var graphemes = vaxis.unicode.graphemeIterator(word);
                    while (graphemes.next()) |grapheme| {
                        soft_wrapped = false;
                        col += measure.gwidth(grapheme.bytes(word));
                        if (col >= measure.width) {
                            row += 1;
                            col = 0;
                            soft_wrapped = true;
                        }
                    }
                },
            };
            if (lines.has_break) {
                soft_wrapped = false;
                row += 1;
                col = 0;
            }
        }
    }
    return @max(row + @intFromBool(col > 0), 1);
}

const TextLineIterator = struct {
    buf: []const u8,
    index: usize = 0,
    has_break: bool = true,

    fn next(self: *TextLineIterator) ?[]const u8 {
        if (self.index >= self.buf.len) return null;
        const start = self.index;
        const end = std.mem.indexOfAnyPos(u8, self.buf, self.index, "\r\n") orelse {
            if (start == 0) self.has_break = false;
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

fn drawDocument(viewport: vaxis.Window, lines: []const Line, scroll: usize) void {
    var document_row: usize = 0;
    for (lines) |line| {
        document_row += line.gap_before;
        const height = lineHeight(viewport, line);
        const line_end = document_row + height;
        if (line_end > scroll and document_row < scroll + viewport.height) {
            const visible_start = scroll -| document_row;
            const screen_row: u16 = @intCast(document_row -| scroll);
            const visible_height: u16 = @intCast(@min(height - visible_start, viewport.height - screen_row));
            const visible_window = viewport.child(.{
                .y_off = @intCast(screen_row),
                .height = visible_height,
            });
            if (line.kind == .table) {
                drawTable(visible_window, line.kind.table, visible_start);
                document_row = line_end;
                if (document_row >= scroll + viewport.height) break;
                continue;
            }

            if (visible_start > std.math.maxInt(i17)) {
                document_row = line_end;
                if (document_row >= scroll + viewport.height) break;
                continue;
            }
            const line_window = viewport.child(.{
                .y_off = @as(i17, @intCast(screen_row)) - @as(i17, @intCast(visible_start)),
                .height = @intCast(@min(height, std.math.maxInt(u16))),
            });

            switch (line.kind) {
                .rule => drawRule(viewport, @intCast(document_row - scroll)),
                .heading => |level| {
                    drawHeadingBackground(visible_window, level);
                    _ = line_window.print(line.segments, .{
                        .row_offset = if (level == 1) 1 else 0,
                        .wrap = .word,
                    });
                    if (level == 2) drawHeadingDivider(line_window, height);
                },
                .code => {
                    visible_window.fill(.{ .char = .{ .grapheme = " " }, .style = .{ .bg = .{ .index = 0 } } });
                    _ = line_window.print(line.segments, .{ .wrap = .word });
                },
                .image => |image| {
                    if (visible_start == 0 and image.image != null) {
                        image.image.?.draw(visible_window, .{ .scale = .contain }) catch drawImageFallback(visible_window, line.segments);
                    } else {
                        drawImageFallback(visible_window, line.segments);
                    }
                },
                .table => unreachable,
                .normal => _ = line_window.print(line.segments, .{ .wrap = .word }),
            }
        }
        document_row = line_end;
        if (document_row >= scroll + viewport.height) break;
    }
}

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

fn drawTable(win: vaxis.Window, table: TableBlock, visible_start: usize) void {
    if (table.columns.len == 0 or win.width < table.columns.len * 4 + 1) {
        _ = win.printSegment(.{ .text = "[table too wide for terminal]", .style = .{ .dim = true } }, .{ .wrap = .none });
        return;
    }

    const widths = tableColumnWidths(win.width, table.columns.len);
    var document_row: usize = 0;
    drawVisibleTableBorder(win, document_row, visible_start, widths, .top);
    document_row += 1;
    const header_height = tableRowHeight(win, table, widths, null);
    drawVisibleTableRow(win, document_row, visible_start, table, widths, null, true, header_height);
    document_row += header_height;
    drawVisibleTableBorder(win, document_row, visible_start, widths, if (table.row_count == 0) .bottom else .middle);
    document_row += 1;
    for (0..table.row_count) |row_index| {
        const height = tableRowHeight(win, table, widths, row_index);
        drawVisibleTableRow(win, document_row, visible_start, table, widths, row_index, false, height);
        document_row += height;
        drawVisibleTableBorder(win, document_row, visible_start, widths, if (row_index + 1 == table.row_count) .bottom else .middle);
        document_row += 1;
        if (document_row >= visible_start + win.height) break;
    }
}

fn drawVisibleTableBorder(
    win: vaxis.Window,
    document_row: usize,
    visible_start: usize,
    widths: TableWidths,
    kind: TableBorderKind,
) void {
    if (document_row < visible_start or document_row >= visible_start + win.height) return;
    drawTableBorder(win, @intCast(document_row - visible_start), widths, kind);
}

fn drawVisibleTableRow(
    win: vaxis.Window,
    document_row: usize,
    visible_start: usize,
    table: TableBlock,
    widths: TableWidths,
    row_index: ?usize,
    header: bool,
    height: usize,
) void {
    const row_end = document_row + height;
    if (row_end <= visible_start or document_row >= visible_start + win.height) return;
    const skipped = visible_start -| document_row;
    if (skipped > std.math.maxInt(i17)) return;
    const screen_row = document_row -| visible_start;
    const row_window = win.child(.{
        .y_off = @as(i17, @intCast(screen_row)) - @as(i17, @intCast(skipped)),
        .height = @intCast(@min(height, std.math.maxInt(u16))),
    });
    _ = drawTableRow(row_window, 0, table, widths, row_index, header);
}

fn drawTableRow(
    win: vaxis.Window,
    row: u16,
    table: TableBlock,
    widths: TableWidths,
    row_index: ?usize,
    header: bool,
) u16 {
    const height: u16 = @intCast(tableRowHeight(win, table, widths, row_index));
    const fill_style: vaxis.Style = if (header)
        .{ .fg = .{ .index = 15 }, .bg = .{ .index = 4 }, .bold = true }
    else if (row_index.? % 2 == 1)
        .{ .bg = .{ .index = 0 } }
    else
        .{};

    for (0..height) |line| {
        win.writeCell(0, row + @as(u16, @intCast(line)), tableBorderCell("│"));
        for (table.columns, 0..) |_, index| {
            const cell_x = widths.offset(index) + @as(u16, @intCast(index + 1));
            const cell_width = widths.width(index);
            win.writeCell(cell_x + cell_width, row + @as(u16, @intCast(line)), tableBorderCell("│"));
        }
    }

    for (table.columns, 0..) |column, index| {
        const cell_x = widths.offset(index) + @as(u16, @intCast(index + 1));
        const cell_width = widths.width(index);
        const cell = win.child(.{
            .x_off = @intCast(cell_x),
            .y_off = @intCast(row),
            .width = cell_width,
            .height = height,
        });
        cell.fill(.{ .char = .{ .grapheme = " " }, .style = fill_style });

        const segments = if (row_index) |value_index|
            if (value_index < column.values.len) column.values[value_index] else &.{}
        else
            column.header;
        const content_width = cell_width -| 2;
        const content = cell.child(.{ .x_off = 1, .width = content_width, .height = height });
        const text_height = measuredLineHeight(content, segments);
        const col_offset = tableTextOffset(content, segments, text_height, column.alignment);
        _ = content.print(segments, .{ .col_offset = col_offset, .wrap = .word });
    }
    return height;
}

fn tableTextOffset(
    win: vaxis.Window,
    segments: []const vaxis.Segment,
    text_height: usize,
    alignment: markdown.Node.Column.Alignment,
) u16 {
    if (text_height != 1 or alignment == .left) return 0;
    const result = win.print(segments, .{ .wrap = .none, .commit = false });
    const remaining = win.width -| result.col;
    return switch (alignment) {
        .left => 0,
        .center => remaining / 2,
        .right => remaining,
    };
}

fn drawTableBorder(win: vaxis.Window, row: u16, widths: TableWidths, kind: TableBorderKind) void {
    if (row >= win.height) return;
    const left: []const u8, const join: []const u8, const right: []const u8 = switch (kind) {
        .top => .{ "┌", "┬", "┐" },
        .middle => .{ "├", "┼", "┤" },
        .bottom => .{ "└", "┴", "┘" },
    };
    win.writeCell(0, row, tableBorderCell(left));
    for (0..widths.columns) |index| {
        const start = widths.offset(index) + @as(u16, @intCast(index + 1));
        for (0..widths.width(index)) |offset| {
            win.writeCell(start + @as(u16, @intCast(offset)), row, tableBorderCell("─"));
        }
        win.writeCell(start + widths.width(index), row, tableBorderCell(if (index + 1 == widths.columns) right else join));
    }
}

fn tableBorderCell(grapheme: []const u8) vaxis.Cell {
    return .{
        .char = .{ .grapheme = grapheme },
        .style = .{ .fg = .{ .index = 8 } },
    };
}

fn drawRule(viewport: vaxis.Window, row: u16) void {
    if (row >= viewport.height) return;
    var col: u16 = 0;
    while (col < viewport.width) : (col += 1) {
        viewport.writeCell(col, row, .{
            .char = .{ .grapheme = "─" },
            .style = .{ .fg = .{ .index = 8 } },
        });
    }
}

fn drawImageFallback(win: vaxis.Window, segments: []const vaxis.Segment) void {
    win.fill(.{ .char = .{ .grapheme = " " }, .style = .{ .bg = .{ .index = 0 } } });
    _ = win.print(segments, .{ .row_offset = 1, .col_offset = 2, .wrap = .word });
    _ = win.printSegment(.{
        .text = "Kitty graphics support is unavailable in this terminal.",
        .style = .{ .dim = true },
    }, .{ .row_offset = 3, .col_offset = 2, .wrap = .word });
}

fn drawHeadingBackground(win: vaxis.Window, level: u8) void {
    if (level > 2) return;
    const style: vaxis.Style = if (level == 1)
        .{ .fg = .{ .index = 15 }, .bg = .{ .index = 5 }, .bold = true }
    else
        .{ .fg = .{ .index = 15 }, .bg = .{ .index = 4 }, .bold = true };
    win.fill(.{ .char = .{ .grapheme = " " }, .style = style });
}

fn drawHeadingDivider(win: vaxis.Window, height: usize) void {
    if (height == 0 or height > win.height) return;
    const row: u16 = @intCast(height - 1);
    var col: u16 = 0;
    while (col < win.width) : (col += 1) {
        win.writeCell(col, row, .{
            .char = .{ .grapheme = "─" },
            .style = .{ .fg = .{ .index = 6 }, .bg = .{ .index = 4 } },
        });
    }
}

fn drawScrollbar(win: vaxis.Window, scroll: usize, total_rows: usize, viewport_height: u16) void {
    if (total_rows <= viewport_height or viewport_height == 0) return;
    const track_height: usize = viewport_height;
    const thumb_height = @max(track_height * track_height / total_rows, 1);
    const max_scroll = total_rows - track_height;
    const thumb_start = scroll * (track_height - thumb_height) / max_scroll;
    const col = win.width - 1;

    for (0..track_height) |row| {
        win.writeCell(col, @intCast(row + 1), .{
            .char = .{ .grapheme = if (row >= thumb_start and row < thumb_start + thumb_height) "█" else "│" },
            .style = .{ .fg = .{ .index = if (row >= thumb_start and row < thumb_start + thumb_height) 6 else 8 } },
        });
    }
}

fn drawBar(win: vaxis.Window, text: []const u8, position: enum { top, bottom }) void {
    const style: vaxis.Style = switch (position) {
        .top => .{ .bold = true, .fg = .{ .index = 15 }, .bg = .{ .index = 4 } },
        .bottom => .{ .fg = .{ .index = 15 }, .bg = .{ .index = 8 } },
    };
    win.fill(.{ .char = .{ .grapheme = " " }, .style = style });
    _ = win.printSegment(.{ .text = if (position == .top) "  Markdown  " else "  ", .style = style }, .{ .wrap = .none });
    _ = win.printSegment(.{ .text = text, .style = style }, .{
        .col_offset = if (position == .top) 12 else 2,
        .wrap = .none,
    });
}

fn headingStyle(level: u8) vaxis.Style {
    return switch (level) {
        1 => .{ .bold = true, .fg = .{ .index = 15 }, .bg = .{ .index = 5 } },
        2 => .{ .bold = true, .fg = .{ .index = 15 }, .bg = .{ .index = 4 } },
        3 => .{ .bold = true, .ul_style = .single, .fg = .{ .index = 6 } },
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

fn segment(text: []const u8, style: vaxis.Style, link: ?[]const u8) vaxis.Segment {
    return .{
        .text = text,
        .style = style,
        .link = if (link) |uri| .{ .uri = uri } else .{},
    };
}

fn applyBackground(segments: []vaxis.Segment, background: vaxis.Color) void {
    for (segments) |*item| item.style.bg = background;
}

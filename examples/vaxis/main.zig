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

const LineKind = union(enum) {
    normal,
    heading: u8,
    code,
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
            .table => try self.addTextLine("[table]", .{ .dim = true }),
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
        .heading => |level| measuredLineHeight(measure, line.segments) + @as(usize, switch (level) {
            1 => 2,
            2 => 1,
            else => 0,
        }),
    };
}

fn measuredLineHeight(measure: vaxis.Window, segments: []const vaxis.Segment) usize {
    if (segments.len == 0) return 1;
    const result = measure.print(segments, .{ .wrap = .word, .commit = false });
    return @max(@as(usize, result.row) + @intFromBool(result.col > 0), 1);
}

fn drawDocument(viewport: vaxis.Window, lines: []const Line, scroll: usize) void {
    var document_row: usize = 0;
    for (lines) |line| {
        document_row += line.gap_before;
        const height = lineHeight(viewport, line);
        const line_end = document_row + height;
        if (line_end > scroll and document_row < scroll + viewport.height) {
            const visible_start = scroll -| document_row;
            const screen_row: i17 = @intCast(document_row -| scroll);
            const line_window = viewport.child(.{
                .y_off = screen_row - @as(i17, @intCast(visible_start)),
                .height = @intCast(@min(height, std.math.maxInt(u16))),
            });

            switch (line.kind) {
                .rule => drawRule(viewport, @intCast(document_row - scroll)),
                .heading => |level| {
                    drawHeadingBackground(line_window, level);
                    _ = line_window.print(line.segments, .{
                        .row_offset = if (level == 1) 1 else 0,
                        .wrap = .word,
                    });
                    if (level == 2) drawHeadingDivider(line_window, height);
                },
                .code => {
                    line_window.fill(.{ .char = .{ .grapheme = " " }, .style = .{ .bg = .{ .index = 0 } } });
                    _ = line_window.print(line.segments, .{ .wrap = .word });
                },
                .normal => _ = line_window.print(line.segments, .{ .wrap = .word }),
            }
        }
        document_row = line_end;
        if (document_row >= scroll + viewport.height) break;
    }
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

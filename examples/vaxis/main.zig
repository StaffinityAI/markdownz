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

const Line = struct {
    segments: []const vaxis.Segment,
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
                try self.appendSections(&segments, heading.text, headingStyle(heading.level), null);
                try self.addLine(&segments);
                try self.render(heading.children.items, quote_depth);
            },
            .text => |sections| {
                var segments: std.ArrayList(vaxis.Segment) = .empty;
                try self.appendPrefix(&segments, quote_depth, "");
                try self.appendSections(&segments, sections, .{}, null);
                try self.addLine(&segments);
            },
            .line_break => try self.addTextLine("", .{}),
            .horizontal_rule => try self.addTextLine("────────────────────────────────────────", .{ .dim = true }),
            .code_block => |block| {
                const label = if (block.language.len == 0) "code" else block.language;
                var header: std.ArrayList(vaxis.Segment) = .empty;
                try self.appendPrefix(&header, quote_depth, "");
                try header.append(self.allocator, .{ .text = label, .style = .{ .bold = true, .fg = .{ .index = 6 } } });
                try self.addLine(&header);
                for (block.lines.items) |line| {
                    var segments: std.ArrayList(vaxis.Segment) = .empty;
                    try self.appendPrefix(&segments, quote_depth, "  ");
                    try segments.append(self.allocator, .{ .text = line, .style = .{ .fg = .{ .index = 2 } } });
                    try self.addLine(&segments);
                }
            },
            .list => |list| try self.renderList(list, 0, quote_depth),
            .block_quote => |nodes_in_quote| try self.render(nodes_in_quote.items, quote_depth + 1),
            .table => try self.addTextLine("[table]", .{ .dim = true }),
            .footnote => |sections| {
                var segments: std.ArrayList(vaxis.Segment) = .empty;
                try self.appendPrefix(&segments, quote_depth, "[^] ");
                try self.appendSections(&segments, sections, .{ .dim = true }, null);
                try self.addLine(&segments);
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
            try self.addLine(&segments);
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

    fn addLine(self: *Renderer, segments: *std.ArrayList(vaxis.Segment)) !void {
        try self.document.lines.append(self.allocator, .{ .segments = try segments.toOwnedSlice(self.allocator) });
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
                if (key.matches(vaxis.Key.end, .{}) or key.matches('G', .{})) scroll = document.lines.items.len;
            },
            .winsize => |winsize| try vx.resize(init.gpa, tty.writer(), winsize),
        }

        const win = vx.window();
        win.clear();

        const content_height = win.height -| 1;
        const max_scroll = document.lines.items.len -| content_height;
        scroll = @min(scroll, max_scroll);

        var row: u16 = 0;
        while (row < content_height and scroll + row < document.lines.items.len) : (row += 1) {
            _ = win.print(document.lines.items[scroll + row].segments, .{ .row_offset = row, .wrap = .none });
        }

        var status_buffer: [512]u8 = undefined;
        const status = try std.fmt.bufPrint(&status_buffer, " {s}  line {d}/{d}  ↑↓/jk scroll  q quit ", .{
            if (args.len == 2) std.fs.path.basename(args[1]) else "Markdown concepts",
            if (document.lines.items.len == 0) 0 else scroll + 1,
            document.lines.items.len,
        });
        _ = win.printSegment(.{ .text = status, .style = .{ .reverse = true } }, .{ .row_offset = win.height -| 1, .wrap = .none });

        try vx.render(tty.writer());
        try tty.writer().flush();
    }
}

fn headingStyle(level: u8) vaxis.Style {
    return .{
        .bold = true,
        .ul_style = if (level <= 2) .single else .off,
        .fg = .{ .index = switch (level) {
            1 => 5,
            2 => 4,
            3 => 6,
            else => 3,
        } },
    };
}

fn segment(text: []const u8, style: vaxis.Style, link: ?[]const u8) vaxis.Segment {
    return .{
        .text = text,
        .style = style,
        .link = if (link) |uri| .{ .uri = uri } else .{},
    };
}

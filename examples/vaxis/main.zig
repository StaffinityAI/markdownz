const std = @import("std");
const default_document = @import("default_document");
const markdown = @import("markdown");
const term = @import("markdown-term");
const vaxis = @import("vaxis");

pub const panic = vaxis.Panic;

const max_markdown_size = 64 * 1024 * 1024;
const default_markdown = default_document.source;
const image_height = 14;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
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
    const document = try term.build(render_arena.allocator(), graph);
    const images = try render_arena.allocator().alloc(?vaxis.Image, document.blocks.len);
    @memset(images, null);

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
        document,
        images,
        &vx,
        tty.writer(),
        init.gpa,
        if (args.len == 2) std.fs.path.dirname(args[1]) orelse "." else null,
    ) catch |err| {
        freeDocumentImages(images, vx, tty.writer());
        return err;
    };
    defer freeDocumentImages(images, vx, tty.writer());

    const title = if (args.len == 2) std.fs.path.basename(args[1]) else "Markdown concepts";
    var scroll: usize = 0;
    var layout: term.Layout = .{};
    defer layout.deinit(init.gpa);
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
        const measure = windowMeasure(win);
        try layout.update(init.gpa, document.blocks, .{
            .width = body_width,
            .measure = measure,
            .image_height = image_height,
        });
        const total_rows = layout.total_rows;
        const max_scroll = total_rows -| content_height;
        scroll = @min(scroll, max_scroll);

        const viewport = win.child(.{
            .x_off = @intCast(outer_margin),
            .y_off = 1,
            .width = body_width,
            .height = content_height,
        });
        drawDocument(viewport, document, images, layout, scroll, measure);
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
    document: term.Document,
    images: []?vaxis.Image,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    markdown_dir: ?[]const u8,
) !void {
    if (!vx.caps.kitty_graphics) return;

    for (document.blocks, images) |block, *image| switch (block.kind) {
        .image => |image_path| {
            image.* = if (markdown_dir) |dir| blk: {
                const path = if (std.fs.path.isAbsolute(image_path))
                    image_path
                else
                    try std.fs.path.join(allocator, &.{ dir, image_path });
                defer if (path.ptr != image_path.ptr) allocator.free(path);
                break :blk vx.loadImage(allocator, tty, .{ .path = path }) catch |err| {
                    std.log.warn("unable to load image '{s}': {s}", .{ image_path, @errorName(err) });
                    continue;
                };
            } else if (std.mem.eql(u8, image_path, default_document.image_name))
                vx.loadImage(allocator, tty, .{ .mem = default_document.image }) catch |err| {
                    std.log.warn("unable to load embedded image '{s}': {s}", .{ image_path, @errorName(err) });
                    continue;
                }
            else
                continue;
        },
        else => {},
    };
}

fn freeDocumentImages(images: []const ?vaxis.Image, vx: vaxis.Vaxis, tty: *std.Io.Writer) void {
    for (images) |image| if (image) |loaded| vx.freeImage(tty, loaded.id);
}

fn drawDocument(
    viewport: vaxis.Window,
    document: term.Document,
    images: []const ?vaxis.Image,
    layout: term.Layout,
    scroll: usize,
    measure: term.Measure,
) void {
    var index = layout.firstVisible(scroll);
    while (index < document.blocks.len) : (index += 1) {
        const block = document.blocks[index];
        const block_row = layout.starts.items[index];
        const height = layout.heights.items[index];
        const block_end = block_row + height;
        if (block_end > scroll and block_row < scroll + viewport.height) {
            const visible_start = scroll -| block_row;
            const screen_row: u16 = @intCast(block_row -| scroll);
            const visible_window = viewport.child(.{
                .y_off = screen_row,
                .height = @intCast(@min(height - visible_start, viewport.height - screen_row)),
            });
            const region = windowRegion(&visible_window);
            switch (block.kind) {
                .image => if (visible_start == 0 and visible_window.height == height) {
                    if (images[index]) |loaded| {
                        loaded.draw(visible_window, .{ .scale = .contain }) catch drawImageFallback(region, block.spans, measure);
                    } else {
                        drawImageFallback(region, block.spans, measure);
                    }
                } else {
                    drawClippedImagePlaceholder(region, block.spans, visible_start, images[index] != null, measure);
                },
                else => term.paintBlock(region, block, height, visible_start, measure),
            }
        }
        if (block_end >= scroll + viewport.height) break;
    }
}

fn drawImageFallback(region: term.Region, spans: []const term.Span, measure: term.Measure) void {
    region.fill(.{ .style = .{ .bg = .{ .index = 0 } } });
    const text = region.child(.{ .x_off = 2 });
    term.paintSpans(text, spans, 0, 1, 0, measure);
    term.paintSpans(text, &.{.{
        .text = "Kitty graphics support is unavailable in this terminal.",
        .style = .{ .dim = true },
    }}, 0, 3, 0, measure);
}

fn drawClippedImagePlaceholder(region: term.Region, spans: []const term.Span, skipped_rows: usize, loaded: bool, measure: term.Measure) void {
    region.fill(.{ .style = .{ .bg = .{ .index = 0 } } });
    term.paintSpans(region, spans, skipped_rows, 1, 0, measure);
    term.paintSpans(region, &.{.{
        .text = if (loaded) "Image preview is shown when the full image block is visible." else "Image preview is unavailable.",
        .style = .{ .dim = true },
    }}, skipped_rows, 3, 0, measure);
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

/// Measures with the width method vaxis detected for the terminal, so wrapping
/// matches what vaxis draws.
fn windowMeasure(win: vaxis.Window) term.Measure {
    return .{ .context = &win.screen.width_method, .widthFn = measureWidth };
}

fn measureWidth(context: ?*const anyopaque, grapheme: []const u8) u16 {
    const method: *const vaxis.gwidth.Method = @ptrCast(@alignCast(context.?));
    return vaxis.gwidth.gwidth(grapheme, method.*);
}

/// `win` must stay alive while the region is used.
fn windowRegion(win: *const vaxis.Window) term.Region {
    return .{
        .surface = .{ .context = @constCast(win), .writeCellFn = writeWindowCell },
        .width = win.width,
        .height = win.height,
    };
}

fn writeWindowCell(context: *anyopaque, col: u16, row: u16, cell: term.Cell) void {
    const win: *const vaxis.Window = @ptrCast(@alignCast(context));
    win.writeCell(col, row, .{
        .char = .{ .grapheme = cell.grapheme, .width = cell.width },
        .style = vaxisStyle(cell.style),
        .link = if (cell.link) |uri| .{ .uri = uri } else .{},
        .wrapped = cell.wrapped,
    });
}

fn vaxisStyle(style: term.Style) vaxis.Style {
    return .{
        .fg = vaxisColor(style.fg),
        .bg = vaxisColor(style.bg),
        .ul_style = if (style.underline) .single else .off,
        .bold = style.bold,
        .dim = style.dim,
        .italic = style.italic,
        .reverse = style.reverse,
        .strikethrough = style.strikethrough,
    };
}

fn vaxisColor(color: term.Color) vaxis.Color {
    return switch (color) {
        .default => .default,
        .index => |index| .{ .index = index },
        .rgb => |rgb| .{ .rgb = rgb },
    };
}

test "window region writes styled cells through vaxis" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 2,
        .cols = 4,
        .x_pixel = 4,
        .y_pixel = 2,
    });
    defer screen.deinit(std.testing.allocator);
    screen.width_method = .unicode;
    var vx: vaxis.Vaxis = undefined;
    vx.screen = screen;
    const win = vx.window();
    const region = windowRegion(&win);
    term.paintSpans(region, &.{.{ .text = "ab😀", .style = .{ .bold = true }, .link = "https://example.com" }}, 0, 0, 0, windowMeasure(win));
    try std.testing.expectEqualStrings("a", screen.buf[0].char.grapheme);
    try std.testing.expect(screen.buf[0].style.bold);
    try std.testing.expectEqualStrings("https://example.com", screen.buf[0].link.uri);
    try std.testing.expectEqualStrings("😀", screen.buf[2].char.grapheme);
}

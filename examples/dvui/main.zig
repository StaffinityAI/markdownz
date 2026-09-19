const std = @import("std");
const default_document = @import("default_document");
const dvui = @import("dvui");
const SDLBackend = @import("sdl-backend");
const MarkdownWidget = @import("widget.zig");

const max_markdown_size = 64 * 1024 * 1024;
const max_image_size = 64 * 1024 * 1024;
const default_markdown = default_document.source;
const default_title: [:0]const u8 = "Markdown concepts";

var markdown_source: []const u8 = &.{};
var markdown_dir: []const u8 = ".";
const CachedImage = union(enum) {
    loaded: []const u8,
    failed,
};
var image_cache: std.StringHashMapUnmanaged(CachedImage) = .empty;
var image_arena: std.mem.Allocator = undefined;
var app_io: std.Io = undefined;
var using_default_document = false;
var image_load_attempts: usize = 0;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) {
        std.debug.print("usage: {s} [markdown-file]\n", .{args[0]});
        return error.InvalidArguments;
    }

    image_arena = init.arena.allocator();
    app_io = init.io;

    const window_title: [:0]const u8 = if (args.len == 2) title: {
        markdown_source = try std.Io.Dir.cwd().readFileAlloc(
            init.io,
            args[1],
            init.gpa,
            .limited(max_markdown_size),
        );
        markdown_dir = std.fs.path.dirname(args[1]) orelse ".";
        break :title try image_arena.dupeZ(u8, std.fs.path.basename(args[1]));
    } else title: {
        markdown_source = default_markdown;
        using_default_document = true;
        break :title default_title;
    };
    defer if (args.len == 2) init.gpa.free(markdown_source);

    if (@import("builtin").os.tag == .windows) {
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }

    SDLBackend.enableSDLLogging();

    var backend = try SDLBackend.initWindow(.{
        .io = init.io,
        .environ_map = init.environ_map,
        .allocator = init.gpa,
        .size = .{ .w = 960, .h = 720 },
        .min_size = .{ .w = 400, .h = 300 },
        .vsync = true,
        .title = window_title,
    });
    defer backend.deinit();

    var win = try dvui.Window.init(@src(), init.gpa, backend.backend(), .{
        .theme = switch (backend.preferredColorScheme() orelse .light) {
            .light => dvui.Theme.builtin.adwaita_light,
            .dark => dvui.Theme.builtin.adwaita_dark,
        },
    });
    defer win.deinit();

    var widget_arena = std.heap.ArenaAllocator.init(init.gpa);
    defer widget_arena.deinit();

    var interrupted = false;
    while (true) {
        const nstime = win.beginWait(interrupted);
        try win.begin(nstime);
        try backend.addAllEvents(&win);

        _ = SDLBackend.c.SDL_SetRenderDrawColor(backend.renderer, 0, 0, 0, 0);
        _ = SDLBackend.c.SDL_RenderClear(backend.renderer);

        {
            var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
            defer scroll.deinit();
            try MarkdownWidget.init(@src(), &widget_arena, markdown_source, .{
                .parser = .{ .underline_extension = true },
                .get_image = getImage,
            });
        }

        var keep_running = true;
        for (dvui.events()) |*event| {
            if (event.evt == .window and event.evt.window.action == .close) keep_running = false;
            if (event.evt == .app and event.evt.app.action == .quit) keep_running = false;
        }

        const end_micros = try win.end(.{});
        try backend.setCursor(win.cursorRequested());
        try backend.textInputRect(win.textInputRequested());
        try backend.renderPresent();

        if (!keep_running) break;
        interrupted = try backend.waitEventTimeout(win.waitTime(end_micros));
    }
}

fn getImage(path_or_url: []const u8) dvui.Texture.ImageSource {
    if (image_cache.get(path_or_url)) |cached| return imageSource(path_or_url, cached);

    const bytes = loadImage(path_or_url) catch |err| {
        std.log.warn("unable to load image '{s}': {s}", .{ path_or_url, @errorName(err) });
        image_cache.put(image_arena, image_arena.dupe(u8, path_or_url) catch return imageSource(path_or_url, .failed), .failed) catch {};
        return imageSource(path_or_url, .failed);
    };

    image_cache.put(image_arena, image_arena.dupe(u8, path_or_url) catch return imageSource(path_or_url, .{ .loaded = bytes }), .{ .loaded = bytes }) catch {};
    return imageSource(path_or_url, .{ .loaded = bytes });
}

fn imageSource(path_or_url: []const u8, cached: CachedImage) dvui.Texture.ImageSource {
    const bytes = switch (cached) {
        .loaded => |loaded| loaded,
        .failed => &.{},
    };
    return .{ .imageFile = .{ .bytes = bytes, .name = path_or_url } };
}

fn loadImage(path_or_url: []const u8) ![]const u8 {
    image_load_attempts += 1;
    if (using_default_document and std.mem.eql(u8, path_or_url, default_document.image_name)) {
        return default_document.image;
    }

    if (std.mem.startsWith(u8, path_or_url, "http://") or std.mem.startsWith(u8, path_or_url, "https://")) {
        return error.RemoteImagesUnsupported;
    }

    const path = if (std.fs.path.isAbsolute(path_or_url))
        path_or_url
    else
        try std.fs.path.join(image_arena, &.{ markdown_dir, path_or_url });
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        app_io,
        path,
        image_arena,
        .limited(max_image_size),
    );
    return bytes;
}

test "failed image loads are cached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    image_arena = arena.allocator();
    image_cache = .empty;
    image_load_attempts = 0;

    _ = getImage("https://example.invalid/missing.png");
    _ = getImage("https://example.invalid/missing.png");
    try std.testing.expectEqual(@as(usize, 1), image_load_attempts);
}

const std = @import("std");
const builtin = @import("builtin");
const default_document = @import("default_document");
const term = @import("markdown-term");

const max_markdown_size = 64 * 1024 * 1024;
const default_width = 80;

const ColorMode = enum { auto, always, never };

const Arguments = struct {
    path: ?[]const u8 = null,
    width: ?u16 = null,
    color: ColorMode = .auto,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const arguments = parseArguments(args) catch {
        std.debug.print("usage: {s} [--width N] [--color auto|always|never] [markdown-file]\n", .{args[0]});
        return error.InvalidArguments;
    };

    const source = if (arguments.path) |path|
        try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .limited(max_markdown_size))
    else
        default_document.source;
    defer if (arguments.path != null) init.gpa.free(source);

    const stdout = std.Io.File.stdout();
    const color = switch (arguments.color) {
        .always => true,
        .never => false,
        .auto => try stdout.isTty(init.io) and !hasValue(init.environ_map.get("NO_COLOR")),
    };

    var buffer: [4096]u8 = undefined;
    var writer = stdout.writer(init.io, &buffer);
    try term.renderText(init.gpa, &writer.interface, source, .{
        .width = arguments.width orelse terminalWidth(stdout) orelse default_width,
        .color = color,
        .parse = .{ .underline_extension = true },
    });
    try writer.interface.flush();
}

fn parseArguments(args: []const [:0]const u8) !Arguments {
    var arguments: Arguments = .{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--width") or std.mem.eql(u8, arg, "--color")) {
            index += 1;
            if (index == args.len) return error.InvalidArguments;
            const value = args[index];
            if (arg[2] == 'w') {
                arguments.width = try std.fmt.parseInt(u16, value, 10);
                if (arguments.width == 0) return error.InvalidArguments;
            } else {
                arguments.color = std.meta.stringToEnum(ColorMode, value) orelse return error.InvalidArguments;
            }
        } else if (arguments.path == null and !std.mem.startsWith(u8, arg, "-")) {
            arguments.path = arg;
        } else {
            return error.InvalidArguments;
        }
    }
    return arguments;
}

fn terminalWidth(file: std.Io.File) ?u16 {
    if (builtin.os.tag == .windows) return null;
    var winsize: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const rc = std.posix.system.ioctl(file.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&winsize));
    if (std.posix.errno(rc) != .SUCCESS or winsize.col == 0) return null;
    return winsize.col;
}

fn hasValue(value: ?[]const u8) bool {
    return if (value) |text| text.len > 0 else false;
}

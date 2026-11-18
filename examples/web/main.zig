const std = @import("std");
const default_document = @import("default_document");
const html = @import("markdown-html");
const httpz = @import("httpz");

const port = 8801;

pub fn main(init: std.process.Init) !void {
    var server = try httpz.Server(void).init(init.io, init.gpa, .{
        .address = .localhost(port),
    }, {});
    defer server.deinit();
    defer server.stop();

    var router = try server.router(.{});
    router.get("/", index, .{});

    std.debug.print("listening http://localhost:{d}/\n", .{port});
    try server.listen();
}

fn index(_: *httpz.Request, response: *httpz.Response) !void {
    response.content_type = .HTML;
    try html.renderText(response.arena, response.writer(), default_document.source, .{
        .title = "markdownz concept gallery",
        .parse = .{ .underline_extension = true },
    });
}

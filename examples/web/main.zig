const std = @import("std");
const default_document = @import("default_document");
const html = @import("markdown-html");
const httpz = @import("httpz");
const markdown = @import("markdown");

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
    const nodes = try markdown.parse(response.arena, default_document.source, .{ .underline_extension = true });
    response.content_type = .HTML;
    try html.render(response.writer(), nodes, .{ .title = "markdownz concept gallery" });
}

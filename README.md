# markdownz

`markdownz` is a Markdown parser for Zig 0.17.0+. It provides:

- `markdown`: dependency-free parser and AST
- `markdown-html`: optional HTML renderer
- `markdown-term`: optional terminal renderer for CLIs and TUIs
- Optional DVUI, Vaxis, and http.zig examples

## Installation

```sh
zig fetch --save git+https://github.com/StaffinityAI/markdownz
```

Add the modules you need in `build.zig`:

```zig
const markdown_dep = b.dependency("markdown", .{
    .target = target,
    .optimize = optimize,
});

const imports: []const std.Build.Module.Import = &.{
    .{ .name = "markdown", .module = markdown_dep.module("markdown") },
    .{ .name = "markdown-html", .module = markdown_dep.module("markdown-html") },
    .{ .name = "markdown-term", .module = markdown_dep.module("markdown-term") },
};
```

Import only `markdown` if HTML rendering is not needed. The separate renderer module adds no code to parser-only consumers.

## Parsing

```zig
const std = @import("std");
const markdown = @import("markdown");

var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();

const source = "# Hello\nMarkdown with **bold text**.";
const nodes = try markdown.parse(arena.allocator(), source, .{});
```

The returned AST and its slices remain valid while both the supplied allocator and source buffer are alive. An arena allocator is recommended for complete documents.

Parser options:

```zig
const options: markdown.Options = .{
    .mode = .loose,
    .underline_extension = true,
};
```

## HTML Rendering

Render a complete document into an allocated buffer:

```zig
const html = @import("markdown-html");

const document = try html.renderAlloc(allocator, nodes, .{
    .title = "Example",
});
defer allocator.free(document);
```

Use `html.render(writer, nodes, options)` to stream directly to an `std.Io.Writer`. Set `.document = false` for an HTML fragment. Content and attributes are HTML-escaped.

## Terminal Rendering

Write a document as terminal text, word-wrapped to a width:

```zig
const term = @import("markdown-term");

try term.render(allocator, writer, nodes, .{
    .width = 80,
    .color = true, // false for plain text without escape sequences
});
```

Styled output uses SGR escape sequences and OSC 8 hyperlinks. `term.renderAlloc` returns the output in an allocated buffer.

TUIs can use the steps behind `render` directly:

- `term.build(arena, nodes)` returns a `Document` of styled blocks.
- `term.Layout` stores the row offset and height of every block for a width, and finds the first visible block for a scroll position.
- `term.paintBlock(region, block, height, skipped_rows, measure)` draws the visible rows of a block onto a `Region` of any `Surface`, which receives cells through one callback.
- `term.Measure` returns grapheme widths. The default uses Unicode properties from uucode. Pass the TUI library's width function so wrapping matches what it draws.

The Vaxis example shows a Surface and Measure for libvaxis. It builds libvaxis with `external_uucode` so both use one uucode module.

## Supported Syntax

- ATX and Setext headings, including custom IDs
- Paragraphs, horizontal rules, and fenced code blocks
- Block quotes and nested ordered, unordered, and task lists
- Bold, italic, bold-italic, underline, strikethrough, highlight, and inline code
- Links, images, hover text, and emoji shortcodes
- Tables with column alignment
- LF and CRLF input

Automatic URLs, raw HTML, entities, and general backslash escapes are not implemented. Markdown marker detection is currently ASCII-oriented, while UTF-8 content is preserved.

## Examples

Run the DVUI graphical viewer:

```sh
zig build run-gui -Ddvui=true
```

Render Markdown to standard output:

```sh
zig build run-cli -- [--width N] [--color auto|always|never] [file.md]
```

Run the Vaxis terminal viewer:

```sh
zig build run-tui -Dvaxis=true
```

Run the http.zig web example, then open `http://localhost:8801/`:

```sh
zig build run-web -Dhttp=true
```

DVUI, Vaxis, and http.zig are lazy dependencies and are fetched only when their option is enabled. The DVUI and Vaxis viewers also accept a Markdown file after `--`.

## Testing

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test-compile -Dtarget=x86_64-linux-gnu
```

Licensed under the MIT License.

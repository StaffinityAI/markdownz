# markdownz

`markdownz` is a Markdown parser written in Zig. The core package has no UI dependency and exposes a parser module named `markdown`. Optional DVUI and Vaxis applications demonstrate graphical and terminal rendering.

The package requires Zig 0.16.0 or newer and is licensed under the MIT License.

## Installation

Add the package to your project:

```sh
zig fetch --save git+https://github.com/StaffinityAI/markdownz
```

Import the parser module from your `build.zig`:

```zig
const markdown_dep = b.dependency("markdown", .{
    .target = target,
    .optimize = optimize,
});

const app = b.addExecutable(.{
    .name = "example",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "markdown", .module = markdown_dep.module("markdown") },
        },
    }),
});
```

## Parsing

`parse` returns a tree of `markdown.Node` values allocated from the supplied allocator:

```zig
const std = @import("std");
const markdown = @import("markdown");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();

    const source =
        \\# Example
        \\
        \\A paragraph with **bold text**.
    ;

    const nodes = try markdown.parse(arena.allocator(), source, .{});
    for (nodes) |node| {
        switch (node.*) {
            .heading => |heading| std.debug.print("heading level {d}\n", .{heading.level}),
            .text => std.debug.print("paragraph\n", .{}),
            else => {},
        }
    }
}
```

### Ownership

- All nodes, sections, lists, table values, and parser-owned slices are allocated from the allocator passed to `markdown.parse`.
- Keep that allocator alive while reading the returned graph.
- The graph contains slices into the original Markdown buffer. Keep the input buffer alive for at least as long as the graph.
- An arena allocator is recommended when parsing a complete document. Deinitializing or resetting the arena releases the graph as one generation.

## Parser Options

```zig
const options: markdown.Options = .{
    .mode = .loose,
    .underline_extension = true,
};
```

| Option | Default | Behavior |
| --- | --- | --- |
| `mode` | `.loose` | `.loose` trims accepted padding in constructs such as link and image destinations. `.strict` rejects those padded forms. |
| `underline_extension` | `false` | Parses `__text__` as underline instead of bold. |
| `parse_arbitrary_urls` | `false` | Reserved for automatic URL parsing; not implemented. |
| `typographic_replacement` | `false` | Reserved for typographic substitutions; not implemented. |

## Supported Syntax

The parser currently supports:

- ATX headings from level 1 through 6, including custom IDs
- Setext headings
- Paragraph text and blank-line separation
- Horizontal rules
- Fenced code blocks with optional language text
- Block quotes
- Ordered, unordered, task, and indented nested lists
- Bold, italic, bold-italic, strikethrough, highlight, and inline code
- Optional underline syntax
- Links and images with optional hover text
- Emoji shortcode sections such as `:sparkles:`
- Tables with column alignment, missing-cell padding, escaped pipes, and pipes inside code spans
- LF and CRLF documents

The public node model also reserves variants for footnotes, alerts, containers, subscript, superscript, and typographic text. Those constructs are not currently parsed as dedicated nodes. Automatic URLs, HTML, entities, and general Markdown backslash escapes are also not implemented. Table parsing does recognize escaped pipes so they remain inside a cell.

Text scanning currently assumes ASCII for Markdown marker detection. UTF-8 text can be preserved in content, but full Unicode-aware parsing is not yet implemented.

## Tables

A table is represented as a slice of `markdown.Node.Column`. Each column contains:

- `alignment`: `.left`, `.center`, or `.right`
- `header`: parsed inline sections for the header cell
- `values`: one parsed section slice per body row

Rows with missing cells receive empty values. Cells beyond the declared header columns are ignored.

## Examples

Run the graphical DVUI viewer with the built-in concept gallery:

```sh
zig build run-gui
```

Run it with another Markdown file:

```sh
zig build run-gui -- path/to/document.md
```

Run the Vaxis terminal viewer:

```sh
zig build run-tui -- path/to/document.md
```

Build the viewers without running them:

```sh
zig build dvui-viewer
zig build vaxis-viewer
```

DVUI and Vaxis are lazy dependencies used only by their examples and renderer tests.

## Testing

Run the native parser and renderer tests:

```sh
zig build test
```

Run the safety-optimized test suite:

```sh
zig build test -Doptimize=ReleaseSafe
```

Compile parser tests for another target without attempting to execute foreign binaries:

```sh
zig build test-compile -Dtarget=x86_64-linux-gnu
```

## Migration From `dvui_markdown`

The package is now parser-first and uses the package name `markdown`.

| Previous API | Current API |
| --- | --- |
| `dependency.module("lib")` | `dependency.module("markdown")` |
| `lib.Parser.parse(...)` | `markdown.parse(...)` |
| `lib.Parser.Node` | `markdown.Node` |
| `lib.MarkdownWidget` | Optional legacy DVUI compatibility API through `module("lib")` |

The `lib` compatibility module requires the optional DVUI dependency and is retained for existing consumers. New parser-only integrations should use the `markdown` module directly.

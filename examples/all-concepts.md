# Markdown concept gallery

This document is the default input for the DVUI Markdown viewer. Pass a file path on the command line to view another document.

## Headings

### Level three

#### Level four

##### Level five

###### Level six

Setext level one
================

Setext level two
----------------

## Inline formatting

Plain text, *italic text*, **bold text**, ***bold italic text***, ~~struck text~~, ==highlighted text==, `inline code`, and :sparkles: emoji shortcode syntax.

The parser also recognizes __underline extension syntax__ when its underline option is enabled.

Subscript syntax H~2~O and superscript syntax 2^10^ are included for feature tracking.

## Links and images

[A link to the Zig website](https://ziglang.org/ "Zig programming language") and an automatic-looking URL: https://example.com/path?q=markdown

![Remote image placeholder](https://example.com/markdown.png "Remote images are intentionally unsupported by the sample")

## Block quotes

> A block quote can contain **formatted text**.
> Another quoted line follows it.

> [!NOTE]
> Alert-style block quote syntax is represented here too.

## Lists

- Unordered item
- Another unordered item
  - Nested unordered item
    - Deeply nested item

1. First ordered item
2. Second ordered item
  1. Nested ordered item
  2. Another nested ordered item

- [x] Completed task
- [ ] Incomplete task

## Horizontal rules

---

***

___

## Code blocks

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("Hello, Markdown!\\n", .{});
}
```

```text
Fenced code can also omit language-specific highlighting.
Special Markdown characters stay literal here: **bold** [link](url)
```

## Tables

| Feature | Status | Notes |
| :--- | :---: | ---: |
| Headings | Supported | Six levels |
| Tables | Planned | Included for feature tracking |

## Footnotes

This sentence contains a footnote reference.[^viewer]

[^viewer]: Footnote definitions are included for feature tracking.

## Containers

::: details
Custom container content is included for feature tracking.
:::

## HTML

<details>
<summary>Embedded HTML example</summary>
HTML is preserved as source text by parsers that do not interpret it.
</details>

## Escapes and entities

Escaped-looking punctuation: \\*not italic\\*, \\[not a link\\], and entities such as &amp;, &copy;, and &#8482;.

## Final paragraph

The gallery ends with a normal paragraph containing **bold**, *italic*, `code`, a [link](https://example.com), and ~~strikethrough~~ together.

# Remaining Merge Review Findings

- [x] Use frame-scoped allocation for transient DVUI table rendering data.
- [x] Clip partially visible Vaxis headings, code blocks, and images without negative child windows.
- [x] Measure Vaxis lines taller than 65,535 terminal rows without truncating document height.
- [x] Invalidate the DVUI parser graph cache when the Markdown source or parser options change.
- [x] Preserve line breaks when rendering unclosed fenced code blocks in DVUI.
- [x] Expose parser options through the DVUI widget API.
- [x] Clean up Vaxis terminal images when loading a later image fails.
- [x] Cache failed DVUI image loads so they are not retried and logged every frame.
- [x] Add DVUI renderer regression tests for the fixed runtime behavior.

## Final Audit Follow-ups

- [x] Invalidate cached DVUI code buffers when the source generation changes.
- [ ] Render table rows taller than 65,535 rows without narrowing the logical height to `u16`.
- [ ] Reclaim previous DVUI parser graph generations when source or parser options change.
- [ ] Avoid repeated renderer logs for cached DVUI image failures.
- [ ] Add behavioral assertions for source replacement, image caching, and extreme Vaxis heights.

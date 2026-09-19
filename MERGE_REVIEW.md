# Remaining Merge Review Findings

- [x] Use frame-scoped allocation for transient DVUI table rendering data.
- [x] Clip partially visible Vaxis headings, code blocks, and images without negative child windows.
- [x] Measure Vaxis lines taller than 65,535 terminal rows without truncating document height.
- [x] Invalidate the DVUI parser graph cache when the Markdown source or parser options change.
- [ ] Preserve line breaks when rendering unclosed fenced code blocks in DVUI.
- [ ] Expose parser options through the DVUI widget API.
- [ ] Clean up Vaxis terminal images when loading a later image fails.
- [ ] Cache failed DVUI image loads so they are not retried and logged every frame.
- [ ] Add DVUI renderer regression tests for the fixed runtime behavior.

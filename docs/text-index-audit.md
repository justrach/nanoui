# Text index audit

## Units used today

| Area | Unit | Source |
| --- | --- | --- |
| Text buffer, caret, selection and marked ranges | UTF-8 bytes | `src/ui/textfield.zig`, `src/ui/input.zig` |
| Ordinary left/right and deletion in editable fields | UTF-8 scalar boundaries. The caret is still a byte offset. | `src/ui/textfield.zig` |
| Pointer selection in selectable static text | Extended grapheme clusters and Unicode character classes. Existing tests cover Unicode 17 break vectors. | `src/ui/text_selection.zig`, `src/ui/tests_text_selection.zig` |
| Native IME offsets | AppKit, UIKit and Windows IMM use UTF-16 code units at the boundary. GTK converts the preedit cursor from code points. Android's hidden EditText keeps the composing span, and the widget receives committed text as UTF-8. | `src/ui/textinput.zig`, `src/ios/textinput.zig`, `src/windows/ime.zig`, `src/linux/ime.zig`, `src/android/ime.zig` |
| Text layout | Glyph positions are measured in points. Source indices in nanoui's shaping output are UTF-8 byte offsets. | `src/ui/text.zig`, `src/ui/text_tt.zig`, `src/ui/text_mac.zig` |
| Gallery notes counter | UTF-8 bytes and newline-delimited lines | `examples/gallery/main.zig` |

An offset inside a valid UTF-8 scalar now rounds down when applied to the
editable widget. Out-of-range offsets clamp to the end. Selection direction
is preserved. This also applies to queued selection and preedit offsets.
In invalid text, a stray continuation byte keeps its own offset rather than
moving the caret onto an earlier scalar.

## Follow-up contributions

1. Make ordinary caret movement, selection extension and deletion in
   editable fields respect extended grapheme boundaries. Reuse the
   segmentation already used by static text selection. Keep storage and IME
   APIs byte based. Cover decomposed accents, emoji with modifiers and ZWJ
   sequences, flags, Indic conjuncts, and a caret supplied inside a cluster.
   Measure repeated backward steps on long ASCII and non-ASCII lines before
   choosing a reverse lookup strategy.
2. Test geometry separately from editing. Use a synthetic ligature font
   with known advances and a deterministic CJK fallback fixture. Verify
   hit testing, caret placement and copied source bytes on the native and
   portable text paths. Glyph count can change with the font and shaping
   options even when byte and grapheme counts stay fixed.
3. Add host conversion cases for supplementary plane scalars in the middle
   of composition, including selection ranges next to a surrogate pair.
   Preserve each host's rounding and cancellation rules in its adapter.

See [Unicode Text Segmentation](https://www.unicode.org/reports/tr29/) for
extended grapheme rules.

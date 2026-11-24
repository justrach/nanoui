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

## Known gaps

- Caret movement and deletion in editable fields step by scalar, not by
  extended grapheme cluster ([UAX #29](https://www.unicode.org/reports/tr29/)).
- No tests cover glyph geometry (hit testing, caret placement) for ligatures
  or CJK fallback fonts separately from editing.
- No tests cover host offset conversion for supplementary-plane scalars in
  the middle of a composition.

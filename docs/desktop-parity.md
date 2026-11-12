# Opt-in desktop rendering controls

Applications that share a design with another renderer can select explicit
text and layout conventions without changing nanoui's defaults.

```zig
c.pixel_snap = true;
c.pixel_snap_text = false;
c.keyboard_hides_hover = true;
c.text.wrap_rule = .glyph_positions;
c.text.glyph_snap = .half_toward_zero;
c.text.baseline_rule = .glyph_box;
```

- `pixel_snap` rounds absolute box edges onto the device pixel grid before
  paint and hit rectangles are saved. Shared edges stay shared. Half ties
  round toward zero. `pixel_snap_text` separately controls text measurement;
  disabling it preserves explicitly requested fractional line heights.
- `keyboard_hides_hover` suppresses pointer hover after keyboard or text
  operations until pointer activity resumes. It preserves ancestor hover
  behavior and does not move keyboard focus.
- `wrap_rule = .glyph_positions` uses the shaped paragraph's glyph positions
  for CoreText wrapping. The default remains CoreText's native line breaker.
  Portable text already breaks by glyph positions. Empty paragraphs, UTF-8
  boundaries, styled spans, and tracking remain supported.
- `baseline_rule = .glyph_box` centers ascent and descent in the requested
  line height; `.font_line` retains the normal font-leading convention.
- `glyph_snap = .half_toward_zero` selects matching device-space baseline and
  glyph phase quantization. `.nearest` retains nanoui's normal placement.

## Theme

Set `c.theme_chosen` to `ui.Theme.light`, `ui.Theme.dark_theme`, or `null`
(the system) in the view; a change resolves in the same frame. A window's
`theme` option takes precedence. The title bar follows on macOS and Windows;
on Linux it belongs to the desktop's decoration theme, which no app can set
per window.

## Text styles

`TextStyle.system_font` bypasses a proportional theme font for a system-style
label. Monospaced text keeps the configured mono family. Native and portable
font/layout caches distinguish the two requests.

`TextStyle.span_box` gives highlighted spans a line-based background:

```zig
ui.richText(c, "Match", spans, .{
    .size = 13,
    .line_height = 20,
    .span_box = .{ .pad_x = 1, .inset_y = 1.5, .radius = 3 },
});
```

Without `span_box`, backgrounds retain the existing glyph-fitted shape.

`TextFieldOptions.weight` and `TextFieldOptions.mono` select the field's font
for text, placeholder, suggestion, wrapping, selection, and caret geometry.
Defaults remain regular proportional text.

## Layout and offscreen rendering

Multiline fields depend on the previous layout's width. They request a
follow-up frame when their laid-out size changes, so wrapping and anchored
controls settle without relying on an unrelated focus animation. Unchanged
sizes do not schedule frames.

`Tester.render` clears with the view's resolved live theme, including
transparent backgrounds, rather than its initial test options.

## Delayed help

`Div.tooltip(text, options)` and `Div.tooltipWith(state, draw, options)` attach
window-contained help to a control. Options include delay, padding, width,
text style, background, border, and shadows. A decorative child can own a
hint without taking its parent's click target. Pressing dismisses the hint;
keyboard modality can hide it until the pointer resumes.

Hints schedule a frame for the remaining delay rather than polling. Custom
content is laid out outside the owner's normal flow. `Tester.hoverText`,
`tooltipText`, and `tooltipRect` support offscreen interaction assertions.

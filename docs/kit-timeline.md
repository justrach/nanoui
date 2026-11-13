# Timeline rows

`nanoui.kit.timelineItem(c, opts) ui.Div` opens a full-width horizontal row
with a decorative connector rail and dot. Draw ordinary native content after
it, then call `end()`. The component does not select items, clip content,
handle input, or request animation frames.

```zig
const kit = nanoui.kit;
const ui = nanoui.ui;

const list = ui.div(c).column().wFull(); // No gap: the rails join.
defer list.end();
for (events, 0..) |event, i| {
    ui.key(c, event.id);
    const item = kit.timelineItem(c, .{
        .first = i == 0,
        .last = i + 1 == events.len,
        .selected = selected == i,
    });
    defer item.end();
    const body = ui.div(c).column().grow().gap(4);
    defer body.end();
    ui.text(c, event.title, .{});
    ui.text(c, event.detail, .{ .size = 12, .color = c.theme.muted });
}
```

`kit.TimelineItemOptions`:

| Field | Default | Meaning |
| --- | --- | --- |
| `height: f32` | `56` | Fixed row height in points, clamped to at least 8. |
| `first: bool` | `false` | Omit the connector above the dot. |
| `last: bool` | `false` | Omit the connector below the dot. |
| `color: ?ui.Color` | `null` | Dot color, defaulting to the theme's primary. Connectors use 35% of its opacity. |
| `selected: bool` | `false` | Static background tint at 8% of the dot's opacity; no selection behavior. |

The rail is 24 points wide, followed by an 8-point gap. Its 8-point circular
dot is centered vertically in the configured height. Set both `first` and
`last` for a single isolated item. For a partial or virtualized list, mark
only the actual endpoints, not the visible or loaded page's boundaries.
Use stable `ui.key`s for repeated rows.

Content owns its layout and interaction. A growing column uses the remaining
width; use wrapping or truncation as needed, and choose a height that fits
it. Place controls in the content, or opt into the returned row's ordinary
`Div` interaction methods yourself. Keep the configured height when styling
the returned row so its connector geometry stays aligned.

Offscreen synthetic fixtures in `src/kit/tests_timeline.zig` cover light and
dark appearance, endpoint connectors, custom heights and colors, selection
tint, overflow, pointer passthrough, native controls, and idle quiescence.
They save `nanoui-kit-timeline-{light,dark}.png` in `.zig-cache/tmp`, using
`ui.Tester` without showing windows.

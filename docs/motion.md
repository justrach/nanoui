# ui.motion

Declarative, interruptible animation for nanoui's native UI. Every frame you
say where a box should be (its target) and how to get there (a spring or a
tween). Motion remembers where it is. A target that changes midway is taken
from there; a spring keeps its speed.

The model follows [gpui-motion](https://github.com/1bye/gpui-motion) (MIT)
and [Motion](https://motion.dev) (ideas only, no copied code): state-driven
targets, closed-form springs, FLIP layout, presence, drag, scroll-linked
values, and staggered text. State lives in the `Context` by box id. Nothing
is allocated per frame on the hot path once the store has its slots, and
frames are requested only while something is moving.

Reduced motion jumps to the target.

## Targets

`x`, `y`, `scale`, `opacity`, `width`, `height`, `radius`, `background`.
What a target leaves null is left alone. `hover` and `press` overlay the
target while the pointer is over or pressing the box.

```zig
const f = ui.motion.frame(c, .{
    .target = .{ .width = if (open) 320 else 180, .background = if (open) th.accent else th.surface },
    .initial = .{ .y = 12, .opacity = 0 },
    .press = .{ .scale = 0.96 },
    .hover = .{ .y = -2 },
    .transition = .{ .spring = ui.motion.Spring.bouncy },
});
const card = ui.div(c).control().motion(f);
```

## Springs and tweens

```zig
.{ .spring = .{ .stiffness = 240, .damping = 26, .mass = 1 } }
.{ .spring = ui.motion.Spring.snappy } // also .gentle, .bouncy
.{ .spring = ui.motion.Spring.visual(0.4, 0.15) } // 90% in 0.4s
.{ .tween = .{ .duration = 0.3, .ease = .ease_out } }
.instant
```

The spring is solved exactly (under-, critically-, and over-damped). A
value at any time is the same however the frames fell.

## Presence

```zig
if (ui.motion.present(c, "toast", show, .{
    .initial = .{ .y = 24, .opacity = 0 },
    .exit = .{ .y = 24, .opacity = 0 },
})) |f| { ... }
```

The box stays drawn until its exit settles, then `present` returns null.

## Layout and shared elements

`.layout = true` glides a box when flexbox moves it (a list shuffle).
`share(c, "chip", show, m)` does the same across parents: one key, one
place it was last drawn, FLIP to where it is now.

## Drag and snap

```zig
const d = ui.motion.drag(c, .{
    .min = .{ 0, 0 },
    .max = .{ 280, 0 },
    .axis = .x,
    .snap = &.{ .{ 0, 0 }, .{ 140, 0 }, .{ 280, 0 } },
    .elasticity = 0.18,
    .momentum = true,
});
const knob = ui.div(c).control().motion(d.frame());
```

While pressed the box follows the pointer (rubber-banded past the edges).
On release it keeps its speed and springs to the nearest snap or grid.

## Scroll-linked values

Every scrolling box records `scroll_max` (not only `follow_end` ones).

```zig
const p = ui.motion.scroll.of(c, scroller_id); // 0..1
const w = ui.motion.scroll.value(c, "bar", scroller_id, .{ 0, 200 }, .instant);
const y = ui.motion.scroll.remap(p, .{ 0, 1 }, .{ 0, 40 }, true);
```

`inView(viewport, item)` is the overlapping fraction of the item.

## Staggered text

```zig
ui.motion.letters(c, "nanoui in motion", .{ .size = 22 }, .{
    .unit = .letters, // or .words, .whole
    .enter = .{ .y = 12, .opacity = 0 },
    .stagger_each = 0.03,
});
```

## Numbers and keyframes

```zig
const n = ui.motion.number(c, "count", value, .{ .tween = .{ .duration = 0.8 } });
const pulse = ui.motion.keyframes(c, .{
    .values = &.{ .{ .scale = 1 }, .{ .scale = 1.6 }, .{ .scale = 1 } },
    .duration = 1.6,
    .repeat = null,
});
```

## Tick

`Context.animationFrame` is set only while a channel is moving. An idle
app draws nothing. The tick does not wait for app logic: each channel is
sampled from the clock independently of the view that declared the target.

## Stretch: vector clips

Lottie / Rive-style vector playback is not in this layer. Keyframes cover
poses of boxes; a later clip player can drive the same `Target` channels
from a parsed animation file.

## Demos

The gallery's Motion page (`examples/gallery/motion.zig`) and
`src/ui/tests_motion.zig` / `tests_motion_more.zig`.

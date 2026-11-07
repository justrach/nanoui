# Motion presets and reusable effects

`ui.motion.catalog` adds named duration/curve presets over nanoui's existing
interruptible animation channels. Nothing changes until an application opts in.
The presets originate in Harness's desktop UI; they are usable without Harness,
its engine, or a process-global clock.

```zig
const ui = @import("nanoui").ui;

fn view(_: *State, c: *ui.Context) void {
    const entry = ui.motion.menuIn(c);
    const menu = ui.div(c).column().motion(entry);
    defer menu.end();
    ui.text(c, "Choose a folder", .{});
}
```

Give repeated items stable `ui.key` identities before requesting their motion.
`fadeIn`, `settleDown`, `fadeQuick`, `menuIn`, `dialogIn`, and `splashOut`
produce paint-layer frames; they do not create a second animation engine.
`menuOut` accepts caller-owned normalized closing progress so a remount cannot
restart the exit timeline.

## Presets

A `MotionSpec` contains `duration_ms`, `delay_ms`, and `curve`. `transition()`
returns a normal nanoui transition; `animate(initial, target)` includes delay.
`total()` reports seconds including delay, and `progress()` maps normalized
whole-timeline progress through the delay and easing curve. `scaled(factor)`
is an explicit measurement aid, not an environment-variable override.

Presets include fades, menus, dialogs, resizing, tab movement, collapse,
chevrons, scroll glides, hover fades, and repeating loader phases.

## Hover and loaders

`hoverT` reverses from the current value and resets after unmounting. `revealT`
retains its progress across skipped paints; call `resetReveal` when clearing
that retained state. `hoverBlend` interpolates colors with premultiplied alpha.

`pulseLease` schedules the next frame only while called by a mounted loader.
Its `active` and `slow` options reduce cosmetic update frequency; no polling
thread remains after unmount. `pulseDelta` uses the Context clock, while
`phaseAt` accepts a shared elapsed clock for synchronization between windows.

`ui.motion.effects` also exposes pure pulse, stagger, matrix-wave, resize-edge
bounce, color interpolation, and reduced-motion preference calculations.
These functions do not read application state or schedule frames.

## Reduced motion

Both `Context.reduced_motion` and the legacy `reduce_motion` flag settle
entrances immediately, including their initial delay. Switching an already
moving channel to `.instant` also settles it when the target is unchanged.
Loader helpers do not schedule cosmetic frames while motion is reduced.

Regressions for these behaviors live in `src/ui/motion/tests_reduced_motion.zig`;
the catalog and pure effects are exercised by `tests_catalog.zig` and
`effects_test.zig`. Run them with the rest of the toolkit:

```sh
zig build test --release=safe -j1
zig build test --release=safe -j1 -Dportable=true
```

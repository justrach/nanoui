# Motion catalog

`ui.motion` includes Harness's `crates/ui/src/motion.rs` catalog, using the
existing nanoui channels, presence, and layout engine. No GPUI dependency,
second animation store, process-global timers, or settings persistence.

```zig
const m = ui.motion;
const catalog = m.catalog;

// Call before its box, after ui.key when the box is in a keyed list.
const entry = m.fadeIn(c);
const card = ui.div(c).column().motion(entry);
defer card.end();
ui.text(c, "Ready", .{});
```

## Timings and curves

All `MotionSpec.duration_ms` and `delay_ms` values are milliseconds;
`total()` and transitions return seconds.

| `ui.motion.catalog` | Duration | Delay | CSS curve |
|---|---:|---:|---|
| `fade_in` | 500 | 0 | `(0.16, 1, 0.3, 1)` |
| `fade_quick` | 150 | 0 | `ease` |
| `menu_in` | 140 | 0 | `ease` |
| `menu_out` | 100 | 0 | `ease` |
| `dialog_in` | 180 | 0 | `ease` |
| `splash_out` | 500 | 150 | `ease` |
| `resize` | 200 | 0 | `ease-out` |
| `tab_slide` | 150 | 0 | `ease-out` |
| `collapse` | 180 | 0 | `ease-out` |
| `new_thread_transition` | 420 | 0 | `(0.22, 1, 0.36, 1)` |
| `chevron` | 200 | 0 | `ease` |
| `scroll_glide` | 500 | 0 | `ease-in-out` |
| `hover_fade` | 150 | 0 | `(0.4, 0, 0.2, 1)` |
| `hover_reveal` | 320 | 0 | `(0.22, 1, 0.36, 1)` |
| `harness_pulse` | 2400 | 0 | `ease` |
| `gradient_spin` | 750 | 0 | `ease` |

Named curves are also public (`ease_out_expo`, `ease_out`, `ease`,
`ease_out_quint`, `ease_resort`, `ease_in_out`, `ease_tailwind`).

Use `spec.transition()` with `motion.number`, a custom `Motion.transition`,
or layout motion. This supplies duration/curve only; `spec.animate(initial,
target)` also supplies delay. `spec.progress(raw)` evaluates the complete
normalized timeline, including the hold, and clamps roundoff to `[0,1]`.
`spec.withDelay(ms)` changes the hold; `spec.scaled(factor)` explicitly slows
or speeds a timeline for measurement, without reading environment variables.

```zig
const width = m.number(c, "sidebar-width", if (open) 256 else 0,
    catalog.resize.transition());
```

## Entrances and hover

`fadeIn`, `settleDown`, `fadeQuick`, `menuIn`, `dialogIn`, and `splashOut`
return a `motion.Frame` for the next box. Translations are paint-layer
changes: siblings do not reflow. Menu/dialog helpers preserve GPUI's actual
fade/translation approximation, rather than adding a new scale effect.

`menuOut(c, progress)` takes caller-owned eased closing progress. Evaluate
`catalog.menu_out.progress(@floatCast(elapsed / catalog.menu_out.total()))`
from the closing instant; remounting cannot restart the exit timeline.
Remove the element once closing completes.

`hoverT(c, key, hovered)` returns reversible hover progress; `hoverBlend`
uses that progress for premultiplied-alpha sRGB color interpolation. A key
unread for a complete frame is treated as unmounted. `revealT` uses the
slower reveal timing and retains state across cached paints; `resetReveal`
explicitly removes that key. Keep keys in the same parent scope.

## Loaders and reduced motion

```zig
// Call only while a loader is mounted. Supply the app's window focus.
const phase = m.pulseDelta(c, catalog.gradient_spin,
    .{ .active = window_active, .slow = false });
const opacity = m.effects.gspinOpacity(phase, m.effects.gspin_dim);
```

`pulseDelta` is raw phase: apply `effects.pulseWave`, `pulseOpacity`,
`pulseScale`, `staggeredPhase`, `matrixWave`, or `gspinOpacity` per cell.
The Context clock keeps cells phase-locked. For a shared epoch across
windows use `phaseAt(spec, elapsed)` plus `pulseLease(c, options)`.

Loader requests are bounded to one frame per 33ms (66ms with `.slow=true`),
three times slower in the background. They use `Context.frameIn`, not a
full-refresh animation. Unmounting stops requests on the next frame;
reduced motion returns phase zero and schedules nothing. Entrances snap
to their end state, including when reduced motion changes mid-flight.

`effects.resolve(preference, system, pause_in_background, active)` combines
`.system`, `.on`, or `.off` with accessibility and focus. Apps own those
inputs and persistence; assign the result to `c.reduced_motion` in the view
when applying an app override.

`effects.resizeDragSample` clamps a resize and starts one bounce per edge
contact. Store every returned `edge` (including null, which releases the
latch). `resizeBounceOffset(edge, normalized_elapsed)` supplies the signed
5px, 220ms two-phase response. Reduced motion suppresses new bounces.

# Fluid ruler — native nanoui

A reference-inspired, original implementation of a draggable ruler. This is
not a webview: the interactive app and offscreen replay share `view.zig`,
`ui.RulerPicker`, native text, box clipping, SVG neck and the native renderer.
The reference is https://x.com/withAnimationUI/status/2118682546951360730 .
No source code or visual assets from the post are included.

## Run

Requires this repository's Zig 0.17.0 toolchain and normal nanoui dependencies.

```sh
zig build ruler           # build only this example
zig build run-ruler
zig build test
zig build lines
```

Drag anywhere in the square. Drag left to increase, right to decrease. On
release the bounded velocity projects to a nearby integer, then nanoui's
existing exact spring solver coasts/snaps into place. Grabbing it again
preserves its current position. Tap to select the tick under the pointer.
Left/right keys and accessibility increment/decrement step the focused ruler.
Reduced motion jumps to the snap and omits numeral animation.

Keep a `ui.RulerPicker` in app state, give repeated controls stable `ui.key`s,
and call `picker.draw(c, .{ .width = 480, .min = 0, .max = 99 })`. It returns
whether the selected integer changed this build; read `picker.value()`.
Call `picker.select(n)` to spring to an integer target. Bounds are nonnegative
integers up to 9999, sanitized if supplied in reverse order. Width is clamped
to 160–1920 logical points. Input movement is in points, not device pixels.

## Reproducible motion evidence

No real screen, mouse or keyboard is touched. `ui.Tester` sends pointer
press/move/release input to the **same control and view**, and nanoui's CPU
rasterizer writes pixels. ffmpeg only encodes those pixels, not an imitation.

```sh
zig build ruler-replay -Doptimize=ReleaseFast
mkdir -p /tmp/ruler
zig-out/bin/ruler-replay --stills=/tmp/ruler
set -o pipefail
zig-out/bin/ruler-replay | ffmpeg -f rawvideo -pix_fmt bgra -s 960x960 \
  -r 60 -i - -an -c:v libx264 -crf 18 -pix_fmt yuv420p /tmp/ruler/demo.mp4
```

Eight seconds at 60 *simulated samples per second*. This is a scripted
native render, **not a real-time capture or a measured 60 FPS result**.
The script drags, releases, interrupts the in-flight spring and reverses,
then rests. Tests cover direction, bounds, release, interrupted spring,
30/60/120 Hz settling, invalid input, tap, capture, reduced motion and idle.

## Fidelity and limitations

The off-white square, fixed black pill/stem, curved neck, soft shadow,
bottom-aligned gray marks, stationary tapered envelope and zero-padded
clipped vertically rolling numerals follow the reference's stills. The
original physics is unknown: bounded velocity projection and an exact
critically-near-damped spring are our interpretation, not a claim about
SwiftUI internals. The envelope is a Gaussian chosen to approximate the
reference stills, not a recovered original formula. Numeral roll is a continuous spring coordinate, so
reversals don't restart a transition or pop a discarded old string.

Linux uses the installed font; `rounded = true` is SF Rounded only on Apple
systems. Thus glyph design differs on Linux. Pointer artwork from the post
is deliberately not copied. Shadow falloff is nanoui's native implementation.
This work makes no display FPS, latency or GPU-throughput claims.


## Pixel clipping audit

`zig-out/bin/ruler-replay --audit-clip --stills=/tmp/ruler` replays all 480
frames. Each frame is rendered normally and again with numeral glyph alpha
zeroed. The instances are restored before any screenshot/video output.
Every differing pixel must lie in the native inset [400,233] to [560,329] (max edges exclusive) at
960 square and over solid black, not the shadow or off-white background.
The audit also requires changed pixels on BOTH the top/bottom clip rows,
so an invisible or removed roll cannot pass. `tests_ruler.zig` separately
sweeps outgoing/incoming phases in both directions and includes a negative
control: removing glyph clipping must produce detectable overflow.
This diagnoses actual native pixels; lossy video frames are not pixel
identical to their renderer inputs. No renderer or animation changes were
needed for the reported clipping concern: the original clip held.

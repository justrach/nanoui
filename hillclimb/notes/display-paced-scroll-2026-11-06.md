# Borrow nodes while painting scrolling views

Base: `origin/main` at `e26765e`, branch `perf/display-paced-scroll`.

## Bounded change

`paintNode` copied the entire `Node`, including its style and content, on
all recursive visits. A long clipped column still visits its offscreen
rows: their children can overflow or escape clipping through layers.
Borrow the immutable node instead. The tree is not rebuilt, resized or
mutated during paint; text/image/atlas, hit, instance and motion storage
are separate. No new cache, invalidation rules or subtree culling needed.

This leaves layout, paint order, clipping, selection, hit testing and
scroll ownership unchanged. A regression test repaints a scrolled tree
with text, grouped opacity, scaling and a deferred fixed overlay, checking
that nodes remain unchanged and instances are identical. Existing tests
also cover rendering, scrolling, layers, transforms and overscroll.

No event accumulation, delta handling, direction changes, momentum,
overscroll, nested/overlay routing, reduced-motion or deadline behavior
is changed. The existing `CAMetalDisplayLink` already requests the
screen maximum (including 120 Hz on capable displays); there is no timer
or new idle work. PR #96's axis ownership change is independent.

## Measurement

Zig 0.17.0, hillclimb's default release-fast optimization, native macOS
Metal renderer, 900 × 640 at 2×. No windows or real-screen input.

Identical command before and after (only the label changed):

```sh
cd hillclimb
zig build run -- --scene scroll,list,text --only nanoui \
  --frames 600 --repeat 5 --label display-scroll-baseline
```

Each scene has 30 warm-up frames and five 600-frame trials; hillclimb
retains the trial with the lowest frame median, not a pooled distribution.
Raw results are the `display-scroll-baseline` and
`display-scroll-borrow-nodes` entries in `hillclimb/history.jsonl`.
Historical runs on other revisions are not the baseline.

| Scene | Before p50 / p95, ms | After p50 / p95, ms | p50 / p95 change |
| --- | --- | --- | --- |
| scroll | 0.501625 / 0.552792 | 0.436542 / 0.484417 | −13.0% / −12.4% |
| list | 0.074375 / 0.098917 | 0.076333 / 0.102792 | +2.6% / +3.9% |
| text | 0.139583 / 0.162750 | 0.129625 / 0.154208 | −7.1% / −5.2% |

Scroll's paint median falls from 0.143542 to 0.078250 ms (−45.5%);
list's from 0.023292 to 0.019958 ms (−14.3%); text's from 0.069750
to 0.058333 ms (−16.4%). Scroll build/layout are essentially unchanged.
List's whole-frame change is within the benchmark's ±5% noise threshold:
this is not evidence of a virtualized-list throughput win. Draw counts
match exactly: scroll 574, list 597, text 1201. GPU timings are unchanged
within noise. Only this one measured optimization is retained.

Headless throughput measures frame CPU work, not display presentation.
It does not establish measured 120 fps, display latency or real gesture
smoothness. The benchmark advances deterministic content at a nominal
120 Hz but runs unpaced into an offscreen target.

## Verification

- `zig build test -j1`: passed, including the new repaint regression.
- `zig build test -Dportable=true -j1`: passed.
- `zig build lines -j1`: passed.
- `zig build -j1`: passed (all native examples).
- `zig build -j1 -Dtarget=aarch64-linux-gnu --prefix zig-out/linux`: passed.
- `zig build test-bin -j1 -Dtarget=aarch64-linux-gnu --prefix zig-out/linux`:
  passed (Linux tests cross-compiled).
- `zig build -j1 -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast
  --prefix zig-out/windows`: passed. ReleaseFast keeps this x86 build on LLVM.
- `zig build $(sh tools/ios/zig-lib.sh) -j1
  -Dtarget=aarch64-ios-simulator --prefix zig-out/ios-check`: passed.
- `zig build -j1 -Dtarget=aarch64-linux-android`: passed (134/134 steps),
  with command-local `JAVA_HOME` pointing to Android Studio's bundled JBR.
  The first attempt compiled native libraries but failed APK signing because
  Java was not on the default environment. No system settings changed.
- Linux container runtime tests: blocked. Docker is installed, but its only
  context points to an unavailable daemon (`/var/run/docker.sock` absent).
  No Docker desktop app was launched or environment provisioned.

## Independent confirmation

After the builds, reran the original baseline and changed cached binaries
sequentially, with the identical scene/frame/repeat arguments and no
compilation during measurement. Raw labels:
`display-scroll-baseline-confirm`, `display-scroll-borrow-confirm`.

| Scene | Before p50 / p95, ms | After p50 / p95, ms |
| --- | --- | --- |
| scroll | 0.506667 / 0.571542 | 0.438125 / 0.490250 |
| list | 0.075625 / 0.112333 | 0.074917 / 0.101500 |
| text | 0.140167 / 0.164000 | 0.128042 / 0.161792 |

Scroll's frame median/p95 improve 13.5%/14.2%, and its paint median
improves 46.2% (0.144417 to 0.077625 ms). Text's median improves 8.6%,
but its p95 difference is within noise. List's median is unchanged within
noise; its tail varies between pairs. Draw counts again match exactly.
The retained claim is lower scroll paint/frame CPU cost, not guaranteed
display frame rate, a list speedup, or improved tails in every workload.

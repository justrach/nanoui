# Linux performance hill-climb

Headless measurements of nanoui on Linux against itself and other GUI
frameworks. The JSON source of truth is `bench/frameworks.json`.

Host: Ubuntu 24.04, x86_64, **no discrete GPU**. nanoui draws with
`src/ui/raster.zig` through `ui.Tester` (offscreen, 900×640 at 2×).
rustc **1.99.1** (rustup stable). Mesa **lavapipe** (llvmpipe LLVM 20.1.2)
is the Vulkan ICD under `xvfb-run`.

## Method

Scenes: `boxes` (600 moving shadowed rects), `text`, `scroll`, `list`,
`dashboard`, `springs` (2 000 `ui.motion` boxes), `letters`. 30 frames of
warm-up, 20 measured. A change is kept only if a scene improves by more
than 3% and nothing important regresses by more than that.

GPUI 0.2.2 is built with its Linux X11 + Blade backend. A window opens
on Xvfb and `Window::draw` is timed (layout, prepaint, paint, scene).
Blade **present hung** on lavapipe's vsync path, so GPU present is not in
the GPUI times. `TestAppContext` (present discarded) is recorded too and
matches the X11 draw times.

## Results (after climb, with GPUI)

Frame CPU is build + layout + paint (nanoui `Tester.frame` / GPUI
`Window::draw`). Encode is nanoui's CPU raster into pixels.

| scene | nanoui frame | nanoui encode | GPUI frame (X11/Blade) | egui | iced tree | slint | clay |
|---|---:|---:|---:|---:|---:|---:|---:|
| boxes | 0.074 ms | 24.0 ms | 1.444 ms | 0.107 | 0.072* | ≤1.05† | 0.064 |
| text | 0.205 ms | 2.1 ms | 2.285 ms | 0.315 | 0.033* | 17.4 | — |
| scroll | 0.510 ms | 2.0 ms | 14.601 ms | 1.431 | 0.377* | ≤1.14† | — |
| list | 0.057 ms | 2.0 ms | 0.380 ms | — | — | — | — |
| dashboard | 0.044 ms | 12.8 ms | 0.340 ms | — | — | — | — |
| springs | 0.571 ms | 4.7 ms | 5.562 ms | 0.334‡ | 0.281*‡ | ≤1.04†‡ | — |
| letters | 0.081 ms | 0.71 ms | 1.474 ms | — | — | — | — |

\* iced times are widget-tree build only (no layout/present hook).
† Slint 1 ms timer floor except text.
‡ egui/iced/slint "springs" are `sin()` offsets. GPUI and nanoui solve
the same closed-form spring (k=240, c=26, m=1).

nanoui **leads GPUI on every scene's frame CPU** (about 10–30× on
boxes/text/scroll/springs). It leads egui on boxes, text and scroll.
Clay is still slightly ahead on boxes layout (0.064 vs 0.074) and draws
nothing.

The Linux gap vs a live GPUI window is **encode**, not the view tick:
Gaussian shadows on boxes/dashboard are 13–24 ms on the CPU. GPUI's
Blade present was not timed here (hung on lavapipe). A 60 Hz CPU window
would drop on those two scenes; the OpenGL path is the intended live
path when a GPU exists.

`--cheap-shadow` (1 Y-sample instead of Metal's 4) cuts boxes encode
24.0 → 13.5 ms (−44%) and dashboard 12.8 → 7.4 ms (−42%). It does
**not** match the Metal raster tests; default stays Metal's (4 then, 8 now).

ReleaseFast binary: gallery 8.1 MB, counter 6.9 MB. Idle CPU is 0
(nothing polls).

## Steps

### 0. Baseline

Motion API expansion and `scroll_max` on every scroller. First Linux
numbers: springs frame 0.807 ms (build 0.682), boxes encode 26 ms.

### 1. `ui.keyInt` (kept, springs −9.3%)

Integer keys for the 2 000-box scene. No formatted strings per box per
frame.

### 2. Reuse `ui.Canvas` (kept)

Hill-climb's CPU path now draws into a retained buffer, as a Linux
window does. letters encode −65%, dashboard encode −46%, text encode
−47%. boxes still redraws the whole framebuffer (every shadow moves).

### 3. `Channel.sample` at t ≤ 0 (kept, springs −11.5%)

`retarget` samples the old motion, then samples again at t = 0. The
second sample skipped the spring matrix.

### 4. `Spring.matrix` last-value cache (kept, springs −11.9%)

Channels of the same spring share a clock. The last closed-form
solution is reused when stiffness, damping, mass and t match.

Springs frame CPU: **0.807 → 0.571 ms (−29%)**.

### 5. GPUI / iced / Slint (rustc 1.99.1)

GPUI 0.2.2 builds. X11 window opens under Xvfb with the lavapipe ICD.
`Window::draw` is 1.4–14.6 ms depending on the scene. Blade present
never returned on lavapipe, so those times are scene build only.

iced 0.13 and Slint 1.18 also build. iced exposes no per-draw hook
(tree-only times). Slint's software renderer runs; a 1 ms timer floors
most scenes.

### 6. Cheap CPU shadow (flag, kept)

`ui.raster.shapes.shadow_samples` defaults to Metal's count (4 then, 8 now).
`hillclimb --cheap-shadow` sets 1. boxes encode **24.0 → 13.5 ms**.
A 4-sample SIMD / interior-skip try did not beat 24 ms without
breaking raster equality, so it was not kept on the default path.

## Skips

Dioxus, Flutter, Qt Quick, GTK4 widgets, Tauri, Electron, mygo: reasons
in `bench/frameworks.json` `skips`. GPUI, iced and Slint are no longer
skipped.

## Where nanoui still trails

- **vs GPUI present:** not measured. Expected live-path gap is nanoui's
  CPU Gaussian shadows (13–24 ms encode) vs GPUI's Blade GPU. Frame CPU
  already leads.
- **vs egui springs:** egui is not solving springs.
- **vs Clay boxes:** Clay emits 600 flat commands and no shadows.
- **vs Slint text:** Slint's 17 ms includes software present of a 300-
  cell text grid; nanoui frame is 0.2 ms and encode 2.1 ms.
- **CPU shadows:** default 4-sample encode still ~24 ms on boxes. A GPU
  (OpenGL/llvmpipe window) or `--cheap-shadow` is the remaining climb.

# nanoui Benchmarks

Baseline: **[`v0.14.7`](https://github.com/justrach/nanoui/releases/tag/v0.14.7)** (2026-11-19).
See [Roadmap](roadmap.md) for upcoming performance work, [hillclimb/README.md](../hillclimb/README.md) for scene definitions, and [docs/linux-perf.md](linux-perf.md) for Linux x86_64 framework comparisons against GPUI, egui, iced, Slint, and Clay.

## Method

All `v0.14.7` runs below use `hillclimb` in `ReleaseFast`, rendering **30 warm-up frames followed by 300 measured frames**, keeping the best of 3 runs per scene, headless and offscreen (no window opens).

- **frame CPU:** `build + layout + paint` per frame in milliseconds (median and p95).
- **encode CPU:** CPU time uploading instances and encoding Metal command buffers (or CPU rasterizing on the portable backend).
- **GPU:** Metal command buffer GPU execution time (`GPUEndTime - GPUStartTime`).
- **draw items:** GPU instances emitted for the frame.

---

## macOS (Apple M3 Ultra)

Host: Apple M3 Ultra, macOS 26, `900×640` points at `2×` (`1800×1280` px).

### Metal + CoreText

```sh
cd hillclimb
zig build run -- --only nanoui --no-history
```

| scene | frame CPU (median) | frame CPU (p95) | build / layout / paint | encode CPU | GPU | draw items |
|---|---:|---:|---:|---:|---:|---:|
| boxes | 0.103 ms | 0.126 ms | 0.047 / 0.018 / 0.028 ms | 0.028 ms | 0.238 ms | 1,201 |
| text | 0.187 ms | 0.220 ms | 0.031 / 0.061 / 0.086 ms | 0.027 ms | 0.049 ms | 1,201 |
| scroll | 0.665 ms | 0.717 ms | 0.187 / 0.311 / 0.145 ms | 0.029 ms | 0.039 ms | 1,221 |
| list | 0.096 ms | 0.111 ms | 0.008 / 0.053 / 0.034 ms | 0.020 ms | 0.039 ms | 813 |
| dashboard | 0.029 ms | 0.048 ms | 0.005 / 0.007 / 0.015 ms | 0.015 ms | 0.152 ms | 325 |
| springs | 0.647 ms | 0.813 ms | 0.494 / 0.058 / 0.093 ms | 0.035 ms | 0.120 ms | 2,001 |
| letters | 0.117 ms | 0.143 ms | 0.056 / 0.036 / 0.026 ms | 0.020 ms | 0.028 ms | 46 |

### Portable CPU Rasterizer (`-Dportable=true`)

Measures `src/ui/raster.zig` + `src/ui/text_tt.zig` on the same Apple M3 Ultra host (`900×640 @ 2×`). Note that `boxes` and `dashboard` run full 8-sample-Y Gaussian shadows on CPU threads (`encode CPU` ~19–20 ms), whereas GPU paths stay under 0.25 ms.

```sh
cd hillclimb
zig build -Dportable=true --prefix zig-out/cpu
./zig-out/cpu/bin/hillclimb --only nanoui --no-history
```

| scene | frame CPU (median) | frame CPU (p95) | encode CPU (raster) | process CPU / frame | draw items |
|---|---:|---:|---:|---:|---:|
| boxes | 0.107 ms | 0.118 ms | 19.142 ms | 241.160 ms | 1,201 |
| text | 0.159 ms | 0.184 ms | 1.134 ms | 7.686 ms | 1,201 |
| scroll | 0.574 ms | 0.627 ms | 0.831 ms | 10.855 ms | 1,221 |
| list | 0.050 ms | 0.056 ms | 0.783 ms | 9.909 ms | 813 |
| dashboard | 0.040 ms | 0.053 ms | 20.413 ms | 111.099 ms | 325 |
| springs | 0.639 ms | 0.855 ms | 1.720 ms | 23.655 ms | 2,001 |
| letters | 0.093 ms | 0.123 ms | 0.478 ms | 0.558 ms | 46 |

---

## iOS (iPhone 18 Pro Simulator, iOS 27.2)

Measured headlessly via `xcrun simctl spawn` on an `iPhone 18 Pro` simulator (`iOS 27.2`) using nanoui's Metal + CoreText backend (running on the Apple M3 Ultra host GPU).

```sh
cd hillclimb
zig build $(sh ../tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator --prefix zig-out/ios-sim
codesign --force --sign - --timestamp=none zig-out/ios-sim/bin/hillclimb
xcrun simctl spawn booted "$PWD/zig-out/ios-sim/bin/hillclimb" --only nanoui --no-history --width 393 --height 852 --scale 3
```

### iPhone Portrait (`393×852 @ 3×`, `1179×2556` px)

| scene | frame CPU (median) | frame CPU (p95) | build / layout / paint | encode CPU | GPU | draw items |
|---|---:|---:|---:|---:|---:|---:|
| boxes | 0.215 ms | 0.499 ms | 0.078 / 0.044 / 0.072 ms | 0.079 ms | 0.062 ms | 1,201 |
| text | 0.188 ms | 0.478 ms | 0.022 / 0.065 / 0.092 ms | 0.037 ms | 0.075 ms | 1,201 |
| scroll | 0.653 ms | 1.051 ms | 0.158 / 0.312 / 0.155 ms | 0.038 ms | 0.087 ms | 1,390 |
| list | 0.283 ms | 0.444 ms | 0.019 / 0.159 / 0.107 ms | 0.064 ms | 0.085 ms | 1,020 |
| dashboard | 0.075 ms | 0.159 ms | 0.009 / 0.017 / 0.043 ms | 0.066 ms | 0.101 ms | 325 |
| springs | 1.489 ms | 1.939 ms | 1.037 / 0.155 / 0.280 ms | 0.109 ms | 0.084 ms | 2,001 |
| letters | 0.143 ms | 0.294 ms | 0.060 / 0.040 / 0.036 ms | 0.044 ms | 0.091 ms | 46 |

### Desktop Parity Viewport (`900×640 @ 2×`, `1800×1280` px)

| scene | frame CPU (median) | frame CPU (p95) | encode CPU | GPU | draw items |
|---|---:|---:|---:|---:|---:|
| boxes | 0.091 ms | 0.456 ms | 0.052 ms | 0.087 ms | 1,201 |
| text | 0.237 ms | 0.567 ms | 0.055 ms | 0.061 ms | 1,201 |
| scroll | 1.542 ms | 1.976 ms | 0.086 ms | 0.095 ms | 1,221 |
| list | 0.295 ms | 0.569 ms | 0.078 ms | 0.105 ms | 813 |
| dashboard | 0.031 ms | 0.086 ms | 0.025 ms | 0.041 ms | 325 |
| springs | 0.806 ms | 2.028 ms | 0.071 ms | 0.092 ms | 2,001 |
| letters | 0.133 ms | 0.294 ms | 0.034 ms | 0.060 ms | 46 |

---

## iPadOS (iPad Pro 13-inch M5 Simulator, iPadOS 27.2)

Measured headlessly via `xcrun simctl spawn` on an `iPad Pro 13-inch (M5)` simulator (`iOS 27.2` runtime) using Metal + CoreText.

### iPad Pro 13" Landscape (`1366×1024 @ 2×`, `2732×2048` px)

| scene | frame CPU (median) | frame CPU (p95) | build / layout / paint | encode CPU | GPU | draw items |
|---|---:|---:|---:|---:|---:|---:|
| boxes | 0.096 ms | 0.248 ms | 0.034 / 0.022 / 0.030 ms | 0.058 ms | 0.080 ms | 1,201 |
| text | 0.296 ms | 0.543 ms | 0.025 / 0.103 / 0.107 ms | 0.064 ms | 0.110 ms | 1,201 |
| scroll | 0.803 ms | 2.039 ms | 0.179 / 0.387 / 0.173 ms | 0.071 ms | 0.117 ms | 1,540 |
| list | 0.209 ms | 0.408 ms | 0.012 / 0.125 / 0.062 ms | 0.063 ms | 0.108 ms | 1,176 |
| dashboard | 0.041 ms | 0.145 ms | 0.006 / 0.011 / 0.021 ms | 0.054 ms | 0.121 ms | 325 |
| springs | 0.802 ms | 1.000 ms | 0.604 / 0.066 / 0.132 ms | 0.075 ms | 0.121 ms | 2,001 |
| letters | 0.140 ms | 0.274 ms | 0.058 / 0.041 / 0.037 ms | 0.052 ms | 0.110 ms | 46 |

### Desktop Parity Viewport (`900×640 @ 2×`, `1800×1280` px)

| scene | frame CPU (median) | frame CPU (p95) | encode CPU | GPU | draw items |
|---|---:|---:|---:|---:|---:|
| boxes | 0.095 ms | 0.135 ms | 0.058 ms | 0.072 ms | 1,201 |
| text | 0.209 ms | 0.381 ms | 0.057 ms | 0.068 ms | 1,201 |
| scroll | 0.705 ms | 0.997 ms | 0.061 ms | 0.079 ms | 1,221 |
| list | 0.136 ms | 0.236 ms | 0.046 ms | 0.049 ms | 813 |
| dashboard | 0.038 ms | 0.085 ms | 0.042 ms | 0.050 ms | 325 |
| springs | 0.732 ms | 1.343 ms | 0.063 ms | 0.109 ms | 2,001 |
| letters | 0.135 ms | 0.297 ms | 0.044 ms | 0.056 ms | 46 |

---

## Android

Live Android device/emulator hardware benchmarks are not yet captured on this host (no Android SDK/NDK installed locally). On a connected device or headless emulator (`sh tools/android/emulator.sh`), run:

```sh
cd hillclimb
zig build -Dtarget=aarch64-linux-android --prefix zig-out/android
adb push zig-out/android/bin/hillclimb /data/local/tmp/
adb shell /data/local/tmp/hillclimb --only nanoui --no-history --width 412 --height 915 --scale 3
```

### Android Phone Viewport Reference (Host M3 Ultra, Portable CPU Rasterizer)

Measured using Android's text and CPU renderer (`src/ui/text_tt.zig` + `src/ui/raster.zig`) at a typical Android phone viewport (`412×915 @ 3×`, `1236×2745` px) on the Apple M3 Ultra host as a non-GPU reference:

| scene | frame CPU (median) | frame CPU (p95) | encode CPU (raster) | draw items |
|---|---:|---:|---:|---:|
| boxes | 0.111 ms | 0.126 ms | 19.491 ms | 1,201 |
| text | 0.163 ms | 0.197 ms | 1.081 ms | 1,201 |
| scroll | 0.592 ms | 0.665 ms | 1.164 ms | 1,440 |
| list | 0.062 ms | 0.081 ms | 1.138 ms | 1,072 |
| dashboard | 0.037 ms | 0.055 ms | 19.750 ms | 325 |
| springs | 0.666 ms | 0.832 ms | 1.909 ms | 2,001 |
| letters | 0.099 ms | 0.126 ms | 0.928 ms | 46 |

Live Android devices with a GPU draw through OpenGL ES 3 (`src/android/egl.zig` + `src/ui/opengl.zig`), avoiding the CPU Gaussian shadow cost on `boxes` and `dashboard`.

---

## Linux (x86_64, CPU Raster & Startup)

See [docs/linux-perf.md](linux-perf.md) and `bench/frameworks.json` for full Linux x86_64 CPU-raster measurements (Ubuntu 24.04, `900×640 @ 2×`) and framework comparisons: nanoui leads GPUI 0.2.2 across every scene's frame CPU (`0.074` vs `1.444 ms` on `boxes`, `0.205` vs `2.285 ms` on `text`, `0.510` vs `14.601 ms` on `scroll`, `0.571` vs `5.562 ms` on `springs`) and outperforms egui on `boxes`, `text`, and `scroll`.

### Linux Startup Latency & Idle PSS (Xvfb, no-GPU, `ReleaseFast`)

Measured on GitHub Actions `ubuntu-24.04` (Xvfb + Mesa llvmpipe, no hardware GPU) with `examples/counter` (`10.34 MiB`, `runs=9`, `tools/linux-startup-bench.py`), guided by Lean 4 theorems in [`lean-proofs/NanoUI/LinuxStartup.lean`](../lean-proofs/NanoUI/LinuxStartup.lean):

| scenario | median first-frame | range | idle PSS | idle CPU | trace |
|---|---:|---:|---:|---:|---|
| default (no-GPU warm) | 93.0 ms | 90.5–94.8 ms | 74.9 MiB | 0.0 ms | `nanoui: first-frame (CPU)` |
| default (no-GPU cold cache) | 112.1 ms | 111.8–115.7 ms | 85.4 MiB | 0.0 ms | `nanoui: first-frame (CPU)` |
| default (headless bus, no portal) | 82.9 ms | 82.1–88.0 ms | —¹ | 0.0 ms | `nanoui: first-frame (CPU)` |
| forced software GL (`NANOUI_RENDERER=gl`, warm) | 210.8 ms | 208.4–212.4 ms | 116.1 MiB | 20.0 ms | `nanoui: first-frame (OpenGL ES)` |
| forced software GL (`NANOUI_RENDERER=gl`, cold cache) | 936.9 ms | 929.8–940.4 ms | 180.6 MiB | 90.0 ms | `nanoui: first-frame (OpenGL ES)` |

¹ Run `44668614282` sampled the `dbus-run-session` wrapper PID (`0.3 MiB`) in that scenario; `tools/linux-startup-bench.py` now resolves the child `counter` PID for future runs.

Versus forced software GL under Xvfb/llvmpipe: **-56%** warm first-frame (`93.0 ms` vs `210.8 ms`), **-88%** (`8.4×` faster) cold-cache first-frame (`112.1 ms` vs `936.9 ms`), **-35%** to **-53%** idle PSS (`74.9–85.4 MiB` vs `116.1–180.6 MiB`), and **0.0 ms** idle CPU.

---

## Binary Sizes (`v0.14.7`)

Unstripped binary sizes measured with Zig 0.17.0 on `v0.14.7` (plus documented Android APK baseline from [docs/android.md](android.md)):

| target | mode | `counter` | `gallery` | `hello` |
|---|---|---:|---:|---:|
| macOS (`aarch64-macos`) | `ReleaseFast` | 1.75 MB (1,753,400 B) | 2.69 MB (2,687,816 B) | 1.78 MB (1,780,616 B) |
| macOS (`aarch64-macos`) | `ReleaseSmall` | 934 KB (933,752 B) | 1.51 MB (1,512,552 B) | 952 KB (952,056 B) |
| iOS Sim (`aarch64-ios-simulator`) | `ReleaseSmall` | 661 KB (660,720 B) | 874 KB (874,496 B) | 661 KB (660,736 B) |
| Android (`aarch64-linux-android`, [docs/android.md](android.md)) | `ReleaseSmall` | — | ~730 KB APK | — |

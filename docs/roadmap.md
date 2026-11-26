# nanoui Roadmap

Baseline: **[`v0.14.12`](https://github.com/justrach/nanoui/releases/tag/v0.14.12)** (2026-11-25).
See [Benchmarks](benchmarks.md) for current macOS, iOS, iPadOS, CPU-raster, and Linux numbers, [CLI Reference](cli.md) for `nui` workflows, [docs/ios.md](ios.md) for iOS/iPadOS bundling, and [docs/android.md](android.md) for Android details.

---

## Shipped Recently

### `v0.14.12` (2026-11-25)

- **Accessibility listbox & option roles ([#246](https://github.com/justrach/nanoui/pull/246)):** Added `Role.listbox`, `Role.option`, `Describe.controls` / `Element.controls`, `position`, and `set_size` (`src/ui/access.zig`) with macOS NSAccessibility (`src/ui/a11y.zig`) and iOS VoiceOver (`src/ios/access.zig`) mappings so pickers and command palettes expose active descendants cleanly.
- **Web Canvas 2D fallback & recovery ([#240](https://github.com/justrach/nanoui/pull/240)):** Added opt-in startup and live device-loss failover from WebGPU to CPU-rasterized Canvas 2D (`src/web/host.js`, `src/web/web.zig`), capping `cpuMaxScale`, presenting RGBA directly via `ImageData`, cancelling in-progress input on device loss, and fixing `uncapturederror` listener cleanup.
- **Cross-platform HDR, WebKitGTK privacy, iPadOS scene & iOS EDR fixes ([#255](https://github.com/justrach/nanoui/pull/255)):**
  - **Windows HDR retry gating (`src/windows/surface_gpu.zig`, `src/windows/surface_display.zig`):** Avoid retrying `setExtended(true)` every painted frame when an HDR-capable app runs on an SDR monitor; retry only on `setColour`, presenter creation, `WM_DISPLAYCHANGE`, or monitor changes.
  - **Linux WebKitGTK `PageOptions.private` & `allow_request` (`src/page_webkitgtk.zig`, `src/linux/webkit.zig`):** Isolate `private` pages in per-page ephemeral `WebKitNetworkSession` (6.0) or `WebKitWebsiteDataManager` + `WebKitWebContext` (4.x) instances, and filter every frame's navigations, redirects, and new-window actions fail-closed via `decide-policy` (`src/linux/tests_page.zig`).
  - **iPadOS scene-scoped alerts & `⌘W` (`src/ios/scenes.zig`, `src/ios/app.zig`, `src/ios/keys.zig`, `src/ios/touch.zig`, `src/ios/dialog.zig`):** Route dialogs and `⌘W` to the focused/active `UIWindowScene` instead of always targeting the first scene (`docs/ios.md`), and unblock waiting dialogs if their scene disconnects.
  - **iOS & iPadOS EDR surfaces (`src/ios/surface_display.zig`, `src/ios/surface.zig`):** Added `Surface.setColour(.extended_linear)`, `Surface.displayInfo()`, and `Surface.on_display_change` backed by `UIScreen` headroom and P3 gamut traits.

### `v0.14.11` (2026-11-24)

- **Windows D3D11/DXGI shader, text & color parity ([#253](https://github.com/justrach/nanoui/pull/253)):** Brought D3D11 shaders (`src/ui/shader.hlsl`, `src/ui/corner_sdf.hlsl`), text rasterization, multi-stop gradient binding (`src/windows/surface_gpu.zig`), and DXGI color-space configuration (`src/windows/d3d.zig`) to parity with Metal.
- **Windows task dialog message boxes ([#230](https://github.com/justrach/nanoui/issues/230), [#231](https://github.com/justrach/nanoui/pull/231)):** `src/windows/task_dialog.zig` renders message boxes via `comctl32` 6 activation context with custom button labels and checkboxes, modal to the active window (`src/windows/tests_task_dialog.zig`).
- **UTF-8 text editing bounds & headless picker ([#235](https://github.com/justrach/nanoui/pull/235), [#236](https://github.com/justrach/nanoui/pull/236)):** Text edit offsets clamp to UTF-8 scalar boundaries ([text-index-audit.md](text-index-audit.md)), and `kit.picker` (`src/kit/picker.zig`) extracts stable-id picker selection, IME composition guards, and keyboard intents used by Gallery's command palette.
- **Accessibility heading levels & list containers ([#250](https://github.com/justrach/nanoui/pull/250)):** Added `Describe.level` / `Element.level` (1–6) and `access.holdsElements` so `.list` containers keep rows and tabs as individual elements (`src/ui/access.zig`).
- **Web default browser shell & worker stability ([#233](https://github.com/justrach/nanoui/pull/233), [#238](https://github.com/justrach/nanoui/pull/238)):** Added default `src/web/app.html` (`tools/web/build.zig`) with opt-in `keyboard` forwarding in `src/web/host.js` and worker click-settle synchronization in `tools/web/browser.mjs`.
- **Fonts, iOS & Android fixes ([#234](https://github.com/justrach/nanoui/pull/234), [#245](https://github.com/justrach/nanoui/pull/245), [#247](https://github.com/justrach/nanoui/pull/247), [#252](https://github.com/justrach/nanoui/pull/252)):** Multi-face TTC font collection scanning + Android CJK fallback (`src/ui/tt/fontdb.zig`), iOS `App.soon` (`src/cf_soon.zig`) and remote document-picker attachment waits (`src/ios/dialog.zig`), Zig 0.17.1 iOS stdlib patch (`tools/ios/zig-lib.sh`), and opt-in app-supplied `NativeActivity` subclasses (`tools/android/apk.zig`).

### `v0.14.10` (2026-11-24)

- **Overlay occlusion (`Div.occlude()` / `Style.occlude`, [#244](https://github.com/justrach/nanoui/pull/244)):** Blocks pointer clicks, hover, scrollbar grabs, vertical/horizontal scroll pass-through, and paint-order text selection bleed-through behind overlays without hand-cursor side effects or implied accessibility buttons; adopted across `kit.dialog`, `kit.sheet`, `kit.popover`, and `kit.Toaster`.
- **`nui` CLI, templates, installers & release archives ([#244](https://github.com/justrach/nanoui/pull/244)):** Modularized `tools/nui/` (`start --template native|kit|page`, `--id`, short target aliases, `check --lines`, `doctor`, `snapshot --portable/--eval`), added `tools/install-nui.sh` and `tools/install-nui.ps1`, documented `docs/cli.md`, fixed `wasm32-wasi` downstream builds, and shipped 6-platform `nui` archives + `SHA256SUMS`.

### `v0.14.9` & `v0.14.8` (2026-11-20 – 2026-11-21)

- **WebGPU backend, security & platform polish ([#214](https://github.com/justrach/nanoui/pull/214) – [#229](https://github.com/justrach/nanoui/pull/229)):** `wasm32-wasi` WebGPU renderer & host (`src/web/`), fail-closed WebView2 `allow_request` filtering, `tools/check-security.sh`, Lean-verified Linux startup/memory optimization (`lean-proofs/NanoUI/LinuxStartup.lean`, async D-Bus portal), Dock restore (`#201`), `Page.loadRequest` / `defer_initial_load` (`#212`), and native webview `file_drop` (`#211`).

---

## Upcoming Milestones

### `v0.15.0` — Cross-Platform Parity & Stacked Follow-ups

- **Windows (`src/windows/`, `src/page_webview2*.zig`):** Add live WebView2 SDK smoke tests in Windows CI.
- **Linux (`src/ui/opengl.zig`):** Add OpenGL vs. CPU parity tests for negative circular `clip_round` and nested masked `scroll_edge_fade`, plus Wayland HDR/fractional-scale polish.
- **macOS (`src/page_webkit.zig`, `tools/nui/`):** Provide a `WKURLSchemeHandler` / `WKContentRuleList` request-filtering helper for `PageOptions.allow_request`, and integrate `.app` / `.dmg` bundling and notarization into `nui`.
- **Web stacked follow-ups (`src/web/`):** Land follow-up PRs once rebased and security-hardened: browser color-scheme (`#239`, pending rebase onto `#240`), DOM semantics/IME/clipboard (`#241` — resolving widget-tag reuse, module-level `composing` lock, and unfocused password fields), shared bounded `file_picker` (`#242` — resolving POSIX FIFO/growing-file/size-bound and JS `file.size` TOCTOU), Worker Canvas 2D recovery (`#243`), browser glyph fallback (`#249`), and ARIA mapping (`#251`).
- **Text & Fonts:** Grapheme-cluster editing (`#237`, pending `backspaceStart("", 1)` underflow and stray continuation fixes) and `CFF2` outlines for Android `NotoSansCJK` (`#248`, pending 32-bit overflow and IVS null-offset fixes).
- **Mobile parity (`src/ios/`, `src/android/`):** Close remaining share sheets/haptics, Android SAF (`#232` blocked on Java-free policy), TalkBack accessibility, and 120 Hz pacing items listed below.

### `v0.15.x – v0.16.0` — Engine Performance, Formal Proofs & Ecosystem

- **Retained / partial-frame UI:** Land `feat/retained-scroll` and partial tree/damage optimizations backed by [`lean-proofs/NanoUI/RetainedScroll.lean`](../lean-proofs/NanoUI/RetainedScroll.lean), reducing `scroll` and `springs` CPU build/layout cost at 120 Hz.
- **Staged `nanobrowser` landing:** Upstream `nanobrowser` CSS cascade/invalidation, HTML fast fragment parser, DOM Bloom filters, and ARM64 JIT optimizations onto `main` in reviewable PRs paired with Lean 4 theorems (`lean-proofs/NanoUI.lean`).
- **Expanded Lean 4 verification:** Model and prove invariants for Windows VBlank frame pacing (`src/ui/frame_pace.zig`) and CPU raster layer-depth isolation (`src/ui/raster_group.zig`).
- **`nanoui.kit`, Gallery & contributor workflow:** Expand `src/kit/` accessibility coverage and Gallery Studio demos; keep PR security & COM-vtable verification checks current.

---

## Platform Roadmaps

### macOS

- **Shipped:** AppKit windows/menus (including Dock restore `#201`), Metal + Liquid Glass, CoreText & UAX #29 selection, EDR surfaces (`Surface.setColour(.extended_linear)`, `DisplayInfo`, `Screen`), `Div.occlude()`, WKWebView typed IPC + `private` + `loadRequest` + `file_drop`, `NSAccessibility` (`.list` / `.listbox` / `.option` / `level`), `nanoui.Updater`, `nui` CLI + archives, and headless `--nanoui-*` test flags.
- **Next (`v0.15.0`):** `WKContentRuleList` / request-filtering bridge for `PageOptions.allow_request`, plus `.app` / `.dmg` bundling and notarization in `nui`.
- **Later (`v0.15.x+`):** Native `UNUserNotificationCenter` notifications, retained scroll / partial-frame rebuilds, staged `nanobrowser` engine landings.

### iOS & iPadOS

- **Shipped:** UIKit + Metal + CoreText + Liquid Glass, EDR surfaces (`Surface.setColour(.extended_linear)`, `DisplayInfo`, `on_display_change`), WKWebView (`private`), touch scroll/flings, pinch zoom, `UITextInput` IME, `App.soon` + remote document-picker attach wait (`#247`), Zig 0.17.1 stdlib workaround (`#234`), VoiceOver (including `.listbox` / `.option`) + Dynamic Type traits, `MapKit`, multi-window `UIScene` with scene-scoped alerts & `⌘W`, zero-Xcode `.app` / `.ipa` bundling (`tools/ios/bundle.zig`).
- **Next (`v0.15.0`):** `PHPickerViewController` / `UIActivityViewController` share sheets & haptics, `CAFrameRateRange` 120 Hz pacing, trackpad/mouse hover & Apple Pencil metadata.
- **Later (`v0.15.x+`):** Background texture purging on Jetsam pressure, `BGTaskScheduler` / notifications, inter-scene drag-and-drop, and `UIMenuBuilder` shortcuts.

### Android

- **Shipped:** `NativeActivity` backend + opt-in app subclass packaging (`#252`), OpenGL ES 3 + CPU raster, nanoui TrueType text with multi-face TTC & CJK fallback (`#245`), `EditText` IME, touch/fling/pinch/mouse input, safe areas/cutouts, `AlertDialog` messages, APK builder & signer (`tools/android/apk.zig`, API 29+).
- **Next (`v0.15.0`):** `CFF2` outlines for `NotoSansCJK` (`#248` after overflow fixes), `dialog.open` SAF support aligned with the no-nanoui-Java policy (or app-provided subclassing; see `#232`), embedded `android.webkit.WebView` + IPC, TalkBack (`AccessibilityNodeProvider`), on-device GLES3/CPU benchmarks.
- **Later (`v0.15.x+`):** Predictive Back animation (API 33+), `SurfaceTexture` / `AHardwareBuffer` interop for `ui.texture`, HDR swapchains.

### Linux, Windows & Web

- **Linux (`src/linux/`, `src/page_webkitgtk.zig`, `src/ui/opengl.zig`):** Shipped GTK 4/3 runtime loading, StatusNotifierItem + dbusmenu trays, OpenGL 3.3 + CPU raster, bubblewrap messaging, `Page.loadRequest`, `PageOptions.file_drop`, `PageOptions.private` (per-page ephemeral session/context), navigation `PageOptions.allow_request`, Lean-proved startup/memory optimization (`74.3 ms` warm / `68.4 ms` headless first-frame, `40.7–84.8 MiB` idle PSS). Next: OpenGL vs. CPU circular clip & nested fade parity tests, Wayland HDR/fractional-scale polish.
- **Windows (`src/windows/`, `src/ui/d3d11*.zig`, `src/page_webview2*.zig`):** Shipped D3D11 + shader caching, scRGB HDR swap chains + SDR retry gating, VBlank pacing + circular SDF parity, TaskDialog message boxes with custom labels & checkboxes (`#231`), WebView2 `private` / `allow_request` (fail-closed) / `loadRequest` / `file_drop`. Next: live WebView2 SDK CI tests.
- **Web (`src/web/`, `tools/web/`):** Shipped `wasm32-wasi` WebGPU renderer + Worker host (`#225`), Canvas 2D startup & device-loss failover (`#240`), default `app.html` shell with opt-in keyboard forwarding (`#238`), and `nui start --template page` / WASI build support (`#244`). Next: color-scheme following (`#239`), DOM semantics/ARIA/IME/clipboard (`#241`/`#251`), Worker Canvas 2D recovery (`#243`), shared `file_picker` (`#242`), and browser glyph fallback (`#249`).

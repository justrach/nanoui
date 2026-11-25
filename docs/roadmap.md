# nanoui Roadmap

Baseline: **[`v0.14.10`](https://github.com/justrach/nanoui/releases/tag/v0.14.10)** (2026-11-24), plus recent merges on `main`.
See [Benchmarks](benchmarks.md) for current macOS, iOS, iPadOS, CPU-raster, and Linux numbers, [CLI Reference](cli.md) for `nui` workflows, [docs/ios.md](ios.md) for iOS/iPadOS bundling, and [docs/android.md](android.md) for Android details.

---

## Shipped Recently

### On `main` (post-`v0.14.10`)

- **Windows task dialog message boxes ([#230](https://github.com/justrach/nanoui/issues/230), [#231](https://github.com/justrach/nanoui/pull/231)):** `src/windows/task_dialog.zig` renders message boxes via `comctl32` 6 activation context with custom button labels and checkboxes, modal to the active window (`src/windows/tests_task_dialog.zig`).
- **UTF-8 text editing bounds & headless picker ([#235](https://github.com/justrach/nanoui/pull/235), [#236](https://github.com/justrach/nanoui/pull/236)):** Text edit offsets clamp to UTF-8 scalar boundaries ([text-index-audit.md](text-index-audit.md)), and `kit.picker` (`src/kit/picker.zig`) extracts stable-id picker selection, IME composition guards, and keyboard intents used by Gallery's command palette.
- **Accessibility heading levels & list containers ([#250](https://github.com/justrach/nanoui/pull/250)):** Added `Describe.level` / `Element.level` (1–6) and `access.holdsElements` so `.list` containers keep rows and tabs as individual elements (`src/ui/access.zig`).
- **Web default browser shell & worker stability ([#233](https://github.com/justrach/nanoui/pull/233), [#238](https://github.com/justrach/nanoui/pull/238)):** Added default `src/web/app.html` (`tools/web/build.zig`) with opt-in `keyboard` forwarding in `src/web/host.js` and worker click-settle synchronization in `tools/web/browser.mjs`.
- **Fonts, iOS & Android fixes ([#234](https://github.com/justrach/nanoui/pull/234), [#245](https://github.com/justrach/nanoui/pull/245), [#247](https://github.com/justrach/nanoui/pull/247), [#252](https://github.com/justrach/nanoui/pull/252)):** Multi-face TTC font collection scanning + Android CJK fallback (`src/ui/tt/fontdb.zig`), iOS `App.soon` (`src/cf_soon.zig`) and remote document-picker attachment waits (`src/ios/dialog.zig`), Zig 0.17.1 iOS stdlib patch (`tools/ios/zig-lib.sh`), and opt-in app-supplied `NativeActivity` subclasses (`tools/android/apk.zig`).

### `v0.14.10` (2026-11-24)

- **Overlay occlusion (`Div.occlude()` / `Style.occlude`, [#244](https://github.com/justrach/nanoui/pull/244)):** Blocks pointer clicks, hover, scrollbar grabs, vertical/horizontal scroll pass-through, and paint-order text selection bleed-through behind overlays without hand-cursor side effects or implied accessibility buttons; adopted across `kit.dialog`, `kit.sheet`, `kit.popover`, and `kit.Toaster`.
- **`nui` CLI, templates, installers & release archives ([#244](https://github.com/justrach/nanoui/pull/244)):** Modularized `tools/nui/` (`start --template native|kit|page`, `--id`, short target aliases, `check --lines`, `doctor`, `snapshot --portable/--eval`), added `tools/install-nui.sh` and `tools/install-nui.ps1`, documented `docs/cli.md`, fixed `wasm32-wasi` downstream builds, and shipped 6-platform `nui` archives + `SHA256SUMS`.

### `v0.14.9` (2026-11-21)

- **WebGPU backend & security hardening ([#225](https://github.com/justrach/nanoui/pull/225), [#228](https://github.com/justrach/nanoui/pull/228), [#229](https://github.com/justrach/nanoui/pull/229)):** Added the `wasm32-wasi` WebGPU renderer and browser host (`src/web/`), fail-closed WebView2 `allow_request` resource filtering + tests, `tools/check-security.sh` CI/PR security gate, and gallery `--nanoui-*` CLI flag preservation.

### `v0.14.8` (2026-11-20)

- **Lean-verified Linux startup & memory, Dock reopen & WebView APIs ([#214](https://github.com/justrach/nanoui/pull/214), [#215](https://github.com/justrach/nanoui/pull/215), [#216](https://github.com/justrach/nanoui/pull/216), [#217](https://github.com/justrach/nanoui/pull/217)):** Added `lean-proofs/NanoUI/LinuxStartup.lean`, `src/linux/renderer.zig`, async D-Bus portal (`src/linux/appearance.zig`), Dock restore on minimized macOS windows (`#201`), `Page.loadRequest` / `PageOptions.defer_initial_load` (`#212`), and native webview `PageOptions.file_drop` (`#211`).

---

## Upcoming Milestones

### `v0.15.0` — Cross-Platform Parity & Stacked Follow-ups

- **Windows (`src/windows/`, `src/page_webview2*.zig`):** Avoid retrying `setExtended(true)` every painted frame when an HDR-capable app starts on an SDR monitor (`src/windows/surface_gpu.zig`; retry on `WM_DISPLAYCHANGE` / monitor move), and add live WebView2 SDK smoke tests in Windows CI.
- **Linux (`src/page_webkitgtk.zig`, `src/ui/opengl.zig`):** Implement `PageOptions.private` using an ephemeral `WebKitWebsiteDataManager` / network session and `PageOptions.allow_request` via WebKitGTK request filtering; add OpenGL vs. CPU parity tests for negative circular `clip_round` and nested masked `scroll_edge_fade`; Wayland HDR/fractional-scale polish.
- **macOS (`src/page_webkit.zig`, `tools/nui/`):** Provide a `WKURLSchemeHandler` / `WKContentRuleList` request-filtering helper for `PageOptions.allow_request`, and integrate `.app` / `.dmg` bundling and notarization into `nui`.
- **Web stacked follow-ups (`src/web/`):** Land follow-up PRs for browser color-scheme (`#239`), Canvas 2D fallback (`#240`), DOM semantics/IME/clipboard (`#241`), shared bounded `file_picker` (`#242`), Worker Canvas 2D recovery (`#243`), browser glyph fallback (`#249`), and ARIA mapping (`#251`).
- **Text, Fonts & Accessibility:** Grapheme-cluster editing (`#237`), `CFF2` outlines for Android `NotoSansCJK` (`#248`), and listbox/option accessibility roles (`#246`).
- **Mobile parity (`src/ios/`, `src/android/`):** Close remaining EDR, file-picker, TalkBack accessibility, and multi-window scene gaps listed below.

### `v0.15.x – v0.16.0` — Engine Performance, Formal Proofs & Ecosystem

- **Retained / partial-frame UI:** Land `feat/retained-scroll` and partial tree/damage optimizations backed by [`lean-proofs/NanoUI/RetainedScroll.lean`](../lean-proofs/NanoUI/RetainedScroll.lean), reducing `scroll` and `springs` CPU build/layout cost at 120 Hz.
- **Staged `nanobrowser` landing:** Upstream `nanobrowser` CSS cascade/invalidation, HTML fast fragment parser, DOM Bloom filters, and ARM64 JIT optimizations onto `main` in reviewable PRs paired with Lean 4 theorems (`lean-proofs/NanoUI.lean`).
- **Expanded Lean 4 verification:** Model and prove invariants for Windows VBlank frame pacing (`src/ui/frame_pace.zig`) and CPU raster layer-depth isolation (`src/ui/raster_group.zig`).
- **`nanoui.kit`, Gallery & contributor workflow:** Expand `src/kit/` accessibility coverage and Gallery Studio demos; keep PR security & COM-vtable verification checks current.

---

## Platform Roadmaps

### macOS

- **Shipped:** AppKit windows/menus (including Dock restore `#201`), Metal + Liquid Glass, CoreText & UAX #29 selection, EDR surfaces (`Surface.setColour(.extended_linear)`, `DisplayInfo`, `Screen`), `Div.occlude()`, WKWebView typed IPC + `private` + `loadRequest` + `file_drop`, `NSAccessibility` (`level` / `.list` containers), `nanoui.Updater`, `nui` CLI + archives, and headless `--nanoui-*` test flags.
- **Next (`v0.15.0`):** `WKContentRuleList` / request-filtering bridge for `PageOptions.allow_request`, plus `.app` / `.dmg` bundling and notarization in `nui`.
- **Later (`v0.15.x+`):** Native `UNUserNotificationCenter` notifications, retained scroll / partial-frame rebuilds, staged `nanobrowser` engine landings.

### iOS & iPadOS

- **Shipped:** UIKit + Metal + CoreText + Liquid Glass, WKWebView (`private`), touch scroll/flings, pinch zoom, `UITextInput` IME, `App.soon` + remote document-picker attach wait (`#247`), Zig 0.17.1 stdlib workaround (`#234`), VoiceOver + Dynamic Type traits, `MapKit`, multi-window `UIScene`, zero-Xcode `.app` / `.ipa` bundling (`tools/ios/bundle.zig`).
- **Next (`v0.15.0`):** `Surface.setColour(.extended_linear)` / EDR `CAMetalLayer` headroom, `PHPickerViewController` / `UIActivityViewController` share sheets & haptics, scene-scoped alerts & `⌘W` targeting the active `UIWindowScene` (fixing [docs/ios.md](ios.md#ipad-windows)), `CAFrameRateRange` 120 Hz pacing, trackpad/mouse hover & Apple Pencil metadata.
- **Later (`v0.15.x+`):** Background texture purging on Jetsam pressure, `BGTaskScheduler` / notifications, inter-scene drag-and-drop, and `UIMenuBuilder` shortcuts.

### Android

- **Shipped:** `NativeActivity` backend + opt-in app subclass packaging (`#252`), OpenGL ES 3 + CPU raster, nanoui TrueType text with multi-face TTC & CJK fallback (`#245`), `EditText` IME, touch/fling/pinch/mouse input, safe areas/cutouts, `AlertDialog` messages, APK builder & signer (`tools/android/apk.zig`, API 29+).
- **Next (`v0.15.0`):** `CFF2` outlines for `NotoSansCJK` (`#248`), `dialog.open` SAF support aligned with the no-nanoui-Java policy (or app-provided subclassing; see `#232`), embedded `android.webkit.WebView` + IPC, TalkBack (`AccessibilityNodeProvider`), on-device GLES3/CPU benchmarks.
- **Later (`v0.15.x+`):** Predictive Back animation (API 33+), `SurfaceTexture` / `AHardwareBuffer` interop for `ui.texture`, HDR swapchains.

### Linux, Windows & Web

- **Linux (`src/linux/`, `src/page_webkitgtk.zig`, `src/ui/opengl.zig`):** Shipped GTK 4/3 runtime loading, StatusNotifierItem + dbusmenu trays, OpenGL 3.3 + CPU raster, bubblewrap messaging, `Page.loadRequest`, `PageOptions.file_drop`, Lean-proved startup/memory optimization (`74.3 ms` warm / `68.4 ms` headless first-frame, `40.7–84.8 MiB` idle PSS). Next: `PageOptions.private` / `allow_request`, OpenGL vs. CPU circular clip & nested fade parity tests, Wayland HDR/fractional-scale polish.
- **Windows (`src/windows/`, `src/ui/d3d11*.zig`, `src/page_webview2*.zig`):** Shipped D3D11 + shader caching, scRGB HDR swap chains, VBlank pacing + circular SDF parity, TaskDialog message boxes with custom labels & checkboxes (`#231`), WebView2 `private` / `allow_request` (fail-closed) / `loadRequest` / `file_drop`. Next: SDR monitor `setExtended` retry gating and live WebView2 SDK CI tests.
- **Web (`src/web/`, `tools/web/`):** Shipped `wasm32-wasi` WebGPU renderer + Worker host (`#225`), default `app.html` shell with opt-in keyboard forwarding (`#238`), and `nui start --template page` / WASI build support (`#244`). Next: color-scheme following (`#239`), Canvas 2D fallback (`#240`/`#243`), DOM semantics/ARIA/IME/clipboard (`#241`/`#251`), shared `file_picker` (`#242`), and browser glyph fallback (`#249`).

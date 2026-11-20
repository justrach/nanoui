# nanoui Roadmap

Baseline: **[`v0.14.7`](https://github.com/justrach/nanoui/releases/tag/v0.14.7)** (2026-11-19).
See [Benchmarks](benchmarks.md) for current macOS, iOS, iPadOS, CPU-raster, and Linux numbers, [docs/ios.md](ios.md) for iOS/iPadOS bundling, and [docs/android.md](android.md) for Android details.

---

## Upcoming Milestones

### `v0.14.8` — Stabilization & Security Hardening

- **macOS Dock window restore ([#201](https://github.com/justrach/nanoui/issues/201)):** Fix `shouldReopen` (`src/app.zig`) inspecting nanoui's own `[NSApp windows]` (`isVisible` / `isMiniaturized`) or letting AppKit unminimize when no visible window is open, clarify `on_reopen` semantics, and verify with a live Dock click.
- **WebView2 security follow-ups (`src/page_webview2*.zig`):** Fail closed with `403` on UTF-8 conversion/OOM inside `ResourceRequested` (`src/page_webview2_handlers.zig`), gate or reject loading when `addWebResourceRequested` fails with `allow_request != null`, and add live WebView2 SDK smoke tests in Windows CI.
- **Windows extended-colour surface polish (`src/windows/surface_gpu.zig`):** Avoid retrying `setExtended(true)` every painted frame when an HDR-capable app starts on an SDR monitor; retry only on `WM_DISPLAYCHANGE` or monitor moves.
- **`nui` & docs alignment:** Document `PageOptions.private`, `PageOptions.allow_request`, and `SurfaceColour` support matrix clearly across templates and generated headers.

### `v0.15.0` — Cross-Platform Parity

- **Linux WebKitGTK page security (`src/page_webkitgtk.zig`):** Implement `PageOptions.private` using an ephemeral `WebKitWebsiteDataManager` / network session and `PageOptions.allow_request` via WebKitGTK request filtering.
- **macOS `allow_request` ergonomics (`src/page_webkit.zig`):** Provide a first-class helper or bridge (`WKURLSchemeHandler` / `WKContentRuleList`) so `PageOptions.allow_request` works cross-platform where possible.
- **Extended linear colour & GPU parity:** Bring `Surface.setColour(.extended_linear)` and `DisplayInfo` to iOS/iPadOS (`CAMetalLayer` EDR) and Linux Wayland/OpenGL (`src/ui/opengl.zig`), and add OpenGL/GLES vs. CPU parity tests for negative circular `clip_round` and nested masked `scroll_edge_fade` layers.
- **Mobile parity (`src/ios/`, `src/android/`):** Close remaining IME, file-picker, accessibility, and multi-window scene gaps listed below.

### `v0.15.x – v0.16.0` — Engine Performance, Formal Proofs & Ecosystem

- **Retained / partial-frame UI:** Land `feat/retained-scroll` and partial tree/damage optimizations backed by [`lean-proofs/NanoUI/RetainedScroll.lean`](../lean-proofs/NanoUI/RetainedScroll.lean), reducing `scroll` and `springs` CPU build/layout cost at 120 Hz.
- **Staged `nanobrowser` landing:** Upstream the `nanobrowser` CSS cascade/invalidation, HTML fast fragment parser, DOM Bloom filters, and ARM64 JIT optimizations onto `main` in reviewable PRs paired with their Lean 4 theorems (`lean-proofs/NanoUI.lean`).
- **Expanded Lean 4 verification:** Model and prove invariants for Windows VBlank frame pacing (`src/ui/frame_pace.zig`) and CPU raster layer-depth isolation (`src/ui/raster_group.zig`).
- **`nanoui.kit`, Gallery & contributor workflow:** Expand `src/kit/` accessibility coverage and Gallery Studio demos; add a PR security & COM-vtable verification checklist for external contributors.

---

## Platform Roadmaps

### macOS

- **Shipped in `v0.14.7`:** AppKit windows and menus, Metal renderer + Liquid Glass, CoreText text shaping & UAX #29 selection, extended linear-light EDR surfaces (`Surface.setColour(.extended_linear)`, `DisplayInfo`, `Screen`), `Texture.encoding`, WKWebView typed IPC + `PageOptions.private`, `NSAccessibility`, self-updates (`nanoui.Updater`), headless `--nanoui-snapshot` / `--nanoui-script` / `--nanoui-eval`.
- **Next (`v0.14.8` – `v0.15.0`):**
  - Restore minimized windows on Dock click (`#201`, `src/app.zig`).
  - Ergonomic `WKContentRuleList` / request-filtering bridge for `PageOptions.allow_request` (`src/page_webkit.zig`).
  - `.app` / `.dmg` bundling and notarization integration in `nui`.
- **Later (`v0.15.x+`):**
  - Native desktop notifications (`UNUserNotificationCenter`).
  - Retained scroll / partial-frame rebuilds for sustained 120 Hz ProMotion headroom.
  - Staged `nanobrowser` engine & JIT landings onto `main`.

### iOS

- **Shipped in `v0.14.7`:** UIKit + Metal + CoreText + Liquid Glass, WKWebView pages with typed IPC and `PageOptions.private`, single-finger scroll & flings, pinch zoom, selection handles, `UITextInput` IME composition (CJK/dictation/autocorrect), hardware keyboard & key repeat, VoiceOver (`UIAccessibilityElement` + Dynamic Type/contrast/bold-text traits in `src/ios/access.zig`), `MapKit`, safe-area / keyboard insets, and zero-Xcode `.app` / `.ipa` bundling (`tools/ios/bundle.zig`, iOS 15+).
- **Next (`v0.15.0`):**
  - **EDR / HDR surfaces:** Extend `Surface.setColour(.extended_linear)` and `DisplayInfo` (`UIScreen.currentEDRHeadroom` / `potentialEDRHeadroom`) to iOS `CAMetalLayer` (`src/ios/surface.zig`).
  - **Native pickers & sharing:** Wire `UIDocumentPickerViewController` / `PHPickerViewController` into `dialog.open`, add `UIActivityViewController` share sheets, and add haptics (`UIImpactFeedbackGenerator`).
  - **ProMotion & keyboard pacing:** Explicit `CAFrameRateRange` (120 Hz) for animations/flings and smooth frame-paced keyboard height transitions (`UIKeyboardWillChangeFrameNotification`).
  - **Physical device benchmarks:** Run `hillclimb` on physical iPhone Silicon via `xcrun devicectl` alongside Simulator baselines in [benchmarks.md](benchmarks.md).
- **Later (`v0.15.x+`):**
  - Release transient Metal intermediate/layer textures on `UIApplicationDidEnterBackgroundNotification` to stay under Jetsam background memory limits.
  - Background/audio/notification app-lifecycle hooks (`BGTaskScheduler`, `UNUserNotificationCenter`).

### iPadOS

- **Shipped in `v0.14.7`:** Multi-window `UIScene` support (`UIApplicationSupportsMultipleScenes` via `.multiple_windows = true`, `.own_scene = true`, `App.onNewWindow` in `src/ios/scenes.zig`), external hardware keyboard + key repeat, VoiceOver, and adaptive safe areas across split/slide-over layouts.
- **Next (`v0.15.0`):**
  - **Scene-scoped alerts & `⌘W`:** Fix the current limitation in [docs/ios.md](ios.md#ipad-windows) where dialogs and `⌘W` act on the first scene's stack instead of the active/frontmost `UIWindowScene`.
  - **Trackpad, mouse & Apple Pencil:** Support pointer hover (`UIHoverGestureRecognizer` / `UIPointerInteraction`), indirect scroll-wheel events on Magic Keyboard/trackpad, and Apple Pencil hover/pressure metadata in `ui.Input`.
  - **Stage Manager & XDR parity:** Per-scene `DisplayInfo` updates on external display / Stage Manager resize, plus Reference Mode / XDR headroom via `Surface.setColour(.extended_linear)`.
- **Later (`v0.15.x+`):**
  - Cross-scene and inter-app drag-and-drop (`UIDragInteraction` / `UIDropInteraction` bridged to `src/ui/drag_payload.zig`).
  - `UIMenuBuilder` integration so desktop `Menu` templates populate iPadOS's hold-`⌘` shortcut overlay and menu bar.

### Android

- **Shipped in `v0.14.7`:** `NativeActivity` backend (`src/android/` with zero nanoui Java — JNI calls only), OpenGL ES 3 + banded multi-threaded CPU raster (`src/ui/raster.zig`, `src/ui/raster_group.zig`), nanoui TrueType text (`src/ui/text_tt.zig`), composing `EditText` IME (`src/android/ime.zig` supporting CJK, voice, emoji), touch/fling/pinch/mouse input, safe areas/display cutouts/keyboard insets, `AlertDialog` messages, APK builder & signer (`tools/android/apk.zig`, ~730 KB `ReleaseSmall` gallery), API 29+.
- **Next (`v0.15.0`):**
  - **Web pages + IPC:** Embed `android.webkit.WebView` via JNI (`src/page_android.zig` or equivalent) with bridge injection and `PageOptions.private` / request interception.
  - **File picker (`dialog.open`) & >3-button sheets:** Trampoline `ACTION_OPEN_DOCUMENT` (SAF) results back into `src/android/dialog.zig` without dropping NativeActivity results.
  - **TalkBack accessibility (`src/android/access.zig`):** Bridge `ui/access.zig` semantic trees to Android `AccessibilityNodeProvider` / `ExploreByTouchHelper`.
  - **On-device GLES3 & CPU benchmarks:** Capture physical Android ARM64 `hillclimb` baselines (`OpenGL ES 3` offscreen EGL pbuffer + CPU raster) in [benchmarks.md](benchmarks.md).
- **Later (`v0.15.x+`):**
  - Predictive Back animation (`OnBackAnimationCallback` on API 33+).
  - `SurfaceTexture` / `AHardwareBuffer` interop for `ui.texture` and extended-range/HDR swapchains (`EGL_EXT_gl_colorspace_scrgb_linear` / `FP16`).

### Linux & Windows

- **Linux (`src/linux/`, `src/page_webkitgtk.zig`, `src/ui/opengl.zig`):** Shipped GTK 4/3 runtime loading, StatusNotifierItem + dbusmenu trays, OpenGL 3.3 + CPU raster, and bubblewrap fallback messaging. Next: `PageOptions.private` / `allow_request`, OpenGL vs. CPU parity tests for circular clips and nested scroll-fade groups, and Wayland HDR/fractional-scale polish.
- **Windows (`src/windows/`, `src/ui/d3d11*.zig`, `src/page_webview2*.zig`):** Shipped D3D11 + shader caching, scRGB HDR swap chains (`#204`), VBlank beat starvation fix + circular SDF parity (`#203`), and WebView2 `private` / `allow_request` (`#205`/`#206`). Next: `ResourceRequested` OOM fail-closed hardening, SDR monitor `setExtended` retry gating, and live WebView2 SDK tests in Windows CI.

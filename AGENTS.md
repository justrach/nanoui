# AGENTS.md

nanoui is a desktop application framework in Zig 0.17, after
[mygo](https://github.com/egoist/mygo). Windows show either a web page in the
system webview (WKWebView, macOS only for now) with typed Zig ↔ TypeScript
IPC, or native UI that nanoui draws itself, in the manner of GPUI: with Metal
and CoreText on macOS; on Linux (GTK 3, loaded with dlopen) and Windows
(Win32) with nanoui's own TrueType text (`src/ui/tt/`) and CPU renderer
(`src/ui/raster.zig`, tested against Metal); on Linux, OpenGL 3.3 draws
where there is a GPU (`src/ui/opengl.zig`, tested against the CPU
renderer); on iOS (UIKit) with Metal and CoreText as on the Mac; on
Android (NativeActivity, no Java of nanoui's own: Java's classes through
JNI) with nanoui's own text and OpenGL ES 3, or the CPU. Every platform
builds from any machine (`-Dtarget=...`); iOS needs Xcode's SDK and Zig's
lib fixed (`tools/ios/zig-lib.sh`), Android the Android SDK and NDK.

## Hard rules

- **Every file is at most 600 lines.** Source, scripts, shaders, docs: no
  exceptions. When a file would grow past 600 lines, split it by
  responsibility (a widget set, a backend concern, a layout pass) before
  adding to it. `zig build lines` checks it and must pass. The one
  exception: upstream license texts kept verbatim in `third_party/licenses/`,
  which must not be split or edited.
- **Zig 0.17.0.** Use its APIs (`std.process.Init`, `std.Io`, `@Fn`,
  `std.lang.Type`'s `field_names`/`field_types`/`decl_names`), not older idioms.
- **No C shims.** Native code is called directly: the Objective-C runtime
  through `src/objc.zig` (`objc.msg` builds each `objc_msgSend` prototype at
  comptime), C frameworks (CoreText, CoreGraphics, Metal, ImageIO,
  libdispatch) and Win32 through `extern` declarations, GTK through
  `dlopen`/`dlsym` (`src/linux/gtk.zig`), Java through JNI's function
  table (`src/android/jni.zig`). No `@cImport`, no `.c`/`.m`, no `.java`.
- **Every platform keeps building.** After a change, build for Linux and
  Windows too (`zig build -Dtarget=aarch64-linux-gnu --prefix zig-out/linux`,
  `-Dtarget=x86_64-windows-gnu`), iOS
  (`zig build $(sh tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator`) and
  Android (`zig build -Dtarget=aarch64-linux-android`: zig-out/android/*.apk),
  and run the Linux tests in the container (`tools/linux.Dockerfile`, `zig build test-bin`).
- **Never show windows on the developer's screen** while working: no
  running examples or benchmark apps windowed, nothing that activates an
  app or takes focus (nanoterm may be shown when asked). Live apps are
  checked headlessly with `--nanoui-snapshot` and `--nanoui-wait`; on
  iOS in a simulator booted headless, on Android in an emulator without a
  window (`tools/android/emulator.sh`), which adb may drive and capture
  (`adb shell input`, `adb exec-out screencap`). Measure with the headless hill-climb app
  (`hillclimb/`), verify with `ui.Tester` and the `--nanoui-*` flags.
- **Never drive the real screen.** No synthetic mouse or keyboard events
  (CGEventPost, AppleScript clicks), no full-screen captures: the user's
  other windows are theirs. Test native UI with `ui.Tester` (in process,
  rendered offscreen), apps with `--nanoui-snapshot`/`--nanoui-script`, and
  pages with `--nanoui-eval`, all of which keep windows hidden. Tests never
  touch the user's state either: no system clipboard (the Tester has its
  own), no files outside temporary directories, no defaults.
- **Threading.** AppKit, WebKit and the UI run on the main thread. Work from
  other threads reaches it through `objc.dispatchMain`.
- **Nothing polls.** Frames are drawn on input, resize, or while an
  animation runs; an idle app uses no CPU.
- **Objective-C memory:** `alloc`/`new` objects are owned and must be
  released; wrap code that makes temporary objects in `objc.Pool`. Objects
  a callback may still reach after teardown (a scheduled flush or frame)
  free themselves when it runs (`dead` flags in `Page` and `Surface`).
- **Heavy builds:** never build with Zig's self-hosted backend
  (`-fno-llvm`/`-fno-lld`); one heavy build at a time.

## Layout

```
src/nanoui.zig        the public API
src/objc.zig          Objective-C runtime, runtime classes, blocks, libdispatch
src/app.zig           lifecycle, menu bar, trays, services, client generation
src/dev.zig           --nanoui-* flags: generate, snapshot, script, eval, hidden
src/window.zig        NSWindow showing a page or native UI, window controls
src/page.zig          WKWebView, the nanoui:// scheme, the batched outbox
src/ipc.zig           bound services, calls, typed events, page messages
src/tsgen.zig         comptime TypeScript declarations and JS client
src/bridge.js         the page runtime (window.nanoui)
src/menu.zig          menus from templates: roles, accelerators, checkboxes
src/tray.zig          status bar icons
src/dialog.zig        open/save panels, message boxes
src/desktop.zig       clipboard, shell (open, reveal, trash), paths, appearance
src/update.zig        updates from GitHub releases: check, verify, swap the bundle
src/ui/ui.zig         native UI's public API and View
src/ui/context.zig    per-frame box tree, ids, input, hit testing, animation
src/ui/input.zig      keys, shortcuts, text operations, one event's input
src/ui/layout.zig     flexbox: measure, arrange, grow, shrink, absolute, scroll
src/ui/paint.zig      tree → GPU instances, clipping, culling, scrollbars
src/ui/frame.zig      one frame, shared by windows and the Tester; frame stats
src/ui/widgets.zig    boxes, text, icons, buttons, toggles, sliders, …
src/ui/div.zig        GPUI-style elements: ui.div(c).row().gap(8)…
src/ui/list.zig       virtualized list (GPUI's uniform_list)
src/ui/textfield.zig  the text field: selection, composition, clipboard
src/ui/textinput.zig  NSTextInputClient: IME, key bindings → text ops
src/ui/text.zig       fonts, shaping, cached layouts, wrapping
src/ui/shaper.zig     the exact fast path for printable ASCII
src/ui/atlas.zig      the glyph and SF Symbol atlas, growing
src/ui/metal.zig      the renderer: one pipeline, ring of instance buffers
src/ui/shader.metal   rounded rects, borders, glyphs, Gaussian shadows
src/ui/glass.zig      Liquid Glass: the material, backdrop and optics (CPU too)
src/ui/glass.metal    the glass's backdrop kernels and fragment function
src/ui/metal_glass.zig  panes of glass in the Metal renderer
src/ui/surface.zig    the NSView: events, display link, occlusion, resize
src/ui/motion/        ui.motion: springs, tweens, presence, keyframes, layout,
                      drag/snap, scroll-linked values, shared elements, text
src/ui/tester.zig     views without a window: input, time, PNG snapshots
src/ui/tests.zig      widget tests through the Tester
src/ui/text_tt.zig    text where nanoui shapes it itself (Linux, Windows, Android)
src/ui/tt/            TrueType: font files, the installed fonts, outlines to coverage
src/ui/atlas_tt.zig   the glyph atlas in memory; icons.zig: line icons
src/ui/raster.zig     the CPU renderer (same pixels as shader.metal)
src/ui/canvas.zig     a CPU-drawn window's pixels: only what a frame changed is drawn
src/ui/opengl.zig     the OpenGL 3.3 renderer (Linux), and OpenGL ES 3's (Android); shader.glsl: both Metal shaders in GLSL
src/ui/gl.zig         OpenGL's functions, loaded with dlopen
src/ui/images.zig     pictures (ui.image): decoded once, packed in a BGRA atlas
src/ui/png_decode.zig PNG to pixels where ImageIO isn't (Linux, Windows, portable)
src/platform.zig      what differs by OS below the UI (event loop, clipboard)
src/linux/            GTK 3 backend: app, window, surface (GL area or CPU), dialogs, fd watches
src/windows/          Win32 backend: app, window, surface (events, frames) +
                      surface_gpu (paint, D3D11 present), d3d (swap chain),
                      ime (IMM32), win32 (the extern layer), desktop, dialog,
                      fdwatch, loop, tests_*
src/ios/              UIKit backend: app and scenes, windows as stacked screens,
                      surface (Metal view), touch (pointer, scrolling, flings),
                      keys (hardware keys, software keyboard), desktop, dialogs
src/android/          NativeActivity backend: the activity and the app's thread (activity,
                      main, launch, calls), JNI, windows as stacked screens, surface
                      (EGL, or the CPU), touch, keys and the keyboard (ime), bars and
                      insets, desktop, dialogs (AlertDialog), fd watches, Zig std's
                      workarounds for bionic (sigaction, lookup)
src/menu_accel.zig    menus as accelerators (Linux, Windows, iOS, Android)
src/kit/              nanoui.kit: components after GPUI Kit (buttons, overlays, tabs, forms)
tools/*.Dockerfile    Linux (GTK, Xvfb) and Windows (Wine) test images
tools/ios/            app bundles (bundle.zig), the Simulator (sim.sh), Zig's lib fixed (zig-lib.sh)
tools/android/        APKs (apk.zig: the SDK, the manifest, aapt2, pack.zig, apksigner), run.sh, emulator.sh
examples/             hello (webview), counter and gallery (native UI)
hillclimb/            headless benchmarks against mygo (its own package)
apps/nanoterm/        the first app: a Warp-like terminal with ACP agents
apps/nanomon/         a small activity monitor (libproc, Mach, /proc)
apps/nanomail/        a JMAP mail client for macOS and iOS
site/                 the website (its own repo): Next.js on Cloudflare Workers, a gallery
tools/lines.zig       the 600-line check
tools/version.sh      set or check the version (build.zig.zon) for a release
.github/workflows/    CI (tests on macOS and Linux) and releases from v* tags
```

## Commands

```sh
zig build                 # build every example into zig-out/bin
zig build test            # unit and widget tests (renders offscreen with Metal)
zig build test -Dportable=true   # the same with nanoui's own text and CPU renderer
zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux   # Linux tests, run in the container
zig build lines           # enforce the 600-line limit
zig build run-hello       # webview + typed IPC
zig build run-counter     # native UI
zig build run-gallery     # native UI widgets
zig build gen             # write examples/hello/frontend/nanoui.{js,d.ts}
zig build $(sh tools/ios/zig-lib.sh) run-gallery -Dtarget=aarch64-ios-simulator   # the gallery in a simulator booted headless (xcrun simctl boot)
sh tools/android/emulator.sh   # an Android emulator without a window (stop: sh tools/android/emulator.sh stop)
zig build run-gallery -Dtarget=aarch64-linux-android   # the gallery on it (or a phone), its log here
zig build test-bin -Dtarget=aarch64-linux-android --prefix zig-out/android-tests   # the tests for a device:
adb push zig-out/android-tests/bin/nanoui-tests /data/local/tmp && adb shell /data/local/tmp/nanoui-tests
zig build test-tools      # the Android build tools' own tests (zip writing, the manifest)
sh tools/version.sh 0.2.1 # set the version; commit, push tag v0.2.1 to release
cd hillclimb && zig build run -- --label "change"   # climb: compare with mygo and history
cd apps/nanomon && zig build test --fork=../..     # an app (a submodule) against this nanoui, not its pinned one

# Headless checks of the real apps (no window is shown):
zig-out/bin/gallery --nanoui-snapshot=/tmp/g.png --nanoui-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --nanoui-eval='nanoui.call("Greeter.greet","Ada").then(v=>{nanoui.log(v);nanoui.window.close()})'
```

## Conventions

- New widgets are made of boxes (`Context.open`/`leaf`) styled from the
  theme and animated with `Context.animate`; a widget whose interaction
  changes app state sets `c.changed` so the frame is built again.
- Interactions read the previous frame's layout; keep ids stable with
  `ui.key` for list items.
- Every widget behavior gets a test in `src/ui/tests.zig`; every new IPC
  type mapping gets one in `src/tsgen.zig`.
- Keep `examples/hello/frontend/nanoui.d.ts` current (`zig build gen`).
- Performance work is hill-climbed: run `hillclimb` before and after, keep
  changes that climb, label runs. Never trade correctness for speed: fast
  paths come with tests proving they match the slow path (`shaper.zig`).

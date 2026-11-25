# WebGPU target

The browser renderer and minimal canvas host build for single-threaded
`wasm32-wasi` with Zig 0.17. They began as a port of the earlier 0.11
WebGPU experiment to the current renderer.

The renderer consumes the current **192-byte** `gpu.Instance`, including
subtree matrices, and respects `Texture.encoding` (`auto`, `display_sdr`,
`surface_linear`). It supports every current kind, pictures and glyphs,
rounded clipping, gradient stops, layers, holes, motion, glass (including
progressive sidebar blur), BGRA/half-float/external textures and LUTs.

## Build and verify

```sh
npm ci --prefix tools/web
PLAYWRIGHT_SKIP_BROWSER_GC=1 tools/web/node_modules/.bin/playwright install --only-shell chromium
zig build web-check -j1
node tools/web/check.mjs
zig build web-parity -j1
node tools/web/parity.mjs
zig build web-demo -j1
node tools/web/browser.mjs
node tools/web/serve.mjs
```

Open the printed loopback URL with `/counter.html` or `/gallery.html`.
The default shell uses Canvas 2D when it cannot acquire a WebGPU device.
The GPU parity checks still require WebGPU and fail on shader diagnostics or
validation errors. Linux CI uses pinned Playwright 1.63.0 with SwiftShader.

`NANOUI_GPU=hardware node tools/web/parity.mjs` selects ANGLE Metal on this
Mac and adds H.264/HEVC decode tests. `NANOUI_ENGINE=webkit` selects WebKit.
The tests compare against CPU pixels at scales 1/2 and in BGRA/RGBA. They
cover subtree matrices, explicit color encodings, same-frame compute,
readback across memory growth, stale devices and incremental atlas uploads.

## App integration

`nanoui.web.mount(view, options)` creates one canvas surface;
`nanoui.web.run()` unwinds main to the JavaScript event loop. Register fonts
first. The app's state must outlive the surface. JavaScript drives only
requested frames; an idle surface registers no animation callback.
The canvas keeps a GPU backing texture for ordinary axis-aligned scenes.
It repaints changed tiles and leaves the previous image on screen when an
update produces identical pixels. Backdrop effects, transformed layers,
and application-owned passes use a full redraw.

The build helper `@import("nanoui").web.install(b, exe, dependency.path("."))`
installs a wasm32-wasi command, browser modules, and a default
`web/<executable>.html` entry point. Serve that page over localhost or HTTPS.
The standard shell needs no app-authored HTML or JavaScript. Its module
must be single-threaded and link libc. In JavaScript:

```js
import {start} from './nanoui.js';
const runtime = await start({canvas, url: './my-app.wasm', device});
```

Omit `device` to have nanoui acquire and recover one. Injecting a device
leaves its ownership/recovery to the app; call `await runtime.setDevice(next)`
after replacement. `runtime.destroy()` frees renderer resources and only
an owned device. OffscreenCanvas/Workers use the same API (`worker.js`).

`ui.webgpuDevice()` and `ui.webgpuDeviceGeneration()` identify the shared
GPUDevice. `runtime.gpu.objects.put/get/drop` bridges app objects as handles.
Pass `true` as the second argument to `put` for textures that will keep the
same contents for their entire lifetime. Decoded `VideoFrame` objects are
already treated as immutable.
`Texture.web_texture` borrows a GPUTexture; `web_external` borrows a VideoFrame
or video element. Keep them alive until the frame is submitted. Ordinary
`VideoFrame` sources import directly. Padded frames are cropped, and video
elements use the normalized copy path to bridge decoder backends. Native two-plane formats are not web sources.

`Surface.before_encode` receives the GPUCommandEncoder's handle as a
pointer-sized integer; app JS resolves it through the object table.
`Surface.after_frame` retains its native meaning. `nanoui.web.Renderer` and
`Target` support offscreen rendering and asynchronous premultiplied BGRA
readback; keep output memory and callback context alive until completion.

`Surface.recordFrames` enables CPU/GPU timing; `gpu.stats` exposes recent
samples. The timestamp readback pool is bounded and never blocks a frame.

The host handles pointer and wheel input, pinch gestures, resize/DPR and
device recovery. The canvas delivers pinch scale and midpoint through
`Context.input.zoom` and `mouse`, and two-finger translation through `pan`.
A pinch cancels any active touch pointer drag rather than releasing it.
Workers can forward a pinch through `runtime.host.pinch(x, y, scale, dx, dy)`.
On a focusable DOM canvas, pass a `keyboard(event)` predicate to `start` to
forward selected key events. The Gallery demo uses this for its Zig command
palette. The predicate leaves browser-owned shortcuts and Tab available.
Apps still need IME, clipboard, dialogs, filesystem, semantic accessibility,
multi-window and a complete
App/Window platform remain separate work. Opaque desktop handle types let
shared app state compile without creating desktop windows in the browser.

`start({ ..., cpuFallback: true })` uses the Zig CPU rasterizer if adapter or
device acquisition fails. If a host-owned WebGPU device is lost, the host
tries to recover WebGPU first. If recovery fails, an attached DOM canvas is
replaced in place and the mounted Zig view keeps its state and focus. Use
`runtime.canvas` to find the current element. Event listeners installed
directly by an embedder need to be attached to the replacement.
Externally owned devices use the app's device recovery path.
`cpu: true` forces Canvas 2D on startup.
The Canvas 2D path renders at most at `cpuMaxScale` (2 by default), so a
DPR 3 phone rasterizes 2.25 times fewer pixels and the browser scales the
canvas up. It also caps the buffer at 4096 × 4096 pixels by reducing backing
scale. Zig writes RGBA, and the host presents it through an `ImageData` view
of WASM memory. GPU textures, custom GPU encoding and GPU timing
require WebGPU. A canvas inside a Worker has no element to replace, so
`cpuFallback` there only applies at startup.

See [MEASUREMENTS.md](MEASUREMENTS.md) for verification scope.

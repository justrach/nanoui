# nanobrowser

A web browser on [nanoui](../../README.md), with an engine of its own: no WebKit, no
Blink, no Gecko, and no C. Its HTML parser, CSS cascade, layout, display list and
JavaScript engine are written in Zig, and it looks like
[browse](https://github.com/justrach/browse): the tabs and the page are the whole window.

```sh
cd apps/nanobrowser
zig build -Doptimize=ReleaseFast
zig-out/bin/nanobrowser https://en.wikipedia.org/wiki/Bird

# Without a window, as tests and agents use it:
zig-out/bin/nanobrowser --nanoui-snapshot=/tmp/bird.png --nanoui-wait=8 https://en.wikipedia.org/wiki/Bird

zig build test                     # the app, the engines, the web bindings
zig test src/js/tests.zig          # the JavaScript engine's own tests (from this folder)
NANOBROWSER_LOG=1 zig-out/bin/...  # the page's console on stderr
```

| Key | |
|---|---|
| ⌘L | Go somewhere: an address goes there, anything else is searched for with the engine picked in the field (Google or DuckDuckGo) |
| ⌘K | Find a tab |
| ⌘S | Hide the tabs |
| ⌘D | Two pages side by side; ⇧⌘D duplicates the tab |
| ⌘T, ⌘W, ⇧⌘T | New tab, close it, bring it back |
| ⇧⌘W | Close the window |
| ⌘[, ⌘], ⌘R | Back, forward, reload |
| ⌘F, ⌘G, ⇧⌘G | Find on the page |

## What it is

It runs JavaScript apps, not the whole web: React and Vue apps boot, take clicks and
typing, and update. It is not a browser to trust with a bank account.

- **Not safe for hostile sites yet.** Nothing is sandboxed: a page's scripts, parsers and
  decoders share one process with everything else, in a language without memory safety.
  CORS is only checked when a response is read (no preflights), and CSP and subresource
  integrity are ignored. WebGL shaders reach the OpenGL driver without ANGLE validation;
  the limited WGSL-to-Metal translator is not a complete WebGPU validator.
- **Little is kept.** `localStorage` and history live for the life of the process. On
  Apple's systems the system's HTTP client also keeps cookies and a cache of its own on
  disk, so a site can remember what it decided about this browser between runs.
- **Bot walls remain unsupported.** Cross-frame array and message-port fixes remove
  reCAPTCHA's earlier JavaScript errors, but the demo still times out waiting for its
  challenge frame in hidden-window tests, even though the checkbox receives its click.
  This is not a completed CAPTCHA fix. Turnstile still stops in its scripts.
- **It says it's Chrome.** The user agent is Chrome's own string, with the version in
  `chrome_major` (`src/page.zig`) and no name of ours, so sites can't tell it apart by that
  and it needs raising as Chrome moves on. It doesn't get past the walls above: Google's
  stopped this browser with and without our name, and headless Chromium too.
- **Suggestions leave the machine.** What's typed in the address field goes to the chosen
  engine as it's typed, once it stops looking like an address. An address is never sent.
- **Slow on big sites.** No JIT, and a script that inserts CSS rules restyles the whole
  page. A heavy page such as GitHub takes many seconds to settle.

On macOS, canvases can draw with bounded, offscreen [WebGL 1/2](src/gl/README.md)
and [WebGPU](src/gpu/SUBSET.md) implementations. These execute real shaders and expose
readback, not the full APIs or conformance; unsupported platforms return no GPU context.
WebGPU includes a small WGSL grammar, compute/storage buffers and triangle rendering.
Both implementations run synchronously and can hold up the UI thread.

Absent: `WebSocket`, service workers, `indexedDB`, WebRTC, video and audio, canvas 2D
drawing (2D contexts exist and draw nothing), WebP and AVIF off Apple's systems,
`contenteditable`, bidirectional text and complex scripts off Apple's systems.

A `Worker` runs on the UI thread, a turn at a time among the page's: scripts see what they
expect of one, but a long computation there holds the window up. `importScripts` only finds
what the worker's script names literally.

## Comparing with Chromium

`node tools/compare.mjs --out DIR URL...` renders each page here and in headless Chromium at
the same size with the same user agent, and writes a side-by-side picture and a report of the
boxes that differ while their parent's doesn't. `NANOBROWSER_DUMP`, `NANOBROWSER_EVAL` and
`NANOBROWSER_LOG` are what it reads, and work alone.

## Parity with Ladybird

`tools/parity/` runs what Ladybird publishes, at the same revisions, and `report.py` puts the
results beside theirs test by test. `zig build test262-host` is the engine alone for
tc39/test262 (`test262.mjs`). `wpt_container.sh` runs WPT's testharness tests in a Linux
container through a hidden window (`wpt_run.py`), and `reftest.py` a sample of its reftests
and crashtests, more roughly than wptrunner does. There is no WebDriver, so tests needing
simulated input can't pass.

| Suite | nanobrowser | Ladybird |
|---|---:|---:|
| test262 | 72.4% | 98.8% |
| WPT subtests | 13.9% | 96.3% |
| WPT subtests, without encoding, wasm and crypto | 38.3% | 90.1% |

## How it is laid out

```
src/html/    the WHATWG tokenizer and tree construction, encodings
src/css/     selectors, the cascade, every property, var() and calc()
src/layout/  block, inline, float, flex, grid, table, positioned
src/paint/   the display list, drawn through nanoui's boxes; form controls
src/js/      the JavaScript engine: parser, bytecode VM, GC, built-ins, RegExp (js.zig is its API)
src/web/     the DOM and web APIs scripts see, the event loop, script loading
src/gl/      offscreen CGL contexts, GLSL translation and WebGL draw validation
src/gpu/     Metal resources, commands and the bounded WGSL-to-Metal compiler
src/shell/   the tabs, the field, the finder
src/page*.zig, loader.zig   one document: fetching, frames, input
```

What the framework gives it: windows, text, the GPU and CPU renderers, HTTP, and pictures.

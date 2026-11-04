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
| ⌘L | Go somewhere: the field takes addresses only, and shivers at anything else |
| ⌘K | Find a tab |
| ⌘S | Hide the tabs |
| ⌘D | Two pages side by side; ⇧⌘D duplicates the tab |
| ⌘T, ⌘W, ⇧⌘T | New tab, close it, bring it back |
| ⌘[, ⌘], ⌘R | Back, forward, reload |
| ⌘F, ⌘G, ⇧⌘G | Find on the page |

## What it is

It runs JavaScript apps, not the whole web: React and Vue apps boot, take clicks and
typing, and update. It is not a browser to trust with a bank account.

- **Not safe for hostile sites yet.** Nothing is sandboxed: a page's scripts, parsers and
  decoders share one process with everything else, in a language without memory safety.
  CORS is only checked when a response is read (no preflights), and CSP and subresource
  integrity are ignored.
- **Nothing is kept.** Cookies, `localStorage` and history live for the life of the process.
- **Slow on big sites.** No JIT, and a script that inserts CSS rules restyles the whole
  page. A heavy page such as GitHub takes many seconds to settle.

Absent: `WebSocket`, `Worker`, service workers, `indexedDB`, WebGL, WebRTC, video and
audio, canvas drawing (2D contexts exist and draw nothing), iframes' contents, CSS
transitions and animations, WebP and AVIF off Apple's systems, web fonts, `contenteditable`,
bidirectional text and complex scripts off Apple's systems.

## How it is laid out

```
src/html/    the WHATWG tokenizer and tree construction, encodings
src/css/     selectors, the cascade, every property, var() and calc()
src/layout/  block, inline, float, flex, grid, table, positioned
src/paint/   the display list, drawn through nanoui's boxes; form controls
src/js/      the JavaScript engine: parser, bytecode VM, GC, built-ins, RegExp (js.zig is its API)
src/web/     the DOM and web APIs scripts see, the event loop, script loading
src/shell/   the tabs, the field, the finder
src/page*.zig, loader.zig   one document: fetching, frames, input
```

What the framework gives it: windows, text, the GPU and CPU renderers, HTTP, and pictures.

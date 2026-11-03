# Web pages on Windows

The same pages macOS shows in WKWebView, in Microsoft Edge's WebView2. The
public API does not change: `content = .{ .page = ... }`, `app.bind`,
`nanoui.Event`, and `/nanoui.js` are the same on both.

## What you need

- The **WebView2 Evergreen Runtime**. Windows 11 has it; Windows 10 usually
  does (Edge installs it). A machine without it opens the window with a
  native notice and a link to the download page instead of failing.
- **`WebView2Loader.dll`**, beside the executable. `zig build` installs it
  there from the WebView2 SDK (`-Dwebview2=sdk`, the default). To use a copy
  of your own, `-Dwebview2=<folder>`; to build without pages,
  `-Dwebview2=none`.

The SDK is found in the NuGet cache (`%USERPROFILE%\.nuget\packages\
microsoft.web.webview2\<version>\build\native\x64`) — installing the
`Microsoft.Web.WebView2` package once with any NuGet client is enough.

Nothing is linked at build time: `src/windows/webview2.zig` loads the loader
with `LoadLibraryW` and calls every COM interface through its vtable, the way
`ui/d3d11_glue.zig` calls Direct3D. That keeps both Windows ABIs — Zig's
default `-gnu` and `-msvc` — building the same way. The SDK's
`WebView2LoaderStatic.lib` cannot do this: it is MSVC's C++ and its static CRT,
which will not link into a `-gnu` binary.

## How a page is served

WKWebView gets a custom scheme (`nanoui://localhost`). Chromium needs one it
knows, so Windows pages live on **`https://nanoui.local`**, and every request
to it is answered by `WebView2WebResourceRequested` from the app's asset
table — the same table, the same `/nanoui.js`. Both origins are
`page.zig`'s `origin`; a page that uses relative URLs needs no change.

The bridge is one file for both (`src/bridge.js`): it posts through
`chrome.webview.postMessage` when the page has it, and through
`window.webkit.messageHandlers` otherwise.

## Switching between pages

A page cannot navigate the webview away from itself without losing the
bridge that made the call, so the app does it:

```zig
.content = .{ .page = .{
    .url = "/",
    .assets = &assets,
    .pages = &.{
        .{ .title = "Local page", .url = "/" },
        .{ .title = "WebView2 docs", .url = "https://learn.microsoft.com/microsoft-edge/webview2/" },
    },
} },
```

`pages` puts a bar in the corner of **every** document the window shows — the
app's own and any remote page — with one button per entry and the current one
marked. `window.setPageUrl(url)` and `window.showPage(i)` do the same from Zig.

An absolute `http(s)://` URL loads as it is; anything else is a path in the
app's assets.

## What is not there yet

- A page and native UI in the same window. `Content` is one or the other;
  pages get their whole window.
- Input methods that compose text: the software keyboard types what
  `WM_CHAR` gives.
- The profile folder is `%LOCALAPPDATA%\<app>\WebView2`, or
  `NANOUI_WEBVIEW_PROFILE`. If that folder cannot be made (a run from a
  directory Windows denies writes to), the runtime's own default is used
  rather than failing the window.

## Checking a page without a window

```sh
zig-out/bin/hello --nanoui-eval='nanoui.log(document.title)' --nanoui-wait=6
```

`--nanoui-eval` runs once the page's navigation completes, and `nanoui.log`
prints to stderr. `--nanoui-hidden` keeps the window off the screen.

# Web pages on Linux

The same pages macOS shows in WKWebView, in WebKitGTK. The public API does not
change: `content = .{ .page = ... }`, `app.bind`, `nanoui.Event`, and
`/nanoui.js` are the same on every platform.

## What you need

**WebKitGTK 2.40 or later**, at run time. Nothing is linked at build time:
`src/linux/webkit.zig` loads it with `dlopen`, as `src/linux/gtk.zig` loads GTK,
so Linux binaries still build from any machine.

```sh
sudo apt install libwebkit2gtk-4.1-0   # Debian, Ubuntu (GTK 3)
sudo apt install libwebkitgtk-6.0-4    # or, for GTK 4
sudo dnf install webkit2gtk4.1         # Fedora
sudo pacman -S webkit2gtk-4.1          # Arch
```

A machine without it still opens the window, with a native notice saying what to
install. `nui doctor` says whether it can find one.

## Which GTK

A WebKitGTK is built for one GTK, and two GTKs in one process abort. So GTK starts
with the first window, not with `App.create`, and a page has the first say:

| First window | WebKitGTK | GTK |
|---|---|---|
| a page | 6.0, where [its sandbox can start](#the-sandbox) | 4 |
| a page | 4.1, else 4.0 (no usable 6.0, or `NANOUI_GTK=3`) | 3 |
| a page | none usable | 4, else 3, showing the notice |
| native UI | | 4, else 3 |

GTK cannot change once it is loaded. These then show the notice unless the
loaded GTK's WebKitGTK is installed, and `NANOUI_GTK=3` is the way round it where
only 4.1 is:

- a page window made after a native one;
- a page window made after `App.after`, `App.onMain` or a process or file watch,
  which load GTK for GLib's loop. Make the window first.

## The sandbox

WebKitGTK 6.0 always runs its web process in bubblewrap (`bwrap`). Where bubblewrap
can't run, 2.52 doesn't leave the page blank: it aborts the whole app. Ubuntu 24.04
restricts unprivileged user namespaces with AppArmor
(`kernel.apparmor_restrict_unprivileged_userns=1`), and a stock GitHub Actions
runner, which has that setting and no AppArmor profile for bwrap, crashes this way.

So before it chooses 6.0, nanoui runs the check WebKit itself runs in a container:
`bwrap --ro-bind / / --proc /proc --dev /dev --unshare-all true`. If bwrap refuses:

- with 4.1 or 4.0 installed, the page takes that, and GTK 3. **WebKitGTK 4.x as
  nanoui uses it has no process sandbox at all**, with or without this check, so
  the app's page runs unsandboxed: one more reason to show only pages you trust.
- with only 6.0, the window shows a notice saying to install 4.1, as it does when
  no WebKitGTK is installed.

The check is skipped where WebKit doesn't use bubblewrap: under Flatpak or Snap, in
a Podman container, or with `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS` set. nanoui
never sets that variable itself; it's for tests, or for a user who has decided to.
A system can also let bwrap through with its own AppArmor profile, and then 6.0 runs
sandboxed as usual.

## How a page is served

As on macOS, pages live on **`nanoui://localhost`**, answered from the app's asset
table. The scheme is registered as secure and CORS-enabled, so module scripts,
`fetch` and `crypto.subtle` work. The bridge (`src/bridge.js`) is the same file:
WebKitGTK has WKWebView's `window.webkit.messageHandlers`.

Each app has its own profile, `$XDG_DATA_HOME/<app>/webkit` and
`$XDG_CACHE_HOME/<app>/webkit`, because every nanoui app has the same origin and
would otherwise share its storage. A hidden run (`--nanoui-hidden`,
`--nanoui-eval`) keeps nothing.

## What is not there yet

- A page and native UI in the same window. As on Windows, pages get their whole
  window.
- The app's menu accelerators while a page has the keyboard: they reach native
  UI only. The page's own keys, copy and paste work.
- `title_bar = .hidden` and `.popover`, which native windows on Linux don't have
  either.
- A limit on who can call the app. A page from the web can call its bound
  services, as it can on macOS and Windows: show only pages you trust with them.

## Checking a page without a window

```sh
xvfb-run -a zig-out/bin/hello --nanoui-wait=20 \
  --nanoui-eval='nanoui.log(document.title); nanoui.window.close()'
```

`--nanoui-eval` runs when the page's DOM is ready and `nanoui.log` prints to
stderr. The app quits when the page closes its last window, or after
`--nanoui-wait` seconds (5 by default).

<p align="center">
  <img src="docs/images/nano-transparent.png" alt="Nano, nanoui's field mouse craftsperson, wearing a blue workshop jacket and holding a miniature app window" width="280">
</p>

<h1 align="center">nanoui</h1>

<p align="center">Desktop apps in Zig, with native UI drawn on the GPU or a web frontend.</p>

<p align="center"><sub>Meet Nano. <a href="docs/images/nano-transparent.png">Transparent PNG</a> · <a href="docs/images/nano-paper.png">Original paper illustration</a></sub></p>

<p align="center">Want to see it in use? <a href="https://github.com/justrach/nanoterm"><strong>nanoterm</strong></a> is a terminal with a coding agent, and <a href="https://github.com/justrach/nanomon"><strong>nanomon</strong></a> an activity monitor, both built on nanoui.</p>

<p align="center">
  <img alt="macOS · Linux · Windows" src="https://img.shields.io/badge/macOS%20·%20Linux%20·%20Windows-555">
  <img alt="Apps of about 0.7 MB" src="https://img.shields.io/badge/apps-~0.7%20MB-44cc11">
  <img alt="Zero dependencies" src="https://img.shields.io/badge/dependencies-0-44cc11">
  <img alt="Built in Zig 0.17" src="https://img.shields.io/badge/built%20in-Zig%200.17-f7a41d?logo=zig&logoColor=white">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

<p align="center">
  <a href="#get-started">Get started</a> ·
  <a href="#native-ui">Native UI</a> ·
  <a href="#web-pages">Web pages</a> ·
  <a href="#testing-without-a-window">Testing</a> ·
  <a href="#platforms">Platforms</a> ·
  <a href="#apps">Apps</a> ·
  <a href="#performance">Performance</a> ·
  <a href="#credits">Credits</a>
</p>

<p align="center">
  <img src="docs/images/nanomon-window.png" alt="nanomon, built on nanoui: the overview in Codegraff Light, with cell graphs of CPU, memory, GPU, disk and network" width="760">
</p>

Each window shows one of two kinds of interface:

- **Native UI**, written in Zig alone and drawn by nanoui: no HTML, no
  JavaScript, no webview. It has flexbox layout, text in a glyph atlas,
  animations, and views you can test without a window. On macOS it draws with
  Metal and CoreText, in one instanced draw call per frame.
- **A web page** in the system webview (WKWebView, macOS for now). The
  frontend calls Zig through a JavaScript client generated from your Zig
  types, with TypeScript declarations.

Apps are single binaries. Nothing polls, so an idle app uses no CPU.

## Get started

```sh
git clone --recursive https://github.com/justrach/nanoui
cd nanoui
zig build run-gallery    # the native UI tour
zig build run-hello      # the webview example
zig build test           # unit and widget tests
```

You need Zig 0.17.0, plus the macOS SDK on a Mac (Xcode or the Command Line
Tools). Linux apps need GTK 3 at run time and nothing at build time.

`--recursive` also fetches the apps, which live in their own repositories as
submodules under `apps/`. To fetch them after a plain clone, run
`git submodule update --init`.

To use nanoui in your own project, add a release to its `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/justrach/nanoui#v0.2.0
```

Releases are tagged `vMAJOR.MINOR.PATCH`, as mygo's are, and each is listed
under [Releases](https://github.com/justrach/nanoui/releases) with what
changed. While nanoui is 0.x, a minor release may change the API; a patch
release won't.

## Native UI

```zig
const Counter = struct {
    n: i64 = 0,

    fn view(s: *Counter, c: *ui.Context) void {
        const col = ui.div(c).column().sizeFull().center().gap(16);
        defer col.end();
        ui.textf(c, .{ .size = 56, .weight = .bold }, "{d}", .{s.n});
        if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
    }
};

pub fn main(init: std.process.Init) !void {
    const app = try nanoui.App.create(init, .{ .name = "Counter" });
    defer app.destroy();
    var state: Counter = .{};
    _ = try app.newWindow(.{ .title = "Counter", .content = .{ .view = .init(&state, Counter.view) } });
    try app.run();
}
```

<p align="center">
  <img src="docs/images/gallery-dark.png" alt="The nanoui gallery: buttons, toggles, sliders and a text field, drawn by nanoui" width="640">
  <br><sub>The gallery example, <code>zig build run-gallery</code>.</sub>
</p>

Views are immediate mode: a function of your state, run on every event.
Widgets answer from the previous frame's layout. When an interaction changes
state, the frame is built again before it's drawn, so the screen never lags
the state.

<details>
<summary>What's in the toolkit</summary>

- **Layout:** rows, columns, cards and scroll views, with flexbox grow,
  shrink, absolute placement, and maximum sizes.
- **Elements:** GPUI-style method chains, such as
  `ui.div(c).row().gap(8).bg(...)`.
- **Lists:** a virtualized list (`ui.list`) that builds only the rows in view.
- **Text:** wrapping, monospace, weights and rich spans, with text that can
  be selected and copied like a terminal's.
- **Controls:** buttons, checkboxes, toggles, sliders, progress bars,
  segmented controls, badges, and text fields with IME support.
- **Images:** pictures decoded once and packed into an atlas.
- **Look:** light and dark themes that follow the system, eased animations,
  Gaussian shadows, and Liquid Glass.
- **Pointer:** hover that follows ancestry as CSS's `:hover` does, double
  clicks, and pointer tracking for graphs (`c.wants_moves`).

</details>

### Liquid Glass

`.glass(.{})` fills a box with Liquid Glass, the material of macOS 26 and
later, in place of a background. Whatever was painted under the box shows
through it: frosted, bent near its edges as through the rim of a lens, and
lit along a hairline rim. That includes content scrolling under a toolbar
placed over it with `absolute()`.

```zig
const bar = ui.div(c).absolute().offset(20, 20).w(420).h(56).row().itemsCenter().px(16).rounded(28).glass(.{});
defer bar.end();
ui.text(c, "On glass", .{ .weight = .semibold });
ui.spacer(c);
// A prominent button: glass tinted with the accent.
const tap = ui.div(c).px(16).py(8).rounded(16).glass(.{ .tint = th.accent }).control();
defer tap.end();
ui.text(c, "Tap", .{ .color = th.accent_text });
```

Regular glass frosts and lightens what shows through, or darkens it in dark
mode, so text on it reads over anything. `.style = .clear` barely frosts it,
for glass over photos and video. nanoui draws the glass itself, after mygo's
glass plugin and its measurements of AppKit's `NSGlassEffectView`. Each pane
averages and blurs what's under it, then shades it on the GPU, and the CPU
renderer computes the same pixels. It looks the same on Linux and Windows,
and a test checks the two renderers agree.

<p align="center">
  <img src="docs/images/gallery-glass.png" alt="A toolbar of Liquid Glass over colored cards, with a tinted button and a pane of clear glass" width="640">
  <br><sub>The gallery's Glass page.</sub>
</p>

## Web pages

```zig
const Greeter = struct {
    pub const nanoui_params = .{ .greet = .{"name"} };

    pub fn greet(_: *Greeter, call: *nanoui.Call, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(call.arena, "Hello, {s}!", .{name});
    }
};

const Tick = nanoui.Event("tick", struct { uptime: u64 });

// in main:
try app.bind(&greeter);
try app.registerEvent(Tick);
_ = try app.newWindow(.{ .title = "Hello", .content = .{ .page = .{ .url = "/", .assets = &assets } } });
```

```js
import { Greeter, onTick } from "/nanoui.js"; // generated, served by the app

document.body.textContent = await Greeter.greet("Ada");
onTick(({ uptime }) => console.log(uptime));
```

`zig build gen` writes `nanoui.d.ts`:

```ts
export declare const Greeter: { greet(name: string): Promise<string> };
export declare function onTick(listener: (payload: TickPayload) => void): () => void;
```

Methods may return error unions; an error rejects the page's promise with
the error's name. Assets are served from the `nanoui://localhost/` scheme.
Elements styled `--app-region: drag` move frameless windows.

## Testing without a window

```zig
var t: ui.Tester = undefined;
try t.init(gpa, .init(&state, Counter.view), .{});
defer t.deinit();
try t.clickText("Increment");
try std.testing.expect(t.hasText("1"));
try t.screenshot("/tmp/counter.png"); // rendered offscreen by the Metal renderer
```

The real apps run headless too:

```sh
zig-out/bin/gallery --nanoui-snapshot=shot.png --nanoui-script="click:Tasks;type:Hi;key:enter"
zig-out/bin/hello --nanoui-eval='nanoui.call("Greeter.greet","Ada").then(v => { nanoui.log(v); nanoui.window.close() })'
```

## Platforms

nanoui loads what each platform has instead of linking it, so every platform
builds from any machine. On a Mac, `zig build -Dtarget=x86_64-linux-gnu` or
`-Dtarget=x86_64-windows-gnu` makes a Linux or Windows binary.

| | macOS | Linux | Windows |
|---|---|---|---|
| windows, input, timers | AppKit | GTK 3 (loaded with `dlopen`) | Win32 |
| text | CoreText | nanoui's TrueType reader (`src/ui/tt/`) | the same |
| rendering | Metal | OpenGL 3.3 in a GtkGLArea; CPU (`src/ui/raster.zig`) without one | CPU, shown with GDI |
| icons | SF Symbols | line icons drawn by nanoui (`src/ui/icons.zig`) | the same |
| pages (webview) | WKWebView | not yet | not yet |
| menus | the menu bar | accelerators | accelerators |

The CPU renderer matches the Metal one pixel for pixel, and a test compares
them; another compares the OpenGL renderer with the CPU one, in a context
without a window. `NANOUI_RENDERER=cpu` draws on the CPU where OpenGL is. `zig build test -Dportable=true` runs the Linux and Windows text and
renderer on a Mac. Linux is also tested in a container
(`tools/linux.Dockerfile`: GTK, fonts and a virtual display).

## Apps

<table>
  <tr>
    <td width="50%" valign="top">
      <a href="https://github.com/justrach/nanoterm"><img src="docs/images/nanoterm-light.png" alt="nanoterm: an agent's answer with a native visual"></a>
      <p><a href="https://github.com/justrach/nanoterm"><strong>nanoterm</strong></a>: a terminal of blocks, in the manner of Warp, with a coding agent (graff or Claude Code) over ACP. It has native visuals, a ⌘P launcher, and SSH sessions where the agent works on the remote host.</p>
    </td>
    <td width="50%" valign="top">
      <a href="https://github.com/justrach/nanomon"><img src="docs/images/nanomon-dark.png" alt="nanomon: the overview with graff's suggestions"></a>
      <p><a href="https://github.com/justrach/nanomon"><strong>nanomon</strong></a>: an activity monitor in Codegraff colors, with cell graphs of CPU, memory, GPU, disk and network. You can quit several processes at once, and a graff bubble suggests what to quit.</p>
    </td>
  </tr>
</table>

Download them for macOS:
[nanoterm](https://github.com/justrach/nanoterm/releases/latest/download/nanoterm-macos-arm64.dmg) ·
[nanomon](https://github.com/justrach/nanomon/releases/latest/download/nanomon-macos-arm64.dmg).

Both live in `apps/` as submodules, and each also builds on its own, fetching
nanoui pinned by commit. To build one against the nanoui next to it, with
your changes, use `--fork`: `cd apps/nanomon && zig build run --fork=../..`.

## Performance

Performance is measured headless with [`hillclimb/`](hillclimb/README.md):
the same scenes rendered through each framework's own frames and offscreen
Metal renderer, on an Apple M3 Ultra. The figures are medians per frame in
milliseconds; lower is better.

| scene | frame CPU nanoui | frame CPU mygo | GPU nanoui | GPU mygo |
|---|---:|---:|---:|---:|
| boxes (600 shadowed boxes) | 0.061 | 0.301 | 0.140 | 1.616 |
| text (300 changing labels) | 0.108 | 0.418 | 0.065 | 0.056 |
| scroll (1000-row column) | 0.315 | 2.076 | 0.055 | 0.122 |
| list (100 000-row virtual list) | 0.060 | 0.367 | 0.046 | 0.045 |
| dashboard (12 cards) | 0.015 | 0.087 | 0.098 | 0.295 |

Release binaries are about 0.7 MB for nanoui and 11.8 MB for mygo. IPC (5000
sequential calls from the page to native code) took 493 ms with nanoui and
528 ms with mygo.

## Development

```sh
zig build lines                                                       # the 600-line limit, enforced
zig build test-bin -Dtarget=aarch64-linux-gnu --prefix zig-out/linux  # Linux tests, for the container
cd hillclimb && zig build run -- --label "change"                     # benchmarks against mygo and history
sh tools/version.sh 0.2.1                                             # set the version for a release
```

To release, set the version, commit, and push its tag (`git tag v0.2.1 &&
git push origin v0.2.1`). The release workflow checks that the tag matches
`build.zig.zon`, runs the tests, and opens the GitHub release.

Rules for working here, by hand or with an agent, are in
[AGENTS.md](AGENTS.md).

nanoui is a subset of what full frameworks offer. Pages work only on macOS so
far, and there's no accessibility, bundling, notifications, channels or
plugins yet. Apps update themselves from GitHub releases on macOS
(`nanoui.Updater`). Bound methods run on the main thread.

## License

nanoui is licensed under the [MIT License](LICENSE). Material from mygo (MIT)
and GPUI (Apache 2.0) keeps its own notices; see
[third-party notices](THIRD_PARTY_NOTICES.md).

## Credits

nanoui stands on the shoulders of two projects:

- **[mygo](https://github.com/egoist/mygo)** by [egoist](https://github.com/egoist):
  nanoui began as a port of its core to Zig, and keeps its architecture. That
  means:
  - the Objective-C runtime called directly, with runtime classes for
    delegates;
  - a batched outbox with one evaluation per main-loop turn;
  - events held until the page is ready;
  - a generated, typed client;
  - native UI drawn by the framework;
  - Liquid Glass drawn by its own renderers, ported from mygo's glass plugin.
- **[GPUI](https://github.com/zed-industries/zed/tree/main/crates/gpui)** by
  [Zed Industries](https://zed.dev). From GPUI, nanoui takes:
  - elements styled by method chains;
  - the virtualized `uniform_list`;
  - layouts cached across frames, with glyphs rasterized once into an atlas;
  - Gaussian shadows;
  - its general idea of a fast, GPU-drawn native UI.

<p align="center"><sub>Built in Zig 0.17 · <a href="AGENTS.md">AGENTS.md</a> · <a href="hillclimb/README.md">benchmarks</a> · <a href="LICENSE">MIT</a> · <a href="THIRD_PARTY_NOTICES.md">third-party notices</a></sub></p>

//! What windows are made of, the same on every platform: their options,
//! a page's or a native view's content, and the files pages are served.
const ui = @import("ui/ui.zig");

/// A file served to pages at `nanoui://localhost<path>`.
pub const Asset = struct {
    path: []const u8,
    data: []const u8,
    mime: ?[]const u8 = null,
};

pub const PageOptions = struct {
    /// Relative URLs resolve against `nanoui://localhost/`, served from
    /// `assets`; absolute URLs (`http://localhost:5173`) load as is.
    url: []const u8 = "/",
    assets: []const Asset = &.{},
    /// A name the app gives the page ("motion-code"), carried by every call
    /// it makes (`Call.label`) so a service can tell its pages apart.
    label: []const u8 = "",
    /// Web Inspector (right click > Inspect Element).
    inspectable: bool = true,
    /// Pages the window can switch between, shown as a bar on every one of
    /// them (the app's own and every remote page): `{ "Local", "/" }`,
    /// `{ "Docs", "https://example.com/" }`. Empty: no bar.
    pages: []const PageEntry = &.{},
    /// Docked: the native view (an NSView on macOS) the webview goes in,
    /// instead of filling the window's content; the app places it with
    /// `Page.setFrame`. For `Window.dockPage` in a native-UI window.
    parent: ?*anyopaque = null,
    /// Called with the platform's webview configuration (macOS: the
    /// WKWebViewConfiguration) before the webview is made: preferences,
    /// process pool, data store, extra script handlers.
    configure: ?*const fn (ctx: ?*anyopaque, config: *anyopaque) void = null,
    configure_ctx: ?*anyopaque = null,
};

/// One entry of `PageOptions.pages`.
pub const PageEntry = struct {
    title: []const u8,
    /// A path from the app's assets, or an absolute `http(s)://` URL.
    url: []const u8,
};

pub const Content = union(enum) {
    page: PageOptions,
    view: ui.View,
};

pub const TitleBar = enum {
    default,
    /// Content under a transparent title bar; the traffic lights stay.
    hidden,
    /// No frame at all: a panel with rounded corners and a shadow, above
    /// other windows, that takes keys without bringing its app forward and
    /// hides when it loses them (a menu bar extra's popover). macOS.
    popover,
};

pub fn Callback(comptime Window: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, window: *Window) void,
    };
}

/// Asked before the window closes (its close button, ⌘W): false keeps it.
pub fn ShouldClose(comptime Window: type) type {
    return struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, window: *Window) bool,
    };
}

/// A window, or a panel (`NSPanel`: a floating palette, a popover's window).
pub const Kind = enum { window, panel };

/// Which layer of the desktop a layer-shell window sits in, in the
/// compositor's stacking: above ordinary windows (a launcher), above
/// everything the shell draws (`overlay`), under windows, or behind them.
pub const LayerShellLayer = enum { background, bottom, top, overlay };

/// Whether a layer-shell window takes the keyboard: `none` never, `exclusive`
/// whenever it is shown (a launcher: you can type as it appears), `on_demand`
/// when the compositor gives it the focus (a click).
pub const KeyboardMode = enum { none, exclusive, on_demand };

/// Wayland: the window is a layer-shell surface rather than a window among
/// windows: a panel, a bar or a launcher, in a layer of its own above (or
/// below) ordinary windows, positioned and sized by its anchors. It needs
/// GTK 4 with `gtk4-layer-shell` installed, on a Wayland session; elsewhere
/// the window stays ordinary and a warning says so.
///
/// A launcher is typically `transparent` with `decorations = false` and no
/// anchors at all: the compositor centers it, and the view draws its own
/// rounded panel over what is behind.
pub const LayerShell = struct {
    layer: LayerShellLayer = .top,
    /// The name the compositor knows it by: what `hyprctl layers` shows, and
    /// what a compositor's own rules match (`layerrule = …, name:…`).
    namespace: []const u8 = "nanoui",
    /// Anchored edges: what the surface is pinned to, and so what it
    /// stretches along (or keeps its size against, with margins). None
    /// anchored: centered.
    anchor_left: bool = false,
    anchor_right: bool = false,
    anchor_top: bool = false,
    anchor_bottom: bool = false,
    /// Gaps from the anchored edges, in points.
    margin_left: i32 = 0,
    margin_right: i32 = 0,
    margin_top: i32 = 0,
    margin_bottom: i32 = 0,
    /// Asks for a place of its own, the size of the surface along its
    /// anchored edges (a bar's), that other windows are kept out of.
    exclusive: bool = false,
    /// The exclusive zone in points, where `exclusive`'s automatic one is
    /// not wanted; null uses the automatic one.
    exclusive_zone: ?i32 = null,
    keyboard: KeyboardMode = .on_demand,
};

/// How high a window stacks (NSWindowLevel on macOS): above the menu bar
/// at `status`, over everything at `screen_saver`. Any other level is a
/// value of its own (`@enumFromInt`).
pub const Level = enum(i32) {
    normal = 0,
    floating = 3,
    modal_panel = 8,
    main_menu = 24,
    status = 25,
    pop_up_menu = 101,
    screen_saver = 1000,
    _,
};

pub fn Options(comptime Window: type) type {
    return struct {
        title: []const u8 = "",
        /// The window's icon, in the platform's own container: ICO on
        /// Windows, ICNS or PNG on macOS, PNG on GTK 3. Windows draws it in
        /// the title bar and the taskbar; macOS sets the Dock icon (a
        /// bundled .app's own `CFBundleIconFile` wins); GTK 3 sets the window
        /// icon its window manager draws (GTK 4 dropped window icons, and on
        /// Wayland the shell takes it from the .desktop file).
        icon: ?[]const u8 = null,
        width: f64 = 800,
        height: f64 = 600,
        min_width: f64 = 200,
        min_height: f64 = 150,
        resizable: bool = true,
        title_bar: TitleBar = .default,
        /// With `title_bar = .hidden`, macOS: where the close button's center
        /// goes, from the window's top left, the title bar grown to twice
        /// `y` to hold it; the other two follow at AppKit's spacing. Lets a
        /// view's own taller top bar (`ui.Context.title_bar_height`) line up
        /// with them. Null leaves them where AppKit puts them; other systems
        /// have none to move.
        traffic_lights: ?ui.Point = null,
        /// Whether the window has a title bar and a resizable frame at all.
        /// `false` is a borderless window: no title bar, no border and no
        /// drag-to-resize — the application draws or moves it,
        /// `ui.Context.window_drag` moves one. On Windows that is `WS_POPUP`
        /// (no system shadow either); on macOS a borderless NSWindow that
        /// still takes keys; on GTK an undecorated window.
        ///
        /// Independent of `title_bar`, which is about what the title bar looks
        /// like when there is one.
        decorations: bool = true,
        /// Window opacity, 0 to 1. 1 is opaque and the normal path. macOS
        /// and GTK set the window's alpha; on Windows, below 1 the window is
        /// translucent, and that costs the GPU renderer there:
        /// `SetLayeredWindowAttributes` has no effect on a DXGI flip-model
        /// swap chain, so the frame is drawn by GDI while the
        /// window is translucent and the GPU is picked up again at 1. One CPU
        /// copy per frame while translucent is the price; see
        /// `src/windows/surface_gpu.zig`.
        ///
        /// At 0 the window is invisible, which is a way to fade one out
        /// (`setOpacity`) but not a way to hide it — use `show`/`hide`.
        opacity: f64 = 1,
        /// No background: only what the view draws shows, antialiased
        /// against what is behind the window (a launcher's rounded panel,
        /// with nothing square behind its corners). For a borderless window
        /// (`decorations = false`); ignored on one with a frame. Windows:
        /// per-pixel alpha (`UpdateLayeredWindow`, the CPU renderer), and
        /// clicks on what isn't drawn fall through. Linux (GTK 3): an RGBA
        /// window where a compositor runs; where none does, the window is
        /// cut to what is more than half opaque. Elsewhere it changes nothing.
        transparent: bool = false,
        /// Keeps the window out of the taskbar and out of Alt-Tab
        /// (`WS_EX_TOOLWINDOW` on Windows; the skip-taskbar and skip-pager
        /// hints on GTK 3, which GTK 4 no longer has). The Mac lists apps,
        /// not windows, so there the window leaves Command-` and the Window
        /// menu. For a sidebar or a utility window that belongs to another
        /// application.
        skip_taskbar: bool = false,
        /// Native UI's colors, fixed; the system's light or dark when null.
        theme: ?ui.Theme = null,
        /// Where the window opens, in screen points from the primary screen's
        /// top left; centered when null.
        x: ?f64 = null,
        y: ?f64 = null,
        /// The screen it opens on (`App.screens`' `id`): `x` and `y` are
        /// then from that screen's top left, and without them it is
        /// centered there. A screen not connected is ignored. macOS.
        screen: ?u32 = null,
        always_on_top: bool = false,
        /// Its stacking level (`Window.setLevel`), over `always_on_top`
        /// and `floating`. macOS.
        level: ?Level = null,
        /// Clicks and the pointer pass through it to what is behind (a
        /// clean feed on a second display, an overlay). macOS.
        ignores_mouse: bool = false,
        /// Shown at once; otherwise call `show`.
        visible: bool = true,
        /// iOS: the view spans the whole screen, under the status bar and
        /// the home indicator, and keeps clear of them itself
        /// (`ui.Context.safe_area`); without it, the view is laid out
        /// inside the safe area. Elsewhere it changes nothing.
        full_bleed: bool = false,
        /// iPad: a window of its own beside the app's, which the person can
        /// move and close as any other (needs `ios.Options.multiple_windows`).
        /// On a phone it covers the screen like any other window. Elsewhere
        /// it changes nothing: every window has its own place.
        own_scene: bool = false,
        /// Called as the window closes, before it is freed.
        on_close: ?Callback(Window) = null,
        /// Called after the window resized.
        on_resize: ?Callback(Window) = null,
        /// Called after the window moved: read `frame()`. macOS.
        on_move: ?Callback(Window) = null,
        /// Called as it enters or leaves full screen: read `isFullScreen()`.
        on_fullscreen: ?Callback(Window) = null,
        /// Called as it becomes or stops being the key window: read `isFocused()`.
        on_key: ?Callback(Window) = null,
        should_close: ?ShouldClose(Window) = null,
        /// Its frame is kept in the defaults under this name, and restored.
        frame_autosave: ?[]const u8 = null,
        kind: Kind = .window,
        /// Above other windows (a floating panel's level).
        floating: bool = false,
        /// On every Space, and beside full-screen windows.
        all_spaces: bool = false,
        /// A panel that takes clicks without making its app active.
        non_activating: bool = false,
        /// A panel with the small utility title bar (an inspector, a palette). macOS.
        utility: bool = false,
        /// A panel that hides while its app is inactive (AppKit's default for
        /// panels); false keeps a floating inspector up. macOS.
        hides_on_deactivate: bool = true,
        /// Never merged into another window's tabs.
        tabbing_disallowed: bool = true,
        /// Wayland: a layer-shell surface, a panel of the desktop rather
        /// than a window among windows. Null (the default) is an ordinary
        /// window; on other platforms it changes nothing.
        layer_shell: ?LayerShell = null,
        // Where a platform has none of these (Linux, Windows), they are ignored.
        content: Content,
    };
}

/// A window's native UI as `--nanoui-snapshot` draws it.
pub const NativeView = struct {
    view: ui.View,
    width: f32,
    height: f32,
    scale: f32,
    theme: ?ui.Theme,
};

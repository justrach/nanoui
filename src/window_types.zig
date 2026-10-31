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
    /// Web Inspector (right click > Inspect Element).
    inspectable: bool = true,
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

pub fn Options(comptime Window: type) type {
    return struct {
        title: []const u8 = "",
        width: f64 = 800,
        height: f64 = 600,
        min_width: f64 = 200,
        min_height: f64 = 150,
        resizable: bool = true,
        title_bar: TitleBar = .default,
        /// Whether the window has a title bar and a resizable frame at all.
        /// `false` is a borderless window on Windows (`WS_POPUP`: no title bar,
        /// no border, no system shadow, and no drag-to-resize — the
        /// application draws or moves it, `ui.Context.window_drag` moves one).
        /// macOS and GTK do not honor it yet.
        ///
        /// Independent of `title_bar`, which is about what the title bar looks
        /// like when there is one.
        decorations: bool = true,
        /// Window opacity, 0 to 1. 1 is opaque and the normal path. Windows
        /// only for now. Below 1 the window is translucent, and that costs the
        /// GPU renderer there: `SetLayeredWindowAttributes` has no effect on a
        /// DXGI flip-model swap chain, so the frame is drawn by GDI while the
        /// window is translucent and the GPU is picked up again at 1. One CPU
        /// copy per frame while translucent is the price; see
        /// `src/windows/surface_gpu.zig`.
        ///
        /// At 0 the window is invisible, which is a way to fade one out
        /// (`setOpacity`) but not a way to hide it — use `show`/`hide`.
        opacity: f64 = 1,
        /// Keeps the window out of the taskbar and out of Alt-Tab
        /// (`WS_EX_TOOLWINDOW` on Windows; macOS and GTK ignore it). For a
        /// sidebar or a utility window that belongs to another application.
        skip_taskbar: bool = false,
        /// Native UI's colors, fixed; the system's light or dark when null.
        theme: ?ui.Theme = null,
        /// Where the window opens, in screen points from the primary screen's
        /// top left; centered when null.
        x: ?f64 = null,
        y: ?f64 = null,
        always_on_top: bool = false,
        /// Shown at once; otherwise call `show`.
        visible: bool = true,
        /// iOS: the view spans the whole screen, under the status bar and
        /// the home indicator, and keeps clear of them itself
        /// (`ui.Context.safe_area`); without it, the view is laid out
        /// inside the safe area. Elsewhere it changes nothing.
        full_bleed: bool = false,
        /// Called as the window closes, before it is freed.
        on_close: ?Callback(Window) = null,
        /// Called after the window resized.
        on_resize: ?Callback(Window) = null,
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
        /// Never merged into another window's tabs.
        tabbing_disallowed: bool = true,
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

//! nanoui: desktop apps in Zig, with native UI drawn on the GPU or a web
//! frontend in the system webview, after mygo. Native UI runs on iOS and
//! Android too.
//!
//!     pub fn main(init: std.process.Init) !void {
//!         const app = try nanoui.App.create(init, .{ .name = "Hello" });
//!         defer app.destroy();
//!         _ = try app.newWindow(.{ .title = "Hello", .content = .{ .page = .{ .url = "/", .assets = &assets } } });
//!         try app.run();
//!     }
const std = @import("std");
const builtin = @import("builtin");

// Zig 0.17.0's std can't build for iOS as it ships (`tools/ios/zig-lib.sh`).
comptime {
    if (builtin.os.tag == .ios and std.process.can_replace) @compileError(
        \\Zig 0.17.0's std can't build programs for iOS (std.process.can_replace).
        \\Build with the fixed copy tools/ios/zig-lib.sh makes:
        \\  zig build $(sh tools/ios/zig-lib.sh) -Dtarget=aarch64-ios-simulator
    );
}

/// The platform's implementations, chosen at compile time.
const mac = builtin.os.tag == .macos;
/// Android is Linux to Zig; nanoui's own there (`src/android/`).
const is_android = builtin.abi.isAndroid();
const plat = switch (builtin.os.tag) {
    .macos => struct {
        pub const app = @import("app.zig");
        pub const window = @import("window.zig");
        pub const menu = @import("menu.zig");
        pub const tray = @import("tray.zig");
        pub const dialog = @import("dialog.zig");
        pub const desktop = @import("desktop.zig");
        pub const fdwatch = @import("fdwatch.zig");
    },
    .linux => if (is_android) struct {
        pub const app = @import("android/app.zig");
        pub const window = @import("android/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("tray_none.zig");
        pub const dialog = @import("android/dialog.zig");
        pub const desktop = @import("android/desktop.zig");
        pub const fdwatch = @import("android/fdwatch.zig");
    } else struct {
        pub const app = @import("linux/app.zig");
        pub const window = @import("linux/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("tray_none.zig");
        pub const dialog = @import("linux/dialog.zig");
        pub const desktop = @import("linux/desktop.zig");
        pub const fdwatch = @import("linux/fdwatch.zig");
    },
    .ios => struct {
        pub const app = @import("ios/app.zig");
        pub const window = @import("ios/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("tray_none.zig");
        pub const dialog = @import("ios/dialog.zig");
        pub const desktop = @import("ios/desktop.zig");
        pub const fdwatch = @import("fdwatch.zig");
    },
    .windows => struct {
        pub const app = @import("windows/app.zig");
        pub const window = @import("windows/window.zig");
        pub const menu = @import("menu_accel.zig");
        pub const tray = @import("windows/tray.zig");
        pub const dialog = @import("windows/dialog.zig");
        pub const desktop = @import("windows/desktop.zig");
        pub const fdwatch = @import("windows/fdwatch.zig");
    },
    else => @compileError("nanoui runs on macOS, iOS, Android, Linux and Windows"),
};

/// Android's entry and panic handler, for an app's library's root
/// (`android.library` in build.zig makes it).
pub const android = if (is_android) @import("android/main.zig") else struct {};

/// The Objective-C runtime (macOS and iOS).
pub const objc = if (mac or builtin.os.tag == .ios) @import("objc.zig") else struct {};
pub const ui = @import("ui/ui.zig");
/// HTTP requests answered on the main thread (http.zig).
pub const http = @import("http.zig");
/// Haptic taps (iOS; nothing elsewhere).
pub const haptics = @import("basics/haptics.zig");
/// The device's location (iOS, Core Location).
pub const location = @import("basics/location.zig");
/// Small values kept between launches (NSUserDefaults on Apple platforms).
pub const kv = @import("basics/kv.zig");
/// A map: MapKit under the UI on iOS, a placeholder elsewhere.
pub const map = @import("basics/map.zig");
/// Walking directions (iOS, MapKit's MKDirections).
pub const directions = @import("basics/directions.zig");
/// Components after GPUI Kit: buttons, overlays, tabs, forms, toasts.
pub const kit = @import("kit/kit.zig");
pub const tsgen = @import("tsgen.zig");
/// A native-UI window's surface: macOS's NSView, Windows' HWND client
/// (`after_frame`, `nativeHandle`, `ctx`).
pub const Surface = if (mac) @import("ui/surface.zig").Surface else if (builtin.os.tag == .windows) @import("windows/surface.zig").Surface else void;
pub const a11y = if (mac) @import("ui/a11y.zig") else struct {};

pub const App = plat.app.App;
pub const AppOptions = plat.app.Options;
pub const Window = plat.window.Window;
pub const WindowOptions = plat.window.Options;
pub const PageOptions = plat.window.PageOptions;
/// How high a window stacks (`WindowOptions.level`, `Window.setLevel`).
pub const WindowLevel = @import("window_types.zig").Level;
/// A connected screen (`App.screens`), the About panel's options
/// (`AppOptions.about`) and what full screen hides
/// (`App.setPresentationOptions`): macOS.
pub const Screen = if (mac) @import("screens.zig").Screen else void;
pub const About = if (mac) @import("app_extras.zig").About else void;
pub const Presentation = if (mac) @import("app_extras.zig").Presentation else void;
/// A page docked in a native-UI window (`Window.dockPage`), macOS.
pub const Page = if (mac) @import("page_webkit.zig").Page else void;
pub const Asset = plat.window.Asset;
/// Typed IPC for pages: wherever a webview draws them (macOS, iOS, Windows, Linux).
const has_pages = mac or builtin.os.tag == .ios or builtin.os.tag == .windows or (builtin.os.tag == .linux and !is_android);
const page_ipc = if (has_pages) @import("ipc.zig").ipc(plat.window.Window, plat.app.App) else struct {};
pub const Call = if (has_pages) page_ipc.Call else void;
pub const Event = if (has_pages) page_ipc.Event else void;

pub const menu = plat.menu;
pub const MenuItem = plat.menu.MenuItem;
pub const MenuRole = plat.menu.Role;
pub const Menu = plat.menu.Menu;
pub const MenuClick = plat.menu.Click;
pub const Tray = plat.tray.Tray;
pub const TrayOptions = plat.tray.Options;
pub const TrayClick = plat.tray.Click;
pub const TrayAnchor = plat.tray.Anchor;
pub const dialog = plat.dialog;
pub const fdwatch = plat.fdwatch;
pub const clipboard = plat.desktop.clipboard;
pub const shell = plat.desktop.shell;
pub const Directory = plat.desktop.Directory;
pub const path = plat.desktop.path;
pub const isDark = plat.desktop.isDark;
pub const accentColor = plat.desktop.accentColor;
/// Updates from GitHub's releases for a signed app bundle (macOS).
pub const update = @import("update.zig");
pub const Updater = update.Updater;
pub const UpdateOptions = update.Options;
/// Restarting into an update unseen (`Updater.autoRestart`).
pub const UpdateAuto = update.Auto;
/// Runs the event loop for a while (headless tests: replies, processes, timers).
pub const runFor = @import("platform.zig").runFor;

/// nanoui's version, from build.zig.zon (set with tools/version.sh).
pub const version = @import("build_options").version;

/// Minimal process entry (`main(init: nanoui.Init)`), with `panic` and
/// `std_options` delegated to `libnanoui-rt.a` so rebuilds after an edit
/// skip recompiling `std.Io.Threaded` and DWARF unwinding in the app's unit.
pub const Init = if (@import("rt.zig").desktop) std.process.Init.Minimal else std.process.Init;
pub const std_options: std.Options = .{
    .enable_segfault_handler = !@import("rt.zig").enabled,
    .allow_stack_tracing = !@import("rt.zig").enabled,
    .unexpected_error_tracing = !@import("rt.zig").enabled,
};
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
pub const panic = if (@import("rt.zig").enabled) std.debug.FullPanic(rtPanic) else std.debug.FullPanic(std.debug.defaultPanic);

fn rtPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    const Ext = struct {
        extern fn nanoui_rt_panic(ptr: [*]const u8, len: usize, addr: usize, has_addr: u8) callconv(.c) noreturn;
    };
    Ext.nanoui_rt_panic(msg.ptr, msg.len, first_trace_addr orelse 0, if (first_trace_addr != null) 1 else 0);
}

test {
    _ = tsgen;
    _ = ui;
    _ = kit;
    // A page's platform-free parts: the asset table, the origin, the bridge.
    _ = @import("tests_page.zig");
    std.testing.refAllDecls(kit);
    _ = @import("menu_types.zig");
    _ = @import("update.zig");
    _ = @import("update_auto.zig");
    // Pure, and tested on every platform: the rest of src/ios only compiles for iOS.
    _ = @import("ios/key_repeat.zig");
    _ = @import("basics/kv_file.zig");
    _ = @import("http.zig");
    _ = haptics;
    _ = location;
    _ = map;
    _ = directions;
    _ = kv;
    // The updater is for desktop apps; iOS updates through the App Store.
    if (builtin.os.tag != .ios) _ = @import("update_portable.zig");
    // The Windows tray's menu model and callback decoding, platform-free.
    if (builtin.os.tag != .ios) _ = @import("windows/tray_model.zig");
    if (is_android) {
        inline for (.{ plat.app, plat.window, plat.dialog, plat.desktop, plat.fdwatch, @import("android/surface.zig"), @import("android/keys.zig"), @import("android/touch.zig"), @import("android/activity.zig"), @import("android/bars.zig"), @import("android/egl.zig"), @import("android/jni.zig") }) |m| std.testing.refAllDecls(m);
        inline for (.{ plat.app.App, plat.window.Window, plat.desktop.clipboard, plat.desktop.shell, @import("android/surface.zig").Surface }) |T| std.testing.refAllDecls(T);
        return;
    }
    if (builtin.os.tag == .ios) {
        inline for (.{ plat.app, plat.window, plat.dialog, plat.desktop, plat.fdwatch, @import("ios/surface.zig"), @import("ios/keys.zig"), @import("ios/touch.zig") }) |m| std.testing.refAllDecls(m);
        inline for (.{ plat.app.App, plat.window.Window, plat.desktop.clipboard, plat.desktop.shell, @import("ios/surface.zig").Surface }) |T| std.testing.refAllDecls(T);
        return;
    }
    if (!mac) {
        inline for (.{
            plat.app,
            plat.window,
            plat.menu,
            plat.dialog,
            plat.desktop,
            plat.fdwatch,
        }) |m| std.testing.refAllDecls(m);
        if (builtin.os.tag == .windows) {
            _ = @import("windows/d3d.zig");
            _ = @import("windows/tests_surface.zig");
            // The window's own: styles, sizes, the close veto, the timers.
            _ = @import("windows/tests_window.zig");
            // Frames on the display's beat, gathered input, the frame log.
            _ = @import("windows/tests_pace.zig");
            // A title bar the app draws, frames kept between launches,
            // the icon, cursors and launch URLs.
            _ = @import("windows/chrome.zig");
            _ = @import("windows/window_place.zig");
            _ = @import("windows/tests_chrome.zig");
            _ = @import("windows/cursor.zig");
            _ = @import("windows/app.zig");
            // The notification area's icon: the shell calls and the popup.
            std.testing.refAllDecls(@import("windows/tray.zig").Tray);
            std.testing.refAllDecls(@import("windows/app.zig").App);
            // File drops: path/URL conversion and one HDROP as one event.
            _ = @import("windows/drop_files.zig");
            _ = @import("windows/tests_drop_files.zig");
            // The input method: its own tests, and the file itself for the
            // decode/mapping units.
            _ = @import("windows/ime.zig");
            _ = @import("windows/tests_ime.zig");
            // The open dialog, made and asked what it is, never shown.
            _ = @import("windows/tests_dialog.zig");
        }
        // The GTK window's: decorations, the taskbar hint, opacity.
        if (builtin.os.tag == .linux) _ = @import("linux/tests_window.zig");
        // A page in WebKitGTK, end to end, where one is installed.
        if (builtin.os.tag == .linux) _ = @import("linux/tests_page.zig");
        return;
    }
    // Analyze every declaration, used by an example or not.
    inline for (.{ @import("menu.zig"), @import("dialog.zig"), @import("desktop.zig"), @import("tray.zig"), @import("window.zig"), @import("app.zig"), @import("ui/textinput.zig"), @import("fdwatch.zig") }) |m| {
        std.testing.refAllDecls(m);
    }
    std.testing.refAllDecls(@import("desktop.zig").clipboard);
    std.testing.refAllDecls(@import("desktop.zig").shell);
    std.testing.refAllDecls(@import("window.zig").Window);
    std.testing.refAllDecls(@import("app.zig").App);
    std.testing.refAllDecls(@import("menu.zig").Menu);
    std.testing.refAllDecls(@import("menu.zig").Item);
    std.testing.refAllDecls(@import("tray.zig").Tray);
    // The window's own: borderless, out of the window cycle, its alpha.
    _ = @import("tests_window.zig");
    // Screens, the About panel's options, recent documents.
    _ = @import("screens.zig");
    _ = @import("app_extras.zig");
    // Windows opened while running and closed by the app, keys.
    _ = @import("tests_window_more.zig");
}

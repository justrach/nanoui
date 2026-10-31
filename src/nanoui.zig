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
        pub const tray = @import("tray_none.zig");
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
/// Components after GPUI Kit: buttons, overlays, tabs, forms, toasts.
pub const kit = @import("kit/kit.zig");
pub const tsgen = @import("tsgen.zig");
pub const Surface = if (mac) @import("ui/surface.zig").Surface else void;
pub const a11y = if (mac) @import("ui/a11y.zig") else struct {};

pub const App = plat.app.App;
pub const AppOptions = plat.app.Options;
pub const Window = plat.window.Window;
pub const WindowOptions = plat.window.Options;
pub const PageOptions = plat.window.PageOptions;
pub const Asset = plat.window.Asset;
/// Typed IPC for pages (macOS for now: pages need a webview).
pub const Call = if (mac) @import("ipc.zig").Call else void;
pub const Event = if (mac) @import("ipc.zig").Event else void;

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
/// Runs the event loop for a while (headless tests: replies, processes, timers).
pub const runFor = @import("platform.zig").runFor;

/// nanoui's version, from build.zig.zon (set with tools/version.sh).
pub const version = @import("build_options").version;

test {
    _ = tsgen;
    _ = ui;
    _ = kit;
    std.testing.refAllDecls(kit);
    _ = @import("menu_types.zig");
    _ = @import("update.zig");
    _ = @import("http.zig");
    // The updater is for desktop apps; iOS updates through the App Store.
    if (builtin.os.tag != .ios) _ = @import("update_portable.zig");
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
        inline for (.{ plat.app, plat.window, plat.menu, plat.dialog, plat.desktop, plat.fdwatch, }) |m| std.testing.refAllDecls(m);
        if (builtin.os.tag == .windows) {
            _ = @import("windows/d3d.zig");
            _ = @import("windows/tests_surface.zig");
            // The input method: its own tests, and the file itself for the
            // decode/mapping units.
            _ = @import("windows/ime.zig");
            _ = @import("windows/tests_ime.zig");
        }
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
}

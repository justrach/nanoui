//! The system's side of an iOS app: its delegates, and its scenes. With
//! `UIApplicationSupportsMultipleScenes` (`ios.Options.multiple_windows`) an
//! iPad gives an app several windows beside each other. The first scene shows
//! the app's stack of windows (`App.arrange`), as a phone does. Every other shows
//! one window, made with `.own_scene = true`: by the app, or for the system's
//! New Window through `App.onNewWindow`. Where there's one scene to a screen, a
//! window asking for its own goes on the stack like any other.
const std = @import("std");
const objc = @import("../objc.zig");
const App = @import("app.zig").App;
const Window = @import("window.zig").Window;

fn sharedApplication() objc.Object {
    return objc.msg(objc.Object, objc.class("UIApplication"), "sharedApplication", .{});
}

/// A window made with `.own_scene`, asking the system for its scene. False where
/// the device (a phone) or the bundle doesn't have them.
pub fn request(app: *App, w: *Window) bool {
    if (objc.msg(objc.BOOL, sharedApplication(), "supportsMultipleScenes", .{}) != objc.YES) return false;
    app.pending_scenes.append(app.gpa, w) catch return false;
    if (app.answering_scene) return true;
    objc.msg(void, sharedApplication(), "requestSceneSessionActivation:userActivity:options:errorHandler:", .{ @as(?objc.Object, null), @as(?objc.Object, null), @as(?objc.Object, null), @as(?*anyopaque, null) });
    return true;
}

/// A scene with no window asked for it: the system's New Window, or one restored.
fn connectOwn(app: *App, scene: objc.Object) void {
    if (app.pending_scenes.items.len == 0) if (app.on_new_window) |cb| {
        app.answering_scene = true;
        cb.func(cb.ctx, app);
        app.answering_scene = false;
    };
    if (app.pending_scenes.items.len == 0) return destroy(scene);
    const w = app.pending_scenes.orderedRemove(0);
    w.realize();
    const vc = w.controller orelse return destroy(scene);
    const win = objc.msg(objc.Object, objc.alloc("UIWindow"), "initWithWindowScene:", .{scene});
    w.scene_window = win;
    w.shown = true;
    objc.msg(void, scene, "setTitle:", .{objc.nsString(std.mem.sliceTo(&w.title, 0))});
    objc.msg(void, win, "setRootViewController:", .{vc});
    objc.msg(void, win, "makeKeyAndVisible", .{});
}

fn destroy(scene: objc.Object) void {
    objc.msg(void, sharedApplication(), "requestSceneSessionDestruction:options:errorHandler:", .{ objc.msg(objc.Object, scene, "session", .{}), @as(?objc.Object, null), @as(?*anyopaque, null) });
}

fn release(w: *Window) void {
    const win = w.scene_window orelse return;
    w.scene_window = null;
    objc.msg(void, win, "setRootViewController:", .{@as(?objc.Object, null)});
    objc.release(win);
}

/// The app closed a window with a scene of its own: the scene goes too.
pub fn closeOwn(w: *Window) void {
    const win = w.scene_window orelse return;
    if (objc.msg(?objc.Object, win, "windowScene", .{})) |scene| destroy(scene);
    release(w);
    // The app's own button closed it: the person stays in the app, not on the
    // Home screen, which is where a full-screen iPad goes otherwise.
    if (w.app.uiwindow) |main| if (objc.msg(?objc.Object, main, "windowScene", .{})) |scene| activateScene(scene);
}

fn activateScene(scene: objc.Object) void {
    objc.msg(void, sharedApplication(), "requestSceneSessionActivation:userActivity:options:errorHandler:", .{ objc.msg(objc.Object, scene, "session", .{}), @as(?objc.Object, null), @as(?objc.Object, null), @as(?*anyopaque, null) });
}

/// A window with a scene of its own, again in front.
pub fn activate(w: *Window) void {
    const win = w.scene_window orelse return;
    activateScene(objc.msg(?objc.Object, win, "windowScene", .{}) orelse return);
}

pub fn focused(w: *Window) bool {
    const win = w.scene_window orelse return false;
    const scene = objc.msg(?objc.Object, win, "windowScene", .{}) orelse return false;
    return objc.msg(objc.NSInteger, scene, "activationState", .{}) == 0;
}

pub fn defineClasses() objc.Class {
    _ = objc.defineClass(.{
        .name = "NanoUISceneDelegate",
        .superclass = "UIResponder",
        .protocols = &.{"UIWindowSceneDelegate"},
        .methods = &.{
            .{ .name = "scene:willConnectToSession:options:", .imp = &sceneConnect, .types = "v@:@@@" },
            .{ .name = "sceneDidBecomeActive:", .imp = &becameActive, .types = "v@:@" },
            .{ .name = "sceneWillEnterForeground:", .imp = &becameActive, .types = "v@:@" },
            .{ .name = "sceneDidEnterBackground:", .imp = &enteredBackground, .types = "v@:@" },
            .{ .name = "sceneDidDisconnect:", .imp = &sceneDisconnect, .types = "v@:@" },
            .{ .name = "window", .imp = &windowGetter, .types = "@@:" },
            .{ .name = "setWindow:", .imp = &windowSetter, .types = "v@:@" },
        },
    });
    return objc.defineClass(.{
        .name = "NanoUIAppDelegate",
        .superclass = "UIResponder",
        .protocols = &.{"UIApplicationDelegate"},
        .methods = &.{
            .{ .name = "application:didFinishLaunchingWithOptions:", .imp = &didFinishLaunching, .types = "B@:@@" },
            .{ .name = "application:configurationForConnectingSceneSession:options:", .imp = &sceneConfiguration, .types = "@@:@@@" },
            .{ .name = "applicationDidBecomeActive:", .imp = &becameActive, .types = "v@:@" },
            .{ .name = "applicationWillEnterForeground:", .imp = &becameActive, .types = "v@:@" },
            .{ .name = "applicationDidEnterBackground:", .imp = &enteredBackground, .types = "v@:@" },
            .{ .name = "window", .imp = &windowGetter, .types = "@@:" },
            .{ .name = "setWindow:", .imp = &windowSetter, .types = "v@:@" },
        },
    });
}

/// Whether Info.plist declares scenes: then the scene delegate shows the app.
fn usesScenes() bool {
    const bundle = objc.msg(objc.Object, objc.class("NSBundle"), "mainBundle", .{});
    return objc.msg(?objc.Object, bundle, "objectForInfoDictionaryKey:", .{objc.nsString("UIApplicationSceneManifest")}) != null;
}

fn didFinishLaunching(_: objc.Object, _: objc.SEL, _: objc.Object, _: ?objc.Object) callconv(.c) objc.BOOL {
    const app = App.shared() orelse return objc.YES;
    if (usesScenes()) return objc.YES;
    const screen = objc.msg(objc.Object, objc.class("UIScreen"), "mainScreen", .{});
    const bounds = objc.msg(objc.CGRect, screen, "bounds", .{});
    const win = objc.msg(objc.Object, objc.alloc("UIWindow"), "initWithFrame:", .{bounds});
    defer objc.release(win);
    app.attach(win);
    return objc.YES;
}

fn sceneConfiguration(_: objc.Object, _: objc.SEL, _: objc.Object, session: objc.Object, _: objc.Object) callconv(.c) objc.Object {
    const role = objc.msg(objc.Object, session, "role", .{});
    const config = objc.msg(objc.Object, objc.class("UISceneConfiguration"), "configurationWithName:sessionRole:", .{ @as(?objc.Object, null), role });
    objc.msg(void, config, "setDelegateClass:", .{objc.class("NanoUISceneDelegate")});
    return config;
}

fn sceneConnect(_: objc.Object, _: objc.SEL, scene: objc.Object, _: objc.Object, _: objc.Object) callconv(.c) void {
    const app = App.shared() orelse return;
    // One scene shows the app's stack of windows; others have one window each.
    if (app.uiwindow != null) return connectOwn(app, scene);
    // Connected in the background (a launch for a background task): no
    // frames until it comes forward (UISceneActivationStateBackground).
    if (objc.msg(objc.NSInteger, scene, "activationState", .{}) == 2) app.active = false;
    const win = objc.msg(objc.Object, objc.alloc("UIWindow"), "initWithWindowScene:", .{scene});
    defer objc.release(win);
    app.attach(win);
}

fn sceneDisconnect(_: objc.Object, _: objc.SEL, scene: objc.Object) callconv(.c) void {
    const app = App.shared() orelse return;
    if (app.uiwindow) |win| if (objc.msg(?objc.Object, win, "windowScene", .{}) == scene) return app.detach();
    // The person closed it: its window goes with it, its owner told.
    for (app.windows.items) |w| {
        const own = w.scene_window orelse continue;
        if (objc.msg(?objc.Object, own, "windowScene", .{}) != scene) continue;
        release(w);
        return w.close();
    }
}

fn becameActive(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    if (App.shared()) |app| app.setActive(true);
}

fn enteredBackground(_: objc.Object, _: objc.SEL, _: objc.Object) callconv(.c) void {
    const app = App.shared() orelse return;
    // One window going to the background isn't the app going there.
    if (!anyForeground()) app.setActive(false);
}

/// Whether a scene of the app is on screen: UISceneActivationState
/// foregroundActive 0, foregroundInactive 1, background 2.
fn anyForeground() bool {
    const scenes = objc.msg(objc.Object, sharedApplication(), "connectedScenes", .{});
    const all = objc.msg(objc.Object, scenes, "allObjects", .{});
    for (0..objc.msg(objc.NSUInteger, all, "count", .{})) |i| {
        const scene = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
        if (objc.msg(objc.NSInteger, scene, "activationState", .{}) < 2) return true;
    }
    return false;
}

fn windowGetter(_: objc.Object, _: objc.SEL) callconv(.c) ?objc.Object {
    const app = App.shared() orelse return null;
    return app.uiwindow;
}

fn windowSetter(_: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {}

//! Restarting into an update by itself, out of sight (`Updater.autoRestart`).
//!
//! Once an update is downloaded and verified (`ready`), the app restarts
//! into it when nobody would see that happen: it isn't the active app, no
//! window of it is key, and none is on screen (each is hidden, minimized or
//! covered). It must have stayed that way for `Auto.idle_ms`. Each time it
//! goes away (the app resigns active, a window hides or is covered) it asks
//! again. Nothing polls. While an update waits and the app stays in sight,
//! one slow timer (`Auto.away_ms`) also checks whether the person has left
//! the Mac (no input anywhere for that long); then it restarts even if it
//! is in front.
//!
//! Before restarting it writes `restore.json` to the app's cache directory.
//! The file holds the version it was, whether the app was active, each
//! window's frame and state (in the order they were made), and what
//! `Auto.save` wrote. The new copy is opened in the background (`open -g`),
//! told so by `NANOUI_RESTORE`. It doesn't activate or bring windows forward
//! (`App.quiet`). `autoRestart`, called once its windows exist, puts them
//! back where they were. The app reads its own state back with
//! `Updater.restoredState` and may say it was updated (`updatedFrom`).
//!
//! macOS only. Elsewhere `autoRestart` does nothing, and an update is
//! installed as the app quits (`Updater.deinit`).
const std = @import("std");
const builtin = @import("builtin");
const mac = builtin.os.tag == .macos;
const objc = if (mac) @import("objc.zig") else struct {};
const App = @import("nanoui.zig").App;
const Updater = @import("update.zig").Updater;

pub const Auto = struct {
    /// How long the app must have stayed out of sight before it restarts.
    idle_ms: u64 = 10 * 1000,
    /// How long with no input anywhere counts as away from the Mac: an app
    /// in sight then restarts too (and comes back in front).
    away_ms: u64 = 5 * 60 * 1000,
    /// Writes what the new copy needs to come back as it was (the open
    /// document, a scroll position, a draft). Main thread, just before the
    /// restart. `Updater.restoredState` hands it back.
    save: ?Save = null,
};

pub const Save = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, out: *std.Io.Writer) anyerror!void,
};

/// What a restart leaves for the next launch, as `restore.json`.
pub const Restore = struct {
    /// The version it restarted from.
    from: []const u8 = "",
    /// It was the active app (so the user was away): it comes back active.
    active: bool = false,
    windows: []const Placed = &.{},
    /// What `Auto.save` wrote, in base64.
    state: []const u8 = "",
};

/// One window: its frame in Cocoa's screen coordinates, and how it showed.
pub const Placed = struct {
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    visible: bool = false,
    /// On screen, not covered: put back in front (without activating).
    front: bool = false,
    minimized: bool = false,
    key: bool = false,
};

const file_name = "restore.json";
pub const env_name = "NANOUI_RESTORE";

/// Starts restarting `u` into updates out of sight, and puts back the
/// windows of a launch that such a restart opened.
pub fn enable(u: *Updater, app: *App, auto: Auto) void {
    if (comptime !mac) return;
    if (u.phase.load(.acquire) == .off) return;
    u.auto = auto;
    u.app = app;
    app.away_hook = .{ .ctx = u, .func = wentAway };
    // `App.quiet` stays set until launching finishes (`didFinishLaunching`):
    // cleared here, before the run loop, AppKit would still activate the app.
    if (u.restored) |r| place(app, r.value);
    consider(u);
}

/// Called when an update becomes ready and each time the app goes out of
/// sight: if one waits, the app restarts once it has stayed away `idle_ms`.
pub fn consider(u: *Updater) void {
    const auto = u.auto orelse return;
    if (u.ready() == null) return;
    // Timers all wait `idle_ms`, so they fire in order: the last one decides.
    u.auto_waits += 1;
    App.after(auto.idle_ms, u, idled);
}

fn wentAway(ctx: *anyopaque) void {
    consider(@ptrCast(@alignCast(ctx)));
}

fn idled(ctx: ?*anyopaque) callconv(.c) void {
    const u: *Updater = @ptrCast(@alignCast(ctx));
    u.auto_waits -= 1;
    if (u.auto_waits != 0) return;
    check(u);
}

fn awayed(ctx: ?*anyopaque) callconv(.c) void {
    const u: *Updater = @ptrCast(@alignCast(ctx));
    u.away_waits -= 1;
    check(u);
}

fn check(u: *Updater) void {
    const auto = u.auto orelse return;
    const app = u.app orelse return;
    if (u.ready() == null or app.stopping) return;
    if (unseen(app) or userAway(auto.away_ms)) return go(u, app, auto);
    // In sight: going away asks again; meanwhile one slow timer watches
    // for the person leaving the Mac.
    if (u.away_waits == 0) {
        u.away_waits += 1;
        App.after(auto.away_ms, u, awayed);
    }
}

/// Not active, no window key or on screen.
fn unseen(app: *App) bool {
    if (comptime !mac) return false;
    if (objc.msg(objc.BOOL, app.nsapp, "isActive", .{})) return false;
    for (app.windows.items) |w| {
        if (objc.msg(objc.BOOL, w.nswindow, "isKeyWindow", .{})) return false;
        if (onScreen(w.nswindow)) return false;
    }
    return true;
}

fn onScreen(nswindow: anytype) bool {
    return objc.msg(objc.BOOL, nswindow, "isVisible", .{}) and
        objc.msg(objc.NSUInteger, nswindow, "occlusionState", .{}) & 2 != 0;
}

extern "c" fn CGEventSourceSecondsSinceLastEventType(state: i32, event_type: u32) f64;

/// No key, click or move anywhere for `ms` (the HID system's own clock: it
/// needs no permission).
fn userAway(ms: u64) bool {
    if (comptime !mac) return false;
    const s = CGEventSourceSecondsSinceLastEventType(1, 0xFFFFFFFF);
    return s * 1000 >= @as(f64, @floatFromInt(ms));
}

/// Writes `restore.json`, then installs and relaunches.
fn go(u: *Updater, app: *App, auto: Auto) void {
    if (comptime !mac) return;
    const active = objc.msg(objc.BOOL, app.nsapp, "isActive", .{});
    const path = std.fs.path.join(u.gpa, &.{ u.cache, file_name }) catch return;
    defer u.gpa.free(path);
    const json = snapshot(u, app, auto, active) catch |e| {
        std.log.info("nanoui: no restore file: {t}", .{e});
        return;
    };
    defer u.gpa.free(json);
    std.Io.Dir.cwd().createDirPath(u.io, u.cache) catch {};
    std.Io.Dir.cwd().writeFile(u.io, .{ .sub_path = path, .data = json }) catch return;
    u.relaunch_env = if (active) env_name ++ "=active" else env_name ++ "=quiet";
    if (u.restart()) return app.quit();
    u.relaunch_env = null;
    std.Io.Dir.cwd().deleteFile(u.io, path) catch {};
}

fn snapshot(u: *Updater, app: *App, auto: Auto, active: bool) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(u.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var state: std.Io.Writer.Allocating = .init(a);
    if (auto.save) |s| try s.func(s.ctx, &state.writer);
    const windows = try a.alloc(Placed, app.windows.items.len);
    for (app.windows.items, windows) |w, *p| {
        const f = objc.msg(objc.CGRect, w.nswindow, "frame", .{});
        const visible = objc.msg(objc.BOOL, w.nswindow, "isVisible", .{});
        p.* = .{
            .x = f.origin.x,
            .y = f.origin.y,
            .w = f.size.width,
            .h = f.size.height,
            .visible = visible,
            .front = onScreen(w.nswindow),
            .minimized = objc.msg(objc.BOOL, w.nswindow, "isMiniaturized", .{}),
            .key = objc.msg(objc.BOOL, w.nswindow, "isKeyWindow", .{}),
        };
    }
    return encode(u.gpa, .{ .from = u.current, .active = active, .windows = windows }, state.written());
}

/// `restore` as JSON, with `state` in base64.
pub fn encode(gpa: std.mem.Allocator, restore: Restore, state: []const u8) ![]u8 {
    const enc = std.base64.standard.Encoder;
    const b64 = try gpa.alloc(u8, enc.calcSize(state.len));
    defer gpa.free(b64);
    var r = restore;
    r.state = enc.encode(b64, state);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.json.Stringify.value(r, .{}, &out.writer);
    return out.toOwnedSlice();
}

/// Parses `restore.json`; `state` is decoded into a slice the caller owns.
pub fn decode(gpa: std.mem.Allocator, json: []const u8, state: *[]u8) !std.json.Parsed(Restore) {
    const parsed = try std.json.parseFromSlice(Restore, gpa, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    errdefer parsed.deinit();
    const d = std.base64.standard.Decoder;
    const out = try gpa.alloc(u8, try d.calcSizeForSlice(parsed.value.state));
    errdefer gpa.free(out);
    try d.decode(out, parsed.value.state);
    state.* = out;
    return parsed;
}

/// At launch: what the restart before it left, if it was one (the
/// environment says so). A file left by anything else is dropped unread.
pub fn load(u: *Updater, env: *const std.process.Environ.Map) void {
    const path = std.fs.path.join(u.gpa, &.{ u.cache, file_name }) catch return;
    defer u.gpa.free(path);
    defer std.Io.Dir.cwd().deleteFile(u.io, path) catch {};
    if (env.get(env_name) == null) return;
    const json = std.Io.Dir.cwd().readFileAlloc(u.io, path, u.gpa, .limited(16 << 20)) catch return;
    defer u.gpa.free(json);
    u.restored = decode(u.gpa, json, &u.restored_state) catch |e| {
        std.log.info("nanoui: restore file unread: {t}", .{e});
        return;
    };
}

/// Puts the app's windows back as the restart found them, in order.
fn place(app: *App, r: Restore) void {
    if (comptime !mac) return;
    const n = @min(app.windows.items.len, r.windows.len);
    for (app.windows.items[0..n], r.windows[0..n]) |w, p| {
        const rect: objc.CGRect = .{ .origin = .{ .x = p.x, .y = p.y }, .size = .{ .width = p.w, .height = p.h } };
        if (p.w > 0 and p.h > 0) objc.msg(void, w.nswindow, "setFrame:display:", .{ rect, objc.NO });
        const none: ?objc.Object = null;
        if (p.minimized) {
            objc.msg(void, w.nswindow, "orderBack:", .{none});
            objc.msg(void, w.nswindow, "miniaturize:", .{none});
        } else if (p.visible and p.front) {
            objc.msg(void, w.nswindow, "orderFrontRegardless", .{});
        } else if (p.visible) {
            objc.msg(void, w.nswindow, "orderBack:", .{none});
        } else w.hide();
    }
    if (!r.active) return;
    objc.msg(void, app.nsapp, "activateIgnoringOtherApps:", .{objc.YES});
    for (app.windows.items[0..n], r.windows[0..n]) |w, p| if (p.key and p.visible) w.show();
}

test "every part builds here" {
    _ = &Updater.autoRestart;
    _ = &Updater.updatedFrom;
    _ = &Updater.restoredState;
    _ = &enable;
    _ = &load;
}

test "a restore file keeps the windows and the app's state" {
    const gpa = std.testing.allocator;
    const windows = [_]Placed{
        .{ .x = 10, .y = 20, .w = 640, .h = 480, .visible = true, .front = true, .key = true },
        .{ .w = 300, .h = 200, .minimized = true },
    };
    const json = try encode(gpa, .{ .from = "0.1.5", .active = true, .windows = &windows }, "draft: \x00\xff hello");
    defer gpa.free(json);
    var state: []u8 = &.{};
    const parsed = try decode(gpa, json, &state);
    defer parsed.deinit();
    defer gpa.free(state);
    try std.testing.expectEqualStrings("0.1.5", parsed.value.from);
    try std.testing.expect(parsed.value.active);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.windows.len);
    try std.testing.expectEqual(windows[0], parsed.value.windows[0]);
    try std.testing.expectEqual(windows[1], parsed.value.windows[1]);
    try std.testing.expectEqualStrings("draft: \x00\xff hello", state);
    // Nothing saved: an empty state, and a file from elsewhere is rejected.
    const bare = try encode(gpa, .{}, "");
    defer gpa.free(bare);
    var empty: []u8 = &.{};
    const p2 = try decode(gpa, bare, &empty);
    defer p2.deinit();
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
    try std.testing.expectError(error.SyntaxError, decode(gpa, "not json", &empty));
}

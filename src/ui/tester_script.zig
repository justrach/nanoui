//! `Tester.runScript`: a script of steps separated by `;`, as
//! `--nanoui-script` runs them.
//!
//! - `click:TEXT`, `move:TEXT`: at the middle of a text.
//! - `at:X,Y` and `hover:X,Y`: a click, or the pointer, at points.
//! - `down:X,Y`, `move:X,Y`, `up`: the pointer held down, moved and let
//!   go (a drag step by step), with the keys `mods:` holds.
//! - `mods:cmd+shift` (`mods:` for none): the modifier keys held.
//! - `drop:X,Y,PATH|PATH`: files (paths or URLs) dropped from another app.
//! - `type:TEXT`, `key:enter|backspace|tab|escape|left|right`,
//!   `chord:cmd+shift+n` (a key combination, as a window offers it).
//! - `scroll:DY` (at the pointer), `wait:SECONDS` (simulated time),
//!   `live:SECONDS` (the real event loop: replies, processes, timers),
//!   `resize:WxH`, `snap:PNG` (the frame so far, written).
//! - Anything else goes to `Tester.app_verbs`, if the app has some.
const std = @import("std");
const ctx_mod = @import("context.zig");
const Tester = @import("tester.zig").Tester;
const runFor = @import("../platform.zig").runFor;

pub fn run(t: *Tester, script: []const u8) !void {
    var steps = std.mem.splitScalar(u8, script, ';');
    while (steps.next()) |raw| {
        const step = std.mem.trim(u8, raw, " ");
        if (step.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, step, ':') orelse step.len;
        const op = step[0..colon];
        const arg = if (colon < step.len) step[colon + 1 ..] else "";
        if (try one(t, op, arg)) t.settle(2);
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Two numbers, `X,Y`.
pub fn point(arg: []const u8) ?[2]f32 {
    const comma = std.mem.indexOfScalar(u8, arg, ',') orelse return null;
    const x = std.fmt.parseFloat(f32, std.mem.trim(u8, arg[0..comma], " ")) catch return null;
    const y = std.fmt.parseFloat(f32, std.mem.trim(u8, arg[comma + 1 ..], " ")) catch return null;
    return .{ x, y };
}

/// Runs one step; whether to let animations settle after it.
fn one(t: *Tester, op: []const u8, arg: []const u8) !bool {
    if (eq(op, "click")) {
        try t.clickText(arg);
    } else if (eq(op, "rclick")) {
        const r = t.findText(arg) orelse return error.TextNotFound;
        t.rightClick(r.x + r.w / 2, r.y + r.h / 2);
    } else if (eq(op, "rat")) {
        const p = point(arg) orelse return error.BadPoint;
        t.rightClick(p[0], p[1]);
    } else if (eq(op, "move")) {
        if (point(arg)) |p| {
            t.move(p[0], p[1]);
        } else {
            const r = t.findText(arg) orelse return error.TextNotFound;
            t.moveTo(r.x + r.w / 2, r.y + r.h / 2);
        }
    } else if (eq(op, "down")) {
        const p = point(arg) orelse return error.BadPoint;
        t.down(p[0], p[1]);
    } else if (eq(op, "up")) {
        if (point(arg)) |p| t.move(p[0], p[1]);
        t.up();
    } else if (eq(op, "mods")) {
        var m: struct { cmd: bool = false, ctrl: bool = false, alt: bool = false, shift: bool = false } = .{};
        var parts = std.mem.splitScalar(u8, arg, '+');
        while (parts.next()) |raw| {
            const p = std.mem.trim(u8, raw, " ");
            const ieq = std.ascii.eqlIgnoreCase;
            if (p.len == 0) continue;
            if (ieq(p, "cmd")) m.cmd = true else if (ieq(p, "ctrl")) m.ctrl = true else if (ieq(p, "alt") or ieq(p, "opt")) m.alt = true else if (ieq(p, "shift")) m.shift = true else return error.UnknownKey;
        }
        t.setMods(.{ .cmd = m.cmd, .ctrl = m.ctrl, .alt = m.alt, .shift = m.shift });
    } else if (eq(op, "drop")) {
        try drop(t, arg);
    } else if (eq(op, "type")) {
        t.typeText(arg);
    } else if (eq(op, "key")) {
        t.key(std.meta.stringToEnum(ctx_mod.Key, arg) orelse return error.UnknownKey);
    } else if (eq(op, "scroll")) {
        t.scroll(t.ctx.input.mouse.x, t.ctx.input.mouse.y, try std.fmt.parseFloat(f32, arg));
    } else if (eq(op, "wait")) {
        t.advance(try std.fmt.parseFloat(f32, arg));
    } else if (eq(op, "live")) {
        const seconds = try std.fmt.parseFloat(f64, arg);
        var waited: f64 = 0;
        while (waited < seconds) : (waited += 0.05) {
            runFor(0.05);
            t.frame();
        }
    } else if (eq(op, "at") or eq(op, "hover")) {
        const p = point(arg) orelse return error.BadPoint;
        if (op[0] == 'a') t.click(p[0], p[1]) else t.moveTo(p[0], p[1]);
    } else if (eq(op, "chord")) {
        const s = ctx_mod.Shortcut.parse(arg) orelse return error.UnknownKey;
        _ = t.shortcut(s.native());
    } else if (eq(op, "snap")) {
        t.settle(2);
        try t.screenshot(arg);
        return false;
    } else if (eq(op, "resize")) {
        const x = std.mem.indexOfScalar(u8, arg, 'x') orelse return error.BadSize;
        t.resize(try std.fmt.parseFloat(f32, arg[0..x]), try std.fmt.parseFloat(f32, arg[x + 1 ..]));
    } else {
        const verbs = t.app_verbs orelse return error.UnknownStep;
        if (!try verbs.run(verbs.ctx, t, op, arg)) return error.UnknownStep;
    }
    return true;
}

/// `X,Y,PATH|PATH`: paths become file URLs, as a drop from Finder has them.
fn drop(t: *Tester, arg: []const u8) !void {
    const c1 = std.mem.indexOfScalar(u8, arg, ',') orelse return error.BadPoint;
    const c2 = c1 + 1 + (std.mem.indexOfScalar(u8, arg[c1 + 1 ..], ',') orelse return error.BadPoint);
    const p = point(arg[0..c2]) orelse return error.BadPoint;
    var arena: std.heap.ArenaAllocator = .init(t.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var urls: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, arg[c2 + 1 ..], '|');
    while (it.next()) |raw| {
        const path = std.mem.trim(u8, raw, " ");
        if (path.len == 0) continue;
        try urls.append(a, try fileUrl(a, path));
    }
    t.drop(p[0], p[1], urls.items, "");
}

/// `/a b.mov` as `file:///a%20b.mov`; a URL as it is.
pub fn fileUrl(a: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, path, "://") != null) return a.dupe(u8, path);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "file://");
    for (path) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-._~", ch) != null;
        if (plain) try out.append(a, ch) else try out.print(a, "%{X:0>2}", .{ch});
    }
    return out.items;
}

test "file URLs for dropped paths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("file:///tmp/a%20b.mov", try fileUrl(arena.allocator(), "/tmp/a b.mov"));
    try std.testing.expectEqualStrings("https://x.org/a", try fileUrl(arena.allocator(), "https://x.org/a"));
    try std.testing.expect(point("12, 30").?[1] == 30);
    try std.testing.expect(point("Play") == null);
}

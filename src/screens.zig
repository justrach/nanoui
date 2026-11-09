//! The Mac's screens (`App.screens`): each one's display id, frame and
//! visible frame in points from the primary screen's top left (as
//! `Window.frame` is), backing scale, whether it is the primary (the one
//! with the menu bar), and its name as System Settings shows it. For a
//! display picker and for windows placed on a given screen
//! (`Window.Options.screen`).
const std = @import("std");
const objc = @import("objc.zig");

pub const Rect = struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };

const EdgeInsets = extern struct { top: f64 = 0, left: f64 = 0, bottom: f64 = 0, right: f64 = 0 };

pub const Screen = struct {
    /// The display's id (NSScreenNumber, a CGDirectDisplayID): stable
    /// while it is connected.
    id: u32,
    frame: Rect,
    /// Without the menu bar and the Dock.
    visible: Rect,
    /// The camera housing's cutout at the top of the screen, in points from
    /// the primary screen's top left; null on displays without a notch.
    notch: ?Rect = null,
    /// Pixels per point (2 on a Retina display).
    scale: f64,
    primary: bool,
    name_buf: [96]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(s: *const Screen) []const u8 {
        return s.name_buf[0..s.name_len];
    }

    /// Height of the menu bar / top inset on this screen, in points.
    pub fn menuBarHeight(s: *const Screen) f64 {
        return @max(0, s.visible.y - s.frame.y);
    }

    /// True when this screen has a physical camera housing cutout (notch).
    pub fn hasNotch(s: *const Screen) bool {
        return s.notch != null;
    }

    /// Top-centered Dynamic Island / notch frame on this screen, at least as
    /// wide and tall as the physical notch when one is present.
    pub fn islandFrame(s: *const Screen, min_width: f64, min_height: f64) Rect {
        const w = if (s.notch) |n| @max(min_width, n.width) else min_width;
        const h = if (s.notch) |n| @max(min_height, n.height) else min_height;
        const cx = if (s.notch) |n| n.x + n.width / 2 else s.frame.x + s.frame.width / 2;
        return .{ .x = cx - w / 2, .y = s.frame.y, .width = w, .height = h };
    }
};

/// Every connected screen, the primary first, written into `out`.
pub fn list(out: []Screen) []Screen {
    const pool = objc.Pool.push();
    defer pool.pop();
    const all = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const n = objc.msg(objc.NSUInteger, all, "count", .{});
    if (n == 0) return out[0..0];
    const primary_h = objc.msg(objc.CGRect, objc.msg(objc.Object, all, "objectAtIndex:", .{@as(objc.NSUInteger, 0)}), "frame", .{}).size.height;
    var k: usize = 0;
    var i: objc.NSUInteger = 0;
    while (i < n and k < out.len) : (i += 1) {
        const sc = objc.msg(objc.Object, all, "objectAtIndex:", .{i});
        out[k] = describe(sc, primary_h, i == 0);
        k += 1;
    }
    return out[0..k];
}

/// The screen with display id `id`, if it is connected.
pub fn byId(id: u32) ?Screen {
    var buf: [16]Screen = undefined;
    for (list(&buf)) |s| if (s.id == id) return s;
    return null;
}

/// The primary screen (the menu bar's), if there is one.
pub fn primary() ?Screen {
    var buf: [1]Screen = undefined;
    const got = list(&buf);
    return if (got.len > 0) got[0] else null;
}

/// The active screen (`[NSScreen mainScreen]`), if there is one.
pub fn mainScreen() ?Screen {
    const pool = objc.Pool.push();
    defer pool.pop();
    const sc = objc.msg(?objc.Object, objc.class("NSScreen"), "mainScreen", .{}) orelse return primary();
    const all = objc.msg(objc.Object, objc.class("NSScreen"), "screens", .{});
    const n = objc.msg(objc.NSUInteger, all, "count", .{});
    if (n == 0) return null;
    const primary_obj = objc.msg(objc.Object, all, "objectAtIndex:", .{@as(objc.NSUInteger, 0)});
    const primary_h = objc.msg(objc.CGRect, primary_obj, "frame", .{}).size.height;
    return describe(sc, primary_h, sc == primary_obj);
}

/// True only when the active Mac screen has a physical camera notch
/// (built-in MacBook display with `safeAreaInsets.top > 0`). False on
/// desktop Macs and external monitors.
pub fn mainHasNotch() bool {
    const s = mainScreen() orelse return false;
    return s.notch != null;
}

fn describe(sc: objc.Object, primary_h: f64, is_primary: bool) Screen {
    const f = objc.msg(objc.CGRect, sc, "frame", .{});
    const v = objc.msg(objc.CGRect, sc, "visibleFrame", .{});
    const screen_frame = flip(f, primary_h);
    var safe_top: f64 = 0;
    var left_aux: Rect = .{};
    var right_aux: Rect = .{};
    if (objc.msg(objc.BOOL, sc, "respondsToSelector:", .{objc.sel("safeAreaInsets")})) {
        safe_top = objc.msg(EdgeInsets, sc, "safeAreaInsets", .{}).top;
    }
    if (safe_top > 0 and objc.msg(objc.BOOL, sc, "respondsToSelector:", .{objc.sel("auxiliaryTopLeftArea")})) {
        left_aux = flip(objc.msg(objc.CGRect, sc, "auxiliaryTopLeftArea", .{}), primary_h);
        right_aux = flip(objc.msg(objc.CGRect, sc, "auxiliaryTopRightArea", .{}), primary_h);
    }
    var s: Screen = .{
        .id = displayId(sc),
        .frame = screen_frame,
        .visible = flip(v, primary_h),
        .notch = computeNotch(screen_frame, safe_top, left_aux, right_aux),
        .scale = objc.msg(f64, sc, "backingScaleFactor", .{}),
        .primary = is_primary,
    };
    if (objc.msg(objc.BOOL, sc, "respondsToSelector:", .{objc.sel("localizedName")})) {
        const nm = objc.fromNSString(objc.msg(?objc.Object, sc, "localizedName", .{}));
        const len = @min(nm.len, s.name_buf.len);
        @memcpy(s.name_buf[0..len], nm[0..len]);
        s.name_len = @intCast(len);
    }
    return s;
}

/// Computes the camera notch rectangle from the screen's top-left `frame`,
/// `safeAreaInsets.top`, and the menu bar areas flanking the housing.
pub fn computeNotch(frame: Rect, safe_top: f64, left_aux: Rect, right_aux: Rect) ?Rect {
    if (safe_top <= 0 or frame.width <= 0) return null;
    const left_end = left_aux.x + left_aux.width;
    if (left_aux.width > 0 and right_aux.width > 0 and right_aux.x > left_end) {
        return .{ .x = left_end, .y = frame.y, .width = right_aux.x - left_end, .height = safe_top };
    }
    const fallback_w = @min(frame.width, 184.0);
    return .{ .x = frame.x + (frame.width - fallback_w) / 2, .y = frame.y, .width = fallback_w, .height = safe_top };
}

fn displayId(sc: objc.Object) u32 {
    const desc = objc.msg(objc.Object, sc, "deviceDescription", .{});
    const num = objc.msg(?objc.Object, desc, "objectForKey:", .{objc.nsString("NSScreenNumber")}) orelse return 0;
    return objc.msg(c_uint, num, "unsignedIntValue", .{});
}

/// AppKit's bottom-left origin to points from the primary's top left.
fn flip(r: objc.CGRect, primary_h: f64) Rect {
    return .{ .x = r.origin.x, .y = primary_h - r.origin.y - r.size.height, .width = r.size.width, .height = r.size.height };
}

test "screens: one at least, the first the primary, with an id, a size and a scale" {
    var buf: [16]Screen = undefined;
    const all = list(&buf);
    // A Mac with no display at all (a headless runner) has nothing to list.
    if (all.len == 0) return error.SkipZigTest;
    try std.testing.expect(all[0].primary);
    var primaries: usize = 0;
    for (all) |s| {
        if (s.primary) primaries += 1;
        try std.testing.expect(s.id != 0);
        try std.testing.expect(s.frame.width > 0 and s.frame.height > 0);
        try std.testing.expect(s.scale >= 1);
        try std.testing.expect(s.visible.height <= s.frame.height);
    }
    try std.testing.expectEqual(@as(usize, 1), primaries);
    // The primary's top left is the origin points are measured from.
    try std.testing.expectEqual(@as(f64, 0), all[0].frame.y);
    try std.testing.expectEqual(all[0].id, (byId(all[0].id) orelse return error.NotFound).id);
    try std.testing.expectEqual(all[0].id, primary().?.id);
}

test "screens: notch geometry and top-centered island frame" {
    const frame: Rect = .{ .x = 0, .y = 0, .width = 1512, .height = 982 };
    // External display: no safe-area top inset -> no physical notch.
    try std.testing.expect(computeNotch(frame, 0, .{}, .{}) == null);
    const ext: Screen = .{ .id = 1, .frame = frame, .visible = .{ .x = 0, .y = 25, .width = 1512, .height = 957 }, .scale = 2, .primary = true };
    try std.testing.expectEqual(@as(f64, 25), ext.menuBarHeight());
    const ext_isl = ext.islandFrame(260, 36);
    try std.testing.expectEqual(@as(f64, (1512.0 - 260.0) / 2.0), ext_isl.x);
    try std.testing.expectEqual(@as(f64, 0), ext_isl.y);
    try std.testing.expectEqual(@as(f64, 260), ext_isl.width);

    // Notched MacBook Pro: auxiliary areas flank a 184x38 notch.
    const notch = computeNotch(
        frame,
        38,
        .{ .x = 0, .y = 0, .width = 664, .height = 38 },
        .{ .x = 848, .y = 0, .width = 664, .height = 38 },
    ).?;
    try std.testing.expectEqual(@as(f64, 664), notch.x);
    try std.testing.expectEqual(@as(f64, 184), notch.width);
    try std.testing.expectEqual(@as(f64, 38), notch.height);
    const mbp: Screen = .{ .id = 2, .frame = frame, .visible = .{ .x = 0, .y = 38, .width = 1512, .height = 944 }, .notch = notch, .scale = 2, .primary = true };
    const compact = mbp.islandFrame(160, 30);
    // Clamped to at least the physical notch's 184x38 housing.
    try std.testing.expectEqual(@as(f64, 184), compact.width);
    try std.testing.expectEqual(@as(f64, 38), compact.height);
    try std.testing.expectEqual(@as(f64, 664), compact.x);
}

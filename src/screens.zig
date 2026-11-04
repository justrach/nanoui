//! The Mac's screens (`App.screens`): each one's display id, frame and
//! visible frame in points from the primary screen's top left (as
//! `Window.frame` is), backing scale, whether it is the primary (the one
//! with the menu bar), and its name as System Settings shows it. For a
//! display picker and for windows placed on a given screen
//! (`Window.Options.screen`).
const std = @import("std");
const objc = @import("objc.zig");

pub const Rect = struct { x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0 };

pub const Screen = struct {
    /// The display's id (NSScreenNumber, a CGDirectDisplayID): stable
    /// while it is connected.
    id: u32,
    frame: Rect,
    /// Without the menu bar and the Dock.
    visible: Rect,
    /// Pixels per point (2 on a Retina display).
    scale: f64,
    primary: bool,
    name_buf: [96]u8 = undefined,
    name_len: u8 = 0,

    pub fn name(s: *const Screen) []const u8 {
        return s.name_buf[0..s.name_len];
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

fn describe(sc: objc.Object, primary_h: f64, is_primary: bool) Screen {
    const f = objc.msg(objc.CGRect, sc, "frame", .{});
    const v = objc.msg(objc.CGRect, sc, "visibleFrame", .{});
    var s: Screen = .{
        .id = displayId(sc),
        .frame = flip(f, primary_h),
        .visible = flip(v, primary_h),
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

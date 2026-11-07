//! What's at a point in an app, through accessibility: an exact way to act
//! when events in the background are only a hope. Pressing what's there, and
//! scrolling what's there and reading whether it moved.
const std = @import("std");
const cf = @import("cf.zig");
const ax = @import("ax.zig");
const tree = @import("../tree.zig");

/// App `pid`'s element at x, y; release it.
fn at(pid: i32, x: f64, y: f64) ?cf.AXUIElementRef {
    const app = cf.AXUIElementCreateApplication(pid);
    defer cf.CFRelease(app);
    var el: ?cf.AXUIElementRef = null;
    if (cf.AXUIElementCopyElementAtPosition(app, @floatCast(x), @floatCast(y), &el) != 0) return null;
    return el;
}

fn role(buf: []u8, el: cf.AXUIElementRef) []const u8 {
    return ax.copyText(buf, el, "AXRole");
}

/// `el`'s parent; release it.
fn parent(el: cf.AXUIElementRef) ?cf.AXUIElementRef {
    return @ptrCast(ax.copy(el, "AXParent"));
}

/// Whether `el` is inside a web page. Chrome answers AXPress on a page's button
/// with success and doesn't act on it, so a page's controls get a click event,
/// whose reply doesn't claim more than it knows.
pub fn inWebPage(el: cf.AXUIElementRef) bool {
    var buf: [64]u8 = undefined;
    var at_el: cf.AXUIElementRef = @ptrCast(cf.CFRetain(el));
    defer cf.CFRelease(at_el);
    for (0..64) |_| {
        if (std.mem.eql(u8, role(&buf, at_el), "AXWebArea")) return true;
        const up = parent(at_el) orelse return false;
        cf.CFRelease(at_el);
        at_el = up;
    }
    return false;
}

/// Presses what's at x, y if it's a control, going up from the label or icon
/// inside it. Writes the control's role into `buf`; null if nothing was pressed.
pub fn press(buf: []u8, pid: i32, x: f64, y: f64) ?[]const u8 {
    var el = at(pid, x, y) orelse return null;
    defer cf.CFRelease(el);
    if (inWebPage(el)) return null;
    for (0..4) |_| {
        const r = role(buf, el);
        if (tree.pressable(r)) return if (ax.perform(el, "AXPress")) tree.bareRole(r) else null;
        if (!tree.insideControl(r)) return null;
        const up = parent(el) orelse return null;
        cf.CFRelease(el);
        el = up;
    }
    return null;
}

pub const Bar = enum { vertical, horizontal };

fn barName(bar: Bar) []const u8 {
    return switch (bar) {
        .vertical => "AXVerticalScrollBar",
        .horizontal => "AXHorizontalScrollBar",
    };
}

/// The scroll area around x, y; release it.
fn scrollArea(pid: i32, x: f64, y: f64) ?cf.AXUIElementRef {
    var el = at(pid, x, y) orelse return null;
    var buf: [64]u8 = undefined;
    for (0..32) |_| {
        if (std.mem.eql(u8, role(&buf, el), "AXScrollArea")) return el;
        const up = parent(el) orelse break;
        cf.CFRelease(el);
        el = up;
    }
    cf.CFRelease(el);
    return null;
}

fn value(bar: cf.AXUIElementRef) ?f64 {
    const v = ax.copy(bar, "AXValue") orelse return null;
    defer cf.CFRelease(v);
    if (cf.CFGetTypeID(v) != cf.CFNumberGetTypeID()) return null;
    var d: f64 = 0;
    return if (cf.CFNumberGetValue(@ptrCast(v), cf.number_double, &d)) d else null;
}

/// How far along it is scrolled, 0 to 1, on each axis, of what has a scroll bar.
pub const Position = struct {
    vertical: ?f64 = null,
    horizontal: ?f64 = null,

    pub fn known(p: Position) bool {
        return p.vertical != null or p.horizontal != null;
    }

    /// Whether anything moved since `before`.
    pub fn moved(p: Position, before: Position) bool {
        const near = struct {
            fn f(a: ?f64, b: ?f64) bool {
                return @abs((a orelse 0) - (b orelse 0)) < 1e-6;
            }
        }.f;
        return !near(p.vertical, before.vertical) or !near(p.horizontal, before.horizontal);
    }

    /// Whether it can't go that way anyway: the end of the document, not a failure.
    pub fn atEnd(p: Position, dx: f64, dy: f64) bool {
        const stuck = struct {
            fn f(v: ?f64, d: f64) bool {
                if (d == 0) return true;
                const at_ = v orelse return false;
                return if (d > 0) at_ >= 0.999 else at_ <= 0.001;
            }
        }.f;
        return stuck(p.vertical, dy) and stuck(p.horizontal, dx);
    }
};

/// The scroll position at x, y.
pub fn position(pid: i32, x: f64, y: f64) Position {
    const area = scrollArea(pid, x, y) orelse return .{};
    defer cf.CFRelease(area);
    var out: Position = .{};
    if (ax.copy(area, barName(.vertical))) |b| {
        defer cf.CFRelease(b);
        out.vertical = value(@ptrCast(b));
    }
    if (ax.copy(area, barName(.horizontal))) |b| {
        defer cf.CFRelease(b);
        out.horizontal = value(@ptrCast(b));
    }
    return out;
}

/// The share of the whole a move of `lines` lines is, in a view with `hidden`
/// points scrolled out of sight (a guess at the line's height).
pub fn lineShare(lines: f64, hidden: f64) f64 {
    const line_points = 16;
    return if (hidden > 1) lines * line_points / hidden else lines * 0.05;
}

/// How many points of the area's content are out of sight on an axis.
fn hiddenPoints(area: cf.AXUIElementRef, bar: Bar) f64 {
    const view = ax.frame(area) orelse return 0;
    const contents = cf.array(ax.copy(area, "AXContents")) orelse return 0;
    defer cf.CFRelease(contents);
    if (cf.CFArrayGetCount(contents) < 1) return 0;
    const first = cf.CFArrayGetValueAtIndex(contents, 0) orelse return 0;
    const inner = ax.frame(@ptrCast(first)) orelse return 0;
    return switch (bar) {
        .vertical => inner[3] - view[3],
        .horizontal => inner[2] - view[2],
    };
}

fn moveBar(area: cf.AXUIElementRef, bar: Bar, lines: f64) void {
    if (lines == 0) return;
    const b = ax.copy(area, barName(bar)) orelse return;
    defer cf.CFRelease(b);
    const now = value(@ptrCast(b)) orelse return;
    const next = std.math.clamp(now + lineShare(lines, hiddenPoints(area, bar)), 0, 1);
    const n = cf.CFNumberCreate(null, cf.number_double, &next) orelse return;
    defer cf.CFRelease(n);
    _ = ax.set(@ptrCast(b), "AXValue", n);
}

/// Scrolls through the scroll bars themselves, for an app that ignored the
/// wheel. The caller reads whether that worked.
pub fn scrollBars(pid: i32, x: f64, y: f64, dx: f64, dy: f64) void {
    const area = scrollArea(pid, x, y) orelse return;
    defer cf.CFRelease(area);
    moveBar(area, .vertical, dy);
    moveBar(area, .horizontal, dx);
}

test "scroll positions: moved, and the end of the document" {
    const p: Position = .{ .vertical = 0.5 };
    try std.testing.expect(p.known());
    try std.testing.expect(!(Position{}).known());
    try std.testing.expect(!p.moved(.{ .vertical = 0.5 }));
    try std.testing.expect(p.moved(.{ .vertical = 0.25 }));
    try std.testing.expect(!(Position{ .vertical = 0.5 }).atEnd(0, 10));
    try std.testing.expect((Position{ .vertical = 1 }).atEnd(0, 10));
    try std.testing.expect((Position{ .vertical = 0 }).atEnd(0, -10));
    try std.testing.expect(!(Position{ .vertical = 0 }).atEnd(0, 10));
    try std.testing.expect(!(Position{ .vertical = 1 }).atEnd(5, 10)); // no way to know sideways
}

test "a line's share of what is out of sight" {
    try std.testing.expectEqual(@as(f64, 0.1), lineShare(10, 1600));
    try std.testing.expectEqual(@as(f64, -0.1), lineShare(-10, 1600));
    try std.testing.expectEqual(@as(f64, 0.5), lineShare(10, 0)); // unknown: a guess
}

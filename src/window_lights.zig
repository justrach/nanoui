//! The traffic lights where a window's own top bar wants them (macOS): set in
//! from the corner and centered in a bar taller than a title bar. AppKit has
//! no setting for this short of a toolbar, which also changes the window's
//! corners, so the title bar is grown and the three buttons are put in place
//! by hand; AppKit lays them out again whenever it sees fit (a resize, full
//! screen, the window becoming key), and each time they are put back.
const objc = @import("objc.zig");

extern "c" const NSViewFrameDidChangeNotification: objc.Object;

const close_button: objc.NSUInteger = 0;
const zoom_button: objc.NSUInteger = 2;
const full_screen_mask: objc.NSUInteger = 1 << 14;

pub const Lights = struct {
    /// Where the close button's center goes, from the window's top left.
    x: f64,
    y: f64,
    /// AppKit's own distance between the buttons, read once: read on every
    /// pass it can be caught halfway through AppKit's layout, one button
    /// moved and the next not yet.
    spacing: f64,
    /// Moving them is what tells us they moved.
    placing: bool = false,
    /// One final placement after AppKit finishes the current layout stack.
    pending: bool = false,

    pub fn init(window: objc.Object, x: f64, y: f64) Lights {
        var spacing: f64 = 20;
        if (button(window, 0)) |a| if (button(window, 1)) |b| {
            const measured = frameOf(b).origin.x - frameOf(a).origin.x;
            if (measured >= 16 and measured <= 32) spacing = measured;
        };
        return .{ .x = x, .y = y, .spacing = spacing };
    }

    /// Has `observer`'s `lightsMoved:` told when the title bar's views move:
    /// the surest sign AppKit has just laid them out again.
    pub fn observe(window: objc.Object, observer: objc.Object) void {
        const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
        const first = button(window, close_button) orelse return;
        const bar = objc.msg(?objc.Object, first, "superview", .{}) orelse return;
        const container = objc.msg(?objc.Object, bar, "superview", .{}) orelse return;
        var views: [5]objc.Object = .{ container, bar, first, first, first };
        var n: usize = 3;
        for (1..3) |i| if (button(window, i)) |b| {
            views[n] = b;
            n += 1;
        };
        for (views[0..n]) |v| {
            objc.msg(void, v, "setPostsFrameChangedNotifications:", .{objc.YES});
            objc.msg(void, center, "addObserver:selector:name:object:", .{ observer, objc.sel("lightsMoved:"), NSViewFrameDidChangeNotification, v });
        }
    }

    pub fn stopObserving(observer: objc.Object) void {
        const center = objc.msg(objc.Object, objc.class("NSNotificationCenter"), "defaultCenter", .{});
        objc.msg(void, center, "removeObserver:", .{observer});
    }

    /// Puts the buttons in place. Full screen keeps its title bar in a
    /// window of its own, laid out by macOS: it is left to it.
    pub fn place(l: *Lights, window: objc.Object) void {
        if (l.placing or objc.msg(objc.NSUInteger, window, "styleMask", .{}) & full_screen_mask != 0) return;
        const first = button(window, close_button) orelse return;
        const bar = objc.msg(?objc.Object, first, "superview", .{}) orelse return;
        const container = objc.msg(?objc.Object, bar, "superview", .{}) orelse return;
        l.placing = true;
        defer l.placing = false;

        // A title bar tall enough for the buttons to sit lower in it, its
        // top at the window's.
        const height = l.y * 2;
        const window_h = frameOf(window).size.height;
        var frame = frameOf(container);
        if (frame.size.height != height or frame.origin.y + frame.size.height != window_h) {
            frame.size.height = height;
            frame.origin.y = window_h - height;
            objc.msg(void, container, "setFrame:", .{frame});
        }
        const bar_h = objc.msg(objc.CGRect, bar, "bounds", .{}).size.height;
        for (close_button..zoom_button + 1) |i| {
            const b = button(window, i) orelse continue;
            const f = frameOf(b);
            const origin: objc.CGPoint = .{
                .x = l.x - f.size.width / 2 + @as(f64, @floatFromInt(i)) * l.spacing,
                .y = bar_h - l.y - f.size.height / 2,
            };
            if (f.origin.x != origin.x or f.origin.y != origin.y) objc.msg(void, b, "setFrameOrigin:", .{origin});
        }
    }
};

fn button(window: objc.Object, which: usize) ?objc.Object {
    return objc.msg(?objc.Object, window, "standardWindowButton:", .{@as(objc.NSUInteger, which)});
}

fn frameOf(o: objc.Object) objc.CGRect {
    return objc.msg(objc.CGRect, o, "frame", .{});
}

//! The traffic lights where a window's own top bar wants them (macOS): set in
//! from the corner and centered in a bar taller than a title bar. AppKit has
//! no setting for this short of a toolbar, which also changes the window's
//! corners, so the title bar is grown and the three buttons are put in place
//! by hand; AppKit lays them out again whenever it sees fit (a resize, full
//! screen, the window becoming key), and each time they are put back.
const objc = @import("objc.zig");
const types = @import("ui/types.zig");

extern "c" const NSViewFrameDidChangeNotification: objc.Object;

const close_button: objc.NSUInteger = 0;
const zoom_button: objc.NSUInteger = 2;
const full_screen_mask: objc.NSUInteger = 1 << 14;

pub const Lights = struct {
    /// Where the close button's center goes, from the window's top left.
    x: f64,
    y: f64,
    /// AppKit's own initial placement for the close button, read once
    /// before moving anything so reverting to a 28pt bar can restore it.
    default_x: f64,
    default_y: f64,
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
        var default_x: f64 = 20;
        var default_y: f64 = 14;
        if (button(window, 0)) |a| {
            const bounds = objc.msg(objc.CGRect, a, "bounds", .{});
            const at = objc.msg(objc.CGPoint, a, "convertPoint:toView:", .{
                objc.CGPoint{ .x = bounds.size.width / 2, .y = bounds.size.height / 2 },
                @as(?objc.Object, null),
            });
            const win_h = frameOf(window).size.height;
            if (at.x >= 8 and at.x <= 48) default_x = at.x;
            const dy = win_h - at.y;
            if (dy >= 8 and dy <= 40) default_y = dy;
            if (button(window, 1)) |b| {
                const measured = frameOf(b).origin.x - frameOf(a).origin.x;
                if (measured >= 16 and measured <= 32) spacing = measured;
            }
        }
        return .{ .x = x, .y = y, .default_x = default_x, .default_y = default_y, .spacing = spacing };
    }

    pub fn autoX(default_x: f64, y: f64) f64 {
        return @min(28.0, @max(default_x, y));
    }

    /// Keeps macOS traffic lights synced with either an explicit per-frame
    /// point (`ctx_lights`), the view's `title_bar_height`, or `options_lights`.
    pub fn sync(w: anytype, ctx_lights: ?types.Point, title_bar_height: f32) void {
        if (!w.can_place_lights) return;
        var tx: f64 = undefined;
        var ty: f64 = undefined;
        var base: ?Lights = w.lights;
        if (ctx_lights) |p| {
            tx = @floatCast(p.x);
            ty = @floatCast(p.y);
        } else if (title_bar_height != 28) {
            ty = @as(f64, title_bar_height) * 0.5;
            if (w.options_lights) |opt| {
                if (@abs(opt.x - opt.y) > 0.5) {
                    tx = opt.x;
                } else {
                    if (base == null) base = init(w.nswindow, 0, 0);
                    tx = autoX(base.?.default_x, ty);
                }
            } else {
                if (base == null) base = init(w.nswindow, 0, 0);
                tx = autoX(base.?.default_x, ty);
            }
        } else if (w.options_lights) |opt| {
            tx = opt.x;
            ty = opt.y;
        } else if (w.lights) |l| {
            tx = l.default_x;
            ty = l.default_y;
        } else return;

        if (w.lights) |*l| {
            if (@abs(l.x - tx) < 0.01 and @abs(l.y - ty) < 0.01) return;
            l.x = tx;
            l.y = ty;
            l.place(w.nswindow);
        } else {
            var next = base orelse init(w.nswindow, tx, ty);
            next.x = tx;
            next.y = ty;
            w.lights = next;
            observe(w.nswindow, w.delegate);
            w.lights.?.place(w.nswindow);
        }
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
        // top at the window's (and shrunk cleanly back down to 28pt if needed).
        const height = @max(28.0, l.y * 2.0);
        const window_h = frameOf(window).size.height;
        var frame = frameOf(container);
        if (frame.size.height != height or frame.origin.y + frame.size.height != window_h) {
            frame.size.height = height;
            frame.origin.y = window_h - height;
            objc.msg(void, container, "setFrame:", .{frame});
        }
        var bar_frame = frameOf(bar);
        if (bar_frame.size.height != height or bar_frame.origin.y != 0) {
            bar_frame.size.height = height;
            bar_frame.origin.y = 0;
            objc.msg(void, bar, "setFrame:", .{bar_frame});
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

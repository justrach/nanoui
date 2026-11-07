//! Selecting text with a finger, as iOS's own views do: holding on text selects
//! its word, the selection's handles drag its ends with the loupe over the
//! finger, and letting go shows the edit menu. The handles are drawn by nanoui
//! (`ui/handles.zig`), so they look the same on every iOS it runs on; the loupe
//! (iOS 17) and the menu (iOS 16) are the system's, and on older systems there
//! are handles alone. The selection itself stays the field's or the page's, set
//! through the same press and drag a mouse gives them.
const std = @import("std");
const objc = @import("../objc.zig");
const types = @import("../ui/types.zig");
const handles = @import("../ui/handles.zig");
const haptics = @import("../basics/haptics.zig");
const Surface = @import("surface.zig").Surface;
const keys = @import("keys.zig");

extern "c" fn objc_getClass(name: [*:0]const u8) ?objc.Class;

/// Seconds a finger holds still before it selects: UIKit's long press.
const hold: u64 = 450 * std.time.ns_per_ms;
/// Further than this from where it landed, it's not holding still.
const drift: f32 = 10;

pub const State = struct {
    /// Which touch a long press waits for: older ones find it changed.
    serial: u32 = 0,
    /// Holding selected: the finger's release shows the menu, and clicks nothing.
    held: bool = false,
    handle: ?handles.Which = null,
    /// From the finger to the handle's grip, kept as it drags.
    offset: types.Point = .{},
    loupe: ?objc.Object = null,
    menu: ?objc.Object = null,
    menu_view: ?objc.Object = null,
    /// Where the selection was when its menu came up, while it's up.
    menu_at: ?types.Rect = null,

    pub fn deinit(st: *State) void {
        if (st.loupe) |l| {
            objc.msg(void, l, "invalidate", .{});
            objc.release(l);
        }
        if (st.menu) |m| objc.release(m);
        st.* = .{};
    }
};

pub const view_methods = [_]objc.Method{
    .{ .name = "canPerformAction:withSender:", .imp = &canPerform, .types = "B@::@" },
    .{ .name = "copy:", .imp = &copyAction, .types = "v@:@" },
};

/// The page's selection, from the edit menu. A field's goes to its own view,
/// which is the first responder then (`textinput.zig`).
fn canPerform(obj: objc.Object, _: objc.SEL, action: objc.SEL, _: ?objc.Object) callconv(.c) objc.BOOL {
    const s = objc.getZig(Surface, obj) orelse return objc.NO;
    if (s.dead or action != objc.sel("copy:")) return objc.NO;
    return if (s.ctx.selection.text.items.len > 0) objc.YES else objc.NO;
}

fn copyAction(obj: objc.Object, _: objc.SEL, _: ?objc.Object) callconv(.c) void {
    const s = objc.getZig(Surface, obj) orelse return;
    if (s.dead) return;
    const c = &s.ctx;
    c.clipboard.write(c.clipboard.ctx, c.selection.text.items);
}

const Waiting = struct { view: objc.Object, serial: u32, gpa: std.mem.Allocator };

/// A finger landed on nothing of the selection's: it may yet hold still.
pub fn pressed(s: *Surface) void {
    const st = &s.selecting;
    dismissMenu(st);
    st.held = false;
    st.serial +%= 1;
    const w = s.gpa.create(Waiting) catch return;
    // The view outlives the surface: a surface gone by then finds it empty.
    w.* = .{ .view = objc.retain(s.uiview), .serial = st.serial, .gpa = s.gpa };
    objc.dispatchAfter(hold, w, waited);
}

fn waited(ctx: ?*anyopaque) callconv(.c) void {
    const w: *Waiting = @ptrCast(@alignCast(ctx.?));
    const view = w.view;
    const serial = w.serial;
    w.gpa.destroy(w);
    defer objc.release(view);
    const s = Surface.enter(view) orelse return;
    defer s.leave();
    if (s.dead or s.selecting.serial != serial) return;
    const t = &s.touch;
    if (t.finger == null or t.second != null or t.scrolling or t.stopper) return;
    if (@abs(t.last.x - t.start.x) > drift or @abs(t.last.y - t.start.y) > drift) return;
    select(s, t.last);
}

fn overText(s: *Surface) bool {
    const c = &s.ctx;
    if (c.focused_text) |f| if (c.hot == f.id) return true;
    for (c.selection.lines.items) |r| if (r.contains(c.input.mouse)) return true;
    return false;
}

/// The finger held still: its word, as two clicks select it.
fn select(s: *Surface, p: types.Point) void {
    const c = &s.ctx;
    c.input.mouse = p;
    c.updateHot();
    if (!overText(s)) return;
    c.input.click_count = 2;
    c.input.pressed = true;
    s.frame();
    if (s.dead) return;
    // Its release isn't a click on whatever the text is in.
    c.selection.moved = true;
    s.selecting.held = true;
    haptics.selection();
    beginLoupe(s, p);
}

/// A finger landed: takes it if it's on a handle.
pub fn takeHandle(s: *Surface, p: types.Point) bool {
    const e = handles.ends(&s.ctx) orelse return false;
    const which = handles.at(e, p) orelse return false;
    const grip = handles.grip(e, which) orelse return false;
    const st = &s.selecting;
    dismissMenu(st);
    st.serial +%= 1;
    st.handle = which;
    st.offset = .{ .x = grip.x - p.x, .y = grip.y - p.y };
    const c = &s.ctx;
    if (c.focused_text) |f| if (f.ends != null) {
        // The other end stays. Shift keeps it, as a mouse's Shift-click does.
        const lo = @min(f.caret, f.anchor);
        const hi = @max(f.caret, f.anchor);
        keys.pushOp(s, .{ .select = if (which == .start) .{ .anchor = hi, .caret = lo } else .{ .anchor = lo, .caret = hi } });
        if (s.dead) return true;
        c.input.mouse = grip;
        c.updateHot();
        c.input.shift = true;
        c.input.click_count = 1;
        c.pointerDown();
        s.frame();
        c.input.shift = false;
        if (!s.dead) beginLoupe(s, p);
        return true;
    };
    const sel = &c.selection;
    const o = sel.ordered() orelse return true;
    sel.anchor = if (which == .start) o[1] else o[0];
    sel.focus = if (which == .start) o[0] else o[1];
    sel.dragging = true;
    sel.moved = true;
    c.input.down = true;
    c.input.mouse = grip;
    s.frame();
    if (!s.dead) beginLoupe(s, p);
    return true;
}

/// The finger moved, on a handle or after holding. True if it was on a handle.
pub fn moved(s: *Surface, p: types.Point) bool {
    const st = &s.selecting;
    moveLoupe(s, p);
    if (st.handle == null) return false;
    const c = &s.ctx;
    c.input.mouse = .{ .x = p.x + st.offset.x, .y = p.y + st.offset.y };
    c.updateHot();
    s.frame();
    return true;
}

/// The finger's up. True if it was on a handle.
pub fn released(s: *Surface) bool {
    const st = &s.selecting;
    endLoupe(st);
    st.serial +%= 1;
    const on_handle = st.handle != null;
    st.handle = null;
    if (on_handle) s.ctx.pointerUp();
    return on_handle;
}

/// After the release's frame: what it leaves on screen.
pub fn settled(s: *Surface, tapped: bool) void {
    const st = &s.selecting;
    if (st.held or !tapped) {
        st.held = false;
        showMenu(s);
    } else if (s.ctx.selection.anchor != null) {
        // A tap anywhere lets the page's selection go, as on iOS. Not the
        // press: scrolling keeps it.
        s.ctx.selection.clear();
        s.requestFrame();
    }
}

/// The system took the touch.
pub fn cancelled(s: *Surface) void {
    const st = &s.selecting;
    endLoupe(st);
    st.serial +%= 1;
    st.held = false;
    st.handle = null;
}

fn beginLoupe(s: *Surface, p: types.Point) void {
    const st = &s.selecting;
    if (st.loupe != null) return;
    const cls = objc_getClass("UITextLoupeSession") orelse return;
    const session = objc.msg(?objc.Object, cls, "beginLoupeSessionAtPoint:fromSelectionWidgetView:inView:", .{ objc.CGPoint{ .x = p.x, .y = p.y }, @as(?objc.Object, null), s.uiview }) orelse return;
    st.loupe = objc.retain(session);
}

fn moveLoupe(s: *Surface, p: types.Point) void {
    const l = s.selecting.loupe orelse return;
    const e = handles.ends(&s.ctx) orelse return;
    const r = (if (s.selecting.handle == .start) e.start else e.end) orelse return;
    const caret: objc.CGRect = .{ .origin = .{ .x = r.x, .y = r.y }, .size = .{ .width = 2, .height = r.h } };
    objc.msg(void, l, "moveToPoint:withCaretRect:trackingCaret:", .{ objc.CGPoint{ .x = p.x, .y = p.y }, caret, objc.YES });
}

fn endLoupe(st: *State) void {
    const l = st.loupe orelse return;
    objc.msg(void, l, "invalidate", .{});
    objc.release(l);
    st.loupe = null;
}

/// Copy, Cut and Paste over the selection. Asked of the first responder, so
/// the menu is added to it: the field's hidden view, or the surface's.
fn showMenu(s: *Surface) void {
    const e = handles.ends(&s.ctx) orelse return;
    const r = e.start orelse e.end orelse return;
    const cls = objc_getClass("UIEditMenuInteraction") orelse return;
    const config_cls = objc_getClass("UIEditMenuConfiguration") orelse return;
    const st = &s.selecting;
    const view = if (s.ctx.focused_text != null) s.keys.input orelse s.uiview else s.uiview;
    if (st.menu_view != view) {
        if (st.menu) |m| {
            if (st.menu_view) |old| objc.msg(void, old, "removeInteraction:", .{m});
            objc.release(m);
        }
        const m = objc.msg(objc.Object, objc.msg(objc.Object, cls, "alloc", .{}), "initWithDelegate:", .{@as(?objc.Object, null)});
        objc.msg(void, view, "addInteraction:", .{m});
        st.menu = m;
        st.menu_view = view;
    }
    const pool = objc.Pool.push();
    defer pool.pop();
    const from = objc.msg(objc.CGPoint, s.uiview, "convertPoint:toView:", .{ objc.CGPoint{ .x = r.x, .y = r.y }, view });
    const config = objc.msg(objc.Object, config_cls, "configurationWithIdentifier:sourcePoint:", .{ @as(?objc.Object, null), from });
    objc.msg(void, st.menu.?, "presentEditMenuWithConfiguration:", .{config});
    st.menu_at = r;
}

/// After a frame: the menu points at the selection, so it goes when the selection
/// moves without a finger (new content pushing it, the keyboard, a resize).
pub fn afterFrame(s: *Surface) void {
    const st = &s.selecting;
    const at = st.menu_at orelse return;
    const e = handles.ends(&s.ctx) orelse return dismissMenu(st);
    const r = e.start orelse e.end orelse return dismissMenu(st);
    if (r.x != at.x or r.y != at.y) dismissMenu(st);
}

fn dismissMenu(st: *State) void {
    st.menu_at = null;
    if (st.menu) |m| objc.msg(void, m, "dismissMenu", .{});
}

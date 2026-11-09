//! A drag inside a window that carries a value of the app's from one box
//! to another (a bin card onto the timeline): it starts when a box made a
//! `dragSource` is pressed and moved past `threshold`, holds the pointer
//! however far it leaves that box (across panels, over the window's
//! edge), and lands on the `dropTarget` under the pointer when let go.
//! Escape gives it up. Not the system's drag (`Context.startDrag`): the
//! value never leaves the app, and the app draws the drag's preview
//! (`dragging` says where).
//!
//!     const card = c.open(style, key);
//!     _ = ui.dragSource(c, card, clip_index);
//!     ...
//!     if (ui.dragOver(c, lane_rect)) |clip| ghost(c, clip);
//!     if (ui.dropTarget(c, lane_rect)) |clip| s.place(clip, c.input.mouse);
//!
//! Rects are in window points (`c.rects`, the last frame's layout).
const std = @import("std");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

/// How far (points, any direction) a pressed source moves before it drags.
pub const threshold: f32 = 4;

/// The drag between frames (`Context.payload_drag`).
pub const State = struct {
    /// The pressed source's box id (0: none).
    source: u64 = 0,
    payload: u64 = 0,
    press_at: types.Point = .{},
    dragging: bool = false,
    /// The frame it was let go in: drops are taken during that frame only.
    released_frame: ?u64 = null,
    /// A drop target took it (each drag lands once, whatever rebuilds).
    taken: bool = false,
};

/// What a source box did this frame.
pub const Source = struct {
    /// Dragging now, the pointer down.
    dragging: bool,
    /// Let go after a drag this frame (a drop or not): not a click.
    released: bool,
    /// The box's own interaction (hover, a click when it wasn't dragged).
    interaction: ctx_mod.Interaction,
};

/// The drag under way, for the app's preview.
pub const Active = struct {
    payload: u64,
    /// The pointer, in window points.
    point: types.Point,
    /// Where it was pressed.
    from: types.Point,
    source: u64,
};

/// Makes box `index` (just opened) a drag source carrying `payload`.
pub fn dragSource(c: *Context, index: u32, payload: u64) Source {
    const it = c.interact(index, .{});
    const st = &c.payload_drag;
    expire(c);
    if (it.pressed and c.input.pressed and st.source != it.id) {
        st.* = .{ .source = it.id, .payload = payload, .press_at = c.input.mouse };
    }
    if (st.source == it.id and st.released_frame == null) {
        if (c.input.down) {
            if (!st.dragging) {
                const dx = c.input.mouse.x - st.press_at.x;
                const dy = c.input.mouse.y - st.press_at.y;
                if (dx * dx + dy * dy >= threshold * threshold) st.dragging = true;
            }
            st.payload = payload;
        }
    }
    settle(c);
    const mine = st.source == it.id;
    if (mine and st.dragging and st.released_frame == null) c.cursor = .closed_hand;
    return .{
        .dragging = mine and st.dragging and st.released_frame == null,
        .released = mine and st.dragging and st.released_frame == c.frame,
        .interaction = it,
    };
}

/// The drag, while one is under way (the pointer down, past the threshold).
pub fn dragging(c: *Context) ?Active {
    expire(c);
    settle(c);
    const st = c.payload_drag;
    if (!st.dragging or st.released_frame != null) return null;
    return .{ .payload = st.payload, .point = c.input.mouse, .from = st.press_at, .source = st.source };
}

/// The payload being dragged over `rect`, while the pointer is down.
pub fn dragOver(c: *Context, rect: types.Rect) ?u64 {
    const a = dragging(c) orelse return null;
    return if (rect.contains(a.point)) a.payload else null;
}

/// The payload let go over `rect` in this frame, once: the drop.
pub fn dropTarget(c: *Context, rect: types.Rect) ?u64 {
    expire(c);
    settle(c);
    const st = &c.payload_drag;
    if (!st.dragging or st.taken or st.released_frame != c.frame) return null;
    if (!rect.contains(c.input.mouse)) return null;
    st.taken = true;
    c.changed = true;
    return st.payload;
}

/// Gives up the drag under way: nothing lands.
pub fn cancel(c: *Context) void {
    c.payload_drag = .{};
}

/// The pointer came up: a drag ends this frame, a press that never
/// dragged is forgotten. Escape gives the drag up.
fn settle(c: *Context) void {
    const st = &c.payload_drag;
    if (st.source == 0 or st.released_frame != null) return;
    if (st.dragging and c.input.key == .escape) {
        c.input.key = null;
        st.* = .{};
        c.changed = true;
        return;
    }
    if (c.input.down) return;
    if (st.dragging) {
        st.released_frame = c.frame;
        c.changed = true;
    } else st.* = .{};
}

/// A drag let go in an earlier frame is over.
fn expire(c: *Context) void {
    const f = c.payload_drag.released_frame orelse return;
    if (c.frame > f) c.payload_drag = .{};
}

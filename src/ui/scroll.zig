//! Vertical and horizontal scrolling, rubber-band overscroll on precise
//! trackpad gestures, and overlay scrollers with hover widening and thumb
//! scrubbing.
const std = @import("std");
const types = @import("types.zig");
const metal = @import("gpu.zig");
const motion = @import("motion.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

const salt_overscroll: u32 = 0x6f76_7363;
const salt_bar_flash: u32 = 0x6261_7200;
const salt_bar_width: u32 = 0x6261_7277;

pub const ScrollbarGeom = struct {
    track_x: f32,
    track_y: f32,
    track_h: f32,
    thumb_y: f32,
    thumb_h: f32,
    max_scroll: f32,
};

pub const ScrollbarDrag = struct {
    id: u64,
    grab_dy: f32,
};

pub fn isHolding(c: *const Context) bool {
    return c.scroll_holding or (c.input.precise and (c.input.scroll_phase == .began or c.input.scroll_phase == .changed));
}

pub fn hasOverscroll(c: *const Context) bool {
    var it = c.overscroll.valueIterator();
    while (it.next()) |v| if (@abs(v.*) > 0.05) return true;
    return false;
}

pub fn capScroll(c: *Context, id: u64, offset: f32) void {
    c.scroll_cap.put(c.gpa, id, @max(0, offset)) catch {};
}

pub fn scrollMoved(c: *Context, id: u64) bool {
    return c.scroll_moved.contains(id);
}

/// Scrolls the innermost scrolling box under the pointer.
pub fn applyScroll(c: *Context, dy: f32) bool {
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (h.scroll and h.rect.contains(c.input.mouse)) {
            const gop = c.scroll.getOrPut(c.gpa, h.id) catch return false;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            if (!isHolding(c)) {
                gop.value_ptr.* = @max(0, gop.value_ptr.* - dy);
                return true;
            }
            const ov_gop = c.overscroll.getOrPut(c.gpa, h.id) catch return false;
            if (!ov_gop.found_existing) ov_gop.value_ptr.* = 0;
            var over = ov_gop.value_ptr.*;
            var cur = gop.value_ptr.*;
            var delta = -dy;
            if (over < 0 and delta > 0) {
                const step = @min(-over, delta * 0.35);
                over += step;
                delta -= step / 0.35;
            } else if (over > 0 and delta < 0) {
                const step = @min(over, -delta * 0.35);
                over -= step;
                delta += step / 0.35;
            }
            const max_s = c.scroll_max.get(h.id) orelse std.math.inf(f32);
            const next = cur + delta;
            if (next < 0) {
                cur = 0;
                over += next * 0.35;
            } else if (next > max_s) {
                cur = max_s;
                over += (next - max_s) * 0.35;
            } else {
                cur = next;
            }
            gop.value_ptr.* = cur;
            ov_gop.value_ptr.* = over;
            motion.jump(c, h.id, salt_overscroll, over);
            return true;
        }
    }
    return false;
}

/// Resolves vertical scroll and rubber-band overscroll for box `n` in `layout.arrange`.
pub fn arrangeScrollY(c: *Context, n: *const ctx_mod.Node, inner_main: f32, used: f32) f32 {
    const st = n.style;
    const max_scroll = @max(0, used - inner_main);
    if (st.follow_end) {
        const prev_max = c.scroll_max.get(n.id) orelse 0;
        const gop = c.scroll.getOrPut(c.gpa, n.id) catch null;
        if (gop) |g| {
            var follow = c.scroll_follow.get(n.id) orelse true;
            if (!g.found_existing) {
                follow = true;
            } else if (c.scroll_seen.get(n.id)) |seen| {
                if (g.value_ptr.* != seen) {
                    follow = g.value_ptr.* >= prev_max - 1;
                    c.scroll_moved.put(c.gpa, n.id, {}) catch {};
                }
            }
            if (follow) {
                const want = if (c.scroll_cap.get(n.id)) |cap| @min(max_scroll, cap) else max_scroll;
                if (g.value_ptr.* != want) c.animating = true;
                g.value_ptr.* = want;
            }
            c.scroll_follow.put(c.gpa, n.id, follow) catch {};
        }
    }
    c.scroll_max.put(c.gpa, n.id, max_scroll) catch {};
    var scroll_y: f32 = 0;
    if (c.scroll.getPtr(n.id)) |s| {
        s.* = @min(s.*, max_scroll);
        scroll_y = s.*;
        if (st.follow_end) c.scroll_seen.put(c.gpa, n.id, s.*) catch {};
    }
    if (c.overscroll.getPtr(n.id)) |ov| {
        if (isHolding(c)) {
            motion.jump(c, n.id, salt_overscroll, ov.*);
            scroll_y += ov.*;
        } else if (@abs(ov.*) > 0.05) {
            ov.* = motion.spring(c, n.id, salt_overscroll, 0, .{ .response = 0.28, .damping = 1.0 });
            if (@abs(ov.*) <= 0.05) ov.* = 0;
            scroll_y += ov.*;
        } else ov.* = 0;
    }
    return scroll_y;
}

fn scrubTo(c: *Context, id: u64, g: ScrollbarGeom, thumb_top: f32) void {
    const travel = @max(1.0, g.track_h - g.thumb_h);
    const t = std.math.clamp((thumb_top - g.track_y) / travel, 0, 1);
    c.scroll.put(c.gpa, id, t * g.max_scroll) catch {};
    c.changed = true;
}

pub fn tryPressScrollbar(c: *Context) bool {
    if (c.input.button != .left or c.input.ctrl) return false;
    const m = c.input.mouse;
    var it = c.scrollbars.iterator();
    while (it.next()) |e| {
        const id = e.key_ptr.*;
        const g = e.value_ptr.*;
        if (c.hot != 0 and c.hot != id) continue;
        if (m.x >= g.track_x and m.x <= g.track_x + 10 and m.y >= g.track_y and m.y <= g.track_y + g.track_h) {
            if (m.y >= g.thumb_y and m.y <= g.thumb_y + g.thumb_h) {
                c.scrollbar_drag = .{ .id = id, .grab_dy = m.y - g.thumb_y };
            } else {
                const grab = g.thumb_h * 0.5;
                c.scrollbar_drag = .{ .id = id, .grab_dy = grab };
                scrubTo(c, id, g, m.y - grab);
            }
            c.hot = 0;
            c.active = 0;
            return true;
        }
    }
    return false;
}

pub fn updateScrollbarDrag(c: *Context) void {
    if (!c.input.down) {
        c.scrollbar_drag = null;
        return;
    }
    const d = c.scrollbar_drag orelse return;
    const g = c.scrollbars.get(d.id) orelse return;
    scrubTo(c, d.id, g, c.input.mouse.y - d.grab_dy);
}

pub fn paintScrollbars(c: *Context, out: *std.ArrayList(metal.Instance), n: ctx_mod.Node, visible: types.Rect, opacity: f32) void {
    const st = n.style;
    const dragging = if (c.scrollbar_drag) |d| d.id == n.id else false;
    const over_bar = dragging or (visible.contains(c.input.mouse) and c.input.mouse.x >= n.rect.x + n.rect.w - 10);
    if (st.scroll and st.scroll_bar and visible.contains(c.input.mouse)) c.wants_moves = true;
    const moved = (c.scroll.get(n.id) orelse 0) + (c.scroll_x.get(n.id) orelse 0);
    var bar: f32 = if (st.scroll_bar_fades) motion.flash(c, n.id, salt_bar_flash, moved, 0.8, 0.3) else 1;
    if (over_bar and bar > 0) {
        bar = 1;
        _ = motion.flash(c, n.id, salt_bar_flash, moved + 0.0001, 0.8, 0.3);
        _ = motion.flash(c, n.id, salt_bar_flash, moved, 0.8, 0.3);
    }
    if (st.scroll and st.scroll_bar) paintScrollbar(c, out, n, visible, opacity * bar, over_bar);
    if (st.scroll_x and st.scroll_bar and bar > 0) paintScrollbarX(c, out, n, visible, opacity * bar);
}

fn paintScrollbar(c: *Context, out: *std.ArrayList(metal.Instance), n: ctx_mod.Node, visible: types.Rect, opacity: f32, over_bar: bool) void {
    if (n.first_child == none) return;
    const first = c.node(n.first_child).rect;
    const last = c.node(n.last_child).rect;
    const content_h = last.y + last.h - first.y + n.style.padding.vertical();
    const view_h = n.rect.h;
    if (content_h <= view_h + 0.5) return;
    const offset = c.scroll.get(n.id) orelse 0;
    const bar_h = @max(24, view_h * view_h / content_h);
    const t = offset / (content_h - view_h);
    const y = n.rect.y + (view_h - bar_h) * std.math.clamp(t, 0, 1);
    if (opacity <= 0) return;
    c.scrollbars.put(c.gpa, n.id, .{
        .track_x = n.rect.x + n.rect.w - 10,
        .track_y = n.rect.y,
        .track_h = view_h,
        .thumb_y = y,
        .thumb_h = bar_h,
        .max_scroll = content_h - view_h,
    }) catch {};
    const raw_w = motion.tween(c, n.id, salt_bar_width, if (over_bar) 7.0 else 4.0, 0.15, .ease_out);
    const w_bar: f32 = if (@abs(raw_w - 4.0) < 0.01) 4.0 else raw_w;
    out.append(c.gpa, .{
        .rect = .{ n.rect.x + n.rect.w - 3 - w_bar, y + 2, w_bar, bar_h - 4 },
        .color = metal.color4(c.theme.muted.alpha(0.5 * opacity)),
        .radius = if (w_bar == 4.0) 2.0 else w_bar * 0.5,
        .clip = metal.clip4(visible),
    }) catch {};
}

fn paintScrollbarX(c: *Context, out: *std.ArrayList(metal.Instance), n: ctx_mod.Node, visible: types.Rect, opacity: f32) void {
    const offset = c.scroll_x.get(n.id) orelse 0;
    var x0: f32 = std.math.inf(f32);
    var x1: f32 = -std.math.inf(f32);
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        const ch = c.node(child);
        if (ch.style.absolute) continue;
        x0 = @min(x0, ch.rect.x);
        x1 = @max(x1, ch.rect.x + ch.rect.w);
    }
    if (x1 <= x0) return;
    const content_w = x1 - x0 + n.style.padding.horizontal();
    const view_w = n.rect.w;
    if (content_w <= view_w + 0.5) return;
    const bar_w = @max(24, view_w * view_w / content_w);
    const t = offset / (content_w - view_w);
    const x = n.rect.x + (view_w - bar_w) * std.math.clamp(t, 0, 1);
    out.append(c.gpa, .{
        .rect = .{ x + 2, n.rect.y + n.rect.h - 7, bar_w - 4, 4 },
        .color = metal.color4(c.theme.muted.alpha(0.5 * opacity)),
        .radius = 2,
        .clip = metal.clip4(visible),
    }) catch {};
}

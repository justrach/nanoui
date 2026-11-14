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

/// Whether the topmost scrolling box under the pointer reads the wheel
/// itself (`Style.wheel`): it gets the wheel's vertical deltas in
/// `input.scroll`, as a view that sets `wants_wheel` does.
pub fn wheelAt(c: *const Context) bool {
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (h.scroll and h.rect.contains(c.input.mouse)) return h.wheel;
    }
    return false;
}

/// Finger travel becomes a bounded displacement: responsive at the edge,
/// progressively firmer on a long pull. Keep this separate from the logical
/// scroll offset, so stretching the bottom never releases `follow_end`.
fn rubberBand(travel: f32, limit: f32) f32 {
    const resisted = @abs(travel) * 0.55;
    const shown = limit * (resisted / (limit + resisted));
    return if (travel < 0) -shown else shown;
}

/// Recover finger travel before adding another event. Applying resistance
/// independently to each delta would make a coalesced gesture feel different
/// from the same pull delivered as many small events, and break reversal.
fn rubberTravel(shown: f32, limit: f32) f32 {
    const magnitude = @min(@abs(shown), limit - 0.001);
    const travel = magnitude * limit / (0.55 * (limit - magnitude));
    return if (shown < 0) -travel else travel;
}

/// Scrolls the innermost scrolling box under the pointer.
pub fn applyScroll(c: *Context, dy: f32) bool {
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (h.scroll and h.rect.contains(c.input.mouse)) {
            // A box that takes the wheel itself is over the one behind.
            if (h.wheel) return false;
            const gop = c.scroll.getOrPut(c.gpa, h.id) catch return false;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            if (!isHolding(c)) {
                const previous = gop.value_ptr.*;
                const next = @max(0, previous - dy);
                gop.value_ptr.* = next;
                const max_s = c.scroll_max.get(h.id) orelse std.math.inf(f32);
                // A native fling gets one bounded impact when it crosses the
                // bottom. Later momentum deltas at that edge must not keep
                // pumping the spring or move the logical follow-end offset.
                if (c.input.precise and c.input.scroll_phase == .momentum and next > max_s) {
                    if (!c.reduced_motion and !c.reduce_motion and previous < max_s) {
                        const limit = @max(1, @min(160, h.rect.h));
                        const over = rubberBand(next - max_s, limit);
                        c.overscroll.put(c.gpa, h.id, over) catch {};
                        motion.jump(c, h.id, salt_overscroll, over);
                        // A retained scene only translates the logical offset;
                        // the impact and its recovery need fresh layout/paint.
                        c.retain.scroll_scene_ok = false;
                    }
                    gop.value_ptr.* = max_s;
                }
                if (dy != 0) c.retain.scroll_delta = true;
                return true;
            }
            const ov_gop = c.overscroll.getOrPut(c.gpa, h.id) catch return false;
            if (!ov_gop.found_existing) ov_gop.value_ptr.* = 0;
            var over = ov_gop.value_ptr.*;
            var cur = gop.value_ptr.*;
            var delta = -dy;
            // Use the viewport, not the content height, so a long pull
            // asymptotically resists instead of sliding far off the edge.
            const limit = @max(1, @min(160, h.rect.h));
            if (over != 0) {
                const travel = rubberTravel(over, limit) + delta;
                if ((over < 0 and travel <= 0) or (over > 0 and travel >= 0)) {
                    over = rubberBand(travel, limit);
                    delta = 0;
                } else {
                    over = 0;
                    delta = travel;
                }
            }
            const max_s = c.scroll_max.get(h.id) orelse std.math.inf(f32);
            const next = cur + delta;
            if (next < 0) {
                cur = 0;
                over = rubberBand(next, limit);
            } else if (next > max_s) {
                cur = max_s;
                over = rubberBand(next - max_s, limit);
            } else {
                cur = next;
            }
            gop.value_ptr.* = cur;
            ov_gop.value_ptr.* = over;
            if (dy != 0 and @abs(over) <= 0.05) c.retain.scroll_delta = true;
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
    if (c.input.button != .left or (@import("keys.zig").mac and c.input.ctrl)) return false;
    const m = c.input.mouse;
    // The bar is drawn over the box's right edge and has no hit box of its own,
    // so whatever is under the pointer there belongs to a row or to nothing:
    // the pointer being on the track decides, not `hot`. Of the tracks under it
    // the innermost wins, so a list inside a page scrolls itself, not the page.
    //
    // The exception is a control that reaches the edge: a button flush against
    // the scroll box's right side is under the track, and the press is the
    // button's. Without this the 10 points of track swallow it and the button
    // never fires.
    if (c.hot_index != none and c.hot_index < c.nodes.items.len and c.node(c.hot_index).interactive) return false;
    var found: ?struct { id: u64, g: ScrollbarGeom } = null;
    var it = c.scrollbars.iterator();
    while (it.next()) |e| {
        const g = e.value_ptr.*;
        if (m.x >= g.track_x and m.x <= g.track_x + 10 and m.y >= g.track_y and m.y <= g.track_y + g.track_h) {
            if (found == null or g.track_h < found.?.g.track_h) found = .{ .id = e.key_ptr.*, .g = g };
        }
    }
    const f = found orelse return false;
    if (m.y >= f.g.thumb_y and m.y <= f.g.thumb_y + f.g.thumb_h) {
        c.scrollbar_drag = .{ .id = f.id, .grab_dy = m.y - f.g.thumb_y };
    } else {
        // A press on the track moves the thumb to the pointer, then drags.
        const grab = f.g.thumb_h * 0.5;
        c.scrollbar_drag = .{ .id = f.id, .grab_dy = grab };
        scrubTo(c, f.id, f.g, m.y - grab);
    }
    c.hot = 0;
    c.active = 0;
    return true;
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
    if (st.scroll and st.scrollbar == .overlay) {
        paintOverlayScrollbar(c, out, n, visible, opacity);
        if (st.scroll_x and st.scroll_bar) paintScrollbarX(c, out, n, visible, opacity);
        return;
    }
    const dragging = if (c.scrollbar_drag) |d| d.id == n.id else false;
    const over_bar = dragging or (visible.contains(c.input.mouse) and c.input.mouse.x >= n.rect.x + n.rect.w - 10);
    const moved = (c.scroll.get(n.id) orelse 0) + (c.scroll_x.get(n.id) orelse 0);
    const idle_hides = st.scroll_bar_idle > 0;
    const fade_dur: f32 = if (idle_hides) @min(0.24, st.scroll_bar_idle * 0.25) else 0.3;
    const hold_dur: f32 = if (idle_hides) @max(0, st.scroll_bar_idle - fade_dur) else 0.8;
    var bar: f32 = if (idle_hides or st.scroll_bar_fades) motion.flash(c, n.id, salt_bar_flash, moved, hold_dur, fade_dur) else 1;
    // `scroll_bar_idle` keeps the rail visible only while scrolling or dragging
    // the thumb; stationary pointer hover lets the idle countdown finish.
    if (dragging or (!idle_hides and over_bar and bar > 0)) {
        bar = 1;
        if (idle_hides or st.scroll_bar_fades) {
            _ = motion.flash(c, n.id, salt_bar_flash, moved + 0.0001, hold_dur, fade_dur);
            bar = motion.flash(c, n.id, salt_bar_flash, moved, hold_dur, fade_dur);
        }
    }
    if (st.scroll and st.scroll_bar and bar > 0 and visible.contains(c.input.mouse)) c.wants_moves = true;
    if (st.scroll and st.scroll_bar) paintScrollbar(c, out, n, visible, opacity * bar, over_bar);
    if (st.scroll_x and st.scroll_bar and bar > 0) paintScrollbarX(c, out, n, visible, opacity * bar);
}

/// How long an overlay bar stays after the box last scrolled, then how
/// long it takes to fade (GPUI's `MENU_SCROLLBAR_LINGER_MS`, `_FADE_MS`).
const overlay_linger: f64 = 1.4;
const overlay_fade: f64 = 0.26;

fn paintOverlayBar(c: *Context, out: *std.ArrayList(metal.Instance), n: ctx_mod.Node, visible: types.Rect, opacity: f32, offset: f32, view_h: f32, content_h: f32, t: f32) void {
    const color = n.style.scrollbar.overlay;
    const gop = c.overlay_bars.getOrPut(c.gpa, n.id) catch return;
    // First seen: nothing has scrolled yet.
    if (!gop.found_existing) gop.value_ptr.* = .{ .offset = offset, .moved_at = -1e9 };
    if (gop.value_ptr.offset != offset) gop.value_ptr.* = .{ .offset = offset, .moved_at = c.time };
    const strip: types.Rect = .{ .x = n.rect.x + n.rect.w - 10, .y = n.rect.y, .w = 10, .h = n.rect.h };
    const held = strip.contains(c.input.mouse);
    const since = c.time - gop.value_ptr.moved_at;
    const fade: f32 = if (held) 1 else @floatCast(std.math.clamp(1 - (since - overlay_linger) / overlay_fade, 0, 1));
    if (!held and since < overlay_linger + overlay_fade) {
        // Wake for the fade's start, then step through it.
        c.frameIn(@floatCast(if (since < overlay_linger) overlay_linger - since else 1.0 / 60.0));
    }
    if (fade <= 0) return;
    const inset: f32 = 4;
    const track = view_h - 2 * inset;
    const bar_h = @max(24, track * view_h / content_h);
    const w: f32 = if (held) 5 else 3;
    out.append(c.gpa, .{
        .rect = .{ n.rect.x + n.rect.w - 2 - w, n.rect.y + inset + (track - bar_h) * std.math.clamp(t, 0, 1), w, bar_h },
        .color = metal.color4(color.alpha(color.a * @as(f32, if (held) 0.68 / 0.5 else 1) * fade * opacity)),
        .radius = w / 2,
        .clip = metal.clip4(visible),
    }) catch {};
}

fn paintOverlayScrollbar(c: *Context, out: *std.ArrayList(metal.Instance), n: ctx_mod.Node, visible: types.Rect, opacity: f32) void {
    const offset = c.scroll.get(n.id) orelse 0;
    if (n.first_child == none) return;
    const first = c.node(n.first_child).rect;
    const last = c.node(n.last_child).rect;
    const content_h = last.y + last.h - first.y + n.style.padding.vertical();
    const view_h = n.rect.h;
    if (content_h <= view_h + 0.5) return;
    const t = offset / (content_h - view_h);
    paintOverlayBar(c, out, n, visible, opacity, offset, view_h, content_h, t);
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

/// Scrolls the box that scrolls around the focused text field until its
/// caret is above `bottom` (in view points: what iOS's keyboard leaves),
/// as a UIScrollView does for its field. True when it scrolled: draw
/// another frame.
pub fn revealCaret(c: *Context, bottom: f32) bool {
    const f = c.focused_text orelse return false;
    const r = f.caret_rect;
    const over = r.y + r.h + 12 - bottom;
    if (r.h <= 0 or over <= 0.5) return false;
    var i: u32 = none;
    for (c.nodes.items, 0..) |n, k| if (n.id == f.id) {
        i = @intCast(k);
        break;
    };
    while (i != none) : (i = c.nodes.items[i].parent) {
        const n = c.nodes.items[i];
        if (!n.style.scroll) continue;
        const max = c.scroll_max.get(n.id) orelse 0;
        const s = c.scroll.getOrPut(c.gpa, n.id) catch return false;
        if (!s.found_existing) s.value_ptr.* = 0;
        const want = @min(max, s.value_ptr.* + over);
        if (want <= s.value_ptr.* + 0.5) continue;
        s.value_ptr.* = want;
        return true;
    }
    return false;
}

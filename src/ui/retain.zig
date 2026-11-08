//! A scroll that only moved its offset draws the last scene shifted, instead
//! of building, measuring and painting the window again. This is the cheap
//! form of a scroll layer: one tile, the last frame, translated.
//!
//! It does not apply when the tree omitted rows (`ui.list`, or a spacer
//! standing in for them). Those have to be built at the new offset. A frame
//! that is animating, or that asked for another frame, is built again too.
const std = @import("std");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

pub fn store(c: *Context, instances: *std.ArrayList(gpu.Instance)) void {
    c.scroll_scene_ok = false;
    c.scroll_offsets.clearRetainingCapacity();
    // A loader's later tick is not a scene change. Treating it as one
    // rebuilds the window on every wheel event and drops scroll off the
    // display's pace.
    if (c.virtual_list or c.animating or c.changed) return;
    if (virtualSpacer(c, 0)) return;
    c.scroll_scene.clearRetainingCapacity();
    c.scroll_scene.appendSlice(c.gpa, instances.items) catch return;
    var i: u32 = 0;
    while (i < c.nodes.items.len) : (i += 1) {
        const n = c.node(i);
        if (!n.style.scroll) continue;
        c.scroll_offsets.append(c.gpa, .{
            .id = n.id,
            .y = c.scroll.get(n.id) orelse 0,
            .view = n.rect,
        }) catch return;
    }
    c.scroll_scene_ok = true;
}

/// Shifts the stored scene when this event only scrolled. False means the
/// caller builds the frame as usual.
pub fn shift(c: *Context, instances: *std.ArrayList(gpu.Instance), size: types.Size, scale: f32) bool {
    defer c.scroll_delta = false;
    if (!c.scroll_delta or !c.scroll_scene_ok or c.scroll_scene.items.len == 0) return false;
    if (c.size.w != size.w or c.size.h != size.h or c.scale != scale) return false;
    const quiet = c.input.pressed or c.input.released or c.input.secondary or c.input.key != null or c.input.chars.len != 0 or c.input.ops.len != 0 or c.input.shortcut != null or c.input.zoom != 1 or c.input.pan.x != 0 or c.input.pan.y != 0;
    if (quiet) return false;
    const moved = changedOffset(c) orelse return false;
    // Past the end, layout clamps and may change follow-end. Build that frame.
    if (moved.next > maxOffset(c, moved.id, moved.view) + 0.5 or moved.next < -0.5) return false;
    const dy = moved.next - moved.prev;
    if (dy == 0) return false;
    instances.clearRetainingCapacity();
    instances.appendSlice(c.gpa, c.scroll_scene.items) catch return false;
    const view = moved.view;
    for (instances.items) |*it| {
        if (!clipMatches(it.clip, view)) continue;
        if (it.rect[0] >= view.x + view.w - 12) continue;
        it.rect[1] -= dy;
    }
    if (scrollIndex(c, moved.id)) |index| shiftTree(c, index, dy);
    for (c.hits.items) |*h| {
        if (h.id == moved.id and h.scroll) continue;
        if (h.rect.y + h.rect.h < view.y - 1 or h.rect.y > view.y + view.h + 1) continue;
        if (h.rect.x >= view.x + view.w - 12) continue;
        h.rect.y -= dy;
    }
    if (c.rects.getPtr(moved.id)) |r| r.* = view;
    // The thumb tracks the offset; the content shift must not carry it.
    placeThumb(c, instances, moved.id, view, moved.next);
    if (c.scroll_offsets.items.len > moved.slot) c.scroll_offsets.items[moved.slot].y = moved.next;
    c.scroll_scene.clearRetainingCapacity();
    c.scroll_scene.appendSlice(c.gpa, instances.items) catch {
        c.scroll_scene_ok = false;
        return true;
    };
    c.stats.nodes = c.nodes.items.len;
    c.stats.instances = instances.items.len;
    c.stats.passes = 0;
    return true;
}

const Moved = struct { id: u64, slot: usize, prev: f32, next: f32, view: types.Rect };

fn changedOffset(c: *Context) ?Moved {
    var found: ?Moved = null;
    for (c.scroll_offsets.items, 0..) |saved, slot| {
        const next = c.scroll.get(saved.id) orelse saved.y;
        if (next == saved.y) continue;
        if (found != null) return null;
        found = .{ .id = saved.id, .slot = slot, .prev = saved.y, .next = next, .view = saved.view };
    }
    return found;
}

fn scrollIndex(c: *Context, id: u64) ?u32 {
    for (c.nodes.items, 0..) |n, i| if (n.id == id and n.style.scroll) return @intCast(i);
    return null;
}

fn shiftTree(c: *Context, index: u32, dy: f32) void {
    var child = c.node(index).first_child;
    while (child != none) : (child = c.node(child).next) {
        c.node(child).rect.y -= dy;
        if (c.rects.getPtr(c.node(child).id)) |r| r.y -= dy;
        shiftTree(c, child, dy);
    }
}

fn placeThumb(c: *Context, instances: *std.ArrayList(gpu.Instance), id: u64, view: types.Rect, offset: f32) void {
    const index = scrollIndex(c, id) orelse return;
    const n = c.node(index);
    if (n.first_child == none) return;
    const first = c.node(n.first_child).rect;
    const last = c.node(n.last_child).rect;
    const content_h = last.y + last.h - first.y + n.style.padding.vertical();
    if (content_h <= view.h + 0.5) return;
    const t = std.math.clamp(offset / (content_h - view.h), 0, 1);
    const bar_h = @max(@as(f32, 24), view.h * view.h / content_h);
    const y = view.y + (view.h - bar_h) * t;
    const x = view.x + view.w - 7;
    for (instances.items) |*it| {
        if (@abs(it.rect[0] - x) > 0.5 or @abs(it.rect[2] - 4) > 0.5) continue;
        it.rect[1] = y + 2;
        it.rect[3] = bar_h - 4;
        return;
    }
}

fn clipMatches(clip: [4]f32, view: types.Rect) bool {
    return @abs(clip[0] - view.x) < 0.6 and @abs(clip[1] - view.y) < 0.6 and @abs(clip[2] - (view.x + view.w)) < 0.6 and @abs(clip[3] - (view.y + view.h)) < 0.6;
}

fn virtualSpacer(c: *Context, index: u32) bool {
    const n = c.node(index);
    if (n.style.scroll and n.rect.h > 0 and spacer(c, index, n.rect.h)) return true;
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        if (virtualSpacer(c, child)) return true;
    }
    return false;
}

fn spacer(c: *Context, index: u32, view_h: f32) bool {
    const n = c.node(index);
    if (n.content == .none and n.first_child == none and n.rect.h > @max(view_h, 40)) return true;
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        if (spacer(c, child, view_h)) return true;
    }
    return false;
}

fn maxOffset(c: *Context, id: u64, view: types.Rect) f32 {
    const index = scrollIndex(c, id) orelse return 0;
    const n = c.node(index);
    if (n.first_child == none) return 0;
    const first = c.node(n.first_child).rect;
    const last = c.node(n.last_child).rect;
    const content_h = last.y + last.h - first.y + n.style.padding.vertical();
    return @max(0, content_h - view.h);
}

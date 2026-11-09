//! A scroll that only moved its offset draws the last scene shifted, instead
//! of building, measuring and painting the window again. This is the cheap
//! form of a scroll layer: one tile, the last frame, translated.
//!
//! It does not apply when the tree omitted rows (`ui.list`, or a spacer
//! standing in for them), or when a scrolling box contains nested clips.
//! Those have to be built at the new offset. A frame that is animating or
//! changed state is built again too.
const std = @import("std");
const gpu = @import("gpu.zig");
const types = @import("types.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

pub const ScrollOffset = struct {
    id: u64,
    y: f32,
    base: f32,
    view: types.Rect,
};

pub const State = struct {
    /// `applyScroll` moved an offset. A quiet next frame may shift the scene.
    scroll_delta: bool = false,
    /// The app says this animation only moved a clip. The next frame may
    /// reuse the last scene instead of rebuilding the window.
    clip_shift: bool = false,
    clip_dx: f32 = 0,
    clip_slot: f32 = 0,
    /// `ui.list` built this frame: its rows are not all in the tree.
    virtual_list: bool = false,
    /// Last painted scene, for a scroll that only moved.
    scroll_scene: std.ArrayList(gpu.Instance) = .empty,
    scroll_offsets: std.ArrayList(ScrollOffset) = .empty,
    scroll_scene_ok: bool = false,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.scroll_scene.deinit(gpa);
        s.scroll_offsets.deinit(gpa);
    }
};

pub fn store(c: *Context, instances: *std.ArrayList(gpu.Instance)) void {
    const rs = &c.retain;
    rs.scroll_scene_ok = false;
    rs.scroll_offsets.clearRetainingCapacity();
    // A loader's later tick (`frame_in`) is not a scene change. Treating it
    // as one rebuilds the window on every wheel event.
    if (rs.virtual_list or c.animating or c.changed) return;
    if (cannotRetain(c, 0)) return;
    rs.scroll_scene.clearRetainingCapacity();
    rs.scroll_scene.appendSlice(c.gpa, instances.items) catch return;
    var i: u32 = 0;
    while (i < c.nodes.items.len) : (i += 1) {
        const n = c.node(i);
        if (!n.style.scroll) continue;
        const y = c.scroll.get(n.id) orelse 0;
        rs.scroll_offsets.append(c.gpa, .{
            .id = n.id,
            .y = y,
            .base = y,
            .view = n.rect,
        }) catch return;
    }
    rs.scroll_scene_ok = true;
}

/// Shifts the stored scene when this event only scrolled. False means the
/// caller builds the frame as usual.
pub fn shift(c: *Context, instances: *std.ArrayList(gpu.Instance), size: types.Size, scale: f32) bool {
    const rs = &c.retain;
    defer rs.scroll_delta = false;
    if (!rs.scroll_delta or !rs.scroll_scene_ok or rs.scroll_scene.items.len == 0) return false;
    if (c.size.w != size.w or c.size.h != size.h or c.scale != scale) return false;
    const quiet = c.input.pressed or c.input.released or c.input.secondary or c.input.key != null or c.input.chars.len != 0 or c.input.ops.len != 0 or c.input.shortcut != null or c.input.zoom != 1 or c.input.pan.x != 0 or c.input.pan.y != 0;
    if (quiet) return false;
    const moved = changedOffset(c) orelse return false;
    // Past the end, or past the 128pt pre-shaped skirt, build a fresh frame.
    if (@abs(moved.next - moved.base) > 128) return false;
    if (moved.next > maxOffset(c, moved.id, moved.view) + 0.5 or moved.next < -0.5) return false;
    const dy = moved.next - moved.prev;
    if (dy == 0) return false;
    const index = scrollIndex(c, moved.id) orelse return false;
    instances.clearRetainingCapacity();
    instances.appendSlice(c.gpa, rs.scroll_scene.items) catch return false;
    const view = moved.view;
    for (instances.items) |*it| {
        if (!clipMatches(it.clip, view)) continue;
        it.rect[1] -= dy;
    }
    shiftTree(c, index, dy);
    for (c.hits.items) |*h| {
        if (h.id == moved.id and h.scroll) continue;
        if (!inSubtree(c, index, h.index)) continue;
        h.rect.y -= dy;
    }
    if (c.rects.getPtr(moved.id)) |r| r.* = view;
    // The thumb tracks the offset; placeThumb restores its exact y and height.
    placeThumb(c, instances, index, view, moved.next);
    if (rs.scroll_offsets.items.len > moved.slot) rs.scroll_offsets.items[moved.slot].y = moved.next;
    rs.scroll_scene.clearRetainingCapacity();
    rs.scroll_scene.appendSlice(c.gpa, instances.items) catch {
        rs.scroll_scene_ok = false;
        return true;
    };
    c.stats.nodes = c.nodes.items.len;
    c.stats.instances = instances.items.len;
    c.stats.passes = 0;
    return true;
}

const Moved = struct { id: u64, slot: usize, prev: f32, next: f32, base: f32, view: types.Rect };

fn changedOffset(c: *Context) ?Moved {
    var found: ?Moved = null;
    for (c.retain.scroll_offsets.items, 0..) |saved, slot| {
        const next = c.scroll.get(saved.id) orelse saved.y;
        if (next == saved.y) continue;
        if (found != null) return null;
        found = .{ .id = saved.id, .slot = slot, .prev = saved.y, .next = next, .base = saved.base, .view = saved.view };
    }
    return found;
}

fn scrollIndex(c: *Context, id: u64) ?u32 {
    for (c.nodes.items, 0..) |n, i| if (n.id == id and n.style.scroll) return @intCast(i);
    return null;
}

fn inSubtree(c: *const Context, root: u32, node_idx: u32) bool {
    if (node_idx <= root or node_idx >= c.nodes.items.len) return false;
    var at = c.nodes.items[node_idx].parent;
    while (at != none) : (at = c.nodes.items[at].parent) {
        if (at == root) return true;
    }
    return false;
}

fn shiftTree(c: *Context, index: u32, dy: f32) void {
    var child = c.node(index).first_child;
    while (child != none) : (child = c.node(child).next) {
        c.node(child).rect.y -= dy;
        if (c.rects.getPtr(c.node(child).id)) |r| r.y -= dy;
        shiftTree(c, child, dy);
    }
}

fn placeThumb(c: *Context, instances: *std.ArrayList(gpu.Instance), index: u32, view: types.Rect, offset: f32) void {
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
    var k = instances.items.len;
    while (k > 0) {
        k -= 1;
        const it = &instances.items[k];
        if (!clipMatches(it.clip, view)) continue;
        if (@abs(it.rect[0] - x) > 0.5 or @abs(it.rect[2] - 4) > 0.5) continue;
        it.rect[1] = y + 2;
        it.rect[3] = bar_h - 4;
        if (c.scrollbars.getPtr(n.id)) |g| {
            g.thumb_y = y;
            g.thumb_h = bar_h;
        }
        return;
    }
}

fn clipMatches(clip: [4]f32, view: types.Rect) bool {
    return @abs(clip[0] - view.x) < 0.6 and @abs(clip[1] - view.y) < 0.6 and @abs(clip[2] - (view.x + view.w)) < 0.6 and @abs(clip[3] - (view.y + view.h)) < 0.6;
}

fn cannotRetain(c: *Context, index: u32) bool {
    const n = c.node(index);
    if (n.style.scroll and n.rect.h > 0 and (spacer(c, index, n.rect.h) or nestedClip(c, index))) return true;
    var child = n.first_child;
    while (child != none) : (child = c.node(child).next) {
        if (cannotRetain(c, child)) return true;
    }
    return false;
}

fn nestedClip(c: *Context, root: u32) bool {
    var child = c.node(root).first_child;
    while (child != none) : (child = c.node(child).next) {
        if (hasClipOrScroll(c, child)) return true;
    }
    return false;
}

fn hasClipOrScroll(c: *Context, index: u32) bool {
    const st = c.node(index).style;
    if (st.clip or st.scroll or st.scroll_x or st.layer > 0) return true;
    var child = c.node(index).first_child;
    while (child != none) : (child = c.node(child).next) {
        if (hasClipOrScroll(c, child)) return true;
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

test "retained scroll shifts instances and right-aligned hits without rebuilding" {
    const testing = std.testing;
    const ui = @import("ui.zig");
    const Page = struct {
        clicked: ?usize = null,
        fn view(p: *@This(), c: *ui.Context) void {
            ui.scroll(c, .{ .width = .fill, .height = .fill, .gap = 4 });
            defer ui.end(c);
            for (0..30) |i| {
                ui.keyInt(c, i);
                ui.row(c, .{ .width = .fill, .height = .{ .px = 24 }, .justify = .space_between });
                defer ui.end(c);
                ui.textf(c, .{}, "Item {d}", .{i});
                if (ui.button(c, "Go", .{}).clicked) p.clicked = i;
            }
        }
    };
    var p: Page = .{};
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Page.view), .{ .width = 240, .height = 160 });
    defer t.deinit();
    const y0 = t.findText("Item 3").?.y;
    t.scroll(100, 80, -28);
    try testing.expect(t.ctx.stats.retained);
    try testing.expectEqual(y0 - 28, t.findText("Item 3").?.y);
    // Right-edge button on Item 3 moved with the row and still takes clicks.
    const row3_y = t.findText("Item 3").?.y;
    t.click(235, row3_y + 4);
    try testing.expectEqual(@as(?usize, 3), p.clicked);
}

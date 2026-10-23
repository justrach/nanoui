//! What a view asks of the window beyond drawing, on `Context`: the
//! focus given by the app, tooltips, drops from other apps, boxes
//! that move the window, and what VoiceOver sees of them.
const std = @import("std");
const types = @import("types.zig");
const input = @import("input.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const DragRequest = struct {
    text: []const u8,
    rect: types.Rect = .{},
};

/// Focuses the next box (a `textField` or `textArea` called right after),
/// selecting all of its text when `select_all` is true.
pub fn focusNext(c: *Context, select_all: bool) void {
    c.focus = c.peekId(null);
    c.focus_select_all = select_all;
}

pub fn focusCycle(c: *Context, reverse: bool) void {
    const ids = if (c.last_focusable_ids.items.len > 0) c.last_focusable_ids.items else c.focusable_ids.items;
    if (ids.len == 0) return;
    if (std.mem.indexOfScalar(u64, ids, c.focus)) |idx| {
        const next_idx = if (reverse) (if (idx == 0) ids.len - 1 else idx - 1) else (idx + 1) % ids.len;
        c.focus = ids[next_idx];
    } else {
        c.focus = if (reverse) ids[ids.len - 1] else ids[0];
    }
    c.input.key = null;
    c.input.ops = &.{};
    c.focus_select_all = true;
    c.caret_moved_at = c.time;
    c.changed = true;
}

pub fn startDrag(c: *Context, index: u32, text: []const u8) void {
    const id = c.node(index).id;
    const rect = c.rects.get(id) orelse types.Rect{ .x = c.input.mouse.x - 80, .y = c.input.mouse.y - 14, .w = 160, .h = 28 };
    c.drag_request = .{ .text = c.alloc().dupe(u8, text) catch text, .rect = rect };
}

/// The tooltip of box `index`, shown while the pointer rests on it or on a
/// box inside it. A box that takes no clicks (a marker icon) shows its own
/// over that of the clickable box it is drawn in, as AppKit's tooltip
/// rects do.
pub fn help(c: *Context, index: u32, s: []const u8) void {
    c.helps.put(c.gpa, c.node(index).id, c.alloc().dupe(u8, s) catch return) catch {};
}

/// The help of the smallest quiet box under the pointer inside the hot
/// box, else of the hot box, or of the nearest box it is in that has one.
pub fn hotHelp(c: *const Context) ?[]const u8 {
    if (c.rects.get(c.hot)) |hot| {
        var best: ?[]const u8 = null;
        var area = hot.w * hot.h;
        var it = c.helps.iterator();
        while (it.next()) |e| {
            const r = c.rects.get(e.key_ptr.*) orelse continue;
            if (e.key_ptr.* == c.hot or !r.contains(c.input.mouse) or r.w * r.h >= area) continue;
            if (r.x < hot.x or r.y < hot.y or r.x + r.w > hot.x + hot.w or r.y + r.h > hot.y + hot.h) continue;
            best = e.value_ptr.*;
            area = r.w * r.h;
        }
        if (best) |s| return s;
    }
    for (c.hot_path.items) |id| if (c.helps.get(id)) |s| return s;
    return null;
}

/// Box `index` takes drops (links, files, text): a drag over it is offered
/// a copy, and `dropAt` gives it what lands.
pub fn acceptDrop(c: *Context, index: u32) void {
    c.drop_targets.append(c.gpa, c.node(index).id) catch {};
}

/// Whether a box that takes drops was under `p` in the last frame.
pub fn acceptsDropAt(c: *const Context, p: types.Point) bool {
    for (c.drop_targets.items) |id| if (c.rects.get(id)) |r| if (r.contains(p)) return true;
    return false;
}

/// What was dropped on box `index` in this event, if anything was.
pub fn dropAt(c: *Context, index: u32) ?input.Drop {
    const d = c.input.drop orelse return null;
    const r = c.rects.get(c.node(index).id) orelse return null;
    if (!r.contains(d.point)) return null;
    c.changed = true;
    return d;
}

/// Whether this press moves the window: a single click on a box with
/// `window_drag` (a second one comes to it as a double click).
pub fn startsWindowDrag(c: *const Context) bool {
    if (c.input.click_count != 1 or c.hot_index >= c.nodes.items.len) return false;
    const n = c.nodes.items[c.hot_index];
    return n.id == c.hot and n.style.window_drag;
}

/// Box `index` as VoiceOver sees it (a button, a field…).
pub fn addA11y(c: *Context, index: u32, role: ctx_mod.A11yRole, label: []const u8, value: []const u8, selected: bool, enabled: bool) void {
    c.a11y_items.append(c.gpa, .{
        .id = c.nodes.items[index].id,
        .node_index = index,
        .role = role,
        .label = if (label.len > 0) (c.alloc().dupe(u8, label) catch label) else "",
        .value = if (value.len > 0) (c.alloc().dupe(u8, value) catch value) else "",
        .selected = selected,
        .enabled = enabled,
    }) catch {};
}

/// Box `index` as an element VoiceOver increments and decrements (a
/// splitter, a slider): its `interact` then reports `a11y_step`.
pub fn adjustable(c: *Context, index: u32, opts: struct { role: ctx_mod.A11yRole = .slider, label: []const u8, value: []const u8 = "", enabled: bool = true }) void {
    const n = c.a11y_items.items.len;
    c.addA11y(index, opts.role, opts.label, opts.value, false, opts.enabled);
    if (c.a11y_items.items.len > n) c.a11y_items.items[n].adjustable = true;
}

/// VoiceOver incremented (`dir` +1) or decremented (−1) box `id`: the
/// next frame's `interact` of it reports the step.
pub fn a11yStep(c: *Context, id: u64, dir: i8) void {
    c.input.a11y_step = .{ .id = id, .dir = dir };
}

pub fn addStageHole(c: *Context, r: types.Rect) void {
    if (c.stage_count < c.stage_rects.len) {
        c.stage_rects[c.stage_count] = r;
        c.stage_nodes[c.stage_count] = ctx_mod.none;
        c.stage_count += 1;
    }
}

pub fn addStageHoleNode(c: *Context, node_index: u32) void {
    if (c.stage_count < c.stage_rects.len) {
        c.stage_nodes[c.stage_count] = node_index;
        c.stage_rects[c.stage_count] = .{};
        c.stage_count += 1;
    }
}

pub fn hitAt(c: *const Context, p: types.Point) bool {
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.scroll and h.rect.contains(p)) return true;
    }
    return false;
}

pub fn inStageHoleAt(c: *const Context, p: types.Point) bool {
    if (c.active != 0 or c.hitAt(p)) return false;
    for (c.stage_rects[0..c.stage_count]) |r| {
        if (r.contains(p)) return true;
    }
    return false;
}

pub fn addHit(c: *Context, id: u64, index: u32, rect: types.Rect, scroll: bool) void {
    c.next_hits.append(c.gpa, .{ .id = id, .index = index, .rect = rect, .scroll = scroll }) catch {};
}

pub fn commitHits(c: *Context) void {
    std.mem.swap(std.ArrayList(ctx_mod.Hit), &c.hits, &c.next_hits);
    updateHot(c);
}

pub fn updateHot(c: *Context) void {
    c.hot = 0;
    c.hot_index = ctx_mod.none;
    c.hot_path.clearRetainingCapacity();
    var i = c.hits.items.len;
    while (i > 0) {
        i -= 1;
        const h = c.hits.items[i];
        if (!h.scroll and h.rect.contains(c.input.mouse)) {
            c.hot = h.id;
            c.hot_index = h.index;
            hotPath(c, h);
            return;
        }
    }
}

fn hotPath(c: *Context, h: ctx_mod.Hit) void {
    if (h.index >= c.nodes.items.len or c.nodes.items[h.index].id != h.id) return;
    var at = h.index;
    while (at != ctx_mod.none) {
        const n = c.nodes.items[at];
        if (n.interactive) c.hot_path.append(c.gpa, n.id) catch return;
        at = n.parent;
    }
}

pub fn interact(c: *Context, index: u32, opts: struct { focusable: bool = false }) ctx_mod.Interaction {
    const n = c.node(index);
    n.interactive = true;
    const id = n.id;
    if (opts.focusable) c.focusable_ids.append(c.gpa, id) catch {};
    const rect = c.rects.get(id);
    const top = c.hot == id;
    const hovered = top or std.mem.indexOfScalar(u64, c.hot_path.items, id) != null;
    const right_press = top and c.input.pressed and (c.input.button == .right or (c.input.button == .left and c.input.ctrl));
    const left_press = top and c.input.pressed and c.input.button == .left and !c.input.ctrl;
    if (top and c.input.pressed) {
        c.active = id;
        if (opts.focusable) c.focus = id else if (left_press) c.focus = 0;
    }
    const released = c.input.released and c.active == id and top and !c.selection.moved;
    const clicked = released and c.input.button == .left and !c.input.ctrl;
    if (top and c.hand_cursor) c.cursor_hand = true;
    return .{
        .id = id,
        .rect = rect,
        .hovered = hovered,
        .pressed = c.active == id and c.input.down and c.input.button == .left and !c.input.ctrl,
        .clicked = clicked,
        .double_clicked = clicked and c.input.click_count >= 2,
        .right_pressed = right_press,
        .right_clicked = right_press,
        .middle_clicked = released and c.input.button == .middle,
        .focused = c.focus == id,
        .a11y_step = if (c.input.a11y_step) |s| (if (s.id == id) s.dir else 0) else 0,
    };
}

pub fn shortcut(c: *Context, want_in: ctx_mod.Shortcut) bool {
    const want = want_in.native();
    const s = (c.input.shortcut orelse return false).native();
    if (s.key != want.key or s.cmd != want.cmd or s.ctrl != want.ctrl or s.alt != want.alt or s.shift != want.shift) return false;
    c.shortcut_taken = true;
    c.changed = true;
    c.input.shortcut = null;
    return true;
}

pub fn state(c: *Context, comptime T: type, key: []const u8) *T {
    comptime std.debug.assert(@sizeOf(T) <= 48 and @alignOf(T) <= 16);
    var h = std.hash.Wyhash.init(c.peekId(null));
    h.update("state:");
    h.update(key);
    const gop = c.memory.getOrPut(c.gpa, h.final()) catch {
        const S = struct {
            var spare: T = .{};
        };
        S.spare = .{};
        return &S.spare;
    };
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .bytes = undefined, .frame = c.frame };
        @as(*T, @ptrCast(&gop.value_ptr.bytes)).* = .{};
    }
    gop.value_ptr.frame = c.frame;
    return @ptrCast(&gop.value_ptr.bytes);
}

pub fn animate(c: *Context, id: u64, salt: u32, target: f32, speed: f32) f32 {
    var h = std.hash.Wyhash.init(id);
    h.update(std.mem.asBytes(&salt));
    const key = h.final();
    const gop = c.anims.getOrPut(c.gpa, key) catch return target;
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .value = target, .frame = c.frame };
        return target;
    }
    const a = gop.value_ptr;
    a.frame = c.frame;
    const k = 1 - @exp(-speed * @min(c.dt, 0.1));
    a.value += (target - a.value) * k;
    if (@abs(target - a.value) < 0.002) a.value = target else c.animating = true;
    return a.value;
}

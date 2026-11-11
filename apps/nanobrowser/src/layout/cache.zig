//! Clean-subtree layout cache (Blink `LayoutObject` / Ladybird incremental layout):
//! adopts unchanged, layout-clean DOM subtrees from `prev_layout_arena` into
//! `layout_arena`, reusing their internal formatting context results and
//! shifting finished page coordinates by `(dx, dy)` in linear time over the
//! adopted boxes without re-tokenizing text, re-breaking lines, or re-running
//! flexbox/grid/positioned passes.
const std = @import("std");
const Allocator = std.mem.Allocator;
const box = @import("box.zig");
const ctx = @import("ctx.zig");
const gen = @import("gen.zig");
const dom = @import("../dom.zig");
const perf = @import("../perf_rules.zig");

const Box = box.Box;
const Ctx = ctx.Ctx;
const Error = ctx.Error;

fn cloneStyleIfNeeded(arena: Allocator, node: ?*dom.Node, pseudo: bool, st: *const box.Style) Error!*const box.Style {
    if (node) |n| {
        if (!pseudo and st == n.computed) return st;
        if (pseudo and (st == n.before or st == n.after)) return st;
    }
    const copy = try arena.create(box.Style);
    copy.* = st.*;
    return copy;
}

fn cloneSubtree(arena: Allocator, old_b: *const Box, is_root: bool) Error!*Box {
    const b = try arena.create(Box);
    b.* = old_b.*;
    b.parent = null;
    b.next = null;
    b.first_child = null;
    b.last_child = null;
    b.style = try cloneStyleIfNeeded(arena, old_b.node, old_b.pseudo, old_b.style);
    b.lay.old_style = old_b.style;
    b.lay.entries = &.{};
    b.lay.pieces = &.{};
    b.lay.marker_text = "";
    b.lay.marker_style = null;
    b.lay.sub_cols = null;
    b.lay.sub_rows = null;
    b.lay.table = null;
    b.lay.adopted = is_root;
    if (b.node) |bn| {
        if (!b.pseudo) bn.setBox(b);
    }
    var ch = old_b.first_child;
    while (ch) |old_ch| : (ch = old_ch.next) {
        const new_ch = try cloneSubtree(arena, old_ch, false);
        b.append(new_ch);
    }
    return b;
}

/// Attempts to adopt a clean cached box subtree for element `n` during `gen.element`.
pub fn tryAdopt(g: *gen.Gen, n: *dom.Node) Error!bool {
    const c = g.c;
    const doc = c.doc orelse return false;
    if (c.prev_gen == 0 or n.subtree_layout_dirty) return false;
    if (n.box_gen != c.prev_gen or n.box_parts.len != 0) return false;
    const s_in = n.computed orelse return false;
    const old_b: *const Box = @ptrCast(@alignCast(n.box orelse return false));
    if (!old_b.lay.reusable or old_b.lay.cache_gen != doc.layout_cache_gen) return false;
    if (old_b.lay.cached_style != s_in) return false;
    if (old_b.lay.in_text_align != g.text_align or old_b.lay.in_nowrap != g.nowrap) return false;
    if (old_b.lay.advances_list_counter) {
        const value = g.counter;
        try g.counters.set(c.arena, "list-item", @intCast(std.math.clamp(value, -1000000000, 1000000000)), g.depth + 1);
        g.counter += g.counter_step;
    }
    const new_b = try cloneSubtree(c.arena, old_b, true);
    try g.stack.append(c.arena, .{ .tag = .box, .box = new_b, .style = new_b.style });
    perf.prof_lay_adopted += 1;
    return true;
}

/// Falls back to full box generation on `b` when available width/height/edges changed.
pub fn unadopt(c: *Ctx, b: *Box) Error!void {
    if (!b.lay.adopted) return;
    b.lay.adopted = false;
    b.lay.reusable = false;
    b.lay.flow_reusable = false;
    b.lay.cache_gen = 0;
    b.lay.state_valid = false;
    b.lay.measure_valid = false;
    b.lay.intrinsic_known = false;
    b.lay.first_baseline = null;
    b.lay.last_baseline = null;
    b.lay.shift_y = 0;
    b.lay.extra_r = 0;
    b.lay.extra_b = 0;
    b.first_child = null;
    b.last_child = null;
    b.runs = &.{};
    b.frags = &.{};
    b.marker = null;
    try gen.rebuildAdoptedContents(c, b);
}

inline fn textLivesInDoc(r: *const box.TextRun) bool {
    const rn = r.node orelse return false;
    const base = @intFromPtr(rn.data.ptr);
    const end = base + rn.data.len;
    const rp = @intFromPtr(r.text.ptr);
    return rp >= base and rp + r.text.len <= end;
}

fn remapRunStyle(arena: Allocator, owner: *const Box, r: *const box.TextRun) Error!*const box.Style {
    if (owner.lay.old_style) |os| if (r.style == os) return owner.style;
    if (owner.node) |on| if (!owner.pseudo and r.style == on.computed) return r.style;
    if (r.node) |rn| if (rn.parent) |rp| if (r.style == rp.computed) return r.style;
    if (owner.parent) |op| {
        if (op.lay.old_style) |pos| if (r.style == pos) return op.style;
        if (op.node) |opn| if (!op.pseudo and r.style == opn.computed) return r.style;
    }
    const copy = try arena.create(box.Style);
    copy.* = r.style.*;
    return copy;
}

fn dupeAndShiftSubtree(arena: Allocator, x: *Box, dx: f32, dy: f32, add_x: f32, add_y: f32, is_root: bool) Error!void {
    if (is_root) {
        x.x += add_x;
        x.y += add_y;
    } else {
        x.x += dx;
        x.y += dy;
    }
    if (x.lay.extra_r != 0) x.lay.extra_r += dx;
    if (x.lay.extra_b != 0) x.lay.extra_b += dy;
    if (x.marker) |*m| {
        m.x += dx;
        m.y += dy;
    }
    if (x.frags.len > 0) {
        const frags = try arena.dupe(box.Rect, x.frags);
        if (dx != 0 or dy != 0) {
            for (frags) |*fr| {
                fr.x += dx;
                fr.y += dy;
            }
        }
        x.frags = frags;
    }
    if (x.runs.len > 0) {
        const runs = try arena.dupe(box.TextRun, x.runs);
        for (runs) |*r| {
            r.x += dx;
            r.baseline += dy;
            r.line_top += dy;
            r.style = try remapRunStyle(arena, x, r);
            if (!textLivesInDoc(r)) {
                r.text = try arena.dupe(u8, r.text);
            }
        }
        x.runs = runs;
    }
    x.lay.old_style = null;
    var ch = x.first_child;
    while (ch) |child_b| : (ch = child_b.next) {
        try dupeAndShiftSubtree(arena, child_b, dx, dy, 0, 0, false);
    }
}

/// Finishes an adopted subtree `b` by shifting all page coordinates by `(dx, dy)`
/// and copying slices (`runs`, `frags`) into `c.arena`.
pub fn finishAdopted(c: *Ctx, b: *Box, add_x: f32, add_y: f32) Error!void {
    const new_page_x = b.x + add_x;
    const new_page_y = b.y + add_y;
    const dx = new_page_x - b.lay.cached_page_x;
    const dy = new_page_y - b.lay.cached_page_y;
    try dupeAndShiftSubtree(c.arena, b, dx, dy, add_x, add_y, true);
    b.lay.cached_page_x = new_page_x;
    b.lay.cached_page_y = new_page_y;
    b.lay.adopted = false;
    if (c.doc) |doc| b.lay.cache_gen = doc.layout_cache_gen;
}

/// Records bottom-up structural cacheability invariants on `b` at the end of `finish`.
pub fn recordFinished(c: *Ctx, b: *Box) void {
    var bad = false;
    var unc_abs = false;
    var unsc_li = false;
    var has_flt = (b.style.float != .none);

    if (b.style.position == .fixed) bad = true;
    switch (b.kind) {
        .table, .table_row_group, .table_row, .table_cell, .table_caption => bad = true,
        else => {},
    }
    if (b.lay.sub_cols != null or b.lay.sub_rows != null or b.style.grid_template_columns.subgrid or b.style.grid_template_rows.subgrid) bad = true;
    if (b.style.container_type != .normal) bad = true;
    if (b.style.counter_reset.len != 0 or b.style.counter_increment.len != 0 or b.style.counter_set.len != 0) bad = true;
    if (b.pseudo and b.style.content_parts.len != 0) bad = true;

    if (b.node) |n| {
        if (!b.pseudo) {
            const ok_ns = (n.ns == .html) or (n.ns == .svg and n.isTag("svg"));
            const lazy_unloaded = (n.html_tag == .img and n.image_key.len == 0);
            if (!ok_ns or lazy_unloaded or n.isTag("iframe") or n.in_top_layer or n.shadow_root != null or n.is_shadow or n.tree_scope != null or n.box_parts.len != 0 or n.html_tag == .slot or n.html_tag == .details) {
                bad = true;
            }
        }
    }

    var first_inflow: ?*const Box = null;
    var last_inflow: ?*const Box = null;
    var ch = b.first_child;
    while (ch) |x| : (ch = x.next) {
        if (x.lay.bad_subtree) bad = true;
        if (x.lay.has_float or x.style.float != .none) has_flt = true;
        if (x.style.position == .absolute or x.lay.uncontained_abs) unc_abs = true;
        if (x.lay.unscoped_li or x.style.display == .list_item) unsc_li = true;
        if (!x.style.isOutOfFlow() and x.style.float == .none) {
            if (first_inflow == null) first_inflow = x;
            last_inflow = x;
        }
    }

    if (b.style.position != .static or b.style.hasTransform()) unc_abs = false;
    if (b.node) |n| {
        if (!b.pseudo and n.html_tag == .list) unsc_li = false;
    }

    b.lay.advances_list_counter = false;
    if (b.style.display == .list_item) {
        const plain_li = b.style.list_style == .none and b.style.list_style_text == null and !b.lay.has_marker and
            (if (b.node) |n| (!b.pseudo and n.marker == null and !n.hasAttr("value")) else false);
        if (plain_li) {
            b.lay.advances_list_counter = true;
        } else {
            bad = true;
        }
    }

    b.lay.bad_subtree = bad;
    b.lay.uncontained_abs = unc_abs;
    b.lay.unscoped_li = unsc_li;
    b.lay.has_float = has_flt;

    if (b.kind == .inline_box or b.style.isOutOfFlow() or b.style.float != .none) {
        b.lay.no_top_collapse = false;
        b.lay.no_bottom_collapse = false;
    } else if (ctx.isBfcRoot(b)) {
        b.lay.no_top_collapse = true;
        b.lay.no_bottom_collapse = true;
    } else if (b.lay.inline_root) {
        const has_line = (b.lay.first_baseline != null);
        b.lay.no_top_collapse = (ctx.bpTop(b) > 0) or has_line;
        b.lay.no_bottom_collapse = (b.border.bottom + b.padding.bottom > 0) or has_line;
    } else {
        b.lay.no_top_collapse = (ctx.bpTop(b) > 0) or (first_inflow != null and first_inflow.?.margin.top == 0 and first_inflow.?.lay.no_top_collapse);
        b.lay.no_bottom_collapse = (b.border.bottom + b.padding.bottom > 0) or (last_inflow != null and last_inflow.?.margin.bottom == 0 and last_inflow.?.lay.no_bottom_collapse);
    }

    b.lay.reusable = false;
    b.lay.flow_reusable = false;
    const doc = c.doc orelse return;
    if (bad or unc_abs or unsc_li or b.lay.has_marker) return;
    const n = b.node orelse return;
    if (b.pseudo or n.box != @as(?*anyopaque, b)) return;
    const p = b.parent orelse return;
    if (p.parent == null) return;
    if (b.kind == .inline_box or b.style.isInlineLevel() or b.style.isOutOfFlow() or b.style.float != .none) return;

    const flow_ok = !has_flt and b.lay.cached_flow_cw >= 0 and b.lay.no_top_collapse and b.lay.no_bottom_collapse and b.style.clear == .none and b.style.aspect_ratio <= 0;
    if (!b.lay.state_valid and !flow_ok) return;

    b.lay.reusable = true;
    b.lay.flow_reusable = flow_ok and !ctx.isBfcRoot(b);
    b.lay.cached_page_x = b.x;
    b.lay.cached_page_y = b.y;
    b.lay.cache_gen = doc.layout_cache_gen;
}

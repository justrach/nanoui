//! The layout engine's entry: from a styled document to a box tree in page
//! coordinates. Box generation is in `gen.zig`; formatting contexts in `block`,
//! `inline`, `flex`, `grid`, `table`; `finish` makes coordinates final.
const std = @import("std");
const box = @import("box.zig");
const dom = @import("../dom.zig");
const css = @import("../css/style.zig");
const ctx = @import("ctx.zig");
const gen = @import("gen.zig");
const sizing = @import("sizing.zig");
const finish = @import("finish.zig");
const cascade = @import("../css/cascade.zig");
const dom_flags = @import("../dom_flags.zig");
const Allocator = std.mem.Allocator;

pub const Viewport = struct { width: f32, height: f32 };

/// Builds and lays out the box tree of `doc` (node.computed filled by the
/// cascade). Everything is in `arena`. Marks the document's layout clean.
pub fn run(arena: Allocator, doc: *dom.Document, viewport: Viewport, m: box.Measurer) !box.Tree {
    return runCached(arena, doc, viewport, m, false);
}

/// As `run`, adopting clean subtrees from the previous layout arena when `allow_cache` is true.
pub fn runCached(arena: Allocator, doc: *dom.Document, viewport: Viewport, m: box.Measurer, allow_cache: bool) !box.Tree {
    const perf = @import("../perf_rules.zig");
    perf.prof_layout_runs += 1;
    const t0 = perf.nowNs();
    var prev_gen: u32 = if (allow_cache) doc.box_generation else 0;
    doc.box_generation +%= 1;
    if (doc.box_generation == 0) {
        clearBoxes(doc);
        doc.box_generation = 1;
        prev_gen = 0;
    }
    var c: ctx.Ctx = .{
        .arena = arena,
        .m = m,
        .vw = @max(0, ctx.clean(viewport.width)),
        .vh = @max(0, ctx.clean(viewport.height)),
        .quirks = doc.quirks,
        .doc = doc,
        .prev_gen = prev_gen,
    };
    const root = try gen.build(&c, doc);
    const t1 = perf.nowNs();
    perf.prof_lay_gen_ns += t1 -| t0;
    ctx.setEdges(root, c.vw);
    _ = try sizing.layoutBfc(&c, root, c.vw, c.vh);
    const t2 = perf.nowNs();
    perf.prof_lay_size_ns += t2 -| t1;
    try finish.run(&c, root);
    perf.prof_lay_fin_ns += perf.nowNs() -| t2;
    dom_flags.clearSubtreeLayoutDirty(doc.node);
    doc.layout_dirty = false;
    doc.oof_dirty_node = null;
    return .{
        .root = root,
        .doc_w = root.content_w,
        .doc_h = root.content_h,
        .canvas = canvasOf(doc),
        .locked = viewportLocked(doc),
    };
}

/// Theorem 74 (`NanoUI.Speedometer3Apex.oof_relayout_boundary_equiv`):
/// Incrementally updates a single out-of-flow (`position: absolute` or `fixed`)
/// element `oof_node` inside `parent_box` without re-laying out normal-flow boxes.
pub fn relayoutOutOfFlow(arena: Allocator, doc: *dom.Document, tree: *box.Tree, viewport: Viewport, m: box.Measurer, oof_node: *dom.Node) !bool {
    if (doc.layout_dirty or !isConnected(oof_node) or oof_node.kind != .element or oof_node.in_top_layer) return false;
    if (oof_node.ns != .html or oof_node.shadow_root != null or oof_node.isTag("slot") or oof_node.isTag("details")) return false;
    const parent_node = oof_node.parent orelse return false;
    if (parent_node.kind != .element or parent_node.ns != .html or parent_node.shadow_root != null or parent_node.isTag("slot") or parent_node.isTag("details") or parent_node.liveBoxParts().len != 0) return false;
    const parent_box: *box.Box = if (parent_node.liveBox()) |raw| @ptrCast(@alignCast(raw)) else return false;
    if (parent_box.lay.center_v or parent_box.lay.inline_root) return false;
    if (oof_node.computed) |st| {
        if (st.display != .none) {
            if (!st.isOutOfFlow() or st.display == .contents) return false;
            switch (st.display) {
                .table_row, .table_cell, .table_row_group, .table_header_group, .table_footer_group, .table_caption, .table_column, .table_column_group => return false,
                else => {},
            }
            if (parent_box.kind == .flex) {
                // Flex containers always give OOF children static offset (bpLeft, bpTop).
            } else if (parent_box.kind == .block) {
                if (!((st.left.kind == .length or st.right.kind == .length) and (st.top.kind == .length or st.bottom.kind == .length))) return false;
            } else return false;
        } else if (parent_box.kind != .flex and parent_box.kind != .block) return false;
    } else if (parent_box.kind != .flex and parent_box.kind != .block) return false;

    var prev_b: ?*box.Box = null;
    var cur_b = parent_box.first_child;
    while (cur_b) |kb| {
        const next_b = kb.next;
        if (kb.node == oof_node) {
            if (prev_b) |pb| pb.next = next_b else parent_box.first_child = next_b;
            if (next_b == null) parent_box.last_child = prev_b;
            kb.next = null;
            kb.parent = null;
        } else {
            prev_b = kb;
        }
        cur_b = next_b;
    }
    var at: ?*dom.Node = oof_node;
    while (at) |n| : (at = n.nextDeep(oof_node)) {
        n.setBox(null);
    }
    if (oof_node.computed == null or oof_node.computed.?.display == .none) return true;

    var c: ctx.Ctx = .{
        .arena = arena,
        .m = m,
        .vw = @max(0, ctx.clean(viewport.width)),
        .vh = @max(0, ctx.clean(viewport.height)),
        .quirks = doc.quirks,
    };
    var g: gen.Gen = .{ .c = &c };
    try gen.element(&g, oof_node);
    if (g.stack.items.len != 1 or g.stack.items[0].tag != .box) return false;
    const new_b = g.stack.items[0].box.?;
    new_b.parent = parent_box;
    var after_box: ?*box.Box = null;
    var sib = oof_node.nextElement();
    outer: while (sib) |sn| : (sib = sn.nextElement()) {
        var kb = parent_box.first_child;
        while (kb) |cand| : (kb = cand.next) {
            if (cand.node == sn) {
                after_box = cand;
                break :outer;
            }
        }
    }
    if (after_box) |ab| {
        var pb: ?*box.Box = null;
        var kb = parent_box.first_child;
        while (kb) |cand| : (kb = cand.next) {
            if (cand == ab) break;
            pb = cand;
        }
        new_b.next = ab;
        if (pb) |p_box| p_box.next = new_b else parent_box.first_child = new_b;
    } else {
        parent_box.append(new_b);
    }
    new_b.x = ctx.bpLeft(parent_box);
    new_b.y = ctx.bpTop(parent_box);
    if (parent_box.kind == .flex) {
        sizing.staticPositions(parent_box, @max(0, parent_box.w - ctx.bpH(parent_box)), parent_box.h - ctx.bpV(parent_box));
    }
    var cb_abs: *box.Box = tree.root;
    var cb_fixed: ?*box.Box = null;
    var anc: ?*box.Box = parent_box;
    while (anc) |ab| : (anc = ab.parent) {
        if (cb_abs == tree.root and (ab.style.position != .static or ab.style.hasTransform())) cb_abs = ab;
        if (cb_fixed == null and ab.style.hasTransform()) cb_fixed = ab;
    }
    try finish.placeOutOfFlowChild(&c, new_b, parent_box.x, parent_box.y, .{ .abs = cb_abs, .fixed = cb_fixed });
    tree.doc_w = @max(tree.doc_w, tree.root.lay.extra_r);
    tree.doc_h = @max(tree.doc_h, tree.root.lay.extra_b);
    return true;
}

/// Containers take their sizes from the layout that just ran; what's in the ones
/// that moved is styled again. True when anything moved, and layout should run again
/// for `@container` rules and cq units to show.
pub fn updateContainers(e: *cascade.Engine) bool {
    if (e.containers.count() == 0) return false;
    var moved = false;
    var it = e.containers.keyIterator();
    while (it.next()) |key| {
        const n = key.*;
        const st = n.computed orelse continue;
        if (st.container_type == .normal) continue;
        const b = boxOf(n) orelse continue;
        const r = b.contentRect();
        if (r.w == n.container_w and r.h == n.container_h) continue;
        const same_w = r.w == n.container_w;
        n.container_w = r.w;
        n.container_h = r.h;
        // A height nothing can ask about needs no second look.
        if (same_w and st.container_type == .inline_size) continue;
        moved = true;
        var k: ?*dom.Node = n.first_child;
        while (k) |x| : (k = x.next) if (x.kind == .element) {
            _ = e.restyleSubtree(x) catch {};
        };
        if (n.shadow_root) |x| _ = e.restyleSubtree(x) catch {};
        _ = e.restyleSubtree(n) catch {};
    }
    return moved;
}

/// Every box pointer of the last layout goes: they die with its arena.
fn clearBoxes(doc: *dom.Document) void {
    var at: ?*dom.Node = doc.node;
    while (at) |n| {
        if (n.kind == .element) {
            if (n.box != null) n.box = null;
            if (n.box_parts.len != 0) n.box_parts = &.{};
            if (n.ns == .svg and n.isTag("svg") and (n.computed == null or n.computed.?.display != .contents)) {
                at = n.nextDeepSkipping(doc.node);
                continue;
            }
        }
        at = n.nextDeep(doc.node);
    }
}

fn viewportLocked(doc: *const dom.Document) bool {
    if (doc.documentElement()) |r| if (r.computed) |s| if (s.locks_viewport) return true;
    if (doc.body()) |b| if (b.computed) |s| return s.locks_viewport;
    return false;
}

fn canvasOf(doc: *const dom.Document) css.Color {
    if (doc.documentElement()) |r| if (r.computed) |s| if (s.background.a > 0) return s.background;
    if (doc.body()) |b| if (b.computed) |s| return s.background;
    return .transparent;
}

fn isConnected(node: *const dom.Node) bool {
    var at: ?*const dom.Node = node;
    while (at) |n| : (at = n.parent) if (n == node.doc.node) return true;
    return false;
}

fn boxOf(node: *const dom.Node) ?*box.Box {
    if (node.doc.layout_dirty or !isConnected(node)) return null;
    const p = node.liveBox() orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The node's first box's border box, in page coordinates: null when it has
/// none, or the tree changed since the last `run` (its pointer may be stale).
pub fn rectOf(node: *dom.Node) ?box.Rect {
    const b = boxOf(node) orelse return null;
    if (node.liveBoxParts().len == 0) return b.borderRect();
    return splitRect(node, b);
}

/// An inline split around blocks: the union of its lines and the lines the blocks
/// stand on, which are as wide as the block they sit in.
fn splitRect(node: *const dom.Node, first: *const box.Box) box.Rect {
    const parts = node.liveBoxParts();
    var x0 = first.x;
    var y0 = first.y;
    var x1 = first.x + first.w;
    var y1 = first.y + first.h;
    var inline_part = false;
    if (first.kind == .inline_box) inline_part = true;
    for (parts) |raw| {
        const p: *const box.Box = @ptrCast(@alignCast(raw));
        y0 = @min(y0, p.y - p.margin.top);
        y1 = @max(y1, p.y + p.h + p.margin.bottom);
        const within = if (p.parent) |q| q.contentRect() else p.borderRect();
        x0 = @min(x0, within.x);
        x1 = @max(x1, within.x + within.w);
    }
    // The block alone says where the box starts when no line came before it.
    if (!inline_part) if (parts.len > 0) {
        const p: *const box.Box = @ptrCast(@alignCast(parts[0]));
        y0 = p.y;
        y1 = @max(y0, y1 - p.margin.bottom);
    };
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// The box laid out for the node, under the same conditions as `rectOf`.
pub fn boxOfNode(node: *dom.Node) ?*box.Box {
    return boxOf(node);
}

/// `offsetParent`: the nearest positioned ancestor, or `td`, `th`, `table`
/// for a static box, or `body`. Null for `body`, fixed boxes, and what has no box.
pub fn offsetParent(node: *dom.Node) ?*dom.Node {
    const b = boxOf(node) orelse return null;
    if (b.style.position == .fixed or node.isTag("body")) return null;
    const is_static = b.style.position == .static;
    var at = node.parent;
    while (at) |p| : (at = p.parent) {
        if (p.kind != .element) break;
        if (p.isTag("body")) return p;
        if (p.computed) |s| {
            if (s.position != .static or s.hasTransform()) return p;
        }
        if (is_static and (p.isTag("td") or p.isTag("th") or p.isTag("table"))) return p;
    }
    return null;
}

test {
    _ = @import("box.zig");
}

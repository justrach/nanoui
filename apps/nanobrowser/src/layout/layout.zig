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
const Allocator = std.mem.Allocator;

pub const Viewport = struct { width: f32, height: f32 };

/// Builds and lays out the box tree of `doc` (node.computed filled by the
/// cascade). Everything is in `arena`. Marks the document's layout clean.
pub fn run(arena: Allocator, doc: *dom.Document, viewport: Viewport, m: box.Measurer) !box.Tree {
    clearBoxes(doc);
    var c: ctx.Ctx = .{
        .arena = arena,
        .m = m,
        .vw = @max(0, ctx.clean(viewport.width)),
        .vh = @max(0, ctx.clean(viewport.height)),
        .quirks = doc.quirks,
    };
    const root = try gen.build(&c, doc);
    ctx.setEdges(root, c.vw);
    _ = try sizing.layoutBfc(&c, root, c.vw, c.vh);
    try finish.run(&c, root);
    doc.layout_dirty = false;
    return .{
        .root = root,
        .doc_w = root.content_w,
        .doc_h = root.content_h,
        .canvas = canvasOf(doc),
        .locked = viewportLocked(doc),
    };
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
        n.box = null;
        n.box_parts = &.{};
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
    const p = node.box orelse return null;
    return @ptrCast(@alignCast(p));
}

/// The node's first box's border box, in page coordinates: null when it has
/// none, or the tree changed since the last `run` (its pointer may be stale).
pub fn rectOf(node: *dom.Node) ?box.Rect {
    const b = boxOf(node) orelse return null;
    if (node.box_parts.len == 0) return b.borderRect();
    return splitRect(node, b);
}

/// An inline split around blocks: the union of its lines and the lines the blocks
/// stand on, which are as wide as the block they sit in.
fn splitRect(node: *const dom.Node, first: *const box.Box) box.Rect {
    var x0 = first.x;
    var y0 = first.y;
    var x1 = first.x + first.w;
    var y1 = first.y + first.h;
    var inline_part = false;
    if (first.kind == .inline_box) inline_part = true;
    for (node.box_parts) |raw| {
        const p: *const box.Box = @ptrCast(@alignCast(raw));
        y0 = @min(y0, p.y - p.margin.top);
        y1 = @max(y1, p.y + p.h + p.margin.bottom);
        const within = if (p.parent) |q| q.contentRect() else p.borderRect();
        x0 = @min(x0, within.x);
        x1 = @max(x1, within.x + within.w);
    }
    // The block alone says where the box starts when no line came before it.
    if (!inline_part) if (node.box_parts.len > 0) {
        const p: *const box.Box = @ptrCast(@alignCast(node.box_parts[0]));
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

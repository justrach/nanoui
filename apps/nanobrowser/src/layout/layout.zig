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
    };
}

/// Every box pointer of the last layout goes: they die with its arena.
fn clearBoxes(doc: *dom.Document) void {
    var at: ?*dom.Node = doc.node;
    while (at) |n| {
        n.box = null;
        at = n.nextInTree(doc.node);
    }
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
    return if (boxOf(node)) |b| b.borderRect() else null;
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

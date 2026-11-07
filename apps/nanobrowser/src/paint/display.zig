//! A laid-out tree as a flat list of things to draw, in CSS's painting order:
//! within each stacking context the negative z-indexes, then block
//! backgrounds, floats, inline content, then positioned boxes by z-index.
//! Built once per layout; scrolling only moves `clips`, which a frame resolves
//! (`resolve`) before replaying the items (`replay.zig`).
const std = @import("std");
const dom = @import("../dom.zig");
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const transform_mod = @import("../css/transform.zig");
const wheel_target = @import("wheel_target.zig");
const corners = @import("corners.zig");
const boxes = @import("boxes.zig");
const filters = @import("filters.zig");
const text_items = @import("text_items.zig");
const builtin = @import("builtin");
const Box = box.Box;
const Rect = box.Rect;
const Allocator = std.mem.Allocator;
const Mat = css.fx.Mat;
pub const Corners = corners.Corners;

/// A transform that does more than move: everything inside is drawn through it.
/// `m` maps the document to the document; each frame `window` maps the window
/// to the window, as what it is in has scrolled.
pub const Xform = struct {
    parent: u32 = 0,
    /// The clip whose scrolling carries it.
    clip: u32 = 0,
    m: Mat = .{},
    window: Mat = .{},
    inverse: ?Mat = .{},
};

/// Clip 0 is the viewport (what `position: fixed` draws in), 1 the page's
/// scroller; the rest are boxes that clip or scroll, parents first.
pub const Clip = struct {
    parent: u32 = 0,
    node: ?*dom.Node = null,
    /// The padding box, in document coordinates.
    rect: Rect = .{},
    radius: f32 = 0,
    /// Which corners `radius` rounds, when not all do.
    corners: u4 = 15,
    /// A shape only the pointer goes by (`clip-path`), in the document.
    path: []const [2]f32 = &.{},
    /// The transform it is in.
    xform: u32 = 0,
    scrolls: bool = false,
    /// Which ways a person can scroll it: `hidden` is for scripts alone.
    wheel_x: bool = true,
    wheel_y: bool = true,
    /// How far its content reaches, from the padding box's top left.
    content_w: f32 = 0,
    content_h: f32 = 0,
    /// Where it is scrolled to (kept across layouts by the page).
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    /// `position: sticky`: clips nothing, moves what is in it.
    sticky: ?Sticky = null,
    /// This frame's, from `resolve`: what to subtract from a thing inside
    /// it, and the part of the window it shows.
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    visible: Rect = .{},
};

/// A box's place in the document, how far from the top it keeps, and where its
/// containing block ends.
pub const Sticky = struct { y: f32, h: f32, top: ?f32, bottom: ?f32, limit_top: f32, limit_bottom: f32 };

pub const Border = struct {
    widths: box.Edges,
    top: css.Border,
    right: css.Border,
    bottom: css.Border,
    left: css.Border,
    /// The border box's, when any is round.
    corners: ?*const Corners = null,
};

pub const Kind = union(enum) {
    /// Nothing drawn: only where the pointer finds its element.
    hit,
    fill: Fill,
    /// A fill whose corners differ, or aren't circles: nanoui has one radius.
    rounded: Rounded,
    /// A fill cut by a `clip-path` no rectangle can do.
    polygon: Polygon,
    border: Border,
    /// `box-shadow: inset`, in the padding box of `rect`.
    inset_shadow: InsetShadow,
    /// What's under it, blurred: `backdrop-filter`, and `filter: blur` on what
    /// has no shape of its own to blur.
    frost: Frost,
    /// An `opacity` that must apply to what's between as one picture.
    group_begin: f32,
    group_end,
    /// A line of text: decorations come as their own `fill`s.
    text: Text,
    /// An `<img>`'s picture, in the box's content rect.
    image: Image,
    /// `background-image`: `rect` is the area to cover.
    background: Background,
    gradient: Gradient,
    /// `mask-image`: the picture's shape filled with this color.
    mask: Mask,
    /// A bullet of a list.
    bullet: Bullet,
    /// A form control, drawn and edited by `controls.zig`.
    control: *const Box,
    pub const Rounded = struct { color: css.Color, corners: *const Corners };
    pub const Polygon = struct { color: css.Color, points: []const [2]f32 };
    pub const InsetShadow = struct { shadow: css.Shadow, corners: Corners };
    pub const Frost = struct { blur: f32, radius: f32 };
    /// Where a background layer goes. `dx`..`h`: its positioning area, from the
    /// item's rect.
    pub const BgLayer = struct {
        size: css.BgSize,
        pos: css.BgPos,
        repeat: css.BackgroundRepeat,
        dx: f32,
        dy: f32,
        w: f32,
        h: f32,
        fixed: bool,
    };
    pub const Gradient = struct { g: css.Gradient, layer: *const BgLayer, radius: f32, corners: u4 = 15 };
    pub const Mask = struct { url: []const u8, color: css.Color };
    pub const Bullet = struct { shape: css.ListStyle, color: css.Color };
    /// `solid_shadow`: a shadow that shows under the box too, as `filter: blur` needs.
    pub const Fill = struct { color: css.Color, radius: f32 = 0, shadow: ?css.Shadow = null, solid_shadow: bool = false };
    pub const Text = struct {
        str: []const u8,
        font: box.Font,
        color: css.Color,
        spacing: f32 = 0,
        baseline: f32,
        /// Its glyphs fill with these: `background-clip: text`.
        gradient: ?*const TextBackground = null,
    };
    /// One layer's tile, and where tiles start from the box's left.
    pub const TextLayer = struct { g: css.Gradient, x0: f32, w: f32, h: f32, repeats: bool };
    /// The box whose background shows through its text: its layers, topmost first.
    pub const TextBackground = struct { layers: []const TextLayer, color: css.Color, box_x: f32 };
    pub const Image = struct {
        node: *dom.Node,
        fit: css.ObjectFit,
        radius: f32,
        /// Which corners `radius` rounds, when not all do.
        corners: u4 = 15,
        /// Drawn in this one color: a filter that leaves only its shape.
        tint: ?css.Color = null,
        /// Its `object-position` and how an SVG takes the text's color.
        style: *const css.Style,
    };
    pub const Background = struct { url: []const u8, layer: *const BgLayer, radius: f32, corners: u4 = 15 };
};

pub const Item = struct {
    kind: Kind,
    rect: Rect,
    clip: u32,
    /// The transform it is drawn through; 0 for none.
    xform: u32 = 0,
    opacity: f32 = 1,
    /// The element the pointer finds here (null: it passes through).
    node: ?*dom.Node = null,
};

pub const List = struct {
    items: []const Item,
    clips: []Clip,
    /// Index 0 is no transform.
    xforms: []Xform,
    /// Some clip has a shape.
    any_paths: bool = false,
    doc_w: f32,
    doc_h: f32,
    canvas: css.Color,
    /// The `<iframe>`s' content boxes among `items`.
    frames: []const *const Item = &.{},

    /// Works out this frame's offsets and visible parts, for a viewport of
    /// `w` × `h` at (`x`, `y`) in the window.
    pub fn resolve(l: *List, x: f32, y: f32, w: f32, h: f32) void {
        const window: Rect = .{ .x = x, .y = y, .w = w, .h = h };
        var done: usize = 1;
        for (l.clips, 0..) |*c, i| {
            if (i == 0) {
                c.* = .{ .rect = window, .visible = window, .offset_x = -x, .offset_y = -y };
                continue;
            }
            // A transform's clip is always before what's made inside it.
            while (done <= c.xform) : (done += 1) l.resolveXform(done);
            const p = l.clips[c.parent];
            if (c.sticky) |s| {
                c.visible = p.visible;
                c.offset_x = p.offset_x;
                c.offset_y = p.offset_y - stickyShift(s, s.y - p.offset_y, p.visible);
                continue;
            }
            if (i == 1) {
                c.rect.w = w;
                c.rect.h = h;
            }
            var own: Rect = if (i == 1) window else .{ .x = c.rect.x - p.offset_x, .y = c.rect.y - p.offset_y, .w = c.rect.w, .h = c.rect.h };
            if (c.xform != 0) own = boundsOf(l.xforms[c.xform].window, own);
            c.visible = intersect(p.visible, own);
            c.offset_x = p.offset_x + c.scroll_x;
            c.offset_y = p.offset_y + c.scroll_y;
        }
        while (done < l.xforms.len) : (done += 1) l.resolveXform(done);
    }

    fn resolveXform(l: *List, i: usize) void {
        const t = &l.xforms[i];
        const o = l.clips[t.clip];
        const own = Mat.translate(-o.offset_x, -o.offset_y).times(t.m).times(Mat.translate(o.offset_x, o.offset_y));
        t.window = if (t.parent != 0) l.xforms[t.parent].window.times(own) else own;
        t.inverse = t.window.inverse();
    }

    /// The largest scroll of clip `i` in a viewport the size of its rect.
    pub fn maxScroll(l: *const List, i: u32) [2]f32 {
        const c = l.clips[i];
        return .{ @max(0, c.content_w - c.rect.w), @max(0, c.content_h - c.rect.h) };
    }

    /// Where an item is in the window this frame.
    pub fn placed(l: *const List, it: *const Item) Rect {
        const c = l.clips[it.clip];
        return .{ .x = it.rect.x - c.offset_x, .y = it.rect.y - c.offset_y, .w = it.rect.w, .h = it.rect.h };
    }

    /// The element at a point in the window, the topmost first.
    pub fn hit(l: *const List, x: f32, y: f32) ?*dom.Node {
        var i = l.items.len;
        while (i > 0) {
            i -= 1;
            const it = &l.items[i];
            const n = it.node orelse continue;
            const c = l.clips[it.clip];
            if (!c.visible.contains(x, y)) continue;
            if (l.any_paths and !l.withinPaths(it.clip, x, y)) continue;
            var at: [2]f32 = .{ x, y };
            if (it.xform != 0) at = (l.xforms[it.xform].inverse orelse continue).apply(x, y);
            if (l.placed(it).contains(at[0], at[1])) return n;
        }
        return null;
    }

    /// Whether a point is inside the `clip-path`s of a clip and those around it.
    fn withinPaths(l: *const List, clip: u32, x: f32, y: f32) bool {
        var i = clip;
        while (i > 1) : (i = l.clips[i].parent) {
            const c = l.clips[i];
            if (c.path.len == 0) continue;
            var at: [2]f32 = .{ x, y };
            if (c.xform != 0) at = (l.xforms[c.xform].inverse orelse return false).apply(x, y);
            const p = l.clips[c.parent];
            if (!inPolygon(c.path, at[0] + p.offset_x, at[1] + p.offset_y)) return false;
        }
        return true;
    }

    pub const scrollerAt = wheel_target.scrollerAt;
    pub const canMove = wheel_target.canMove;
};

/// How far a sticky box is moved from `y`, where it would be in the window.
fn stickyShift(s: Sticky, y: f32, visible: Rect) f32 {
    var shift: f32 = 0;
    if (s.top) |t| shift = @max(0, visible.y + t - y);
    if (s.bottom) |b| shift = @min(shift, visible.y + visible.h - b - (y + s.h));
    return std.math.clamp(shift, s.limit_top - s.y, @max(s.limit_top - s.y, s.limit_bottom - s.y - s.h));
}

fn inPolygon(path: []const [2]f32, x: f32, y: f32) bool {
    var inside = false;
    var j = path.len - 1;
    for (path, 0..) |p, i| {
        const q = path[j];
        if ((p[1] > y) != (q[1] > y) and x < (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1]) + p[0]) inside = !inside;
        j = i;
    }
    return inside;
}

/// The smallest rectangle holding what `m` makes of `r`.
pub fn boundsOf(m: Mat, r: Rect) Rect {
    const xs = [4]f32{ r.x, r.x + r.w, r.x, r.x + r.w };
    const ys = [4]f32{ r.y, r.y, r.y + r.h, r.y + r.h };
    var x0 = std.math.inf(f32);
    var y0 = std.math.inf(f32);
    var x1 = -std.math.inf(f32);
    var y1 = -std.math.inf(f32);
    for (xs, ys) |x, y| {
        const p = m.apply(x, y);
        x0 = @min(x0, p[0]);
        y0 = @min(y0, p[1]);
        x1 = @max(x1, p[0]);
        y1 = @max(y1, p[1]);
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

pub fn intersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
}

/// Where a walk is: which clip is around it, the one absolute boxes inside
/// use (their containing block's, not whatever is between), and what
/// transforms and opacities have added up to.
pub const At = struct {
    clip: u32,
    abs_clip: u32,
    tx: f32 = 0,
    ty: f32 = 0,
    opacity: f32 = 1,
    xform: u32 = 0,
    /// A transform around it: `position: fixed` is held by that, not the window.
    in_transform: bool = false,
    /// A box around it whose background is cut to its text.
    text_bg: ?*const Kind.TextBackground = null,
};

const Entry = struct { z: i32, items: []const Item = &.{} };
const Entries = std.ArrayList(Entry);

/// What paints as one unit, in tree order within each list. `stacked` is its
/// stacking context's: a box that only paints as if it had one (positioned with
/// no z-index, a float, an inline-block) leaves what is positioned in it to the
/// real one around it, as CSS's Appendix E says.
const Layer = struct {
    /// How many of `blocks` are the context's own background.
    own: usize = 0,
    blocks: std.ArrayList(Item) = .empty,
    floats: std.ArrayList(Item) = .empty,
    inlines: std.ArrayList(Item) = .empty,
    stacked: *Entries,
};

/// At most this many opacity groups a list: each costs a pass of the renderer.
const max_groups = 12;
const groups_supported = builtin.os.tag == .macos or builtin.os.tag == .ios;

pub const Builder = struct {
    arena: Allocator,
    m: box.Measurer,
    clips: std.ArrayList(Clip) = .empty,
    xforms: std.ArrayList(Xform) = .empty,
    any_paths: bool = false,
    groups: u32 = 0,
    /// Scroll offsets to keep across layouts, by element.
    scrolls: *const std.AutoHashMapUnmanaged(*dom.Node, [2]f32),

    pub fn add(b: *Builder, list: *std.ArrayList(Item), it: Item) !void {
        try list.append(b.arena, it);
    }

    /// A stacking context: a box and all that's in it, as one list.
    fn atomic(b: *Builder, x: *const Box, at: At) Allocator.Error![]const Item {
        var entries: Entries = .empty;
        var layer: Layer = .{ .stacked = &entries };
        try boxes.self(b, x, at, &layer.blocks);
        layer.own = layer.blocks.items.len;
        const inner = try b.inside(x, at);
        try b.children(x, inner, &layer);
        return b.flatten(&layer, entries.items);
    }

    /// A box that paints as one unit in its context, what's stacked in it going
    /// to that context instead.
    fn unit(b: *Builder, x: *const Box, at: At, entries: *Entries) Allocator.Error![]const Item {
        var layer: Layer = .{ .stacked = entries };
        try boxes.self(b, x, at, &layer.blocks);
        layer.own = layer.blocks.items.len;
        const inner = try b.inside(x, at);
        try b.children(x, inner, &layer);
        return b.flatten(&layer, &.{});
    }

    fn flatten(b: *Builder, layer: *Layer, entries: []Entry) Allocator.Error![]const Item {
        std.mem.sort(Entry, entries, {}, struct {
            fn less(_: void, p: Entry, q: Entry) bool {
                return p.z < q.z;
            }
        }.less);
        var n = layer.blocks.items.len + layer.floats.items.len + layer.inlines.items.len;
        for (entries) |e| n += e.items.len;
        const out = try b.arena.alloc(Item, n);
        var at: usize = 0;
        const put = struct {
            fn f(dst: []Item, i: *usize, src: []const Item) void {
                @memcpy(dst[i.*..][0..src.len], src);
                i.* += src.len;
            }
        }.f;
        // Negative z-indexes go above the context's own background: the
        // first of `blocks`, which is that background when it has one.
        const own = @min(layer.blocks.items.len, layer.own);
        put(out, &at, layer.blocks.items[0..own]);
        for (entries) |e| if (e.z < 0) put(out, &at, e.items);
        put(out, &at, layer.blocks.items[own..]);
        put(out, &at, layer.floats.items);
        put(out, &at, layer.inlines.items);
        for (entries) |e| if (e.z >= 0) put(out, &at, e.items);
        return out;
    }

    /// The `At` for what a box holds: its clip, if it clips.
    fn inside(b: *Builder, x: *const Box, at_in: At) !At {
        var at = at_in;
        const st = x.style;
        if (try boxes.textBackground(b, x, at)) |bg| at.text_bg = bg;
        const clips_it = st.clips() and x.kind != .inline_box;
        if (clips_it) {
            const pad = x.paddingRect();
            const keep = if (x.node) |n| b.scrolls.get(n) else null;
            const inner = Corners.of(st, x.w, x.h).inset(x.border.top, x.border.right, x.border.bottom, x.border.left);
            try b.clips.append(b.arena, .{
                .parent = at.clip,
                .node = x.node,
                .rect = .{ .x = pad.x + at.tx, .y = pad.y + at.ty, .w = pad.w, .h = pad.h },
                .radius = inner.largest(),
                .corners = inner.mask(),
                .xform = at.xform,
                .scrolls = st.scrolls() or st.overflow_x == .scroll or st.overflow_x == .auto,
                .wheel_x = st.overflow_x == .scroll or st.overflow_x == .auto,
                .wheel_y = st.scrolls(),
                .content_w = x.content_w,
                .content_h = x.content_h,
                .scroll_x = if (keep) |k| k[0] else 0,
                .scroll_y = if (keep) |k| k[1] else 0,
            });
            at.clip = @intCast(b.clips.items.len - 1);
        }
        if (st.position != .static) at.abs_clip = at.clip;
        return at;
    }

    fn children(b: *Builder, x: *const Box, at: At, layer: *Layer) Allocator.Error!void {
        try text_items.runs(b, x, at, &layer.inlines);
        var c = x.first_child;
        while (c) |k| : (c = k.next) try b.walk(k, at, layer);
    }

    fn walk(b: *Builder, x: *const Box, at_in: At, layer: *Layer) Allocator.Error!void {
        var at = at_in;
        const st = x.style;
        if (st.position == .fixed and !at.in_transform) {
            at.clip = 0;
            at.abs_clip = 0;
            at.tx = 0;
            at.ty = 0;
            at.xform = 0;
        } else if (st.position == .absolute or st.position == .fixed) at.clip = at.abs_clip;
        // A span in a line isn't transformed; what holds its own flow is.
        if (st.hasTransform() and x.kind != .inline_box) {
            at.in_transform = true;
            if (transform_mod.of(st, x.w, x.h)) |m| {
                if (m.onlyMoves()) {
                    at.tx += m.e;
                    at.ty += m.f;
                } else {
                    const ox = x.x + at.tx;
                    const oy = x.y + at.ty;
                    try b.xforms.append(b.arena, .{ .parent = at.xform, .clip = at.clip, .m = Mat.translate(ox, oy).times(m).times(Mat.translate(-ox, -oy)) });
                    at.xform = @intCast(b.xforms.items.len - 1);
                }
            }
        }
        if (st.position == .sticky) try b.stickyClip(x, &at);
        if (try boxes.shapeClip(b, x, &at)) at.abs_clip = at.clip;

        const in_flex = if (x.parent) |p| p.style.isFlex() or p.style.isGrid() else false;
        const zed = st.z_index != null and (st.position != .static or in_flex);
        const context = zed or st.position == .fixed or st.position == .sticky or st.opacity < 1 or st.hasTransform() or st.filters.len > 0 or st.clip_path != null or st.backdrop_blur > 0 or st.makes_context;
        if (context) {
            const z = if (zed) st.z_index.? else 0;
            try layer.stacked.append(b.arena, .{ .z = z, .items = try b.stacked(x, at) });
            return;
        }
        if (st.position != .static) {
            // In its place among them; what's stacked inside comes after it.
            const place = layer.stacked.items.len;
            try layer.stacked.append(b.arena, .{ .z = 0 });
            const items = try b.unit(x, at, layer.stacked);
            layer.stacked.items[place].items = items;
            return;
        }
        if (st.float != .none) {
            try layer.floats.appendSlice(b.arena, try b.unit(x, at, layer.stacked));
            return;
        }
        // Inline-level things that hold their own flow paint as one, with
        // the inline content around them.
        if (st.isInlineLevel() and st.display != .inline_ or x.kind == .replaced or x.kind == .control) {
            try layer.inlines.appendSlice(b.arena, try b.unit(x, at, layer.stacked));
            return;
        }
        try boxes.self(b, x, at, if (x.kind == .inline_box) &layer.inlines else &layer.blocks);
        try b.children(x, try b.inside(x, at), layer);
    }

    /// A stacking context's list: its filters and its opacity done to it whole.
    fn stacked(b: *Builder, x: *const Box, at: At) Allocator.Error![]const Item {
        const st = x.style;
        var items = try b.atomic(x, at);
        if (st.filters.len > 0) items = try filters.apply(b, x, at, items);
        if (st.opacity >= 1) return items;
        // Over something opaque of its own, its parts mustn't show through
        // each other: the whole is drawn, then faded.
        if (groups_supported and b.groups < max_groups and needsGroup(items)) {
            b.groups += 1;
            const out = try b.arena.alloc(Item, items.len + 2);
            out[0] = .{ .kind = .{ .group_begin = st.opacity }, .rect = .{}, .clip = at.clip };
            @memcpy(out[1 .. items.len + 1], items);
            out[items.len + 1] = .{ .kind = .group_end, .rect = .{}, .clip = at.clip };
            return out;
        }
        const out = try b.arena.dupe(Item, items);
        for (out) |*it| switch (it.kind) {
            .group_begin => |o| it.kind = .{ .group_begin = o * st.opacity },
            else => it.opacity *= st.opacity,
        };
        return out;
    }

    fn needsGroup(items: []const Item) bool {
        var backed = false;
        for (items) |it| switch (it.kind) {
            .hit, .group_begin, .group_end, .frost => {},
            .fill => |f| {
                if (f.color.a > 0) {
                    if (backed) return true;
                    backed = true;
                }
            },
            else => if (backed) return true else {
                backed = it.kind != .text;
            },
        };
        return false;
    }

    /// Keeps a sticky box's whole unit in a clip entry that moves it.
    fn stickyClip(b: *Builder, x: *const Box, at: *At) !void {
        const st = x.style;
        const within = x.parent orelse return;
        const cb = within.contentRect();
        const y = x.y + at.ty;
        const top: ?f32 = if (st.top.kind == .length) st.top.resolve(cb.h, 0) else null;
        const bottom: ?f32 = if (st.bottom.kind == .length) st.bottom.resolve(cb.h, 0) else null;
        if (top == null and bottom == null) return;
        try b.clips.append(b.arena, .{ .parent = at.clip, .node = x.node, .xform = at.xform, .sticky = .{
            .y = y,
            .h = x.h,
            .top = top,
            .bottom = bottom,
            .limit_top = cb.y + at.ty,
            .limit_bottom = cb.y + cb.h + at.ty,
        } });
        at.clip = @intCast(b.clips.items.len - 1);
    }
};

/// The display list of `tree`.
/// `doc`: the page's own scroll is kept in `scrolls` under its node.
pub fn build(arena: Allocator, tree: box.Tree, doc: *dom.Node, m: box.Measurer, scrolls: *const std.AutoHashMapUnmanaged(*dom.Node, [2]f32)) Allocator.Error!List {
    var b: Builder = .{ .arena = arena, .m = m, .scrolls = scrolls };
    try b.xforms.append(arena, .{});
    try b.clips.append(arena, .{});
    const doc_scroll = scrolls.get(doc) orelse .{ 0, 0 };
    try b.clips.append(arena, .{ .parent = 0, .scrolls = !tree.locked, .content_w = tree.doc_w, .content_h = tree.doc_h, .scroll_x = doc_scroll[0], .scroll_y = doc_scroll[1] });
    const items = try b.atomic(tree.root, .{ .clip = 1, .abs_clip = 1 });
    var frames: std.ArrayList(*const Item) = .empty;
    for (items) |*it| if (it.kind == .image and it.kind.image.node.isTag("iframe")) try frames.append(arena, it);
    return .{ .items = items, .clips = b.clips.items, .xforms = b.xforms.items, .any_paths = b.any_paths, .doc_w = tree.doc_w, .doc_h = tree.doc_h, .canvas = tree.canvas, .frames = frames.items };
}

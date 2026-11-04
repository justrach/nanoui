//! A laid-out tree as a flat list of things to draw, in CSS's painting order:
//! within each stacking context the negative z-indexes, then block
//! backgrounds, floats, inline content, then positioned boxes by z-index.
//! Built once per layout; scrolling only moves `clips`, which a frame resolves
//! (`resolve`) before replaying the items (`replay.zig`).
const std = @import("std");
const dom = @import("../dom.zig");
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const paint_gradient = @import("gradient.zig");
const Box = box.Box;
const Rect = box.Rect;
const Allocator = std.mem.Allocator;

/// Clip 0 is the viewport (what `position: fixed` draws in), 1 the page's
/// scroller; the rest are boxes that clip or scroll, parents first.
pub const Clip = struct {
    parent: u32 = 0,
    node: ?*dom.Node = null,
    /// The padding box, in document coordinates.
    rect: Rect = .{},
    radius: f32 = 0,
    scrolls: bool = false,
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
};

pub const Kind = union(enum) {
    /// Nothing drawn: only where the pointer finds its element.
    hit,
    fill: Fill,
    border: Border,
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
    pub const Gradient = struct { g: css.Gradient, style: *const css.Style, radius: f32 };
    pub const Mask = struct { url: []const u8, color: css.Color };
    pub const Bullet = struct { shape: css.ListStyle, color: css.Color };
    pub const Fill = struct { color: css.Color, radius: f32 = 0, shadow: ?css.Shadow = null };
    pub const Text = struct { str: []const u8, font: box.Font, color: css.Color, spacing: f32 = 0, baseline: f32 };
    pub const Image = struct { node: *dom.Node, fit: css.ObjectFit, radius: f32 };
    pub const Background = struct { url: []const u8, style: *const css.Style, radius: f32 };
};

pub const Item = struct {
    kind: Kind,
    rect: Rect,
    clip: u32,
    opacity: f32 = 1,
    /// The element the pointer finds here (null: it passes through).
    node: ?*dom.Node = null,
};

pub const List = struct {
    items: []const Item,
    clips: []Clip,
    doc_w: f32,
    doc_h: f32,
    canvas: css.Color,

    /// Works out this frame's offsets and visible parts, for a viewport of
    /// `w` × `h` at (`x`, `y`) in the window.
    pub fn resolve(l: *List, x: f32, y: f32, w: f32, h: f32) void {
        const window: Rect = .{ .x = x, .y = y, .w = w, .h = h };
        for (l.clips, 0..) |*c, i| {
            if (i == 0) {
                c.* = .{ .rect = window, .visible = window, .offset_x = -x, .offset_y = -y };
                continue;
            }
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
            const own: Rect = if (i == 1) window else .{ .x = c.rect.x - p.offset_x, .y = c.rect.y - p.offset_y, .w = c.rect.w, .h = c.rect.h };
            c.visible = intersect(p.visible, own);
            c.offset_x = p.offset_x + c.scroll_x;
            c.offset_y = p.offset_y + c.scroll_y;
        }
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
            if (l.placed(it).contains(x, y)) return n;
        }
        return null;
    }

    /// The innermost box that scrolls under a point, else the page (1).
    pub fn scrollerAt(l: *const List, x: f32, y: f32) u32 {
        var i = l.clips.len;
        while (i > 2) {
            i -= 1;
            const c = l.clips[i];
            if (c.scrolls and c.visible.contains(x, y)) {
                const m = l.maxScroll(@intCast(i));
                if (m[0] > 0 or m[1] > 0) return @intCast(i);
            }
        }
        return 1;
    }
};

/// How far a sticky box is moved from `y`, where it would be in the window.
fn stickyShift(s: Sticky, y: f32, visible: Rect) f32 {
    var shift: f32 = 0;
    if (s.top) |t| shift = @max(0, visible.y + t - y);
    if (s.bottom) |b| shift = @min(shift, visible.y + visible.h - b - (y + s.h));
    return std.math.clamp(shift, s.limit_top - s.y, @max(s.limit_top - s.y, s.limit_bottom - s.y - s.h));
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
const At = struct {
    clip: u32,
    abs_clip: u32,
    tx: f32 = 0,
    ty: f32 = 0,
    opacity: f32 = 1,
};

const Entry = struct { z: i32, items: []const Item };

/// One stacking context's lists, each in tree order.
const Layer = struct {
    blocks: std.ArrayList(Item) = .empty,
    floats: std.ArrayList(Item) = .empty,
    inlines: std.ArrayList(Item) = .empty,
    stacked: std.ArrayList(Entry) = .empty,
};

const Builder = struct {
    arena: Allocator,
    m: box.Measurer,
    clips: std.ArrayList(Clip) = .empty,
    /// Scroll offsets to keep across layouts, by element.
    scrolls: *const std.AutoHashMapUnmanaged(*dom.Node, [2]f32),

    fn add(b: *Builder, list: *std.ArrayList(Item), it: Item) !void {
        try list.append(b.arena, it);
    }

    /// Everything of a box that paints as one unit, as one list.
    fn atomic(b: *Builder, x: *const Box, at: At) Allocator.Error![]const Item {
        var layer: Layer = .{};
        try b.self(x, at, &layer.blocks);
        const inner = try b.inside(x, at);
        try b.children(x, inner, &layer);
        return b.flatten(&layer);
    }

    fn flatten(b: *Builder, layer: *Layer) Allocator.Error![]const Item {
        std.mem.sort(Entry, layer.stacked.items, {}, struct {
            fn less(_: void, p: Entry, q: Entry) bool {
                return p.z < q.z;
            }
        }.less);
        var n = layer.blocks.items.len + layer.floats.items.len + layer.inlines.items.len;
        for (layer.stacked.items) |e| n += e.items.len;
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
        const own = @min(layer.blocks.items.len, ownCount(layer));
        put(out, &at, layer.blocks.items[0..own]);
        for (layer.stacked.items) |e| if (e.z < 0) put(out, &at, e.items);
        put(out, &at, layer.blocks.items[own..]);
        put(out, &at, layer.floats.items);
        put(out, &at, layer.inlines.items);
        for (layer.stacked.items) |e| if (e.z >= 0) put(out, &at, e.items);
        return out;
    }

    fn ownCount(layer: *const Layer) usize {
        const first = if (layer.blocks.items.len > 0) layer.blocks.items[0].node else return 0;
        var n: usize = 0;
        for (layer.blocks.items) |it| {
            if (it.node != first) break;
            n += 1;
        }
        return n;
    }

    /// The `At` for what a box holds: its clip, if it clips.
    fn inside(b: *Builder, x: *const Box, at_in: At) !At {
        var at = at_in;
        const st = x.style;
        const clips_it = st.clips() and x.kind != .inline_box;
        if (clips_it) {
            const pad = x.paddingRect();
            const keep = if (x.node) |n| b.scrolls.get(n) else null;
            try b.clips.append(b.arena, .{
                .parent = at.clip,
                .node = x.node,
                .rect = .{ .x = pad.x + at.tx, .y = pad.y + at.ty, .w = pad.w, .h = pad.h },
                .radius = st.radius[0],
                .scrolls = st.scrolls() or st.overflow_x == .scroll or st.overflow_x == .auto,
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
        try b.runs(x, at, &layer.inlines);
        var c = x.first_child;
        while (c) |k| : (c = k.next) try b.walk(k, at, layer);
    }

    fn walk(b: *Builder, x: *const Box, at_in: At, layer: *Layer) Allocator.Error!void {
        var at = at_in;
        const st = x.style;
        if (st.position == .fixed) {
            at.clip = 0;
            at.abs_clip = 0;
            at.tx = 0;
            at.ty = 0;
        } else if (st.position == .absolute) at.clip = at.abs_clip;
        if (st.transform) |t| {
            at.tx += t.x.resolve(x.w, 0);
            at.ty += t.y.resolve(x.h, 0);
        }
        at.opacity *= st.opacity;
        if (st.position == .sticky) try b.stickyClip(x, &at);

        const stacks = st.position != .static or st.opacity < 1 or st.transform != null;
        if (stacks) {
            const z = st.z_index orelse 0;
            try layer.stacked.append(b.arena, .{ .z = z, .items = try b.atomic(x, at) });
            return;
        }
        if (st.float != .none) {
            try layer.floats.appendSlice(b.arena, try b.atomic(x, at));
            return;
        }
        // Inline-level things that hold their own flow paint as one, with
        // the inline content around them.
        if (st.isInlineLevel() and st.display != .inline_ or x.kind == .replaced or x.kind == .control) {
            try layer.inlines.appendSlice(b.arena, try b.atomic(x, at));
            return;
        }
        try b.self(x, at, if (x.kind == .inline_box) &layer.inlines else &layer.blocks);
        try b.children(x, try b.inside(x, at), layer);
    }

    /// One background layer, cut to its clip's box.
    fn bgLayer(b: *Builder, list: *std.ArrayList(Item), x: *const Box, st: *const css.Style, r: Rect, radius: f32, url: []const u8, gradient_in: ?css.Gradient, clip: css.BackgroundClip, at: At, node: ?*dom.Node) !void {
        var e: box.Edges = .{};
        if (clip != .border_box) e = x.border;
        if (clip == .content_box) {
            e.top += x.padding.top;
            e.right += x.padding.right;
            e.bottom += x.padding.bottom;
            e.left += x.padding.left;
        }
        const area: Rect = .{ .x = r.x + e.left, .y = r.y + e.top, .w = @max(0, r.w - e.horizontal()), .h = @max(0, r.h - e.vertical()) };
        const round = @max(0, radius - @max(e.left, e.top));
        if (gradient_in) |g| {
            const kind: Kind = if (paint_gradient.solid(g)) |c| .{ .fill = .{ .color = c, .radius = round } } else .{ .gradient = .{ .g = g, .style = st, .radius = round } };
            try b.add(list, .{ .kind = kind, .rect = area, .clip = at.clip, .opacity = at.opacity, .node = node });
        }
        if (url.len > 0) try b.add(list, .{ .kind = .{ .background = .{ .url = url, .style = st, .radius = round } }, .rect = area, .clip = at.clip, .opacity = at.opacity, .node = node });
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
        try b.clips.append(b.arena, .{ .parent = at.clip, .node = x.node, .sticky = .{
            .y = y,
            .h = x.h,
            .top = top,
            .bottom = bottom,
            .limit_top = cb.y + at.ty,
            .limit_bottom = cb.y + cb.h + at.ty,
        } });
        at.clip = @intCast(b.clips.items.len - 1);
    }

    /// A box's background, border, shadow, its picture or control.
    fn self(b: *Builder, x: *const Box, at: At, list: *std.ArrayList(Item)) !void {
        const st = x.style;
        if (st.display == .contents) return;
        const hits = st.pointer_events and x.node != null;
        const node = if (hits) x.node else null;
        const rects: []const Rect = if (x.kind == .inline_box and x.frags.len > 0) x.frags else &.{x.borderRect()};
        for (rects) |r0| {
            const r: Rect = .{ .x = r0.x + at.tx, .y = r0.y + at.ty, .w = r0.w, .h = r0.h };
            try b.add(list, .{ .kind = .hit, .rect = r, .clip = at.clip, .node = node });
            if (st.visibility != .visible) continue;
            const radius = cornerRadius(st, r.w);
            if (st.shadow) |sh| if (sh.color.a > 0) try b.add(list, .{ .kind = .{ .fill = .{ .color = .transparent, .radius = radius, .shadow = sh } }, .rect = r, .clip = at.clip, .opacity = at.opacity });
            if (st.mask_image.len > 0) {
                // The background shows only through the picture's shape.
                const ink = if (st.background.a > 0) st.background else st.color;
                try b.add(list, .{ .kind = .{ .mask = .{ .url = st.mask_image, .color = ink } }, .rect = r, .clip = at.clip, .opacity = at.opacity, .node = node });
                continue;
            }
            if (st.background.a > 0) try b.add(list, .{ .kind = .{ .fill = .{ .color = st.background, .radius = radius } }, .rect = r, .clip = at.clip, .opacity = at.opacity, .node = node });
            // The last layer first: the first is on top.
            var more = st.background_more.len;
            while (more > 0) {
                more -= 1;
                const l = st.background_more[more];
                try b.bgLayer(list, x, st, r, radius, l.url, l.gradient, l.clip, at, node);
            }
            try b.bgLayer(list, x, st, r, radius, st.background_image, st.background_gradient, st.background_clip, at, node);
            if (x.border.top > 0 or x.border.right > 0 or x.border.bottom > 0 or x.border.left > 0)
                try b.add(list, .{ .kind = .{ .border = .{ .widths = x.border, .top = st.border_top, .right = st.border_right, .bottom = st.border_bottom, .left = st.border_left } }, .rect = r, .clip = at.clip, .opacity = at.opacity });
        }
        if (st.visibility != .visible) return;
        const content = x.contentRect();
        const cr: Rect = .{ .x = content.x + at.tx, .y = content.y + at.ty, .w = content.w, .h = content.h };
        if (x.kind == .replaced) if (x.node) |n| {
            try b.add(list, .{ .kind = .{ .image = .{ .node = n, .fit = st.object_fit, .radius = cornerRadius(st, x.w) } }, .rect = cr, .clip = at.clip, .opacity = at.opacity, .node = node });
        };
        if (x.kind == .control) try b.add(list, .{ .kind = .{ .control = x }, .rect = .{ .x = x.x + at.tx, .y = x.y + at.ty, .w = x.w, .h = x.h }, .clip = at.clip, .opacity = at.opacity, .node = node });
        if (x.marker) |m| try b.add(list, .{ .kind = .{ .bullet = .{ .shape = st.list_style, .color = st.color } }, .rect = .{ .x = m.x + at.tx, .y = m.y + at.ty, .w = m.w, .h = m.h }, .clip = at.clip, .opacity = at.opacity });
        if (st.outline.width > 0 and st.outline.style != .none and st.outline.color.a > 0) {
            const w = st.outline.width;
            const r: Rect = .{ .x = x.x + at.tx - w, .y = x.y + at.ty - w, .w = x.w + 2 * w, .h = x.h + 2 * w };
            const o = st.outline;
            try b.add(list, .{ .kind = .{ .border = .{ .widths = .{ .top = w, .right = w, .bottom = w, .left = w }, .top = o, .right = o, .bottom = o, .left = o } }, .rect = r, .clip = at.clip, .opacity = at.opacity });
        }
    }

    fn runs(b: *Builder, x: *const Box, at: At, list: *std.ArrayList(Item)) !void {
        for (x.runs) |*run| {
            const st = run.style;
            const node = textOwner(run, x);
            const line: Rect = .{ .x = run.x + at.tx, .y = run.line_top + at.ty, .w = run.w, .h = run.line_h };
            if (st.pointer_events) try b.add(list, .{ .kind = .hit, .rect = line, .clip = at.clip, .node = node });
            if (st.visibility != .visible or run.font.size <= 0) continue;
            const metrics = b.m.metrics(b.m.ctx, run.font);
            try b.decorations(run, metrics, at, list);
            if (run.word_spacing == 0) {
                try b.text(run, run.text, run.x + at.tx, run.baseline + at.ty, metrics, at, list);
                continue;
            }
            // Justified or spaced words, each put where it goes.
            var pen = run.x + at.tx;
            const space = b.m.width(b.m.ctx, " ", run.font) + run.word_spacing;
            var words = std.mem.splitScalar(u8, run.text, ' ');
            while (words.next()) |w| {
                if (w.len > 0) try b.text(run, w, pen, run.baseline + at.ty, metrics, at, list);
                pen += b.m.width(b.m.ctx, w, run.font) + space;
            }
        }
    }

    fn text(b: *Builder, run: *const box.TextRun, s: []const u8, x: f32, baseline: f32, metrics: box.Metrics, at: At, list: *std.ArrayList(Item)) !void {
        const top = baseline - metrics.ascent - metrics.gap / 2;
        try b.add(list, .{
            .kind = .{ .text = .{ .str = s, .font = run.font, .color = run.style.color, .spacing = run.spacing, .baseline = baseline } },
            .rect = .{ .x = x, .y = top, .w = run.w, .h = metrics.ascent + metrics.descent + metrics.gap },
            .clip = at.clip,
            .opacity = at.opacity,
        });
    }

    fn decorations(b: *Builder, run: *const box.TextRun, m: box.Metrics, at: At, list: *std.ArrayList(Item)) !void {
        const st = run.style;
        if (!st.underline and !st.line_through and !st.overline) return;
        const color = st.text_decoration_color orelse st.color;
        const t = @max(1, run.font.size / 14);
        const base = run.baseline + at.ty;
        const line = struct {
            fn add(bb: *Builder, l: *std.ArrayList(Item), r: *const box.TextRun, y: f32, h: f32, c: css.Color, aa: At) !void {
                try bb.add(l, .{ .kind = .{ .fill = .{ .color = c } }, .rect = .{ .x = r.x + aa.tx, .y = y, .w = r.w, .h = h }, .clip = aa.clip, .opacity = aa.opacity });
            }
        }.add;
        if (st.underline) try line(b, list, run, base + m.descent * 0.35, t, color, at);
        if (st.line_through) try line(b, list, run, base - m.ascent * 0.32, t, color, at);
        if (st.overline) try line(b, list, run, base - m.ascent, t, color, at);
    }
};

fn textOwner(run: *const box.TextRun, x: *const Box) ?*dom.Node {
    if (run.node) |n| return n.parentElement() orelse x.node;
    return x.node;
}

/// Nanoui rounds a box by one radius: the largest of its corners, unless
/// only some corners are round and the box would then look wrong for it.
pub fn cornerRadius(st: *const css.Style, w: f32) f32 {
    var r: f32 = 0;
    for (st.radius, st.radius_pct) |px, pct| r = @max(r, px + pct * w / 100);
    return r;
}

/// The display list of `tree`.
/// `doc`: the page's own scroll is kept in `scrolls` under its node.
pub fn build(arena: Allocator, tree: box.Tree, doc: *dom.Node, m: box.Measurer, scrolls: *const std.AutoHashMapUnmanaged(*dom.Node, [2]f32)) Allocator.Error!List {
    var b: Builder = .{ .arena = arena, .m = m, .scrolls = scrolls };
    try b.clips.append(arena, .{});
    const doc_scroll = scrolls.get(doc) orelse .{ 0, 0 };
    try b.clips.append(arena, .{ .parent = 0, .scrolls = true, .content_w = tree.doc_w, .content_h = tree.doc_h, .scroll_x = doc_scroll[0], .scroll_y = doc_scroll[1] });
    const items = try b.atomic(tree.root, .{ .clip = 1, .abs_clip = 1 });
    return .{ .items = items, .clips = b.clips.items, .doc_w = tree.doc_w, .doc_h = tree.doc_h, .canvas = tree.canvas };
}

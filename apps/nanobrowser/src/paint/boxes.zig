//! A box's own painting as items: its shadows, background layers and border, its
//! picture or control, its outline; and `clip` and `clip-path` as clips.
const std = @import("std");
const dom = @import("../dom.zig");
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const display = @import("display.zig");
const corners = @import("corners.zig");
const paint_gradient = @import("gradient.zig");
const backgrounds = @import("backgrounds.zig");
const Box = box.Box;
const Rect = box.Rect;
const Builder = display.Builder;
const At = display.At;
const Item = display.Item;
const Kind = display.Kind;
const Corners = corners.Corners;
const Allocator = std.mem.Allocator;
const List = std.ArrayList(Item);

fn shifted(r: Rect, at: At) Rect {
    return .{ .x = r.x + at.tx, .y = r.y + at.ty, .w = r.w, .h = r.h };
}

fn item(kind: Kind, r: Rect, at: At, node: ?*dom.Node) Item {
    return .{ .kind = kind, .rect = r, .clip = at.clip, .xform = at.xform, .opacity = at.opacity, .node = node };
}

/// A box's background, border, shadow, its picture or control.
pub fn self(b: *Builder, x: *const Box, at: At, list: *List) !void {
    const st = x.style;
    if (st.display == .contents) return;
    const shows = st.visibility == .visible;
    const node = if (st.pointer_events and shows) x.node else null;
    const rects: []const Rect = if (x.kind == .inline_box and x.frags.len > 0) x.frags else &.{x.borderRect()};
    for (rects) |r0| {
        const r = shifted(r0, at);
        if (shows) try b.add(list, .{ .kind = .hit, .rect = r, .clip = at.clip, .xform = at.xform, .node = node });
        if (!shows) continue;
        try paintRect(b, x, r, at, node, list);
    }
    if (!shows) return;
    const cr = shifted(x.contentRect(), at);
    if (x.kind == .replaced) if (x.node) |n| {
        const c = Corners.of(st, x.w, x.h);
        try b.add(list, item(.{ .image = .{ .node = n, .fit = st.object_fit, .radius = c.largest(), .corners = c.mask(), .style = st } }, cr, at, node));
    };
    if (x.kind == .control) try b.add(list, item(.{ .control = x }, .{ .x = x.x + at.tx, .y = x.y + at.ty, .w = x.w, .h = x.h }, at, node));
    if (x.marker) |m| try b.add(list, item(.{ .bullet = .{ .shape = st.list_style, .color = (x.lay.marker_style orelse st).color } }, shifted(m, at), at, null));
    if (st.outline.width > 0 and st.outline.style != .none and st.outline.color.a > 0) try outline(b, x, at, list);
}

fn outline(b: *Builder, x: *const Box, at: At, list: *List) !void {
    const st = x.style;
    const w = st.outline.width;
    const grow = w + st.outline_offset;
    const r: Rect = .{ .x = x.x + at.tx - grow, .y = x.y + at.ty - grow, .w = @max(0, x.w + 2 * grow), .h = @max(0, x.h + 2 * grow) };
    const o = st.outline;
    const c = Corners.of(st, x.w, x.h).outset(grow);
    const shape = try stored(b, c);
    try b.add(list, item(.{ .border = .{ .widths = .{ .top = w, .right = w, .bottom = w, .left = w }, .top = o, .right = o, .bottom = o, .left = o, .corners = shape } }, r, at, null));
}

/// The corners kept for an item, or null for a square box.
fn stored(b: *Builder, c: Corners) !?*const Corners {
    if (c.isSquare()) return null;
    const p = try b.arena.create(Corners);
    p.* = c;
    return p;
}

fn paintRect(b: *Builder, x: *const Box, r: Rect, at: At, node: ?*dom.Node, list: *List) !void {
    const st = x.style;
    const c = Corners.of(st, r.w, r.h);
    const radius = c.uniform() orelse c.largest();
    // Outside shadows, the first on top.
    var i = st.shadows.len;
    while (i > 0) {
        i -= 1;
        const sh = st.shadows[i];
        if (!sh.inset) try outerShadow(b, sh, c, radius, r, at, list);
    }
    if (st.backdrop_blur > 0) try b.add(list, item(.{ .frost = .{ .blur = st.backdrop_blur, .radius = radius } }, r, at, null));
    if (st.mask_image.len > 0) {
        // The background shows only through the picture's shape.
        const ink = if (st.background.a > 0) st.background else st.color;
        try b.add(list, item(.{ .mask = .{ .url = st.mask_image, .color = ink } }, r, at, node));
        return;
    }
    const layers = st.background_more.len + 1;
    if (st.background.a > 0 and layerClip(st, layers - 1) != .text) {
        // The color reaches as far as the last layer's clip says.
        const area = clipArea(x, r, c, layerClip(st, layers - 1));
        if (polygonOf(b, st, r) catch null) |pts| {
            try b.add(list, item(.{ .polygon = .{ .color = st.background, .points = pts } }, r, at, node));
        } else if (area.c.uniform()) |round| {
            try b.add(list, item(.{ .fill = .{ .color = st.background, .radius = round } }, area.r, at, node));
        } else {
            const shape = try b.arena.create(Corners);
            shape.* = area.c;
            try b.add(list, item(.{ .rounded = .{ .color = st.background, .corners = shape } }, area.r, at, node));
        }
    }
    // The last layer first: the first is on top.
    var more = st.background_more.len;
    while (more > 0) {
        more -= 1;
        const l = st.background_more[more];
        try bgLayer(b, x, r, c, l.url, l.gradient, more + 1, at, node, list);
    }
    try bgLayer(b, x, r, c, st.background_image, st.background_gradient, 0, at, node, list);
    // Inset shadows are over the background and under the border.
    i = st.shadows.len;
    while (i > 0) {
        i -= 1;
        const sh = st.shadows[i];
        if (sh.inset) {
            const pad = clipArea(x, r, c, .padding_box);
            try b.add(list, item(.{ .inset_shadow = .{ .shadow = sh, .corners = pad.c } }, pad.r, at, null));
        }
    }
    if (x.border.top > 0 or x.border.right > 0 or x.border.bottom > 0 or x.border.left > 0) {
        try b.add(list, item(.{ .border = borderOf(x, try stored(b, c)) }, r, at, null));
    }
}

fn outerShadow(b: *Builder, sh: css.Shadow, c: Corners, radius: f32, r: Rect, at: At, list: *List) !void {
    // Sharp around corners that differ: a ring the way a border is drawn.
    if (sh.blur == 0 and sh.x == 0 and sh.y == 0 and sh.spread > 0 and c.uniform() == null) {
        const s = sh.spread;
        const side: css.Border = .{ .width = s, .style = .solid, .color = sh.color };
        try b.add(list, item(.{ .border = .{ .widths = .{ .top = s, .right = s, .bottom = s, .left = s }, .top = side, .right = side, .bottom = side, .left = side, .corners = try stored(b, c.outset(s)) } }, .{ .x = r.x - s, .y = r.y - s, .w = r.w + 2 * s, .h = r.h + 2 * s }, at, null));
        return;
    }
    try b.add(list, item(.{ .fill = .{ .color = .transparent, .radius = radius, .shadow = sh } }, r, at, null));
}

/// What a form control's theme border comes to: the sheet gives it room as
/// CSS's `2px inset`, and Chromium draws a thin line at its edge unless the
/// author has a say.
fn borderOf(x: *const Box, shape: ?*const Corners) display.Border {
    const st = x.style;
    var b: display.Border = .{ .widths = x.border, .top = st.border_top, .right = st.border_right, .bottom = st.border_bottom, .left = st.border_left, .corners = shape };
    const themed = st.border_top.width == 2 and (st.border_top.style == .inset or st.border_top.style == .outset) and st.border_top.style == st.border_left.style and st.border_top.style == st.border_right.style and st.border_top.style == st.border_bottom.style and !st.appearance_none and isThemed(x);
    if (themed) {
        const line: css.Border = .{ .width = 1, .style = .solid, .color = st.border_top.color };
        b.top = line;
        b.right = line;
        b.bottom = line;
        b.left = line;
        b.widths = .{ .top = 1, .right = 1, .bottom = 1, .left = 1 };
    }
    return b;
}

fn isThemed(x: *const Box) bool {
    const n = x.node orelse return false;
    return n.isTag("input") or n.isTag("button") or n.isTag("textarea") or n.isTag("select");
}

fn layerClip(st: *const css.Style, i: usize) css.BackgroundClip {
    if (st.bg_clips.len > 0) return st.bg_clips[i % st.bg_clips.len];
    return st.background_clip;
}

const Area = struct { r: Rect, c: Corners };

/// The rect of a clip's box within the border box `r`, and its corners.
fn clipArea(x: *const Box, r: Rect, c: Corners, clip: css.BackgroundClip) Area {
    var e: box.Edges = .{};
    if (clip != .border_box) e = x.border;
    if (clip == .content_box) {
        e.top += x.padding.top;
        e.right += x.padding.right;
        e.bottom += x.padding.bottom;
        e.left += x.padding.left;
    }
    if (e.top == 0 and e.right == 0 and e.bottom == 0 and e.left == 0) return .{ .r = r, .c = c };
    return .{ .r = .{ .x = r.x + e.left, .y = r.y + e.top, .w = @max(0, r.w - e.horizontal()), .h = @max(0, r.h - e.vertical()) }, .c = c.inset(e.top, e.right, e.bottom, e.left) };
}

/// One background layer, cut to its clip's box.
fn bgLayer(b: *Builder, x: *const Box, r: Rect, c: Corners, url: []const u8, gradient_in: ?css.Gradient, index: usize, at: At, node: ?*dom.Node, list: *List) !void {
    if (url.len == 0 and gradient_in == null) return;
    const st = x.style;
    // Cut to the text: its glyphs show it (`textBackground`).
    if (layerClip(st, index) == .text) return;
    const area = clipArea(x, r, c, layerClip(st, index));
    const round = area.c.uniform() orelse area.c.largest();
    const mask = area.c.mask();
    if (gradient_in) |g| {
        const sized = layerSized(st, index);
        if (!sized) if (paint_gradient.solid(g)) |color| {
            if (area.c.uniform()) |one| {
                try b.add(list, item(.{ .fill = .{ .color = color, .radius = one } }, area.r, at, node));
            } else {
                const shape = try b.arena.create(Corners);
                shape.* = area.c;
                try b.add(list, item(.{ .rounded = .{ .color = color, .corners = shape } }, area.r, at, node));
            }
            return;
        };
        const layer = try layerSpec(b, x, area.r, r, index);
        try b.add(list, item(.{ .gradient = .{ .g = g, .layer = layer, .radius = round, .corners = mask } }, area.r, at, node));
    }
    if (url.len > 0) {
        const layer = try layerSpec(b, x, area.r, r, index);
        try b.add(list, item(.{ .background = .{ .url = url, .layer = layer, .radius = round, .corners = mask } }, area.r, at, node));
    }
}

/// A box's background layers cut to its text, as its text can show them: its
/// gradients across one line. A picture has no color to give: what shows is the
/// box's own color, or a gray so that the text is there at all.
pub fn textBackground(b: *Builder, x: *const Box, at: At) !?*const Kind.TextBackground {
    const st = x.style;
    if (st.background_more.len == 0 and st.background_clip != .text) return null;
    var layers: std.ArrayList(Kind.TextLayer) = .empty;
    var any_picture = false;
    const count = st.background_more.len + 1;
    for (0..count) |i| {
        if (layerClip(st, i) != .text) continue;
        const g = if (i == 0) st.background_gradient else st.background_more[i - 1].gradient;
        const url = if (i == 0) st.background_image else st.background_more[i - 1].url;
        if (url.len > 0) any_picture = true;
        const grad = g orelse continue;
        const spec = try layerSpec(b, x, x.borderRect(), x.borderRect(), i);
        const tile = backgrounds.tileSize(spec.size, null, spec.w, spec.h);
        if (tile.w <= 0 or tile.h <= 0) continue;
        const x0 = spec.dx + (spec.w - tile.w) * spec.pos.x_pct / 100 + spec.pos.x_px;
        const repeats = spec.repeat == .repeat or spec.repeat == .repeat_x;
        try layers.append(b.arena, .{ .g = grad, .x0 = x0, .w = tile.w, .h = tile.h, .repeats = repeats });
    }
    if (layers.items.len == 0 and !any_picture) return null;
    const out = try b.arena.create(Kind.TextBackground);
    var color = st.background;
    if (color.a <= 0 and layers.items.len == 0) color = .{ .r = 0.45, .g = 0.45, .b = 0.45 };
    out.* = .{ .layers = layers.items, .color = color, .box_x = x.x + at.tx };
    return out;
}

/// Whether layer `i` has a size that may not cover its box.
fn layerSized(st: *const css.Style, i: usize) bool {
    const z = pick(css.BgSize, st.bg_sizes, i, .{ .kind = st.background_size, .x = st.background_size_x, .y = st.background_size_y });
    if (z.kind != .auto) return false;
    const whole = struct {
        fn f(l: css.Len) bool {
            return !l.isLength() or (l.px == 0 and l.pct >= 100);
        }
    }.f;
    return !whole(z.x) or !whole(z.y);
}

fn pick(comptime T: type, list: []const T, i: usize, first: T) T {
    return if (list.len > 0) list[i % list.len] else first;
}

/// Where layer `i` goes, from the rect it is cut to.
fn layerSpec(b: *Builder, x: *const Box, area: Rect, border_box: Rect, i: usize) !*const Kind.BgLayer {
    const st = x.style;
    const origin = pick(css.BackgroundOrigin, st.bg_origins, i, st.background_origin);
    var e: box.Edges = .{};
    if (origin != .border_box) e = x.border;
    if (origin == .content_box) {
        e.top += x.padding.top;
        e.right += x.padding.right;
        e.bottom += x.padding.bottom;
        e.left += x.padding.left;
    }
    const spec = try b.arena.create(Kind.BgLayer);
    spec.* = .{
        .size = pick(css.BgSize, st.bg_sizes, i, .{ .kind = st.background_size, .x = st.background_size_x, .y = st.background_size_y }),
        .pos = pick(css.BgPos, st.bg_positions, i, .{ .x_pct = st.background_x, .x_px = st.background_x_px, .y_pct = st.background_y, .y_px = st.background_y_px }),
        .repeat = pick(css.BackgroundRepeat, st.bg_repeats, i, st.background_repeat),
        .dx = border_box.x + e.left - area.x,
        .dy = border_box.y + e.top - area.y,
        .w = @max(0, border_box.w - e.horizontal()),
        .h = @max(0, border_box.h - e.vertical()),
        .fixed = pick(bool, st.bg_fixed, i, st.background_fixed),
    };
    return spec;
}

/// A text's shadow under it: its glyphs moved and in the shadow's color. Text has
/// no blur of its own: a blurred one is several faint copies around the place.
pub fn textShadow(b: *Builder, sh: css.Shadow, s: []const u8, run: *const box.TextRun, rect: Rect, baseline: f32, at: At, list: *List) !void {
    const copy = struct {
        fn add(bb: *Builder, l: *List, str: []const u8, r: *const box.TextRun, re: Rect, base: f32, dx: f32, dy: f32, k: css.Color, aa: At) !void {
            try bb.add(l, item(.{ .text = .{ .str = str, .font = r.font, .color = k, .spacing = r.spacing, .baseline = base + dy } }, .{ .x = re.x + dx, .y = re.y + dy, .w = re.w, .h = re.h }, aa, null));
        }
    }.add;
    if (sh.blur <= 0.5) return copy(b, list, s, run, rect, baseline, sh.x, sh.y, sh.color, at);
    const radius = sh.blur / 2;
    const rings: []const [2]f32 = &.{ .{ 0, 0 }, .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 0.7, 0.7 }, .{ -0.7, 0.7 }, .{ 0.7, -0.7 }, .{ -0.7, -0.7 } };
    var k = sh.color;
    k.a = @min(1, k.a * 1.6 / @as(f32, @floatFromInt(rings.len)));
    for (rings) |d| try copy(b, list, s, run, rect, baseline, sh.x + d[0] * radius, sh.y + d[1] * radius, k, at);
}

/// `clip-path` and `clip` as a clip around the box and all that's in it: exact for
/// a rectangle, rounded or not, and a circle; for other shapes their bounds (the
/// pointer and a plain fill still go by the shape). True when it added one.
pub fn shapeClip(b: *Builder, x: *const Box, at: *At) !bool {
    const st = x.style;
    const r = shifted(x.borderRect(), at.*);
    var clip: display.Clip = .{ .parent = at.clip, .node = x.node, .xform = at.xform };
    if (st.clip_path) |path| {
        var pts: []const [2]f32 = &.{};
        var radius: f32 = 0;
        const area: Rect = switch (path) {
            .inset => |p| blk: {
                const t = p.t.resolve(r.h, 0);
                const l = p.l.resolve(r.w, 0);
                const w = r.w - l - p.r.resolve(r.w, 0);
                const h = r.h - t - p.b.resolve(r.h, 0);
                radius = p.radius.resolve(@min(r.w, r.h), 0);
                break :blk .{ .x = r.x + l, .y = r.y + t, .w = @max(0, w), .h = @max(0, h) };
            },
            .circle => |p| blk: {
                const radii = circleRadius(p.r, p.closest, p.farthest, r, p.cx.resolve(r.w, 0), p.cy.resolve(r.h, 0));
                const cx = r.x + p.cx.resolve(r.w, 0);
                const cy = r.y + p.cy.resolve(r.h, 0);
                radius = radii;
                pts = try ellipse(b.arena, cx, cy, radii, radii);
                break :blk .{ .x = cx - radii, .y = cy - radii, .w = 2 * radii, .h = 2 * radii };
            },
            .ellipse => |p| blk: {
                const cx = p.cx.resolve(r.w, 0);
                const cy = p.cy.resolve(r.h, 0);
                const rx = if (p.closest) @min(cx, r.w - cx) else p.rx.resolve(r.w, 0);
                const ry = if (p.closest) @min(cy, r.h - cy) else p.ry.resolve(r.h, 0);
                pts = try ellipse(b.arena, r.x + cx, r.y + cy, rx, ry);
                // A rounded rectangle is as near as a clip gets to it.
                radius = @min(rx, ry);
                break :blk .{ .x = r.x + cx - rx, .y = r.y + cy - ry, .w = 2 * rx, .h = 2 * ry };
            },
            .polygon => |poly| blk: {
                const out = try b.arena.alloc([2]f32, poly.len);
                var x0 = std.math.inf(f32);
                var y0 = std.math.inf(f32);
                var x1 = -std.math.inf(f32);
                var y1 = -std.math.inf(f32);
                for (poly, out) |p, *o| {
                    o.* = .{ r.x + p[0].resolve(r.w, 0), r.y + p[1].resolve(r.h, 0) };
                    x0 = @min(x0, o[0]);
                    y0 = @min(y0, o[1]);
                    x1 = @max(x1, o[0]);
                    y1 = @max(y1, o[1]);
                }
                pts = out;
                if (poly.len < 3) break :blk .{ .x = r.x, .y = r.y };
                break :blk .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
            },
        };
        clip.rect = area;
        clip.radius = radius;
        clip.path = pts;
        if (pts.len > 0) b.any_paths = true;
    } else if (st.clip_rect) |rc| {
        // `clip` holds only for what is out of the flow.
        if (st.position != .absolute and st.position != .fixed) return false;
        const left = rc.left orelse 0;
        const top = rc.top orelse 0;
        const right = rc.right orelse r.w;
        const bottom = rc.bottom orelse r.h;
        clip.rect = .{ .x = r.x + left, .y = r.y + top, .w = @max(0, right - left), .h = @max(0, bottom - top) };
    } else return false;
    try b.clips.append(b.arena, clip);
    at.clip = @intCast(b.clips.items.len - 1);
    return true;
}

fn circleRadius(l: css.Len, closest: bool, farthest: bool, r: Rect, cx: f32, cy: f32) f32 {
    if (closest) return @min(@min(cx, r.w - cx), @min(cy, r.h - cy));
    if (farthest) return @max(@max(cx, r.w - cx), @max(cy, r.h - cy));
    // A percentage is of the box's normalized diagonal.
    return l.resolve(@sqrt((r.w * r.w + r.h * r.h) / 2), 0);
}

fn ellipse(a: Allocator, cx: f32, cy: f32, rx: f32, ry: f32) ![]const [2]f32 {
    const n = 48;
    const out = try a.alloc([2]f32, n);
    for (out, 0..) |*o, i| {
        const t = @as(f32, @floatFromInt(i)) / n * 2 * std.math.pi;
        o.* = .{ cx + rx * @cos(t), cy + ry * @sin(t) };
    }
    return out;
}

/// A polygon `clip-path` as points from the box's corner, when it is one no
/// rectangle can do: a plain fill is then drawn as that polygon.
fn polygonOf(b: *Builder, st: *const css.Style, r: Rect) !?[]const [2]f32 {
    const path = st.clip_path orelse return null;
    switch (path) {
        .polygon => |poly| {
            if (poly.len < 3) return null;
            const out = try b.arena.alloc([2]f32, poly.len);
            for (poly, out) |p, *o| o.* = .{ p[0].resolve(r.w, 0), p[1].resolve(r.h, 0) };
            return out;
        },
        else => return null,
    }
}

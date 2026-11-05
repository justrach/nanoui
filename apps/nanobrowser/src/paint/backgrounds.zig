//! Background layers: where each sits, as its own size, position and repeat say,
//! against its positioning area (`background-origin`) or the window (`fixed`). A
//! tile repeats only as far as what shows; a gradient's tiles are worked into one
//! larger picture, so hatching costs a few pictures rather than thousands.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const display = @import("display.zig");
const replay = @import("replay.zig");
const Rect = box.Rect;
const Layer = display.Kind.BgLayer;

/// At most this many pictures for a layer: past that it is one, stretched.
const max_tiles = 4096;

const Place = struct {
    /// The positioning area, from the item's rect.
    ox: f32,
    oy: f32,
    ow: f32,
    oh: f32,
    /// What of the item's rect shows, from itself.
    vis: Rect,
};

fn placeOf(layer: *const Layer, r: Rect, view: Rect) Place {
    const vis_x0 = @max(0, view.x - r.x);
    const vis_y0 = @max(0, view.y - r.y);
    const vis_x1 = @min(r.w, view.x + view.w - r.x);
    const vis_y1 = @min(r.h, view.y + view.h - r.y);
    const vis: Rect = .{ .x = vis_x0, .y = vis_y0, .w = @max(0, vis_x1 - vis_x0), .h = @max(0, vis_y1 - vis_y0) };
    if (layer.fixed) return .{ .ox = view.x - r.x, .oy = view.y - r.y, .ow = view.w, .oh = view.h, .vis = vis };
    return .{ .ox = layer.dx, .oy = layer.dy, .ow = layer.w, .oh = layer.h, .vis = vis };
}

/// A tile's size in an area of `ow` × `oh`, from `background-size` and the
/// picture's own (null: a gradient, which has none and fills the area).
pub fn tileSize(z: css.BgSize, own_in: ?ui.Size, ow: f32, oh: f32) ui.Size {
    const own = own_in orelse ui.Size{ .w = ow, .h = oh };
    switch (z.kind) {
        .cover, .contain => {
            const a = ow / @max(own.w, 1);
            const b = oh / @max(own.h, 1);
            const k = if (z.kind == .cover) @max(a, b) else @min(a, b);
            return .{ .w = own.w * k, .h = own.h * k };
        },
        .auto => {},
    }
    if (z.x.isLength() and z.y.isLength()) return .{ .w = z.x.resolve(ow, 0), .h = z.y.resolve(oh, 0) };
    if (z.x.isLength()) {
        const w = z.x.resolve(ow, 0);
        return .{ .w = w, .h = if (own_in != null) own.h * w / @max(own.w, 1) else oh };
    }
    if (z.y.isLength()) {
        const h = z.y.resolve(oh, 0);
        return .{ .w = if (own_in != null) own.w * h / @max(own.h, 1) else ow, .h = h };
    }
    return own;
}

/// The range of tiles of `w` along an axis that touch what shows.
fn range(repeats: bool, start: f32, w: f32, vis0: f32, vis1: f32) [2]f32 {
    if (!repeats) return .{ 0, 1 };
    return .{ @floor((vis0 - start) / w), @ceil((vis1 - start) / w) };
}

fn repeatsX(k: css.BackgroundRepeat) bool {
    return k == .repeat or k == .repeat_x;
}

fn repeatsY(k: css.BackgroundRepeat) bool {
    return k == .repeat or k == .repeat_y;
}

/// A picture layer.
pub fn picture(c: *ui.Context, bg: display.Kind.Background, bytes: []const u8, placed: ui.Style, r: Rect, view: Rect) void {
    var s = placed;
    s.clip = true;
    s.radius = bg.radius;
    s.corner_circular = true;
    s.clip_corners = bg.corners;
    _ = c.open(s, null);
    defer c.end();
    const layer = bg.layer;
    const at = placeOf(layer, r, view);
    const svg = replay.isSvg(bytes);
    const own: ui.Size = if (svg) blk: {
        const v = replay.svgSize(bytes) orelse [2]f32{ at.ow, at.oh };
        break :blk .{ .w = v[0], .h = v[1] };
    } else ui.imageSize(c, bg.url, bytes) orelse return;
    var size = tileSize(layer.size, own, at.ow, at.oh);
    // A shape with a ratio and no size of its own fits the box whole.
    if (svg and layer.size.kind == .auto and !layer.size.x.isLength() and !layer.size.y.isLength() and replay.svgOwn(bytes).size == null) {
        const k = @min(at.ow / @max(own.w, 1), at.oh / @max(own.h, 1));
        size = .{ .w = own.w * k, .h = own.h * k };
    }
    if (size.w <= 0 or size.h <= 0) return;
    const x0 = at.ox + (at.ow - size.w) * layer.pos.x_pct / 100 + layer.pos.x_px;
    const y0 = at.oy + (at.oh - size.h) * layer.pos.y_pct / 100 + layer.pos.y_px;
    laid(c, bg.url, bytes, svg, layer.repeat, x0, y0, size.w, size.h, at.vis);
}

/// Tiles of one picture from (x0, y0), as far as they show.
fn laid(c: *ui.Context, key: []const u8, bytes: []const u8, svg: bool, repeat: css.BackgroundRepeat, x0: f32, y0: f32, w: f32, h: f32, vis: Rect) void {
    const rx = repeatsX(repeat);
    const ry = repeatsY(repeat);
    const ix = range(rx, x0, w, vis.x, vis.x + vis.w);
    const iy = range(ry, y0, h, vis.y, vis.y + vis.h);
    const nx = ix[1] - ix[0];
    const ny = iy[1] - iy[0];
    if (nx <= 0 or ny <= 0) return;
    if (nx * ny > max_tiles) {
        // What a thin repeating strip looks like anyway.
        tile(c, key, bytes, svg, if (rx) vis.x else x0, if (ry) vis.y else y0, if (rx) vis.w else w, if (ry) vis.h else h);
        return;
    }
    var j = iy[0];
    while (j < iy[1]) : (j += 1) {
        var i = ix[0];
        while (i < ix[1]) : (i += 1) tile(c, key, bytes, svg, x0 + i * w, y0 + j * h, w, h);
    }
}

fn tile(c: *ui.Context, key: []const u8, bytes: []const u8, svg: bool, x: f32, y: f32, w: f32, h: f32) void {
    _ = c.open(.{ .absolute = true, .offset = .{ .x = x, .y = y } }, null);
    defer c.end();
    if (svg) {
        _ = ui.svg(c, .{ .key = key, .bytes = bytes, .width = w, .height = h, .current = ui.Color.black });
        return;
    }
    _ = ui.image(c, .{ .key = key, .bytes = bytes, .box = .{ .w = w, .h = h }, .radius = 0 });
}

/// How many tiles of `w` to work into one picture: as many as fit it, and no
/// more than what shows.
fn block(repeats: bool, w: f32, shown: f32, scale: f32) u32 {
    if (!repeats) return 1;
    const fit = @floor(512 / @max(w * scale, 1));
    const need = @ceil(shown / @max(w, 0.01)) + 1;
    return @intFromFloat(std.math.clamp(@min(fit, need), 1, 512));
}

/// A gradient layer. `host.gradient(g, w, h, nx, ny, scale)` gives its picture.
pub fn gradient(c: *ui.Context, g: display.Kind.Gradient, host: anytype, placed: ui.Style, r: Rect, view: Rect) void {
    var s = placed;
    s.clip = true;
    s.radius = g.radius;
    s.corner_circular = true;
    s.clip_corners = g.corners;
    const layer = g.layer;
    const at = placeOf(layer, r, view);
    const size = tileSize(layer.size, null, at.ow, at.oh);
    if (size.w <= 0 or size.h <= 0) return;
    const nx = block(repeatsX(layer.repeat), size.w, r.w, c.scale);
    const ny = block(repeatsY(layer.repeat), size.h, r.h, c.scale);
    const bytes = host.gradient(g.g, size.w, size.h, nx, ny, c.scale) orelse return;
    const key = c.print("gradient:{x}:{d}", .{ @intFromPtr(bytes.ptr), bytes.len });
    _ = c.open(s, null);
    defer c.end();
    const x0 = at.ox + (at.ow - size.w) * layer.pos.x_pct / 100 + layer.pos.x_px;
    const y0 = at.oy + (at.oh - size.h) * layer.pos.y_pct / 100 + layer.pos.y_px;
    const bw = size.w * @as(f32, @floatFromInt(nx));
    const bh = size.h * @as(f32, @floatFromInt(ny));
    laid(c, key, bytes, false, layer.repeat, x0, y0, bw, bh, at.vis);
}

test "a gradient's tile fills its area unless told" {
    const auto: css.BgSize = .{};
    try std.testing.expectEqual(@as(f32, 300), tileSize(auto, null, 300, 100).w);
    const px: css.BgSize = .{ .x = css.Len.of(8), .y = css.Len.of(4) };
    try std.testing.expectEqual(@as(f32, 4), tileSize(px, null, 300, 100).h);
    const half: css.BgSize = .{ .x = .{ .pct = 50 } };
    try std.testing.expectEqual(@as(f32, 150), tileSize(half, null, 300, 100).w);
    try std.testing.expectEqual(@as(f32, 100), tileSize(half, null, 300, 100).h);
    // A picture keeps its proportions.
    try std.testing.expectEqual(@as(f32, 50), tileSize(half, .{ .w = 300, .h = 100 }, 300, 100).h);
    const cover: css.BgSize = .{ .kind = .cover };
    try std.testing.expectEqual(@as(f32, 600), tileSize(cover, .{ .w = 100, .h = 100 }, 600, 200).w);
}

test "tiles only as far as what shows" {
    const a = range(true, -7, 10, 0, 25);
    try std.testing.expectEqual(@as(f32, 0), a[0]);
    try std.testing.expectEqual(@as(f32, 4), a[1]);
    const b = range(false, -7, 10, 0, 25);
    try std.testing.expectEqual(@as(f32, 1), b[1] - b[0]);
    try std.testing.expectEqual(@as(u32, 11), block(true, 10, 100, 1));
    try std.testing.expectEqual(@as(u32, 1), block(false, 10, 100, 1));
    // Bounded by what fits a picture.
    try std.testing.expectEqual(@as(u32, 25), block(true, 10, 10000, 2));
}

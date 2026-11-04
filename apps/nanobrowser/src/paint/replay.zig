//! A display list drawn with nanoui: what is in view each frame becomes
//! absolutely placed boxes, so a page costs what fits in the window however
//! long it is. Items of a clip other than the page's share a clipping box.
//!
//! `host` gives what the list only names:
//!   host.picture(url) ?[]const u8         a background's bytes; asks for them the first time
//!   host.gradient(g) ?[]const u8          a gradient as an encoded picture
//!   host.control(c, box, x, y, opacity)   draws a form control at (x, y) in the open box
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const display = @import("display.zig");
const Rect = box.Rect;

pub fn color(k: css.Color) ui.Color {
    return .{ .r = k.r, .g = k.g, .b = k.b, .a = k.a };
}

pub fn weight(w: u16) ui.Weight {
    return if (w < 450) .regular else if (w < 550) .medium else if (w < 650) .semibold else .bold;
}

pub fn textStyle(f: box.Font) ui.TextStyle {
    return .{ .size = f.size, .weight = weight(f.weight), .italic = f.italic, .mono = f.mono, .serif = f.serif, .mono_scale = 1 };
}

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

/// Draws what of `l` shows, in the open box, which is at `rect` (window
/// coordinates; `l` was resolved for it) and clips.
pub fn replay(c: *ui.Context, l: *const display.List, host: anytype, rect: Rect) void {
    var open_clip: u32 = 0;
    var ox = rect.x;
    var oy = rect.y;
    for (l.items) |*it| {
        if (it.kind == .hit) continue;
        const clip = &l.clips[it.clip];
        if (clip.visible.w <= 0 or clip.visible.h <= 0) continue;
        const r = l.placed(it);
        const reach: f32 = if (it.kind == .fill and it.kind.fill.shadow != null) shadowReach(it.kind.fill.shadow.?) else 0;
        if (!overlaps(.{ .x = r.x - reach, .y = r.y - reach, .w = r.w + 2 * reach, .h = r.h + 2 * reach }, clip.visible)) continue;
        const wanted: u32 = if (it.clip <= 1) 0 else it.clip;
        if (wanted != open_clip) {
            if (open_clip != 0) c.end();
            open_clip = wanted;
            ox = rect.x;
            oy = rect.y;
            if (wanted != 0) {
                _ = c.open(.{
                    .absolute = true,
                    .offset = .{ .x = clip.visible.x - rect.x, .y = clip.visible.y - rect.y },
                    .width = .{ .px = clip.visible.w },
                    .height = .{ .px = clip.visible.h },
                    .clip = true,
                    .radius = clip.radius,
                }, null);
                ox = clip.visible.x;
                oy = clip.visible.y;
            }
        }
        draw(c, it, r.x - ox, r.y - oy, r, host);
    }
    if (open_clip != 0) c.end();
}

fn shadowReach(s: css.Shadow) f32 {
    return s.blur + s.spread + @max(@abs(s.x), @abs(s.y));
}

fn draw(c: *ui.Context, it: *const display.Item, x: f32, y: f32, r: Rect, host: anytype) void {
    const placed: ui.Style = .{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = .{ .px = r.w },
        .height = .{ .px = r.h },
        .opacity = it.opacity,
    };
    switch (it.kind) {
        .hit => {},
        .fill => |f| {
            var s = placed;
            s.radius = f.radius;
            s.corner_circular = true;
            if (f.color.a > 0) s.background = color(f.color);
            if (f.shadow) |sh| s.shadow = .{ .color = color(sh.color), .blur = sh.blur, .x = sh.x, .y = sh.y, .spread = sh.spread, .knockout = f.color.a == 0 };
            _ = c.leaf(s, .none, null);
        },
        .border => |b| drawBorder(c, b, placed, r),
        .text => |t| {
            var s = textStyle(t.font);
            s.tracking = t.spacing;
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = y }, .opacity = it.opacity }, .{ .text = .{ .str = t.str, .style = s, .color = color(t.color) } }, null);
        },
        .image => |im| drawImage(c, im, placed, r),
        .background => |bg| if (host.picture(bg.url)) |bytes| drawBackground(c, bg, bytes, placed, r, null),
        .gradient => |g| if (host.gradient(g.g)) |bytes| {
            const key = c.print("gradient:{x}", .{std.hash.Wyhash.hash(0, bytes)});
            drawBackground(c, .{ .url = key, .style = g.style, .radius = g.radius }, bytes, placed, r, .{ .w = r.w, .h = r.h });
        },
        .mask => |ms| if (host.picture(ms.url)) |bytes| drawMask(c, ms, bytes, placed, r),
        .bullet => |b| {
            var s = placed;
            s.corner_circular = true;
            switch (b.shape) {
                .circle => {
                    s.radius = r.w / 2;
                    s.border = color(b.color);
                },
                .square => s.background = color(b.color),
                else => {
                    s.radius = r.w / 2;
                    s.background = color(b.color);
                },
            }
            _ = c.leaf(s, .none, null);
        },
        .control => |b| host.control(c, b, x, y, it.opacity),
    }
}

fn drawMask(c: *ui.Context, ms: display.Kind.Mask, bytes: []const u8, placed: ui.Style, r: Rect) void {
    _ = c.open(placed, null);
    defer c.end();
    if (isSvg(bytes)) {
        _ = ui.svg(c, .{ .key = ms.url, .bytes = bytes, .width = r.w, .height = r.h, .color = color(ms.color) });
        return;
    }
    _ = ui.image(c, .{ .key = ms.url, .bytes = bytes, .box = .{ .w = r.w, .h = r.h }, .radius = 0, .tint = color(ms.color) });
}

fn drawBorder(c: *ui.Context, b: display.Border, placed: ui.Style, r: Rect) void {
    const w = b.widths;
    const same = w.top == w.right and w.top == w.bottom and w.top == w.left and sameColor(b.top.color, b.right.color) and sameColor(b.top.color, b.bottom.color) and sameColor(b.top.color, b.left.color);
    if (same and b.top.color.a > 0) {
        var s = placed;
        s.border = color(b.top.color);
        s.border_width = w.top;
        s.border_dashed = b.top.style == .dashed or b.top.style == .dotted;
        _ = c.leaf(s, .none, null);
        return;
    }
    // Each side its own: bars that meet at the corners.
    const x = placed.offset.x;
    const y = placed.offset.y;
    const bar = struct {
        fn add(cc: *ui.Context, p: ui.Style, k: css.Color, bx: f32, by: f32, bw: f32, bh: f32) void {
            if (k.a <= 0 or bw <= 0 or bh <= 0) return;
            _ = cc.leaf(.{ .absolute = true, .offset = .{ .x = bx, .y = by }, .width = .{ .px = bw }, .height = .{ .px = bh }, .background = color(k), .opacity = p.opacity }, .none, null);
        }
    }.add;
    bar(c, placed, b.top.color, x, y, r.w, w.top);
    bar(c, placed, b.bottom.color, x, y + r.h - w.bottom, r.w, w.bottom);
    bar(c, placed, b.left.color, x, y + w.top, w.left, r.h - w.top - w.bottom);
    bar(c, placed, b.right.color, x + r.w - w.right, y + w.top, w.right, r.h - w.top - w.bottom);
}

fn sameColor(a: css.Color, b: css.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn drawImage(c: *ui.Context, im: display.Kind.Image, placed: ui.Style, r: Rect) void {
    const n = im.node;
    if (n.image.len == 0) return;
    var s = placed;
    s.width = .{ .px = r.w };
    s.height = .{ .px = r.h };
    _ = c.open(s, null);
    defer c.end();
    if (isSvg(n.image)) {
        _ = ui.svg(c, .{ .key = n.image_key, .bytes = n.image, .width = r.w, .height = r.h });
        return;
    }
    const size = ui.imageSize(c, n.image_key, n.image) orelse return;
    var part: [4]f32 = .{ 0, 0, 1, 1 };
    var w = r.w;
    var h = r.h;
    switch (im.fit) {
        .cover => part = cover(size.w, size.h, r.w, r.h),
        .contain, .scale_down => {
            const k = @min(r.w / @max(size.w, 1), r.h / @max(size.h, 1));
            w = size.w * k;
            h = size.h * k;
        },
        else => {},
    }
    if (w != r.w or h != r.h) {
        _ = c.open(.{ .absolute = true, .offset = .{ .x = (r.w - w) / 2, .y = (r.h - h) / 2 } }, null);
        defer c.end();
        _ = ui.image(c, .{ .key = n.image_key, .bytes = n.image, .box = .{ .w = w, .h = h }, .radius = im.radius, .part = part });
        return;
    }
    _ = ui.image(c, .{ .key = n.image_key, .bytes = n.image, .box = .{ .w = w, .h = h }, .radius = im.radius, .part = part });
}

/// An SVG's own size: its attributes, else its viewBox.
pub fn svgSize(bytes: []const u8) ?[2]f32 {
    const head = bytes[0..@min(bytes.len, 2048)];
    const w = number(attrIn(head, "width"));
    const h = number(attrIn(head, "height"));
    if (w != null and h != null) return .{ w.?, h.? };
    if (attrIn(head, "viewBox")) |vb| {
        var it = std.mem.tokenizeAny(u8, vb, " ,");
        _ = it.next();
        _ = it.next();
        const vw = number(it.next()) orelse return null;
        const vh = number(it.next()) orelse return null;
        return .{ vw, vh };
    }
    return null;
}

fn attrIn(head: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, head, from, name)) |at| {
        from = at + name.len;
        if (at == 0 or head[at - 1] != ' ' and head[at - 1] != '\n' and head[at - 1] != '\t') continue;
        const rest = std.mem.trimStart(u8, head[from..], " ");
        if (rest.len < 2 or rest[0] != '=') continue;
        const q = rest[1];
        if (q != '"' and q != '\'') continue;
        const end = std.mem.indexOfScalarPos(u8, rest, 2, q) orelse continue;
        return rest[2..end];
    }
    return null;
}

fn number(s: ?[]const u8) ?f32 {
    const t = s orelse return null;
    var end: usize = 0;
    while (end < t.len and (std.ascii.isDigit(t[end]) or t[end] == '.')) end += 1;
    if (end == 0 or (end < t.len and t[end] == '%')) return null;
    return std.fmt.parseFloat(f32, t[0..end]) catch null;
}

pub fn isSvg(bytes: []const u8) bool {
    const head = std.mem.trimStart(u8, bytes[0..@min(bytes.len, 256)], " \t\r\n");
    return std.mem.startsWith(u8, head, "<svg") or std.mem.startsWith(u8, head, "<?xml");
}

/// The middle part of a picture that fills a box without bars, cut to fit.
fn cover(iw: f32, ih: f32, bw: f32, bh: f32) [4]f32 {
    const ir = iw / @max(ih, 1);
    const br = bw / @max(bh, 1);
    if (ir > br) {
        const keep = br / ir;
        return .{ (1 - keep) / 2, 0, (1 + keep) / 2, 1 };
    }
    const keep = ir / @max(br, 0.001);
    return .{ 0, (1 - keep) / 2, 1, (1 + keep) / 2 };
}

/// At most this many tiles of a repeating background: a one-pixel picture
/// over a tall page is drawn stretched in a band instead of thousands of tiles.
const max_tiles = 64;

/// A tile's size in a box of `r`, from `background-size` and the picture's own.
fn tileSize(st: *const css.Style, own: ui.Size, r: Rect) ui.Size {
    switch (st.background_size) {
        .cover, .contain => {
            const a = r.w / @max(own.w, 1);
            const b = r.h / @max(own.h, 1);
            const k = if (st.background_size == .cover) @max(a, b) else @min(a, b);
            return .{ .w = own.w * k, .h = own.h * k };
        },
        .auto => {},
    }
    const lw = st.background_size_x;
    const lh = st.background_size_y;
    if (lw.isLength() and lh.isLength()) return .{ .w = lw.resolve(r.w, 0), .h = lh.resolve(r.h, 0) };
    if (lw.isLength()) {
        const w = lw.resolve(r.w, 0);
        return .{ .w = w, .h = own.h * w / @max(own.w, 1) };
    }
    if (lh.isLength()) {
        const h = lh.resolve(r.h, 0);
        return .{ .w = own.w * h / @max(own.h, 1), .h = h };
    }
    return own;
}

/// `own`: the picture's size when it isn't in its bytes (a gradient's is its box's).
fn drawBackground(c: *ui.Context, bg: display.Kind.Background, bytes: []const u8, placed: ui.Style, r: Rect, own_in: ?ui.Size) void {
    var s = placed;
    s.clip = true;
    s.radius = bg.radius;
    _ = c.open(s, null);
    defer c.end();
    const st = bg.style;
    const svg = isSvg(bytes);
    const own: ui.Size = own_in orelse if (svg) blk: {
        const v = svgSize(bytes) orelse [2]f32{ r.w, r.h };
        break :blk .{ .w = v[0], .h = v[1] };
    } else ui.imageSize(c, bg.url, bytes) orelse return;
    const size = tileSize(st, own, r);
    const w = size.w;
    const h = size.h;
    if (w <= 0 or h <= 0) return;
    const x0 = (r.w - w) * st.background_x / 100 + st.background_x_px;
    const y0 = (r.h - h) * st.background_y / 100 + st.background_y_px;
    if (svg) {
        _ = c.open(.{ .absolute = true, .offset = .{ .x = x0, .y = y0 } }, null);
        defer c.end();
        _ = ui.svg(c, .{ .key = bg.url, .bytes = bytes, .width = w, .height = h });
        return;
    }
    // Filling the box from its corner is one tile, however it repeats.
    const rx = (st.background_repeat == .repeat or st.background_repeat == .repeat_x) and !(x0 == 0 and w >= r.w);
    const ry = (st.background_repeat == .repeat or st.background_repeat == .repeat_y) and !(y0 == 0 and h >= r.h);
    // A tile that repeats too often is drawn once, stretched along that axis:
    // what a thin repeating strip looks like anyway.
    const nx: f32 = if (rx) @ceil(r.w / w) + 1 else 1;
    const ny: f32 = if (ry) @ceil(r.h / h) + 1 else 1;
    if (nx * ny > max_tiles) {
        tile(c, bg.url, bytes, if (rx) 0 else x0, if (ry) 0 else y0, if (rx) r.w else w, if (ry) r.h else h);
        return;
    }
    const sx: f32 = if (rx) @mod(x0, w) - w else x0;
    const sy: f32 = if (ry) @mod(y0, h) - h else y0;
    var j: f32 = 0;
    while (j < ny) : (j += 1) {
        var i: f32 = 0;
        while (i < nx) : (i += 1) tile(c, bg.url, bytes, sx + i * w, sy + j * h, w, h);
    }
}

fn tile(c: *ui.Context, key: []const u8, bytes: []const u8, x: f32, y: f32, w: f32, h: f32) void {
    _ = c.open(.{ .absolute = true, .offset = .{ .x = x, .y = y } }, null);
    defer c.end();
    _ = ui.image(c, .{ .key = key, .bytes = bytes, .box = .{ .w = w, .h = h }, .radius = 0 });
}

test "cover cuts the longer side" {
    const wide = cover(200, 100, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), wide[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), wide[2], 0.001);
    const tall = cover(100, 200, 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), tall[1], 0.001);
    try std.testing.expect(isSvg("  <svg width=1>"));
    try std.testing.expect(!isSvg("\x89PNG"));
    try std.testing.expectEqual(@as(f32, 24), svgSize("<svg xmlns=\"x\" width=\"24\" height=\"12px\"></svg>").?[0]);
    try std.testing.expectEqual(@as(f32, 96), svgSize("<svg viewBox=\"0 0 48 96\"></svg>").?[1]);
    try std.testing.expect(svgSize("<svg width=\"100%\" height=\"100%\"></svg>") == null);
}

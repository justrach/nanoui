//! A display list drawn with nanoui: what is in view each frame becomes
//! absolutely placed boxes, so a page costs what fits in the window however
//! long it is. Items of a clip other than the page's share a clipping box.
//!
//! `host` gives what the list only names:
//!   host.picture(url) ?[]const u8         a background's bytes; asks for them the first time
//!   host.gradient(g, w, h, nx, ny, scale) ?[]const u8   tiles of a gradient as a picture
//!   host.control(c, box, x, y, opacity)   draws a form control at (x, y) in the open box
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const display = @import("display.zig");
const replay_box = @import("replay_box.zig");
const backgrounds = @import("backgrounds.zig");
const paint_gradient = @import("gradient.zig");
const Rect = box.Rect;

pub fn color(k: css.Color) ui.Color {
    return .{ .r = k.r, .g = k.g, .b = k.b, .a = k.a };
}

pub fn textStyle(f: box.Font) ui.TextStyle {
    return .{
        .size = f.size,
        .weight = ui.Weight.of(f.weight),
        .css_weight = @max(f.weight, 1),
        .italic = f.italic,
        .mono = f.mono,
        .serif = f.serif,
        .mono_scale = 1,
        .family = if (f.family.len > 0) f.family else null,
        .stretch = f.stretch,
        .tabular = f.tabular,
        .ligatures = f.ligatures,
    };
}

fn overlaps(a: Rect, b: Rect) bool {
    return a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h;
}

fn toAffine(m: css.fx.Mat) ui.Affine {
    return .{ .a = m.a, .b = m.b, .c = m.c, .d = m.d, .e = m.e, .f = m.f };
}

/// What a group has of anything that shows. Items are in order; `from` opens it.
fn groupEnd(items: []const display.Item, from: usize) usize {
    var depth: u32 = 0;
    var i = from;
    while (i < items.len) : (i += 1) switch (items[i].kind) {
        .group_begin => depth += 1,
        .group_end => {
            depth -= 1;
            if (depth == 0) return i;
        },
        else => {},
    };
    return items.len - 1;
}

fn shows(l: *const display.List, it: *const display.Item) bool {
    const clip = &l.clips[it.clip];
    if (clip.visible.w <= 0 or clip.visible.h <= 0) return false;
    var r = l.placed(it);
    const reach: f32 = if (it.kind == .fill and it.kind.fill.shadow != null) shadowReach(it.kind.fill.shadow.?) else 0;
    r = .{ .x = r.x - reach, .y = r.y - reach, .w = r.w + 2 * reach, .h = r.h + 2 * reach };
    if (it.xform != 0) {
        const t = &l.xforms[it.xform];
        if (t.inverse == null) return false;
        r = display.boundsOf(t.window, r);
    }
    return overlaps(r, clip.visible);
}

/// Draws what of `l` shows, in the open box, which is at `rect` (window
/// coordinates; `l` was resolved for it) and clips.
pub fn replay(c: *ui.Context, l: *const display.List, host: anytype, rect: Rect) void {
    var open_clip: u32 = 0;
    var open_xform: u32 = 0;
    var groups: u32 = 0;
    var ox = rect.x;
    var oy = rect.y;
    var i: usize = 0;
    while (i < l.items.len) : (i += 1) {
        const it = &l.items[i];
        switch (it.kind) {
            .hit => continue,
            .group_begin, .group_end => {
                if (open_xform != 0) c.end();
                if (open_clip != 0) c.end();
                open_xform = 0;
                open_clip = 0;
                ox = rect.x;
                oy = rect.y;
                if (it.kind == .group_end) {
                    if (groups > 0) {
                        c.end();
                        groups -= 1;
                    }
                    continue;
                }
                // Nothing of it in the window: not a pass of the renderer.
                const end = groupEnd(l.items, i);
                var any = false;
                for (l.items[i + 1 .. end]) |*x| {
                    if (x.kind != .hit and x.kind != .group_begin and x.kind != .group_end and shows(l, x)) {
                        any = true;
                        break;
                    }
                }
                if (!any) {
                    i = end;
                    continue;
                }
                _ = c.open(.{ .absolute = true, .width = .{ .px = rect.w }, .height = .{ .px = rect.h }, .group = true, .opacity = it.kind.group_begin }, null);
                groups += 1;
                continue;
            },
            else => {},
        }
        if (!shows(l, it)) continue;
        const clip = &l.clips[it.clip];
        const r = l.placed(it);
        const wanted: u32 = if (it.clip <= 1) 0 else it.clip;
        if (wanted != open_clip or it.xform != open_xform) {
            if (open_xform != 0) c.end();
            if (open_clip != 0) c.end();
            open_xform = 0;
            open_clip = wanted;
            ox = rect.x;
            oy = rect.y;
            if (wanted != 0) {
                // By what it clips, not by what was drawn before it: a field
                // inside keeps its id, and with it the keys.
                c.next_key_int = if (clip.node) |n| @intFromPtr(n) else wanted;
                _ = c.open(.{
                    .absolute = true,
                    .offset = .{ .x = clip.visible.x - rect.x, .y = clip.visible.y - rect.y },
                    .width = .{ .px = clip.visible.w },
                    .height = .{ .px = clip.visible.h },
                    .clip = true,
                    .radius = clip.radius,
                    .clip_corners = clip.corners,
                }, null);
                ox = clip.visible.x;
                oy = clip.visible.y;
            }
            if (it.xform != 0) {
                _ = c.open(.{ .absolute = true, .transform = toAffine(l.xforms[it.xform].window) }, null);
                open_xform = it.xform;
            }
        }
        // What's in a transform can be anywhere: nothing is cut to the window for it.
        const view = if (it.xform != 0) r else rect;
        draw(c, it, r.x - ox, r.y - oy, r, view, host);
    }
    if (open_xform != 0) c.end();
    if (open_clip != 0) c.end();
    while (groups > 0) : (groups -= 1) c.end();
}

fn shadowReach(s: css.Shadow) f32 {
    return s.blur * 1.5 + @max(s.spread, 0) + @max(@abs(s.x), @abs(s.y));
}

/// `background-clip: text`: each character the color the layers make where it
/// is. Nanoui can't fill glyphs with a picture, but it can color them one by one:
/// within a glyph the color is flat. A long text gets one color a stretch.
fn gradientSpans(c: *ui.Context, t: display.Kind.Text, doc_x: f32, s: ui.TextStyle) []const ui.Span {
    const bg = t.gradient orelse return &.{};
    const a = c.alloc();
    const samplers = a.alloc(paint_gradient.Sampler, bg.layers.len) catch return &.{};
    for (bg.layers, samplers) |l, *o| o.* = paint_gradient.Sampler.init(a, l.g, l.w, l.h) catch return &.{};
    const stretch: usize = if (t.str.len > 256) 16 else 1;
    var spans: std.ArrayList(ui.Span) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(t.str).iterator();
    var start: usize = 0;
    var before: f32 = 0;
    while (start < t.str.len) {
        var end = start;
        for (0..stretch) |_| end += (it.nextCodepointSlice() orelse break).len;
        if (end == start) break;
        const after = c.text.width(t.str[0..end], s);
        const px = doc_x - bg.box_x + (before + after) / 2;
        var mix: [4]f32 = .{ bg.color.r * bg.color.a, bg.color.g * bg.color.a, bg.color.b * bg.color.a, bg.color.a };
        var i = bg.layers.len;
        while (i > 0) {
            i -= 1;
            const l = bg.layers[i];
            var u = px - l.x0;
            if (l.repeats) u = @mod(u, l.w);
            if (u < 0 or u > l.w) continue;
            const k = samplers[i].at(u, l.h / 2);
            for (&mix, k) |*m, v| m.* = v + m.* * (1 - k[3]);
        }
        const ink: ui.Color = if (mix[3] > 0) .{ .r = mix[0] / mix[3], .g = mix[1] / mix[3], .b = mix[2] / mix[3], .a = mix[3] } else .{ .a = 0 };
        spans.append(a, .{ .start = @intCast(start), .end = @intCast(end), .color = ink }) catch return &.{};
        start = end;
        before = after;
    }
    return spans.items;
}

fn draw(c: *ui.Context, it: *const display.Item, x: f32, y: f32, r: Rect, view: Rect, host: anytype) void {
    const placed: ui.Style = .{
        .absolute = true,
        .offset = .{ .x = x, .y = y },
        .width = .{ .px = r.w },
        .height = .{ .px = r.h },
        .opacity = it.opacity,
    };
    switch (it.kind) {
        .hit, .group_begin, .group_end => {},
        .fill => |f| {
            var s = placed;
            s.radius = f.radius;
            s.corner_circular = true;
            if (f.color.a > 0) s.background = color(f.color);
            if (f.shadow) |sh| s.shadow = .{ .color = color(sh.color), .blur = sh.blur, .x = sh.x, .y = sh.y, .spread = sh.spread, .knockout = f.color.a == 0 and !f.solid_shadow };
            _ = c.leaf(s, .none, null);
        },
        .rounded => |f| replay_box.rounded(c, f.color, f.corners.*, placed, r),
        .polygon => |f| replay_box.polygon(c, f.color, f.points, placed),
        .border => |b| replay_box.border(c, b, placed, r),
        .inset_shadow => |s| replay_box.insetShadow(c, s, placed, r),
        .frost => |f| {
            var s = placed;
            s.radius = f.radius;
            s.corner_circular = true;
            s.glass = .{ .style = .frost, .blur = f.blur };
            _ = c.leaf(s, .none, null);
        },
        .text => |t| {
            var s = textStyle(t.font);
            s.tracking = t.spacing;
            // nanoui puts the baseline by its own measure of the font: this
            // lands it on the one layout worked out.
            const f = c.text.font(s);
            const top = y + (t.baseline - it.rect.y) - (f.ascent + f.leading / 2);
            _ = c.leaf(.{ .absolute = true, .offset = .{ .x = x, .y = top }, .opacity = it.opacity }, .{ .text = .{ .str = t.str, .style = s, .color = color(t.color), .spans = gradientSpans(c, t, it.rect.x, s) } }, null);
        },
        .image => |im| drawPicture(c, im, placed, r),
        .background => |bg| if (host.picture(bg.url)) |bytes| backgrounds.picture(c, bg, bytes, placed, r, view),
        .gradient => |g| backgrounds.gradient(c, g, host, placed, r, view),
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

/// A picture with what `drawImage` doesn't do itself around it: a tint, and
/// corners only some of which are round.
fn drawPicture(c: *ui.Context, im: display.Kind.Image, placed: ui.Style, r: Rect) void {
    if (im.tint) |k| {
        const n = im.node;
        if (n.image.len == 0) return;
        _ = c.open(placed, null);
        defer c.end();
        if (isSvg(n.image)) {
            _ = ui.svg(c, .{ .key = n.image_key, .bytes = n.image, .width = r.w, .height = r.h, .color = color(k) });
            return;
        }
        _ = ui.image(c, .{ .key = n.image_key, .bytes = n.image, .box = .{ .w = r.w, .h = r.h }, .radius = 0, .tint = color(k) });
        return;
    }
    if (im.corners != 15 and im.radius > 0) {
        var s = placed;
        s.clip = true;
        s.radius = im.radius;
        s.clip_corners = im.corners;
        _ = c.open(s, null);
        defer c.end();
        var plain = im;
        plain.radius = 0;
        var inner = placed;
        inner.offset = .{};
        inner.opacity = 1;
        drawImage(c, plain, inner, r);
        return;
    }
    drawImage(c, im, placed, r);
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

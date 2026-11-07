//! A display list drawn with nanoui: what is in view each frame becomes
//! absolutely placed boxes, so a page costs what fits in the window however
//! long it is. Items of a clip other than the page's share a clipping box.
//!
//! `host` gives what the list only names:
//!   host.picture(url) ?[]const u8         a background's bytes; asks for them the first time
//!   host.gradient(g, w, h, nx, ny, scale) ?[]const u8   tiles of a gradient as a picture
//!   host.control(c, box, x, y, opacity)   draws a form control at (x, y) in the open box
//!   host.nearLazy(node)                   a `loading=lazy` picture has come near the window
//!   host.frame(c, node, x, y, r)          draws an `<iframe>`'s page at (x, y) in the open box, `r` in the window
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

/// How far from the window a lazy picture is asked for, as Chromium does.
const lazy_reach = 1250;

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
        if (it.kind == .image) {
            const n = it.kind.image.node;
            if (n.image_key.len == 0 and n.ns == .html and overlaps(.{ .x = r.x - lazy_reach, .y = r.y - lazy_reach, .w = r.w + 2 * lazy_reach, .h = r.h + 2 * lazy_reach }, clip.visible)) host.nearLazy(n);
        }
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
        .image => |im| if (im.node.isTag("iframe")) host.frame(c, im.node, x, y, r) else if (im.node.isTag("canvas")) drawCanvas(c, host.canvas(im.node), placed, r) else drawPicture(c, im, placed, r),
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

/// A canvas's pixels stretched over its box, as `object-fit: fill` has it.
fn drawCanvas(c: *ui.Context, pixels: ?ui.Texture, placed: ui.Style, r: Rect) void {
    const t = pixels orelse return;
    if (r.w <= 0 or r.h <= 0) return;
    var s = placed;
    s.width = .{ .px = r.w };
    s.height = .{ .px = r.h };
    ui.texture(c, s, t, .{ 0, 0, 1, 1 }, 1);
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
    if (n.image.len == 0 or r.w <= 0 or r.h <= 0) return;
    var s = placed;
    s.width = .{ .px = r.w };
    s.height = .{ .px = r.h };
    s.clip = im.radius > 0 or im.fit == .none or im.fit == .cover;
    s.radius = im.radius;
    _ = c.open(s, null);
    defer c.end();
    // An inline `<svg>` is laid out to its box and says for itself how it fits.
    if (n.ns == .svg) {
        _ = ui.svg(c, .{ .key = n.image_key, .bytes = n.image, .width = r.w, .height = r.h });
        return;
    }
    const svg = isSvg(n.image);
    const d = @max(n.image_density, 0.001);
    const own: ui.Size = if (svg) svgFitSize(n.image, r.w, r.h) else blk: {
        const px = ui.imageSize(c, n.image_key, n.image) orelse return;
        break :blk .{ .w = px.w / d, .h = px.h / d };
    };
    const p = fitted(im.fit, own, r.w, r.h, im.style);
    if (svg) {
        // Documents start from black, whatever this window's theme.
        _ = c.open(.{ .absolute = true, .offset = .{ .x = p.x, .y = p.y } }, null);
        defer c.end();
        _ = ui.svg(c, .{ .key = n.image_key, .bytes = n.image, .width = p.w, .height = p.h, .current = ui.Color.black });
        return;
    }
    const v = visiblePart(p, r.w, r.h);
    if (v.w <= 0 or v.h <= 0) return;
    if (v.w != r.w or v.h != r.h or v.x != 0 or v.y != 0) {
        _ = c.open(.{ .absolute = true, .offset = .{ .x = v.x, .y = v.y } }, null);
        defer c.end();
        _ = ui.image(c, .{ .key = n.image_key, .bytes = n.image, .box = .{ .w = v.w, .h = v.h }, .radius = 0, .part = v.part });
        return;
    }
    _ = ui.image(c, .{ .key = n.image_key, .bytes = n.image, .box = .{ .w = v.w, .h = v.h }, .radius = im.radius, .part = v.part });
}

const Placed = struct { x: f32, y: f32, w: f32, h: f32 };

/// Where a picture of `own` size goes in a box of `bw` × `bh`, as `object-fit`
/// and `object-position` say; it may reach outside the box.
fn fitted(fit: css.ObjectFit, own: ui.Size, bw: f32, bh: f32, st: *const css.Style) Placed {
    var w = bw;
    var h = bh;
    const contain = @min(bw / @max(own.w, 0.001), bh / @max(own.h, 0.001));
    const cover_k = @max(bw / @max(own.w, 0.001), bh / @max(own.h, 0.001));
    switch (fit) {
        .fill => return .{ .x = 0, .y = 0, .w = bw, .h = bh },
        .contain => {
            w = own.w * contain;
            h = own.h * contain;
        },
        .cover => {
            w = own.w * cover_k;
            h = own.h * cover_k;
        },
        .none => {
            w = own.w;
            h = own.h;
        },
        .scale_down => {
            const k = @min(contain, 1);
            w = own.w * k;
            h = own.h * k;
        },
    }
    return .{
        .x = (bw - w) * st.object_x / 100 + st.object_x_px,
        .y = (bh - h) * st.object_y / 100 + st.object_y_px,
        .w = w,
        .h = h,
    };
}

const Visible = struct { x: f32, y: f32, w: f32, h: f32, part: [4]f32 };

/// What of a placed picture shows in the box, and which part of the picture it is.
fn visiblePart(p: Placed, bw: f32, bh: f32) Visible {
    const x0 = @max(p.x, 0);
    const y0 = @max(p.y, 0);
    const x1 = @min(p.x + p.w, bw);
    const y1 = @min(p.y + p.h, bh);
    return .{
        .x = x0,
        .y = y0,
        .w = x1 - x0,
        .h = y1 - y0,
        .part = .{ (x0 - p.x) / @max(p.w, 0.001), (y0 - p.y) / @max(p.h, 0.001), (x1 - p.x) / @max(p.w, 0.001), (y1 - p.y) / @max(p.h, 0.001) },
    };
}

/// What an SVG document says of its size.
pub const SvgOwn = struct { size: ?[2]f32 = null, ratio: ?f32 = null };

pub fn svgOwn(bytes: []const u8) SvgOwn {
    const head = rootTag(bytes);
    var out: SvgOwn = .{};
    if (attrIn(head, "viewBox")) |vb| {
        var it = std.mem.tokenizeAny(u8, vb, " ,");
        _ = it.next();
        _ = it.next();
        const vw = number(it.next());
        const vh = number(it.next());
        if (vw != null and vh != null and vw.? > 0 and vh.? > 0) out.ratio = vw.? / vh.?;
    }
    const w = number(attrIn(head, "width"));
    const h = number(attrIn(head, "height"));
    if (w != null and h != null) {
        out.size = .{ w.?, h.? };
    } else if (w != null and out.ratio != null) {
        out.size = .{ w.?, w.? / out.ratio.? };
    } else if (h != null and out.ratio != null) {
        out.size = .{ h.? * out.ratio.?, h.? };
    }
    return out;
}

/// An SVG's size to fit by: its own, or the box when it hasn't one, in its shape.
fn svgFitSize(bytes: []const u8, bw: f32, bh: f32) ui.Size {
    const own = svgOwn(bytes);
    if (own.size) |v| return .{ .w = v[0], .h = v[1] };
    if (own.ratio) |ratio| {
        if (bw / @max(bh, 0.001) > ratio) return .{ .w = bh * ratio, .h = bh };
        return .{ .w = bw, .h = bw / ratio };
    }
    return .{ .w = bw, .h = bh };
}

/// The picture's size for a background: an SVG's own, else its viewBox's.
pub fn svgSize(bytes: []const u8) ?[2]f32 {
    const own = svgOwn(bytes);
    if (own.size) |v| return v;
    const head = rootTag(bytes);
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

/// The `<svg ...>` tag's text, past any prolog; what its attributes are read from.
fn rootTag(bytes: []const u8) []const u8 {
    const head = bytes[0..@min(bytes.len, 8192)];
    const at = std.mem.indexOf(u8, head, "<svg") orelse return "";
    var i = at;
    var quote: u8 = 0;
    while (i < head.len) : (i += 1) {
        const ch = head[i];
        if (quote != 0) {
            if (ch == quote) quote = 0;
        } else if (ch == '"' or ch == '\'') quote = ch else if (ch == '>') break;
    }
    return head[at..i];
}

fn attrIn(head: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, head, from, name)) |at| {
        from = at + name.len;
        if (at == 0 or head[at - 1] != ' ' and head[at - 1] != '\n' and head[at - 1] != '\t' and head[at - 1] != '\r') continue;
        const rest = std.mem.trimStart(u8, head[from..], " ");
        if (rest.len < 2 or rest[0] != '=') continue;
        const q = rest[1];
        if (q != '"' and q != '\'') continue;
        const end = std.mem.indexOfScalarPos(u8, rest, 2, q) orelse continue;
        return rest[2..end];
    }
    return null;
}

/// A length in CSS pixels; a percentage says nothing of a size.
fn number(s: ?[]const u8) ?f32 {
    const t = std.mem.trim(u8, s orelse return null, " \t\r\n");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isDigit(t[end]) or t[end] == '.')) end += 1;
    if (end == 0) return null;
    const v = std.fmt.parseFloat(f32, t[0..end]) catch return null;
    const u = t[end..];
    const eq = std.ascii.eqlIgnoreCase;
    if (u.len == 0 or eq(u, "px")) return v;
    if (eq(u, "%")) return null;
    if (eq(u, "em") or eq(u, "rem")) return v * 16;
    if (eq(u, "ex")) return v * 8;
    if (eq(u, "pt")) return v * 4 / 3;
    if (eq(u, "pc")) return v * 16;
    if (eq(u, "in")) return v * 96;
    if (eq(u, "cm")) return v * 96 / 2.54;
    if (eq(u, "mm")) return v * 96 / 25.4;
    return v;
}

pub fn isSvg(bytes: []const u8) bool {
    const head = std.mem.trimStart(u8, bytes[0..@min(bytes.len, 1024)], " \t\r\n\xef\xbb\xbf");
    if (std.mem.startsWith(u8, head, "<svg")) return true;
    if (!std.mem.startsWith(u8, head, "<?xml") and !std.mem.startsWith(u8, head, "<!")) return false;
    return std.mem.indexOf(u8, head, "<svg") != null;
}

test "object-fit and object-position place a picture, cut to its box" {
    const st: css.Style = .{};
    // Covering: the middle of the longer side.
    const wide = visiblePart(fitted(.cover, .{ .w = 200, .h = 100 }, 100, 100, &st), 100, 100);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), wide.part[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), wide.part[2], 0.001);
    try std.testing.expectEqual(@as(f32, 100), wide.w);
    // At its own size, and at the left: its left part only.
    var left: css.Style = .{};
    left.object_x = 0;
    const none = visiblePart(fitted(.none, .{ .w = 200, .h = 100 }, 100, 100, &left), 100, 100);
    try std.testing.expectEqual(@as(f32, 0), none.part[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), none.part[2], 0.001);
    try std.testing.expectEqual(@as(f32, 0), none.x);
    try std.testing.expectEqual(@as(f32, 0), none.y);
    // Containing: bars either side, in the middle unless positioned.
    const whole = fitted(.contain, .{ .w = 100, .h = 200 }, 100, 100, &st);
    try std.testing.expectEqual(@as(f32, 25), whole.x);
    try std.testing.expectEqual(@as(f32, 50), whole.w);
    // Scaling down leaves a small picture as it is.
    const small = fitted(.scale_down, .{ .w = 10, .h = 10 }, 100, 100, &st);
    try std.testing.expectEqual(@as(f32, 10), small.w);
    try std.testing.expectEqual(@as(f32, 45), small.x);
    try std.testing.expect(svgOwn("<svg width=\"1em\" viewBox=\"0 0 2 1\">").size.?[1] == 8);
    try std.testing.expect(isSvg("<!-- c --><!DOCTYPE svg><svg/>"));
    try std.testing.expect(isSvg("  <svg width=1>"));
    try std.testing.expect(!isSvg("\x89PNG"));
    try std.testing.expectEqual(@as(f32, 24), svgSize("<svg xmlns=\"x\" width=\"24\" height=\"12px\"></svg>").?[0]);
    try std.testing.expectEqual(@as(f32, 96), svgSize("<svg viewBox=\"0 0 48 96\"></svg>").?[1]);
    try std.testing.expect(svgSize("<svg width=\"100%\" height=\"100%\"></svg>") == null);
}

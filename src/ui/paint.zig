//! Turns the laid out tree into the renderer's instances, in paint order,
//! and records the visible rectangles of interactive boxes for hit testing.
const std = @import("std");
const types = @import("types.zig");
const metal = @import("gpu.zig");
const glass = @import("glass.zig");
const text_mod = @import("text.zig");
const rich = text_mod.rich;
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

pub fn paint(c: *Context, out: *std.ArrayList(metal.Instance)) void {
    out.clearRetainingCapacity();
    c.layers.clearRetainingCapacity();
    paintNode(c, out, 0, types.Rect.infinite, 1, false, 0);
    // Higher layers over the page, lowest first; within one, in tree order.
    var done: usize = 0;
    while (done < c.layers.items.len) {
        // What waits, by layer; insertion sort keeps tree order among equals.
        std.sort.insertion(u32, c.layers.items[done..], c, struct {
            fn lt(ctx: *Context, a: u32, b: u32) bool {
                return ctx.node(a).style.layer < ctx.node(b).style.layer;
            }
        }.lt);
        const idx = c.layers.items[done];
        done += 1;
        c.layer_root = idx;
        paintNode(c, out, idx, types.Rect.infinite, 1, false, 0);
    }
    c.layer_root = std.math.maxInt(u32);
}

fn snap(v: f32, scale: f32) f32 {
    return @round(v * scale) / scale;
}

/// To the nearest whole, a half toward zero (GPUI's `round_half_toward_zero`).
fn halfTowardZero(v: f32) f32 {
    return std.math.copysign(@ceil(@abs(v) - 0.5), v);
}

fn push(c: *Context, out: *std.ArrayList(metal.Instance), inst: metal.Instance) void {
    out.append(c.gpa, inst) catch {};
}

/// A canvas's shapes, moved to its box and clipped to it; those wholly
/// outside what shows of it are left out.
fn paintCanvas(c: *Context, out: *std.ArrayList(metal.Instance), cv: *const @import("draw.zig").Canvas, r: types.Rect, visible: types.Rect, opacity: f32) void {
    const clip = metal.clip4(visible);
    out.ensureUnusedCapacity(c.gpa, cv.shapes.items.len) catch return;
    for (cv.shapes.items) |shape| {
        var i = shape;
        i.rect[0] += r.x;
        i.rect[1] += r.y;
        if (i.rect[0] > clip[2] or i.rect[1] > clip[3] or i.rect[0] + i.rect[2] < clip[0] or i.rect[1] + i.rect[3] < clip[1]) continue;
        if (i.kind == metal.Kind.segment or i.kind == metal.Kind.triangle) {
            i.uv[0] += r.x;
            i.uv[1] += r.y;
            i.uv[2] += r.x;
            i.uv[3] += r.y;
        }
        if (i.kind == metal.Kind.triangle) {
            i.border_color[0] += r.x;
            i.border_color[1] += r.y;
        }
        i.color[3] *= opacity;
        i.border_color[3] *= if (i.kind == metal.Kind.quad) opacity else 1;
        i.clip = clip;
        out.appendAssumeCapacity(i);
    }
}

/// `scrolled`: how far the scrolling boxes it's in have scrolled it up.
fn paintNode(c: *Context, out: *std.ArrayList(metal.Instance), index: u32, clip: types.Rect, opacity_in: f32, selectable_in: bool, scrolled: f32) void {
    const n = c.node(index).*;
    const st = n.style;
    // A higher layer is drawn later, over the page.
    if (st.layer > 0 and index != c.layer_root) {
        c.layers.append(c.gpa, index) catch {};
        return;
    }
    const selectable = (selectable_in or st.selectable) and !st.control;
    const opacity = opacity_in * st.opacity;
    const r = n.rect;
    const visible = r.intersect(clip);
    if (opacity <= 0.001) return;
    const start = out.items.len;
    const clip4 = metal.clip4(clip);
    const rect4: [4]f32 = .{ r.x, r.y, r.w, r.h };

    if (visible.w > 0 and visible.h > 0) {
        if (st.shadow) |sh| paintShadow(c, out, sh, r, st.radius, opacity, clip4);
        for (st.shadows) |sh| paintShadow(c, out, sh, r, st.radius, opacity, clip4);
        // Glass takes the background's place.
        const fill: ?types.Color = if (st.glass != null) null else st.background;
        if (st.glass) |g| push(c, out, glass.instance(glass.material(g, r.w, r.h, c.theme.dark, c.scale), rect4, st.radius, clip4, opacity));
        if (fill != null or st.border != null) push(c, out, .{
            .rect = rect4,
            .color = metal.color4((fill orelse types.Color.transparent).alpha(opacity)),
            .border_color = metal.color4((st.border orelse types.Color.transparent).alpha(opacity)),
            .border_width = if (st.border != null) st.border_width else 0,
            .radius = st.radius,
            // A quad's uv is free: its x marks a dashed border.
            .uv = .{ if (st.border_dashed) 1 else 0, 0, 0, 0 },
            .clip = clip4,
        });
        switch (n.content) {
            .text => |t| paintText(c, out, index, n, t, clip4, opacity, selectable),
            .icon => |ic| if (c.text.atlas.symbol(ic.name, ic.size, @intFromEnum(ic.weight))) |sp| {
                // Centered in its box, which may be larger (a fixed frame).
                const inner = r.inset(st.padding);
                const x = inner.x + (inner.w - (sp.w + 2 * sp.x)) / 2;
                const y = inner.y + (inner.h - (sp.h + 2 * sp.y)) / 2;
                push(c, out, .{
                    .rect = .{ snap(x, c.scale) + sp.x, snap(y, c.scale) + sp.y, sp.w, sp.h },
                    .color = metal.color4(ic.color.alpha(opacity)),
                    .uv = sp.uv,
                    .kind = metal.Kind.text,
                    .clip = clip4,
                });
            },
            .image => |im| if (c.text.images.get(im.key, im.bytes)) |e| push(c, out, .{
                .rect = if (im.snap) .{ snap(r.x, c.scale), snap(r.y, c.scale), r.w, r.h } else rect4,
                .color = .{ 1, 1, 1, im.opacity * opacity },
                // A tint (alpha above 0) fills the picture's shape instead.
                .border_color = if (im.tint) |t| metal.color4(t) else .{ 0, 0, 0, 0 },
                .uv = e.uv,
                .radius = st.radius,
                .kind = metal.Kind.image,
                .clip = clip4,
            }),
            .texture => |tx| push(c, out, .{
                .rect = rect4,
                .color = .{ 1, 1, 1, tx.opacity * opacity },
                .uv = tx.uv,
                .radius = st.radius,
                .kind = metal.Kind.texture,
                .border_width = @floatFromInt(tx.slot),
                .clip = clip4,
            }),
            .canvas => |cv| paintCanvas(c, out, cv, r, visible, opacity),
            .none => {},
        }
    }
    if (n.interactive and visible.w > 0 and visible.h > 0) c.addHit(n.id, index, visible, false);

    var child_clip = clip;
    if (st.clip) child_clip = visible;
    if (st.scroll) {
        child_clip = visible;
        c.addHit(n.id, index, visible, true);
    }
    const first = out.items.len;
    var child = n.first_child;
    const inner_scrolled = scrolled + if (st.scroll) c.scroll.get(n.id) orelse 0 else 0;
    while (child != none) : (child = c.node(child).next) paintNode(c, out, child, child_clip, opacity, selectable, inner_scrolled);
    if ((st.clip or st.scroll) and st.radius > 0) roundClip(out.items[first..], r, visible, st.radius);

    if (st.scroll) paintScrollbar(c, out, n, visible, opacity);
    if (st.scale != 1) scaleItems(out.items[start..], r.x + r.w / 2, r.y + r.h / 2, @max(st.scale, 0), clip4);
    if (st.layout_motion != 0) {
        // Where the layout put it, scrolling aside: a scroll isn't a move.
        var placed = r;
        placed.y += scrolled;
        const d = @import("motion/layout.zig").shift(c, st.layout_motion, placed);
        if (d[0] != 0 or d[1] != 0) for (out.items[start..]) |*it| {
            it.rect[0] += d[0];
            it.rect[1] += d[1];
            if (!std.mem.eql(f32, &it.clip, &clip4) and it.clip[0] > -1e5) it.clip = .{ it.clip[0] + d[0], it.clip[1] + d[1], it.clip[2] + d[0], it.clip[3] + d[1] };
        };
    }
}

/// Scales what a box drew about (cx, cy): rectangles, corners, borders,
/// shadows' blur, and the clips its own boxes made; not the clip it's
/// drawn in (`outer`), which stays as its parent set it.
fn scaleItems(items: []metal.Instance, cx: f32, cy: f32, k: f32, outer: [4]f32) void {
    for (items) |*it| {
        it.rect = .{ cx + (it.rect[0] - cx) * k, cy + (it.rect[1] - cy) * k, it.rect[2] * k, it.rect[3] * k };
        it.radius *= k;
        // A quad's border, a shadow's blur, glass's blur; a texture keeps
        // its slot there.
        if (it.kind == metal.Kind.quad or it.kind == metal.Kind.shadow or it.kind == metal.Kind.glass) it.border_width *= k;
        if (!std.mem.eql(f32, &it.clip, &outer) and it.clip[0] > -1e5) {
            it.clip = .{ cx + (it.clip[0] - cx) * k, cy + (it.clip[1] - cy) * k, cx + (it.clip[2] - cx) * k, cy + (it.clip[3] - cy) * k };
            const round = metal.clipCorners(it.clip_round);
            it.clip_round = metal.clipRound(round.radius * k, round.corners);
        }
    }
}

fn paintText(c: *Context, out: *std.ArrayList(metal.Instance), index: u32, n: ctx_mod.Node, t: ctx_mod.Content.Text, clip4: [4]f32, opacity: f32, selectable: bool) void {
    const sel: ?Sel = if (selectable) .{ .id = n.id, .index = index, .x0 = n.rect.x, .x1 = n.rect.x + n.rect.w } else null;
    const inner = n.rect.inset(n.style.padding);
    const f = c.text.font(t.style);
    const lh = c.text.lineHeight(t.style);
    if (t.style.wrap) {
        for (t.lines, 0..) |l, i| {
            const y = inner.y + lh * @as(f32, @floatFromInt(i));
            textRun(c, out, t, l.start, l.end, inner.x, y, f, lh, clip4, opacity, sel);
        }
    } else if (t.style.truncate != .none) {
        truncated(c, out, t, inner, f, lh, clip4, opacity, sel);
    } else {
        textRun(c, out, t, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel);
    }
}

fn paintShadow(c: *Context, out: *std.ArrayList(metal.Instance), sh: types.Shadow, r: types.Rect, radius: f32, opacity: f32, clip4: [4]f32) void {
    const s = sh.spread;
    push(c, out, .{
        .rect = .{ r.x - s, r.y + sh.y - s, @max(0, r.w + 2 * s), @max(0, r.h + 2 * s) },
        .color = metal.color4(sh.color.alpha(opacity)),
        .radius = @max(0, radius + s),
        // CSS's blur radius is twice the Gaussian's standard deviation.
        .border_width = sh.blur / 2,
        .kind = metal.Kind.shadow,
        .clip = clip4,
    });
}

/// Where a truncated line ends, and over how many points it fades out
/// before that (0: cut there).
const Limit = struct { end: f32, fade: f32 = 0 };

/// A line that may be longer than its box: whole if it fits; else cut at a
/// glyph before an ellipsis, or drawn to the box's end, fading out.
fn truncated(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, inner: types.Rect, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel) void {
    const lay = c.text.layout(t.str, t.style);
    if (lay.width <= inner.w + 0.5) return textRun(c, out, t, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel);
    if (t.style.truncate == .fade) {
        const limit: Limit = .{ .end = inner.x + inner.w, .fade = @min(t.style.fade_width, inner.w / 2) };
        return textRunLimit(c, out, t, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel, limit);
    }
    const ellipsis = "\u{2026}";
    const room = inner.w - c.text.width(ellipsis, t.style);
    // The last glyph boundary that leaves room for the ellipsis, before
    // any spaces there.
    var cut: usize = 0;
    var cut_x: f32 = 0;
    for (lay.glyphs) |g| {
        if (g.x > room) break;
        cut = g.index;
        cut_x = g.x;
    }
    while (cut > 0 and t.str[cut - 1] == ' ') cut -= 1;
    if (cut > 0) cut_x = c.text.layout(t.str[0..cut], t.style).width;
    const limit: Limit = .{ .end = inner.x + inner.w };
    if (cut > 0) textRunLimit(c, out, t, 0, cut, inner.x, inner.y, f, lh, clip4, opacity, sel, limit);
    var dots = t;
    dots.str = ellipsis;
    dots.spans = &.{};
    textRunLimit(c, out, dots, 0, ellipsis.len, inner.x + cut_x, inner.y, f, lh, clip4, opacity, null, limit);
}

/// Draws bytes [start, end) of `t`, each glyph in its span's color.
/// A selectable text: its id, its place in the tree, and the box's
/// horizontal extent.
const Sel = struct { id: u64, index: u32, x0: f32, x1: f32 };

fn textRun(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, start: usize, end: usize, x: f32, y: f32, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel) void {
    textRunLimit(c, out, t, start, end, x, y, f, lh, clip4, opacity, sel, null);
}

fn textRunLimit(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, start: usize, end: usize, x: f32, y: f32, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel, limit: ?Limit) void {
    const style = t.style;
    // Cull lines wholly above or below the clip before shaping them; a
    // selectable one still counts for where the pointer is.
    if (y > clip4[3] or y + lh < clip4[1] or x > clip4[2]) {
        if (sel) |s| if (y + lh <= c.input.mouse.y) {
            c.selection.below = .{ .id = s.id, .at = end };
            if (!c.selection.next_order.contains(s.id)) c.selection.next_order.put(c.gpa, s.id, @intCast(c.selection.next_order.count())) catch {};
        };
        return;
    }
    const styled = t.spans.len > 0 and rich.styled(t.spans);
    const lay = if (styled) rich.layout(c.text, t.str[start..end], style, t.spans, start) else c.text.layout(t.str[start..end], style);
    if (lay.glyphs.len == 0 or x + lay.width < clip4[0]) return;
    const scale = c.scale;
    // The line's extra height (its leading) goes half above, half below.
    const gpui_snap = c.text.glyph_snap == .half_toward_zero;
    const baseline_at = if (c.text.baseline_rule == .glyph_box and lh != f.lineHeight())
        y + (lh - f.ascent - f.descent) / 2 + f.ascent
    else
        y + (lh - f.lineHeight()) / 2 + f.leading / 2 + f.ascent;
    const baseline = if (gpui_snap) halfTowardZero(baseline_at * scale) / scale else snap(baseline_at, scale);
    const base = metal.color4(t.color.alpha(opacity));
    if (sel) |s| @import("selection.zig").line(c, out, s.id, s.index, t.str, start, end, lay, x, y, lh, s.x0, s.x1, clip4);
    if (t.spans.len > 0) decorations(c, out, t, lay, start, end, x, .{ .top = y, .h = lh, .baseline = baseline }, f, clip4, opacity);
    var span_i: usize = 0;
    for (lay.glyphs) |g| {
        const pen = (x + g.x) * scale;
        if (pen / scale > clip4[2]) break;
        if (limit) |l| if (pen / scale >= l.end) break;
        const bins: f32 = text_mod.subpixel_bins;
        const pen_at = if (gpui_snap) halfTowardZero(pen * bins) / bins else pen;
        const px = @floor(pen_at);
        const bin: u8 = @intFromFloat(@min(bins - 1, @floor((pen_at - px) * bins + if (gpui_snap) @as(f32, 0.001) else 0)));
        var color = base;
        var tone = t.color;
        if (t.spans.len > 0) {
            const at = start + g.index;
            while (span_i < t.spans.len and t.spans[span_i].end <= at) span_i += 1;
            // Glyphs of a run are mostly in order; a ligature or bidi may step back.
            if (span_i < t.spans.len and t.spans[span_i].start > at) {
                span_i = 0;
                while (span_i < t.spans.len and t.spans[span_i].end <= at) span_i += 1;
            }
            if (span_i < t.spans.len and t.spans[span_i].start <= at) if (t.spans[span_i].color) |sc| {
                color = metal.color4(sc.alpha(opacity));
                tone = sc;
            };
        }
        // Lighter text is drawn with thicker strokes, as macOS draws it.
        const sp = c.text.glyph(g, bin, @TypeOf(c.text.*).dilationFor(tone.r, tone.g, tone.b)) orelse continue;
        push(c, out, .{
            .rect = .{ px / scale + sp.x, baseline - g.y + sp.y, sp.w, sp.h },
            .color = color,
            .uv = sp.uv,
            .kind = metal.Kind.text,
            // A fading line: its glyphs fade out toward `end`, and are
            // cut there (the shader reads these for glyphs).
            .radius = if (limit) |l| l.end else 0,
            .border_width = if (limit) |l| l.fade else 0,
            .clip = if (limit) |l| .{ clip4[0], clip4[1], @min(clip4[2], l.end), clip4[3] } else clip4,
        });
    }
}

/// The x of the first glyph at or after byte `at` of the line, else its end.
fn xAt(lay: text_mod.Layout, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

/// A line's box: its top, its height and its baseline.
const LineBox = struct { top: f32, h: f32, baseline: f32 };

/// What spans draw besides their glyphs: backgrounds (inline code, marks)
/// behind the text, underlines (links) and lines through.
fn decorations(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, lay: text_mod.Layout, start: usize, end: usize, x: f32, line: LineBox, f: text_mod.Font, clip4: [4]f32, opacity: f32) void {
    const baseline = line.baseline;
    for (t.spans) |sp| {
        if (sp.end <= start or sp.start >= end) continue;
        if (sp.background == null and !sp.underline and !sp.strike) continue;
        const a = @max(sp.start, start) - start;
        const b = @min(sp.end, end) - start;
        const x0 = x + xAt(lay, a);
        const x1 = x + xAt(lay, b);
        if (x1 <= x0) continue;
        const color = sp.color orelse t.color;
        if (sp.background) |bg| push(c, out, .{
            .rect = if (t.style.span_box) |box|
                .{ x0 - box.pad_x, line.top + box.inset_y, x1 - x0 + 2 * box.pad_x, line.h - 2 * box.inset_y }
            else
                .{ x0 - 3, baseline - f.ascent * 0.92 - 2, x1 - x0 + 6, (f.ascent + f.descent) * 0.92 + 4 },
            .color = metal.color4(bg.alpha(opacity)),
            .radius = if (t.style.span_box) |box| box.radius else 4,
            .clip = clip4,
        });
        if (sp.underline) push(c, out, .{
            .rect = .{ x0, baseline + 2, x1 - x0, 1 },
            .color = metal.color4(color.alpha(0.6 * opacity)),
            .clip = clip4,
        });
        if (sp.strike) push(c, out, .{
            .rect = .{ x0, baseline - f.ascent * 0.32, x1 - x0, 1 },
            .color = metal.color4(color.alpha(opacity)),
            .clip = clip4,
        });
    }
}

/// What a box with rounded corners clips is cut by its corners too: each
/// instance it clipped whose clip shares one of the box's corners (one the
/// box's own clip didn't cut off) has that corner rounded. A clip within
/// keeps its own rounding.
fn roundClip(items: []metal.Instance, box: types.Rect, visible: types.Rect, radius: f32) void {
    const near = struct {
        fn f(a: f32, b: f32) bool {
            return @abs(a - b) < 0.01;
        }
    }.f;
    const v = metal.clip4(visible);
    const b = metal.clip4(box);
    // The box's corners left whole by its own clip: 1 top left, 2 top
    // right, 4 bottom right, 8 bottom left.
    var whole: u4 = 0;
    if (near(v[0], b[0]) and near(v[1], b[1])) whole |= 1;
    if (near(v[2], b[2]) and near(v[1], b[1])) whole |= 2;
    if (near(v[2], b[2]) and near(v[3], b[3])) whole |= 4;
    if (near(v[0], b[0]) and near(v[3], b[3])) whole |= 8;
    if (whole == 0) return;
    for (items) |*i| {
        const k = i.clip;
        var corners: u4 = 0;
        if (near(k[0], v[0]) and near(k[1], v[1])) corners |= 1;
        if (near(k[2], v[2]) and near(k[1], v[1])) corners |= 2;
        if (near(k[2], v[2]) and near(k[3], v[3])) corners |= 4;
        if (near(k[0], v[0]) and near(k[3], v[3])) corners |= 8;
        corners &= whole;
        if (corners == 0) continue;
        const had = metal.clipCorners(i.clip_round);
        if (had.corners == 0) {
            i.clip_round = metal.clipRound(radius, corners);
        } else if (near(had.radius, radius)) i.clip_round = metal.clipRound(radius, had.corners | corners);
    }
}

/// How long an overlay bar stays after the box last scrolled, then how
/// long it takes to fade (GPUI's `MENU_SCROLLBAR_LINGER_MS`, `_FADE_MS`).
const overlay_linger: f64 = 1.4;
const overlay_fade: f64 = 0.26;

fn paintOverlayBar(c: *Context, out: *std.ArrayList(metal.Instance), n: ctx_mod.Node, visible: types.Rect, opacity: f32, offset: f32, view_h: f32, content_h: f32, t: f32) void {
    const color = n.style.scrollbar.overlay;
    const gop = c.overlay_bars.getOrPut(c.gpa, n.id) catch return;
    // First seen: nothing has scrolled yet.
    if (!gop.found_existing) gop.value_ptr.* = .{ .offset = offset, .moved_at = -1e9 };
    if (gop.value_ptr.offset != offset) gop.value_ptr.* = .{ .offset = offset, .moved_at = c.time };
    const strip: types.Rect = .{ .x = n.rect.x + n.rect.w - 10, .y = n.rect.y, .w = 10, .h = n.rect.h };
    const held = strip.contains(c.input.mouse);
    const since = c.time - gop.value_ptr.moved_at;
    const fade: f32 = if (held) 1 else @floatCast(std.math.clamp(1 - (since - overlay_linger) / overlay_fade, 0, 1));
    if (!held and since < overlay_linger + overlay_fade) {
        // Wake for the fade's start, then step through it.
        c.frameIn(@floatCast(if (since < overlay_linger) overlay_linger - since else 1.0 / 60.0));
    }
    if (fade <= 0) return;
    const inset: f32 = 4;
    const track = view_h - 2 * inset;
    const bar_h = @max(24, track * view_h / content_h);
    const w: f32 = if (held) 5 else 3;
    push(c, out, .{
        .rect = .{ n.rect.x + n.rect.w - 2 - w, n.rect.y + inset + (track - bar_h) * std.math.clamp(t, 0, 1), w, bar_h },
        .color = metal.color4(color.alpha(color.a * @as(f32, if (held) 0.68 / 0.5 else 1) * fade * opacity)),
        .radius = w / 2,
        .clip = metal.clip4(visible),
    });
}

fn paintScrollbar(c: *Context, out: *std.ArrayList(metal.Instance), n: ctx_mod.Node, visible: types.Rect, opacity: f32) void {
    const offset = c.scroll.get(n.id) orelse 0;
    // The content's height: from the first child's top to the last child's bottom.
    if (n.first_child == none) return;
    const first = c.node(n.first_child).rect;
    const last = c.node(n.last_child).rect;
    const content_h = last.y + last.h - first.y + n.style.padding.vertical();
    const view_h = n.rect.h;
    if (content_h <= view_h + 0.5) return;
    const t = offset / (content_h - view_h);
    if (n.style.scrollbar == .overlay) return paintOverlayBar(c, out, n, visible, opacity, offset, view_h, content_h, t);
    const bar_h = @max(24, view_h * view_h / content_h);
    const y = n.rect.y + (view_h - bar_h) * std.math.clamp(t, 0, 1);
    push(c, out, .{
        .rect = .{ n.rect.x + n.rect.w - 7, y + 2, 4, bar_h - 4 },
        .color = metal.color4(c.theme.muted.alpha(0.5 * opacity)),
        .radius = 2,
        .clip = metal.clip4(visible),
    });
}

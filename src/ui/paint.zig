//! Turns the laid out tree into the renderer's instances, in paint order,
//! and records the visible rectangles of interactive boxes for hit testing.
const std = @import("std");
const types = @import("types.zig");
const metal = @import("gpu.zig");
const glass = @import("glass.zig");
const text_mod = @import("text.zig");
const native_windows = @import("dwrite.zig").enabled;
const rich = text_mod.rich;
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const none = ctx_mod.none;

pub fn paint(c: *Context, out: *std.ArrayList(metal.Instance)) void {
    out.clearRetainingCapacity();
    if (out.capacity < 4096) out.ensureTotalCapacity(c.gpa, 4096) catch {};
    c.scrollbars.clearRetainingCapacity();
    c.text.images.beginPaint();
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
    const r = n.rect;
    const visible = r.intersect(clip);
    const total_opacity = opacity_in * st.opacity;
    if (total_opacity <= 0.001) return;
    const open_group = st.group and total_opacity < 0.999 and !c.painting_group;
    const opacity = if (open_group) 1.0 else total_opacity;
    var group_rect: [4]f32 = .{ 0, 0, 0, 0 };
    if (open_group) {
        c.painting_group = true;
        const grown: types.Rect = .{ .x = r.x - 64, .y = r.y - 64, .w = r.w + 128, .h = r.h + 128 };
        const gr = grown.intersect(clip);
        group_rect = .{ gr.x, gr.y, gr.w, gr.h };
        push(c, out, .{
            .rect = group_rect,
            .color = .{ 1, 1, 1, 1 },
            .kind = metal.Kind.layer_begin,
            .clip = metal.clip4(clip),
        });
    }
    defer if (open_group) {
        c.painting_group = false;
        push(c, out, .{
            .rect = group_rect,
            .color = .{ 1, 1, 1, total_opacity },
            .kind = metal.Kind.layer_end,
            .clip = metal.clip4(clip),
        });
    };
    const clip4 = metal.clip4(clip);
    const moving = blk: {
        if (!c.animating) break :blk false;
        const prev = c.prev_rects.get(n.id) orelse break :blk false;
        break :blk @abs(r.x - prev.x) > 0.01 or @abs(r.y - prev.y) > 0.01 or @abs(r.w - prev.w) > 0.01 or @abs(r.h - prev.h) > 0.01;
    };
    const sx0 = if (moving) r.x else snap(r.x, c.scale);
    const sy0 = if (moving) r.y else snap(r.y, c.scale);
    const sw = if (moving) r.w else snap(r.w, c.scale);
    const sh_h = if (moving) r.h else snap(r.h, c.scale);
    const rect4: [4]f32 = .{ sx0, sy0, sw, sh_h };
    const rad: f32 = if (st.corner_circular) -st.radius else st.radius;
    // What the box and its subtree emit, for `Style.scale`.
    const start = out.items.len;

    if (visible.w > 0 and visible.h > 0) {
        if (st.shadow) |sh| paintShadow(c, out, sh, r, rad, opacity, clip4);
        for (st.shadows) |sh| paintShadow(c, out, sh, r, rad, opacity, clip4);
        // Glass takes the background's place.
        const fill: ?types.Color = if (st.glass != null) null else st.background;
        if (st.glass) |g| push(c, out, glass.instance(glass.material(g, rect4[2], rect4[3], c.theme.dark, c.scale), rect4, st.radius, clip4, opacity));
        if (fill != null or st.border != null) push(c, out, .{
            .rect = rect4,
            .color = metal.color4((fill orelse types.Color.transparent).alpha(opacity)),
            .border_color = metal.color4((st.border orelse types.Color.transparent).alpha(opacity)),
            .border_width = if (st.border != null) st.border_width else 0,
            .radius = rad,
            // A quad's uv is free: its x marks a dashed border.
            .uv = .{ if (st.border_dashed) 1 else 0, 0, 0, 0 },
            .clip = clip4,
        });
        switch (n.content) {
            .text => |*t| paintText(c, out, index, &n, t, clip4, opacity, selectable, moving),
            .icon => |ic| if (c.text.atlas.symbol(ic.name, ic.size, @backingInt(ic.weight))) |sp| {
                // Centered in its box, which may be larger (a fixed frame).
                const inner = r.inset(st.padding);
                const cx = inner.x + (inner.w - (sp.w + 2 * sp.x)) / 2;
                const cy = inner.y + (inner.h - (sp.h + 2 * sp.y)) / 2;
                const x = (if (moving) cx else snap(cx, c.scale)) + sp.x;
                const y = (if (moving) cy else snap(cy, c.scale)) + sp.y;
                push(c, out, .{
                    .rect = .{ x, y, sp.w, sp.h },
                    .color = metal.color4(ic.color.alpha(opacity)),
                    .uv = sp.uv,
                    .kind = metal.Kind.text,
                    .clip = clip4,
                });
            },
            .image => |im| if (c.text.images.get(im.key, im.bytes, @intFromFloat(@max(1, @ceil(@max(rect4[2], rect4[3]) * c.scale))))) |e| push(c, out, .{
                .rect = if (im.snap) .{ snap(r.x, c.scale), snap(r.y, c.scale), r.w, r.h } else rect4,
                .color = .{ 1, 1, 1, im.opacity * opacity },
                // A tint (alpha above 0) fills the picture's shape instead.
                .border_color = if (im.tint) |t| metal.color4(t) else .{ 0, 0, 0, 0 },
                .uv = e.uv,
                .radius = rad,
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
            .hole => |radius| push(c, out, .{ .rect = rect4, .color = .{ 0, 0, 0, 1 }, .radius = radius, .kind = metal.Kind.hole, .clip = clip4 }),
            .canvas => |cv| paintCanvas(c, out, cv, r, visible, opacity),
            .none => {},
        }
    }
    if (n.interactive and visible.w > 0 and visible.h > 0) c.addHit(n.id, index, visible, false);

    var child_clip = clip;
    if (st.clip or st.scroll_x) child_clip = visible;
    if (st.scroll) {
        child_clip = visible;
        c.addHit(n.id, index, visible, true);
    }
    const first = out.items.len;
    var child = n.first_child;
    const inner_scrolled = scrolled + if (st.scroll) c.scroll.get(n.id) orelse 0 else 0;
    while (child != none) : (child = c.node(child).next) paintNode(c, out, child, child_clip, opacity, selectable, inner_scrolled);
    if ((st.clip or st.scroll or st.scroll_x) and st.radius > 0) roundClip(out.items[first..], r, visible, st.radius);

    if (st.scroll and st.scrollbar == .overlay) {
        paintScrollbar(c, out, n, visible, opacity);
    } else if (st.scroll or st.scroll_x) {
        @import("scroll.zig").paintScrollbars(c, out, n, visible, opacity);
    }
    if (st.scale != 1) scaleItems(out.items[start..], r, @max(st.scale, 0), st.scale_anchor, clip4);
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

    if (st.spin != 0) c.time_driven = .fast;
    const pulse = if (c.reduce_motion) null else st.pulse;
    if (pulse != null and c.time_driven == .none) c.time_driven = .slow;
    if (st.rotation != 0 or st.spin != 0 or pulse != null) {
        const px = r.x + r.w * 0.5;
        const py = r.y + r.h * 0.5;
        const p4: [4]f32 = if (pulse) |p| .{ p.period, p.scale_amp, p.alpha_low, 0 } else .{ 0, 0, 1, 0 };
        for (out.items[start..]) |*inst| {
            if (inst.kind == metal.Kind.layer_begin or inst.kind == metal.Kind.layer_end) continue;
            if (inst.xf[0] == 0 and inst.xf[1] == 0 and inst.xf[2] == 0 and inst.xf[3] == 0 and inst.pulse[0] == 0 and inst.pulse[1] == 0) {
                inst.xf = .{ st.rotation, st.spin, px, py };
                inst.pulse = p4;
            }
        }
    }
    if (st.motion_blur and c.animating and !c.reduce_motion) {
        if (c.prev_rects.get(n.id)) |prev| {
            const vx = r.x - prev.x;
            const vy = r.y - prev.y;
            if (@sqrt(vx * vx + vy * vy) > 2) {
                for (out.items[start..]) |*inst| {
                    if (inst.kind == metal.Kind.quad or inst.kind == metal.Kind.text or inst.kind == metal.Kind.image) {
                        inst.vel = .{ vx * 0.5, vy * 0.5, 0, 0 };
                    }
                }
            }
        }
    }
}

/// Maps instances around the anchor of `box` (fractions of it) by `s`,
/// still within `outer`, the clip the box was given. Glass keeps its
/// bezel and rim (`uv`, in points) as they are.
fn scaleItems(items: []metal.Instance, box: types.Rect, s: f32, anchor: types.Point, outer: [4]f32) void {
    const ax = box.x + box.w * anchor.x;
    const ay = box.y + box.h * anchor.y;
    for (items) |*i| {
        i.rect = .{ ax + (i.rect[0] - ax) * s, ay + (i.rect[1] - ay) * s, i.rect[2] * s, i.rect[3] * s };
        if (i.xf[0] != 0 or i.xf[1] != 0 or i.pulse[0] > 0) {
            i.xf[2] = ax + (i.xf[2] - ax) * s;
            i.xf[3] = ay + (i.xf[3] - ay) * s;
        }
        i.clip = .{
            @max(outer[0], ax + (i.clip[0] - ax) * s), @max(outer[1], ay + (i.clip[1] - ay) * s),
            @min(outer[2], ax + (i.clip[2] - ax) * s), @min(outer[3], ay + (i.clip[3] - ay) * s),
        };
        i.radius *= s;
        // A border's width, a shadow's blur, a pane's backdrop blur.
        i.border_width *= s;
        if (i.kind == metal.Kind.shadow_out) i.uv = .{ i.uv[0] * s, i.uv[1] * s, 0, 0 };
        const round = metal.clipCorners(i.clip_round);
        if (round.corners != 0) i.clip_round = metal.clipRound(round.radius * s, round.corners);
    }
}

fn paintText(c: *Context, out: *std.ArrayList(metal.Instance), index: u32, n: *const ctx_mod.Node, t: *const ctx_mod.Content.Text, clip4: [4]f32, opacity: f32, selectable: bool, moving: bool) void {
    const sel: ?Sel = if (selectable) .{ .id = n.id, .index = index, .x0 = n.rect.x, .x1 = n.rect.x + n.rect.w } else null;
    const inner = n.rect.inset(n.style.padding);
    const inner_right = n.rect.x + n.rect.w;
    const f = c.text.font(t.style);
    const lh = c.text.lineHeight(t.style);
    if (t.style.wrap) {
        for (t.lines, 0..) |l, i| {
            const y = inner.y + lh * @as(f32, @floatFromInt(i));
            textRun(c, out, t.*, l.start, l.end, inner.x, y, f, lh, clip4, opacity, sel, inner_right, moving);
        }
    } else if (t.style.truncate != .none) {
        truncated(c, out, t.*, inner, inner_right, f, lh, clip4, opacity, sel, moving);
    } else {
        textRun(c, out, t.*, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel, inner_right, moving);
    }
}

fn paintShadow(c: *Context, out: *std.ArrayList(metal.Instance), sh: types.Shadow, r: types.Rect, radius: f32, opacity: f32, clip4: [4]f32) void {
    const s = sh.spread;
    push(c, out, .{
        .rect = .{ r.x + sh.x - s, r.y + sh.y - s, @max(0, r.w + 2 * s), @max(0, r.h + 2 * s) },
        .color = metal.color4(sh.color.alpha(opacity)),
        // A knocked out shadow is cut by the box, where it is from the shadow.
        .uv = if (sh.knockout) .{ -sh.x, -sh.y, 0, 0 } else .{ 0, 0, 0, 0 },
        .radius = @max(0, radius + s),
        // CSS's blur radius is twice the Gaussian's standard deviation.
        .border_width = sh.blur / 2,
        .kind = if (sh.knockout) metal.Kind.shadow_out else metal.Kind.shadow,
        .clip = clip4,
    });
}

/// Where a truncated line ends, and over how many points it fades out
/// before that (0: cut there).
const Limit = struct { end: f32, fade: f32 = 0 };

/// A line that may be longer than its box: whole if it fits; else cut at a
/// glyph before an ellipsis, or drawn to the box's end, fading out.
fn truncated(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, inner: types.Rect, inner_right: f32, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel, moving: bool) void {
    const lay = t.cut_lay orelse c.text.layout(t.str, t.style);
    if (lay.width <= inner.w + 0.5) return textRun(c, out, t, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel, inner_right, moving);
    if (t.style.truncate == .fade) {
        const limit: Limit = .{ .end = inner.x + inner.w, .fade = @min(t.style.fade_width, inner.w / 2) };
        return textRunLimit(c, out, t, 0, t.str.len, inner.x, inner.y, f, lh, clip4, opacity, sel, limit, inner_right, moving);
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
    if (cut > 0) textRunLimit(c, out, t, 0, cut, inner.x, inner.y, f, lh, clip4, opacity, sel, limit, inner_right, moving);
    var dots = t;
    dots.str = ellipsis;
    dots.spans = &.{};
    textRunLimit(c, out, dots, 0, ellipsis.len, inner.x + cut_x, inner.y, f, lh, clip4, opacity, null, limit, inner_right, moving);
}

/// Draws bytes [start, end) of `t`, each glyph in its span's color.
/// A selectable text: its id, its place in the tree, and the box's
/// horizontal extent.
const Sel = struct { id: u64, index: u32, x0: f32, x1: f32 };

fn textRun(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, start: usize, end: usize, x: f32, y: f32, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel, inner_right: f32, moving: bool) void {
    textRunLimit(c, out, t, start, end, x, y, f, lh, clip4, opacity, sel, null, inner_right, moving);
}

fn textRunLimit(c: *Context, out: *std.ArrayList(metal.Instance), t: ctx_mod.Content.Text, start: usize, end: usize, x: f32, y: f32, f: text_mod.Font, lh: f32, clip4: [4]f32, opacity: f32, sel: ?Sel, limit: ?Limit, inner_right: f32, moving: bool) void {
    const style = t.style;
    // Cull lines wholly above or below the clip before shaping them; a
    // selectable one still counts for where the pointer is.
    if (y > clip4[3] or y + lh < clip4[1] or x > clip4[2]) {
        if (sel) |s| if (y + lh <= c.input.mouse.y) {
            c.selection.below = .{ .id = s.id, .at = end };
            const count: u32 = @intCast(c.selection.next_order.count());
            if (c.selection.next_order.getOrPut(c.gpa, s.id) catch null) |g| if (!g.found_existing) {
                g.value_ptr.* = count;
            };
        };
        return;
    }
    const styled = t.spans.len > 0 and rich.styled(t.spans);
    const lay = t.cut_lay orelse if (styled) rich.layout(c.text, t.str[start..end], style, t.spans, start) else c.text.layout(t.str[start..end], style);
    if (lay.glyphs.len == 0 or x + lay.width < clip4[0]) return;
    const scale = c.scale;
    // The line's extra height (its leading) goes half above, half below.
    const raw_baseline = y + (lh - f.lineHeight()) / 2 + f.leading / 2 + f.ascent;
    const baseline = if (moving) raw_baseline else snap(raw_baseline, scale);
    const base = metal.color4(t.color.alpha(opacity));
    if (sel) |s| @import("selection.zig").line(c, out, s.id, s.index, t.str, start, end, lay, x, y, lh, s.x0, s.x1, clip4);
    if (t.spans.len > 0) decorations(c, out, &t, lay, start, end, x, baseline, f, clip4, opacity);
    var span_i: usize = 0;
    for (lay.glyphs) |g| {
        const pen = (x + g.x) * scale;
        if (pen / scale > clip4[2]) break;
        if (limit) |l| if (pen / scale >= l.end) break;
        const positions: f32 = if (native_windows) @floatFromInt(c.text.positions(g)) else text_mod.subpixel_bins;
        const quantized = if (native_windows) @round(pen * positions) / positions else pen;
        const px = @floor(quantized);
        const phase = (quantized - px) * text_mod.subpixel_bins;
        const bin: u8 = @intFromFloat(@min(text_mod.subpixel_bins - 1, if (native_windows) @round(phase) else @floor(phase)));
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
        if (style.fade) |fd| {
            color[3] *= std.math.clamp((inner_right - fd.clear - (x + g.x)) / @max(fd.ramp, 0.001), 0, 1);
            if (color[3] <= 0) continue;
        }
        // Lighter text is drawn with thicker strokes, as macOS draws it.
        const sp = c.text.glyph(g, bin, @TypeOf(c.text.*).dilationFor(tone.r, tone.g, tone.b)) orelse continue;
        var uv = sp.uv;
        if (!text_mod.portable and 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2] < 0.5) {
            const du = uv[2] - uv[0];
            uv[0] += du;
            uv[2] += du;
        }
        push(c, out, .{
            .rect = .{ px / scale + sp.x, baseline - g.y + sp.y, sp.w, sp.h },
            .color = color,
            .uv = uv,
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

/// What spans draw besides their glyphs: backgrounds (inline code, marks)
/// behind the text, underlines (links) and lines through.
fn decorations(c: *Context, out: *std.ArrayList(metal.Instance), t: *const ctx_mod.Content.Text, lay: text_mod.Layout, start: usize, end: usize, x: f32, baseline: f32, f: text_mod.Font, clip4: [4]f32, opacity: f32) void {
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
            .rect = .{ x0 - 3, baseline - f.ascent * 0.92 - 2, x1 - x0 + 6, (f.ascent + f.descent) * 0.92 + 4 },
            .color = metal.color4(bg.alpha(opacity)),
            .radius = 4,
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

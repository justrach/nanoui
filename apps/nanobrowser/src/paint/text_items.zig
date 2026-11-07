//! A box's lines of text as things to draw: glyphs with their shadows under them,
//! and their decorations as fills.
const std = @import("std");
const dom = @import("../dom.zig");
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const display = @import("display.zig");
const boxes = @import("boxes.zig");
const Box = box.Box;
const Rect = box.Rect;
const Builder = display.Builder;
const At = display.At;
const Item = display.Item;
const Kind = display.Kind;

pub fn runs(b: *Builder, x: *const Box, at: At, list: *std.ArrayList(Item)) !void {
    for (x.runs) |*run| {
        const st = run.style;
        const node = textOwner(run, x);
        const line: Rect = .{ .x = run.x + at.tx, .y = run.line_top + at.ty, .w = run.w, .h = run.line_h };
        if (st.visibility != .visible) continue;
        if (st.pointer_events) try b.add(list, .{ .kind = .hit, .rect = line, .clip = at.clip, .xform = at.xform, .node = node });
        if (run.font.size <= 0) continue;
        const metrics = b.m.metrics(b.m.ctx, run.font);
        try decorations(b, run, metrics, at, list);
        if (run.word_spacing == 0) {
            try text(b, x, run, run.text, run.x + at.tx, run.baseline + at.ty, metrics, at, list);
            continue;
        }
        // Justified or spaced words, each put where it goes.
        var pen = run.x + at.tx;
        const space = b.m.width(b.m.ctx, " ", run.font) + run.word_spacing;
        var words = std.mem.splitScalar(u8, run.text, ' ');
        while (words.next()) |w| {
            if (w.len > 0) try text(b, x, run, w, pen, run.baseline + at.ty, metrics, at, list);
            pen += b.m.width(b.m.ctx, w, run.font) + space;
        }
    }
}

fn text(b: *Builder, x: *const Box, run: *const box.TextRun, s: []const u8, tx: f32, baseline: f32, metrics: box.Metrics, at: At, list: *std.ArrayList(Item)) !void {
    const st = run.style;
    const top = baseline - metrics.ascent - metrics.gap / 2;
    const rect: Rect = .{ .x = tx, .y = top, .w = run.w, .h = metrics.ascent + metrics.descent + metrics.gap };
    const fill = st.text_fill orelse st.color;
    // What shows through see-through glyphs.
    const gradient = if (fill.a < 0.01) at.text_bg else null;
    _ = x;
    // The shadows under it, the first on top; a blurred one as faint copies around.
    var i = st.text_shadows.len;
    while (i > 0) {
        i -= 1;
        try boxes.textShadow(b, st.text_shadows[i], s, run, rect, baseline, at, list);
    }
    try b.add(list, .{
        .kind = .{ .text = .{ .str = s, .font = run.font, .color = fill, .spacing = run.spacing, .baseline = baseline, .gradient = gradient } },
        .rect = rect,
        .clip = at.clip,
        .xform = at.xform,
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
            try bb.add(l, .{ .kind = .{ .fill = .{ .color = c } }, .rect = .{ .x = r.x + aa.tx, .y = y, .w = r.w, .h = h }, .clip = aa.clip, .xform = aa.xform, .opacity = aa.opacity });
        }
    }.add;
    if (st.underline) try line(b, list, run, base + m.descent * 0.35, t, color, at);
    if (st.line_through) try line(b, list, run, base - m.ascent * 0.32, t, color, at);
    if (st.overline) try line(b, list, run, base - m.ascent, t, color, at);
}

fn textOwner(run: *const box.TextRun, x: *const Box) ?*dom.Node {
    if (run.node) |n| return n.parentElement() orelse x.node;
    return x.node;
}

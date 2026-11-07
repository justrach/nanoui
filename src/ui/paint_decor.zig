//! Paint: what text spans draw besides their glyphs.
const std = @import("std");
const metal = @import("gpu.zig");
const text_mod = @import("text.zig");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

/// The x of the first glyph at or after byte `at` of the line, else its end.
fn xAt(lay: text_mod.Layout, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

pub const LineBox = struct { top: f32, h: f32, baseline: f32 };

/// What spans draw besides their glyphs: backgrounds (inline code, marks)
/// behind the text, underlines (links) and lines through.
pub fn decorations(c: *Context, out: *std.ArrayList(metal.Instance), t: *const ctx_mod.Content.Text, lay: text_mod.Layout, start: usize, end: usize, x: f32, line: LineBox, f: text_mod.Font, clip4: [4]f32, opacity: f32) void {
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
        if (sp.background) |bg| out.append(c.gpa, .{
            .rect = if (t.style.span_box) |box|
                .{ x0 - box.pad_x, line.top + box.inset_y, x1 - x0 + 2 * box.pad_x, line.h - 2 * box.inset_y }
            else
                .{ x0 - 3, baseline - f.ascent * 0.92 - 2, x1 - x0 + 6, (f.ascent + f.descent) * 0.92 + 4 },
            .color = metal.color4(bg.alpha(opacity)),
            .radius = if (t.style.span_box) |box| box.radius else 4,
            .clip = clip4,
        }) catch {};
        if (sp.underline) out.append(c.gpa, .{
            .rect = .{ x0, baseline + 2, x1 - x0, 1 },
            .color = metal.color4(color.alpha(0.6 * opacity)),
            .clip = clip4,
        }) catch {};
        if (sp.strike) out.append(c.gpa, .{
            .rect = .{ x0, baseline - f.ascent * 0.32, x1 - x0, 1 },
            .color = metal.color4(color.alpha(opacity)),
            .clip = clip4,
        }) catch {};
    }
}

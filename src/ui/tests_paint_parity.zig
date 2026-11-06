//! Render-instance regressions for the opt-in text placement rules.
const std = @import("std");
const ui = @import("ui.zig");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const text = @import("text.zig");
const testing = std.testing;

const Scene = struct {
    // Paint runs after view returns; span storage must outlive that call.
    const spans = [_]types.Span{.{ .start = 0, .end = 2, .background = .hex(0xff0000), .underline = true }};
    rule: types.BaselineRule = .font_line,
    snapping: types.GlyphSnap = .nearest,
    span_box: ?types.SpanBox = null,
    baseline: ?f32 = null,
    x: f32 = 12.21,
    fn style(s: *const Scene) types.TextStyle {
        return .{ .size = 13, .line_height = 40, .color = .hex(0x00ff00), .span_box = s.span_box };
    }
    fn view(s: *Scene, c: *ui.Context) void {
        c.text.baseline_rule = s.rule;
        c.text.glyph_snap = s.snapping;
        const f = c.text.font(s.style());
        const natural = if (s.rule == .glyph_box)
            (40 - f.ascent - f.descent) / 2 + f.ascent
        else
            (40 - f.lineHeight()) / 2 + f.leading / 2 + f.ascent;
        const box = ui.div(c).size(100, 40).offset(s.x, if (s.baseline) |b| b - natural else 10);
        defer box.end();
        ui.richText(c, "Ig", &spans, s.style());
    }
};

fn underline(t: *ui.Tester) !gpu.Instance {
    for (t.instances.items) |instance| {
        if (instance.kind == gpu.Kind.quad and instance.color[1] == 1 and instance.rect[3] == 1) return instance;
    }
    return error.NoUnderline;
}

fn background(t: *ui.Tester) !gpu.Instance {
    for (t.instances.items) |instance| {
        if (instance.kind == gpu.Kind.quad and instance.color[0] == 1 and instance.color[1] == 0) return instance;
    }
    return error.NoSpanBackground;
}

test "glyph snapping chooses half ties toward zero without changing the default" {
    var s: Scene = .{ .baseline = 31.25, .snapping = .half_toward_zero };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .scale = 2 });
    defer t.deinit();
    try testing.expectApproxEqAbs(@as(f32, 33), (try underline(&t)).rect[1], 0.0001);
    s.snapping = .nearest;
    t.frame();
    try testing.expectApproxEqAbs(@as(f32, 33.5), (try underline(&t)).rect[1], 0.0001);
}

test "glyph box baseline centers ascent and descent in an explicit line height" {
    var s: Scene = .{ .rule = .glyph_box, .snapping = .half_toward_zero };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .scale = 2 });
    defer t.deinit();
    const f = t.text.font(s.style());
    const top = t.findText("Ig").?.y;
    const raw = top + (40 - f.ascent - f.descent) / 2 + f.ascent;
    const expected = @ceil(raw * 2 - 0.5) / 2;
    try testing.expectApproxEqAbs(expected + 2, (try underline(&t)).rect[1], 0.0001);
}

test "span boxes use the line's edges while the default keeps its glyph fitted box" {
    var s: Scene = .{ .span_box = .{ .pad_x = 2, .inset_y = 3, .radius = 4.5 } };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{});
    defer t.deinit();
    const line = t.findText("Ig").?;
    const bg = try background(&t);
    const width = t.text.layout("Ig", s.style()).width;
    try testing.expectApproxEqAbs(line.x - 2, bg.rect[0], 0.0001);
    try testing.expectApproxEqAbs(line.y + 3, bg.rect[1], 0.0001);
    try testing.expectApproxEqAbs(width + 4, bg.rect[2], 0.0001);
    try testing.expectEqual(@as(f32, 34), bg.rect[3]);
    try testing.expectEqual(@as(f32, 4.5), bg.radius);
    // Tester's text-based hover uses the laid-out text, not the span's padding.
    try t.hoverText("Ig");
    try testing.expectEqual(line.x + line.w / 2, t.ctx.input.mouse.x);
    s.span_box = null;
    t.frame();
    const old = try background(&t);
    const f = t.text.font(s.style());
    const baseline = (try underline(&t)).rect[1] - 2;
    try testing.expectApproxEqAbs(baseline - f.ascent * 0.92 - 2, old.rect[1], 0.0001);
    try testing.expectApproxEqAbs((f.ascent + f.descent) * 0.92 + 4, old.rect[3], 0.0001);
    try testing.expectEqual(@as(f32, 4), old.radius);
}

test "half-toward-zero text chooses the matching glyph atlas phase" {
    var s: Scene = .{ .snapping = .half_toward_zero };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&s, Scene.view), .{ .scale = 2 });
    defer t.deinit();
    const g = t.text.layout("Ig", s.style()).glyphs[0];
    const native_windows = @import("dwrite.zig").enabled;
    const positions: f32 = if (native_windows) @floatFromInt(t.text.positions(g)) else text.subpixel_bins;
    // Force a phase above the midpoint so nearest differs from flooring.
    s.x = (24 + 0.75 / positions) / 2 - g.x;
    t.frame();
    const quantized = 24 + 1 / positions;
    const px = @floor(quantized);
    const phase = (quantized - px) * text.subpixel_bins;
    const bin: u8 = @intFromFloat(@min(text.subpixel_bins - 1, if (native_windows) @round(phase) else @floor(phase + 0.001)));
    const sprite = t.text.glyph(g, bin, @TypeOf(t.text).dilationFor(0, 1, 0)) orelse return error.NoGlyph;
    for (t.instances.items) |instance| {
        if (instance.kind == gpu.Kind.text) {
            try testing.expectEqual(sprite.uv, instance.uv);
            try testing.expectApproxEqAbs(px / 2 + sprite.x, instance.rect[0], 0.0001);
            return;
        }
    }
    return error.NoPaintedGlyph;
}

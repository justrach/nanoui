//! Windows coverage/compositing regressions. Direct2D draws the same
//! glyph positions independently; this change does not replace shaping.
const std = @import("std");
const ui = @import("ui.zig");
const gpa = std.testing.allocator;

const Sample = struct {
    const words = "Task Manager 1006.3 MB";
    style: ui.TextStyle = .{ .size = 13.5 },
    color: ui.Color = .white,
    fn view(self: *Sample, c: *ui.Context) void {
        ui.text(c, words, .{ .size = self.style.size, .weight = self.style.weight, .color = self.color });
    }
    fn empty(_: *Sample, _: *ui.Context) void {}
};

fn init(t: *ui.Tester, sample: *Sample, scale: f32, background: ui.Color) !void {
    var theme = ui.Theme.light;
    theme.font = "Segoe UI";
    theme.background = background;
    try t.init(gpa, .init(sample, Sample.view), .{ .width = 480, .height = 60, .scale = scale, .theme = theme });
}

fn compare(t: *ui.Tester, sample: Sample) !void {
    const layout = t.text.layout(Sample.words, sample.style);
    const f = t.text.font(sample.style);
    const rf = t.text.run_fonts.items[f.id];
    const native = &t.text.atlas.native;
    try std.testing.expectEqual(@as(usize, 0), native.failures);
    const face = native.fonts.get(.{ .face = @intFromPtr(rf.font), .simulations = 0 }) orelse return error.MissingNativeFace;
    var indices: [Sample.words.len]u16 = undefined;
    var advances: [Sample.words.len]f32 = undefined;
    for (layout.glyphs, 0..) |glyph, i| {
        indices[i] = glyph.glyph;
        const next = if (i + 1 < layout.glyphs.len) layout.glyphs[i + 1].x else layout.width;
        advances[i] = (next - glyph.x) * t.scale;
    }
    const run: Run = .{ .face = @ptrCast(face), .size = sample.style.size * t.scale, .count = @intCast(layout.glyphs.len), .indices = &indices, .advances = &advances };
    const pixels = try t.render(gpa);
    defer pixels.deinit(gpa);
    const bg = t.theme.background;
    const fg = sample.color;
    const expected = try renderReference(run, pixels.width, pixels.height, @round((f.leading / 2 + f.ascent) * t.scale), .{ fg.r, fg.g, fg.b, fg.a }, .{ bg.r, bg.g, bg.b, bg.a }, if (native.aliased) 3 else if (native.cleartype) 1 else 2, @ptrCast(native.params.?));
    defer gpa.free(expected);
    for (0..pixels.width * pixels.height) |i| for (0..3) |channel| {
        const at = i * 4 + channel;
        const delta = @abs(@as(i32, pixels.bytes[at]) - @as(i32, expected[at]));
        if (delta > 3) {
            std.debug.print("Direct2D mismatch: {d}px {s}, scale {d}, pixel {d}, channel {d}: {d} != {d}\n", .{ sample.style.size, @tagName(sample.style.weight), t.scale, i, channel, pixels.bytes[at], expected[at] });
            return error.FontPixelsDiffer;
        }
    };
}

test "Windows final color pixels match Direct2D at six sizes and five DPI scales" {
    for ([_]f32{ 1, 1.25, 1.5, 1.75, 2 }) |scale| for ([_]bool{ false, true }) |dark| {
        var sample: Sample = .{ .color = if (dark) .hex(0xf0f0f0) else .hex(0x1a1a1a) };
        var t: ui.Tester = undefined;
        try init(&t, &sample, scale, if (dark) .hex(0x202020) else .white);
        defer t.deinit();
        for ([_]f32{ 12, 13.5, 14, 16, 20, 26 }) |size| for ([_]ui.Weight{ .regular, .semibold }) |weight| {
            sample.style = .{ .size = size, .weight = weight };
            for (0..3) |_| t.frame();
            try compare(&t, sample);
        };
    };
}

test "Windows grayscale and aliased coverage match native rendering" {
    for ([_]bool{ false, true }) |aliased| {
        var sample: Sample = .{ .color = .hex(0x2378bb) };
        var t: ui.Tester = undefined;
        try init(&t, &sample, 1.25, .white);
        defer t.deinit();
        if (t.text.atlas.native.aliased and !aliased) continue;
        t.text.atlas.native.cleartype = false;
        t.text.atlas.native.aliased = aliased;
        if (aliased) t.text.atlas.native.blending = .{};
        t.text.atlas.phase_counts.clearRetainingCapacity();
        t.text.atlas.reset();
        t.frame();
        try compare(&t, sample);
    }
}

fn hashGlyphs(t: *ui.Tester, weight: ui.Weight, bin: u8) !u64 {
    const layout = t.text.layout("mMeEgGSs0123456789", .{ .size = 13.5, .weight = weight });
    var hash = std.hash.Wyhash.init(0);
    for (layout.glyphs) |glyph| {
        const sp = t.text.glyph(glyph, bin, 0) orelse return error.MissingBitmap;
        const a = &t.text.atlas;
        const side: f32 = @floatFromInt(a.size);
        const x: usize = @intFromFloat(@round(sp.uv[0] * side));
        const y: usize = @intFromFloat(@round(sp.uv[1] * side));
        const w: usize = @intFromFloat(@round((sp.uv[2] - sp.uv[0]) * side));
        const h: usize = @intFromFloat(@round((sp.uv[3] - sp.uv[1]) * side));
        for (0..h) |row| hash.update(a.pixels[(y + row) * a.size + x ..][0..w]);
    }
    try std.testing.expectEqual(@as(usize, 0), t.text.atlas.native.failures);
    return hash.final();
}

test "Windows glyph cache retains phases, weights and DPI transitions" {
    var sample: Sample = .{};
    var t: ui.Tester = undefined;
    try init(&t, &sample, 1, .black);
    defer t.deinit();
    const regular = try hashGlyphs(&t, .regular, 0);
    if (!t.text.atlas.native.aliased) {
        for ([_]u8{ 6, 12, 18 }) |bin| try std.testing.expect(regular != try hashGlyphs(&t, .regular, bin));
    }
    try std.testing.expect(regular != try hashGlyphs(&t, .semibold, 0));
    t.text.setScale(1.5);
    _ = try hashGlyphs(&t, .regular, 0);
    t.text.setScale(1);
    try std.testing.expectEqual(regular, try hashGlyphs(&t, .regular, 0));
    const generation = t.text.atlas.generation;
    try std.testing.expectEqual(regular, try hashGlyphs(&t, .regular, 0));
    const space = t.text.layout(" ", .{ .size = 13.5 });
    try std.testing.expect(t.text.glyph(space.glyphs[0], 0, 0) == null);
    try std.testing.expectEqual(generation, t.text.atlas.generation);
}

test "Windows transparent text retains grayscale premultiplied alpha" {
    var sample: Sample = .{};
    var t: ui.Tester = undefined;
    try init(&t, &sample, 1, .{ .r = 0, .g = 0, .b = 0, .a = 0 });
    defer t.deinit();
    const pixels = try t.render(gpa);
    defer pixels.deinit(gpa);
    var partial = false;
    for (0..pixels.width * pixels.height) |i| {
        const p = pixels.bytes[i * 4 ..][0..4];
        try std.testing.expect(p[0] == p[1] and p[1] == p[2] and p[2] == p[3]);
        partial = partial or (p[3] > 0 and p[3] < 255);
    }
    try std.testing.expect(partial);
}

test "Windows falls back to portable coverage when DirectWrite is unavailable" {
    var sample: Sample = .{};
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&sample, Sample.empty), .{ .scale = 1 });
    defer t.deinit();
    t.text.atlas.native.unavailable = true;
    t.view = .init(&sample, Sample.view);
    t.frame();
    const pixels = try t.render(gpa);
    defer pixels.deinit(gpa);
    try std.testing.expect(t.text.atlas.native.factory == null and t.text.atlas.native.failures > 0);
    var ink: usize = 0;
    for (t.text.atlas.pixels) |p| ink += @intFromBool(p > 0);
    try std.testing.expect(ink > 0);
}

// Independent Direct2D software renderer. No window, atlas sampling or
// copy of the implementation's gamma/contrast equations is used here.
const Com = extern struct {
    vtable: [*]const *const anyopaque,
    fn method(self: *Com, comptime i: usize, comptime F: type) F {
        return @ptrCast(@alignCast(self.vtable[i]));
    }
    fn release(self: *Com) void {
        _ = self.method(2, *const fn (*Com) callconv(.winapi) u32)(self);
    }
};
const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const factory_iid: Guid = .{ .a = 0x06152247, .b = 0x6f50, .c = 0x465a, .d = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 } };
extern "d2d1" fn D2D1CreateFactory(u32, *const Guid, ?*const anyopaque, *?*Com) callconv(.winapi) i32;
extern "gdi32" fn CreateCompatibleDC(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteDC(*anyopaque) callconv(.winapi) i32;
extern "gdi32" fn CreateDIBSection(?*anyopaque, *const Header, u32, *?[*]u8, ?*anyopaque, u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SelectObject(*anyopaque, *anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(*anyopaque) callconv(.winapi) i32;
const Header = extern struct {
    size: u32 = 40,
    width: i32,
    height: i32,
    planes: u16 = 1,
    bpp: u16 = 32,
    compression: u32 = 0,
    bytes: u32 = 0,
    xppm: i32 = 0,
    yppm: i32 = 0,
    used: u32 = 0,
    important: u32 = 0,
};
const Props = extern struct { kind: u32 = 1, format: u32 = 87, alpha: u32 = 3, dpi_x: f32 = 96, dpi_y: f32 = 96, usage: u32 = 0, feature: u32 = 0 };
const Rect = extern struct { left: i32 = 0, top: i32 = 0, right: i32, bottom: i32 };
const Point = extern struct { x: f32, y: f32 };
pub const Run = extern struct {
    face: *Com,
    size: f32,
    count: u32,
    indices: [*]const u16,
    advances: [*]const f32,
    offsets: ?*const anyopaque = null,
    sideways: i32 = 0,
    bidi: u32 = 0,
};

fn renderReference(run: Run, width: usize, height: usize, baseline: f32, fg: [4]f32, bg: [4]f32, antialias: u32, params: *Com) ![]u8 {
    const dc = CreateCompatibleDC(null) orelse return error.ReferenceDC;
    defer _ = DeleteDC(dc);
    var bits: ?[*]u8 = null;
    const bm = CreateDIBSection(dc, &.{ .width = @intCast(width), .height = -@as(i32, @intCast(height)) }, 0, &bits, null, 0) orelse return error.ReferenceBitmap;
    defer _ = DeleteObject(bm);
    const old = SelectObject(dc, bm) orelse return error.ReferenceSelect;
    defer _ = SelectObject(dc, old);
    var factory: ?*Com = null;
    if (D2D1CreateFactory(0, &factory_iid, null, &factory) < 0) return error.ReferenceFactory;
    const f = factory orelse return error.ReferenceFactory;
    defer f.release();
    var target: ?*Com = null;
    if (f.method(16, *const fn (*Com, *const Props, *?*Com) callconv(.winapi) i32)(f, &.{}, &target) < 0) return error.ReferenceTarget;
    const t = target orelse return error.ReferenceTarget;
    defer t.release();
    if (t.method(57, *const fn (*Com, *anyopaque, *const Rect) callconv(.winapi) i32)(t, dc, &.{ .right = @intCast(width), .bottom = @intCast(height) }) < 0) return error.ReferenceBind;
    var brush: ?*Com = null;
    if (t.method(8, *const fn (*Com, *const [4]f32, ?*const anyopaque, *?*Com) callconv(.winapi) i32)(t, &fg, null, &brush) < 0) return error.ReferenceBrush;
    const b = brush orelse return error.ReferenceBrush;
    defer b.release();
    t.method(34, *const fn (*Com, u32) callconv(.winapi) void)(t, antialias);
    t.method(36, *const fn (*Com, *Com) callconv(.winapi) void)(t, params);
    t.method(48, *const fn (*Com) callconv(.winapi) void)(t);
    t.method(47, *const fn (*Com, *const [4]f32) callconv(.winapi) void)(t, &bg);
    t.method(29, *const fn (*Com, Point, *const Run, *Com, u32) callconv(.winapi) void)(t, .{ .x = 0, .y = baseline }, &run, b, 0);
    if (t.method(49, *const fn (*Com, ?*u64, ?*u64) callconv(.winapi) i32)(t, null, null) < 0) return error.ReferenceDraw;
    return gpa.dupe(u8, (bits orelse return error.ReferenceBitmap)[0 .. width * height * 4]);
}

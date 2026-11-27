//! Characters no font has, handed to the host whole (`glyph_fallback.zig`).
const std = @import("std");
const testing = std.testing;
const tt = @import("text_tt.zig");
const fallback = @import("glyph_fallback.zig");
const testfont = @import("tt/testfont.zig");
const text_mod = @import("text.zig");

/// A host whose glyphs are each 9 points wide, 6 × 8 pixels, baseline 6.
const Fake = struct {
    measured: usize = 0,

    fn measure(ctx: ?*anyopaque, _: []const u8, _: f32) f32 {
        const f: *Fake = @ptrCast(@alignCast(ctx.?));
        f.measured += 1;
        return 9;
    }
    fn box(_: ?*anyopaque, _: []const u8, _: f32) ?fallback.Raster {
        return .{ .width = 6, .height = 8, .ascent = 6 };
    }
    /// Half-covered red, unpremultiplied as a browser canvas gives it.
    fn draw(_: ?*anyopaque, _: []const u8, _: f32, _: fallback.Raster, rgba: []u8) bool {
        var i: usize = 0;
        while (i < rgba.len) : (i += 4) @memcpy(rgba[i..][0..4], &[_]u8{ 255, 0, 0, 128 });
        return true;
    }
    fn hooks(f: *Fake) fallback.Hooks {
        return .{ .ctx = f, .measure = measure, .box = box, .draw = draw };
    }
};

test "a cluster no font has is shaped as one host glyph" {
    const gpa = testing.allocator;
    const bytes = try testfont.build(gpa, .{ .family = "Inter", .advance = 500 });
    defer gpa.free(bytes);
    var ts = tt.TextSystem.init(gpa);
    defer ts.deinit();
    ts.db.scanned = true;
    ts.db.bundled = @import("font_registry.zig").registered().len;
    ts.db.addMemory(bytes);
    var host: Fake = .{};
    ts.fallback_glyphs = host.hooks();
    // a, 日, b, a thumbs up with its skin tone (8 bytes), c.
    const s = "a\u{65e5}b\u{1f44d}\u{1f3fd}c";
    const lay = ts.layout(s, .{ .size = 20 });
    try testing.expectEqual(@as(usize, 5), lay.glyphs.len);
    const hosted = [_]u16{ 0, 3, 0, 8, 0 };
    for (lay.glyphs, hosted) |g, len| try testing.expectEqual(len, g.host);
    try testing.expectEqual(@as(u32, 1), lay.glyphs[1].index);
    try testing.expectEqual(@as(u32, 5), lay.glyphs[3].index);
    // Each ASCII letter is 10 points (half an em of 20); each host glyph 9.
    try testing.expectApproxEqAbs(@as(f32, 10), lay.glyphs[1].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 19), lay.glyphs[2].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 29), lay.glyphs[3].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 48), lay.width, 0.001);
    try testing.expectEqual(@as(usize, 2), host.measured);
}

test "host glyphs are white masks, emoji keep their colours" {
    const gpa = testing.allocator;
    var images: @import("images.zig").Images = .{ .gpa = gpa };
    defer images.deinit();
    var cache: fallback.Cache = .{};
    defer cache.deinit(gpa);
    var host: Fake = .{};
    const text = cache.place(gpa, &images, host.hooks(), "\u{65e5}", 4, 2).?;
    try testing.expect(!text.color);
    try testing.expectApproxEqAbs(@as(f32, 3), text.w, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 4), text.h, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3), text.ascent, 0.001);
    const emoji = cache.place(gpa, &images, host.hooks(), "\u{1f44d}\u{1f3fd}", 4, 2).?;
    try testing.expect(emoji.color);
    var it = cache.pixels.valueIterator();
    var seen: usize = 0;
    while (it.next()) |p| {
        const px = p.*.?;
        const first = px.bgra[0..4];
        // White coverage for text; premultiplied BGRA red for emoji.
        if (px.color) {
            try testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128 }, first);
        } else {
            try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 128 }, first);
        }
        seen += 1;
    }
    try testing.expectEqual(@as(usize, 2), seen);
    // A second ask is the cache's, not the host's.
    _ = cache.place(gpa, &images, host.hooks(), "\u{65e5}", 4, 2).?;
    try testing.expectEqual(@as(usize, 2), cache.pixels.count());
    try testing.expect(fallback.colored("\u{1f1ef}\u{1f1f5}"));
    try testing.expect(!fallback.colored("\u{65e5}\u{672c}"));
}

test "a host glyph after a middle ellipsis is still the host's" {
    const gpa = testing.allocator;
    const bytes = try testfont.build(gpa, .{ .family = "Inter", .advance = 500, .ranges = &.{ .{ 0x20, 0x7e }, .{ 0x2026, 0x2026 } } });
    defer gpa.free(bytes);
    var ts = tt.TextSystem.init(gpa);
    defer ts.deinit();
    ts.db.scanned = true;
    ts.db.bundled = @import("font_registry.zig").registered().len;
    ts.db.addMemory(bytes);
    var host: Fake = .{};
    ts.fallback_glyphs = host.hooks();
    // "abcd日e" cut to "a…日e": the head keeps a, the tail starts at 日.
    const lay = ts.layout("abcd\u{65e5}e", .{ .size = 20 });
    const el = ts.layout(text_mod.ellipsis, .{ .size = 20 });
    try testing.expectEqual(@as(u16, 0), el.glyphs[0].host);
    const cut: text_mod.Cut = .{ .head = 1, .tail = 4 };
    const sliced = text_mod.sliceGlyphs(gpa, lay, el, cut).?;
    defer gpa.free(sliced.glyphs);
    try testing.expectEqual(@as(usize, 4), sliced.glyphs.len);
    const shown = "a" ++ text_mod.ellipsis ++ "\u{65e5}e";
    const g = sliced.glyphs[2];
    try testing.expectEqual(@as(u16, 3), g.host);
    try testing.expectEqualStrings("\u{65e5}", shown[g.index..][0..g.host]);
    // The ellipsis sits where b was; 日 right after it.
    try testing.expectApproxEqAbs(@as(f32, 10), sliced.glyphs[1].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10 + el.width), g.x, 0.001);
    try testing.expectEqual(@as(u16, 0), sliced.glyphs[3].host);
}

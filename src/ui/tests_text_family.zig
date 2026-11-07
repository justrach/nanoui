//! A font per text: family lists, faces from bytes with their weights and ranges,
//! weights by number, and text in fonts that aren't installed. The fonts are made
//! here, so where a text lands says which of them drew it.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const ui = @import("ui.zig");
const text_mod = @import("text.zig");
const testfont = @import("tt/testfont.zig");
const wrap = @import("tt/testfont_wrap.zig");
const registry = @import("font_registry.zig");

const Blank = struct {
    fn view(_: *Blank, _: *ui.Context) void {}
};

fn tester(s: *Blank) !ui.Tester {
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(s, Blank.view), .{});
    return t;
}

fn add(family: []const u8, advance: u16, o: ui.FontFaceOptions) !void {
    const gpa = testing.allocator;
    var opts = o;
    const bytes = try testfont.build(gpa, .{ .family = "Made Here", .advance = advance, .ranges = &.{ .{ 0x20, 0x7e }, .{ 0x410, 0x44f } } });
    defer gpa.free(bytes);
    opts.family = family;
    opts.bytes = bytes;
    try ui.registerFontFace(gpa, opts);
}

test "a text is in the first family of its list that exists" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-a");
    try add("family-a", 500, .{ .family = "" });
    t.text.syncFonts();
    // 20px at half an em each.
    try testing.expectApproxEqAbs(@as(f32, 40), t.text.width("abcd", .{ .size = 20, .family = "family-a" }), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 40), t.text.width("abcd", .{ .size = 20, .family = "No Such Font, FAMILY-A, Another" }), 0.01);
    const fallback = t.text.width("abcd", .{ .size = 20, .family = "No Such Font" });
    const plain = t.text.width("abcd", .{ .size = 20 });
    try testing.expectApproxEqAbs(plain, fallback, 0.01);
    try testing.expect(t.text.hasFamily("family-a"));
    try testing.expect(!t.text.hasFamily("No Such Font"));
    try testing.expect(t.text.hasFamily("system-ui"));
}

test "a null family is the theme's font as it was" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    const style: ui.TextStyle = .{ .size = 14, .weight = .semibold };
    const a = t.text.width("Keep the theme's font", style);
    var with = style;
    with.family = null;
    with.css_weight = 600;
    try testing.expectEqual(a, t.text.width("Keep the theme's font", with));
    try testing.expectEqual(t.text.font(style).ascent, t.text.font(with).ascent);
}

test "metrics of a family come from the font that draws it" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-m");
    const gpa = testing.allocator;
    const bytes = try testfont.build(gpa, .{ .family = "Metrics", .ascent = 900, .descent = 300, .gap = 100 });
    defer gpa.free(bytes);
    try ui.registerFontFace(gpa, .{ .family = "family-m", .bytes = bytes });
    t.text.syncFonts();
    const f = t.text.font(.{ .size = 10, .family = "family-m" });
    try testing.expectApproxEqAbs(@as(f32, 9), f.ascent, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 3), f.descent, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 1), f.leading, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 5), f.zero_width, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 4.5), f.x_height, 0.01);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Metrics", t.text.familyName(.{ .size = 10, .family = "family-m" }, &buf));
}

test "a font that gives no family name has an empty one" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-nameless");
    const gpa = testing.allocator;
    const bytes = try testfont.build(gpa, .{ .family = "" });
    defer gpa.free(bytes);
    try ui.registerFontFace(gpa, .{ .family = "family-nameless", .bytes = bytes });
    t.text.syncFonts();
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("", t.text.familyName(.{ .size = 10, .family = "family-nameless" }, &buf));
}

test "each character goes to the face of its range, per CSS's unicode-range" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-r");
    try add("family-r", 500, .{ .family = "", .ranges = &.{.{ 0, 0x7f }} });
    try add("family-r", 1000, .{ .family = "", .ranges = &.{.{ 0x400, 0x4ff }} });
    t.text.syncFonts();
    const style: ui.TextStyle = .{ .size = 10, .family = "family-r" };
    // Both faces have both alphabets; the ranges decide.
    try testing.expectApproxEqAbs(@as(f32, 5), t.text.width("a", style), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 10), t.text.width("\u{430}", style), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 25), t.text.width("a\u{430}\u{431}", style), 0.01);
    // A range only some characters are in: the rest falls to the next family.
    defer ui.unregisterFontFamilies("family-q");
    try add("family-q", 2000, .{ .family = "", .ranges = &.{.{ '&', '&' }} });
    t.text.syncFonts();
    const q: ui.TextStyle = .{ .size = 10, .family = "family-q, family-r" };
    try testing.expectApproxEqAbs(@as(f32, 20 + 5), t.text.width("&a", q), 0.01);
    // A line takes its metrics from the first face with a space.
    try testing.expectApproxEqAbs(t.text.font(.{ .size = 10, .family = "family-r" }).ascent, t.text.font(q).ascent, 0.01);
}

test "a family gets its nearest weight, and fonts go away again" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    try add("family-w", 400, .{ .family = "", .weight = .{ 100, 300 } });
    try add("family-w", 700, .{ .family = "", .weight = .{ 400, 400 } });
    try add("family-w", 900, .{ .family = "", .weight = .{ 900, 900 } });
    t.text.syncFonts();
    const at = struct {
        fn f(tt: *ui.Tester, w: u16) f32 {
            return tt.text.width("a", .{ .size = 10, .family = "family-w", .css_weight = w });
        }
    }.f;
    try testing.expectApproxEqAbs(@as(f32, 4), at(&t, 200), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 7), at(&t, 400), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 7), at(&t, 500), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 9), at(&t, 800), 0.01);
    // The enum's names mean the same numbers.
    try testing.expectEqual(@as(u16, 900), ui.Weight.black.css());
    try testing.expectEqual(ui.Weight.light, ui.Weight.of(280));
    try testing.expectApproxEqAbs(@as(f32, 4), t.text.width("a", .{ .size = 10, .family = "family-w", .weight = .thin }), 0.01);
    const with = t.text.width("a", .{ .size = 10, .family = "family-w, Zzz" });
    try testing.expectApproxEqAbs(@as(f32, 7), with, 0.01);
    ui.unregisterFontFamilies("family-w");
    t.text.syncFonts();
    try testing.expect(!t.text.hasFamily("family-w"));
    const plain = t.text.width("a", .{ .size = 10 });
    try testing.expectApproxEqAbs(plain, t.text.width("a", .{ .size = 10, .family = "family-w, Zzz" }), 0.01);
}

test "a font arriving in WOFF and in WOFF2 draws" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-web");
    const gpa = testing.allocator;
    const bytes = try testfont.build(gpa, .{ .family = "Web", .advance = 800 });
    defer gpa.free(bytes);
    const w1 = try wrap.woff(gpa, bytes, true);
    defer gpa.free(w1);
    const w2 = try wrap.woff2(gpa, bytes, true);
    defer gpa.free(w2);
    try ui.registerFontFace(gpa, .{ .family = "family-web-1", .bytes = w1 });
    try ui.registerFontFace(gpa, .{ .family = "family-web-2", .bytes = w2 });
    try ui.registerFontFace(gpa, .{ .family = "family-web-3", .bytes = @embedFile("tt/data/lato-subset.woff2") });
    try testing.expectError(error.NotAFont, ui.registerFontFace(gpa, .{ .family = "family-web-4", .bytes = "not a font" }));
    t.text.syncFonts();
    try testing.expectApproxEqAbs(@as(f32, 16), t.text.width("ab", .{ .size = 10, .family = "family-web-1" }), 0.01);
    try testing.expectApproxEqAbs(@as(f32, 16), t.text.width("ab", .{ .size = 10, .family = "family-web-2" }), 0.01);
    // A real font's glyphs, placed and rasterized.
    const lay = t.text.layout("Hamburg", .{ .size = 20, .family = "family-web-3" });
    try testing.expectEqual(@as(usize, 7), lay.glyphs.len);
    try testing.expect(lay.width > 40 and lay.width < 110);
    var drawn: usize = 0;
    for (lay.glyphs) |g| if (t.text.glyph(g, 0, 0) != null) {
        drawn += 1;
    };
    try testing.expectEqual(@as(usize, 7), drawn);
}

test "an OpenType font with CFF outlines draws" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-otf");
    const gpa = testing.allocator;
    const bytes = try testfont.build(gpa, .{ .family = "OtfTest", .advance = 700, .cff = true });
    defer gpa.free(bytes);
    try ui.registerFontFace(gpa, .{ .family = "family-otf", .bytes = bytes });
    t.text.syncFonts();
    const style: ui.TextStyle = .{ .size = 20, .family = "family-otf" };
    const lay = t.text.layout("ab", style);
    try testing.expectApproxEqAbs(@as(f32, 28), lay.width, 0.01);
    try testing.expect(t.text.glyph(lay.glyphs[0], 0, 0) != null);
}

test "zoom scales a family's text, and rich text carries families" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-z");
    try add("family-z", 500, .{ .family = "" });
    try add("family-zz", 1000, .{ .family = "" });
    t.text.syncFonts();
    const style: ui.TextStyle = .{ .size = 10, .family = "family-z" };
    try testing.expectApproxEqAbs(@as(f32, 10), t.text.width("ab", style), 0.01);
    t.text.setZoom(2);
    try testing.expectApproxEqAbs(@as(f32, 20), t.text.width("ab", style), 0.01);
    t.text.setZoom(1);
    const rich = text_mod.rich;
    const spans = [_]ui.Span{.{ .start = 1, .end = 2, .family = "family-zz" }};
    try testing.expect(rich.styled(&spans));
    try testing.expectApproxEqAbs(@as(f32, 15), rich.layout(&t.text, "ab", style, &spans, 0).width, 0.01);
}

test "a font made bold and italic where it has no such face still draws, and its advance stays" {
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-s");
    try add("family-s", 500, .{ .family = "" });
    t.text.syncFonts();
    const lay = t.text.layout("ab", .{ .size = 20, .family = "family-s", .css_weight = 700, .italic = true });
    try testing.expectEqual(@as(usize, 2), lay.glyphs.len);
    const plain = t.text.glyph(t.text.layout("a", .{ .size = 20, .family = "family-s" }).glyphs[0], 0, 0).?;
    const bold = t.text.glyph(lay.glyphs[0], 0, 0).?;
    try testing.expect(bold.w > plain.w);
    if (!text_mod.portable) try testing.expectApproxEqAbs(@as(f32, 20), lay.width, 0.01);
}

test "an icon font's ligature turns a word into its glyph, and spaced letters don't" {
    if (text_mod.portable) return error.SkipZigTest;
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    defer ui.unregisterFontFamilies("family-icons");
    const gpa = testing.allocator;
    const bytes = try testfont.build(gpa, .{ .family = "Icons", .ligature = "home", .ligature_advance = 1400 });
    defer gpa.free(bytes);
    try ui.registerFontFace(gpa, .{ .family = "family-icons", .bytes = bytes });
    t.text.syncFonts();
    const style: ui.TextStyle = .{ .size = 10, .family = "family-icons" };
    const icon = t.text.layout("home", style);
    try testing.expectEqual(@as(usize, 1), icon.glyphs.len);
    try testing.expectApproxEqAbs(@as(f32, 14), icon.width, 0.01);
    // Other words stay letters.
    try testing.expectEqual(@as(usize, 4), t.text.layout("hope", style).glyphs.len);
    var plain = style;
    plain.ligatures = false;
    const letters = t.text.layout("home", plain);
    try testing.expectEqual(@as(usize, 4), letters.glyphs.len);
    try testing.expectApproxEqAbs(@as(f32, 20), letters.width, 0.01);
}

test "an installed family and the generic names find fonts on a Mac" {
    if (text_mod.portable or builtin.os.tag != .macos) return error.SkipZigTest;
    var s: Blank = .{};
    var t = try tester(&s);
    defer t.deinit();
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Helvetica", t.text.familyName(.{ .size = 16, .family = "helvetica" }, &buf));
    try testing.expectEqualStrings("Times", t.text.familyName(.{ .size = 16, .family = "Nope, Times" }, &buf));
    const regular = t.text.width("Weight matters", .{ .size = 16, .family = "Helvetica" });
    const bold = t.text.width("Weight matters", .{ .size = 16, .family = "Helvetica", .css_weight = 700 });
    try testing.expect(bold > regular);
    // A PostScript name finds its face.
    try testing.expectApproxEqAbs(bold, t.text.width("Weight matters", .{ .size = 16, .family = "Helvetica-Bold" }), 0.01);
    // Tabular digits in a named family.
    const d: ui.TextStyle = .{ .size = 13, .family = "Helvetica Neue", .tabular = true };
    try testing.expectApproxEqAbs(t.text.width("111", d), t.text.width("888", d), 0.01);
    // The fast path and CoreText agree on a family's text.
    const st: ui.TextStyle = .{ .size = 13, .family = "Arial" };
    try testing.expect(t.text.stackOf(st).?.fast);
    const attr = t.text.attributedOf("AVATAR Typography", st);
    defer @import("cf.zig").CFRelease(attr);
    const ln = @import("cf.zig").CTLineCreateWithAttributedString(attr).?;
    defer @import("cf.zig").CFRelease(ln);
    const w: f32 = @floatCast(@import("cf.zig").CTLineGetTypographicBounds(ln, null, null, null));
    try testing.expectApproxEqAbs(w, t.text.width("AVATAR Typography", st), 0.01);
}

test {
    _ = registry;
}

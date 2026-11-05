//! A tiny TrueType font made on the spot, for tests that need a font no system
//! has: each character a box of a known advance, so where text lands says which
//! font drew it. It can also say it has a `home`-style ligature, as icon fonts
//! do. Also the same font wrapped as WOFF and WOFF2, with brotli's plain stored
//! form, to test those paths without an encoder.
const std = @import("std");
const sfnt = @import("sfnt.zig");

pub const Options = struct {
    family: []const u8 = "Test Font",
    weight: u16 = 400,
    italic: bool = false,
    /// The characters it has, as inclusive ranges.
    ranges: []const [2]u16 = &.{.{ 0x20, 0x7e }},
    /// Every glyph's advance, of 1000 units to the em.
    advance: u16 = 500,
    /// hhea's ascent, descent and line gap.
    ascent: i16 = 800,
    descent: i16 = 200,
    gap: i16 = 0,
    /// Outlines in a `CFF ` table, as an OpenType font's, not TrueType's.
    cff: bool = false,
    /// A `liga` turning this text into one glyph with this advance.
    ligature: ?[]const u8 = null,
    ligature_advance: u16 = 1000,
};

const Buf = struct {
    a: std.mem.Allocator,
    b: std.ArrayList(u8) = .empty,

    fn u16be(w: *Buf, v: u16) !void {
        var x: [2]u8 = undefined;
        std.mem.writeInt(u16, &x, v, .big);
        try w.b.appendSlice(w.a, &x);
    }
    fn i16be(w: *Buf, v: i16) !void {
        try w.u16be(@bitCast(v));
    }
    fn u32be(w: *Buf, v: u32) !void {
        var x: [4]u8 = undefined;
        std.mem.writeInt(u32, &x, v, .big);
        try w.b.appendSlice(w.a, &x);
    }
    fn str(w: *Buf, s: []const u8) !void {
        try w.b.appendSlice(w.a, s);
    }
};

/// One rectangle: the glyph every character here draws.
fn boxGlyph(w: *Buf, advance: u16) !void {
    const x1: i16 = @intCast(@max(advance, 100) - 50);
    try w.i16be(1); // contours
    for ([_]i16{ 50, 0, x1, 700 }) |v| try w.i16be(v); // bbox
    try w.u16be(3); // last point of the contour
    try w.u16be(0); // no instructions
    for (0..4) |_| try w.b.append(w.a, 1); // on curve, words for both axes
    for ([_]i16{ 50, x1 - 50, 0, 50 - x1 }) |v| try w.i16be(v);
    for ([_]i16{ 0, 0, 700, 0 }) |v| try w.i16be(v);
    while (w.b.items.len & 3 != 0) try w.b.append(w.a, 0);
}

fn nameTable(w: *Buf, family: []const u8) !void {
    try w.u16be(0);
    try w.u16be(2);
    try w.u16be(6 + 2 * 12);
    for ([_]u16{ 1, 4 }) |id| {
        try w.u16be(3);
        try w.u16be(1);
        try w.u16be(0x409);
        try w.u16be(id);
        try w.u16be(@intCast(family.len * 2));
        try w.u16be(0);
    }
    for (family) |c| {
        try w.b.append(w.a, 0);
        try w.b.append(w.a, c);
    }
}

fn cmapTable(w: *Buf, o: Options) !void {
    try w.u16be(0);
    try w.u16be(1);
    try w.u16be(3);
    try w.u16be(1);
    try w.u32be(12);
    const segs: u16 = @intCast(o.ranges.len + 1);
    try w.u16be(4);
    try w.u16be(16 + 8 * segs);
    try w.u16be(0);
    try w.u16be(segs * 2);
    const log2: u4 = @intCast(std.math.log2_int(u16, segs));
    try w.u16be(@as(u16, 2) << log2);
    try w.u16be(log2);
    try w.u16be((segs * 2) - (@as(u16, 2) << log2));
    for (o.ranges) |r| try w.u16be(r[1]);
    try w.u16be(0xffff);
    try w.u16be(0);
    for (o.ranges) |r| try w.u16be(r[0]);
    try w.u16be(0xffff);
    // Glyphs follow the ranges in order, from 1.
    var g: u16 = 1;
    for (o.ranges) |r| {
        try w.u16be(g -% r[0]);
        g += r[1] - r[0] + 1;
    }
    try w.u16be(1);
    for (0..segs) |_| try w.u16be(0);
}

/// `liga`: the text's letters to the last glyph.
fn gsubTable(w: *Buf, o: Options, text: []const u8, lig_glyph: u16) !void {
    const glyphOf = struct {
        fn f(op: Options, c: u8) u16 {
            var g: u16 = 1;
            for (op.ranges) |r| {
                if (c >= r[0] and c <= r[1]) return g + (c - r[0]);
                g += r[1] - r[0] + 1;
            }
            return 0;
        }
    }.f;
    const n: u16 = @intCast(text.len);
    try w.u32be(0x00010000);
    try w.u16be(10); // script list
    try w.u16be(10 + 20); // feature list
    try w.u16be(10 + 20 + 14); // lookup list
    // Script list: DFLT, a default language with one feature.
    try w.u16be(1);
    try w.str("DFLT");
    try w.u16be(8);
    try w.u16be(4); // default language system
    try w.u16be(0);
    try w.u16be(0); // lookup order
    try w.u16be(0xffff); // no required feature
    try w.u16be(1);
    try w.u16be(0);
    // Feature list.
    try w.u16be(1);
    try w.str("liga");
    try w.u16be(8);
    try w.u16be(0);
    try w.u16be(1);
    try w.u16be(0);
    // Lookup list: one ligature lookup.
    try w.u16be(1);
    try w.u16be(4);
    try w.u16be(4); // type
    try w.u16be(0);
    try w.u16be(1);
    try w.u16be(8);
    // The substitution: format 1, its coverage and one set of one ligature.
    try w.u16be(1);
    try w.u16be(8);
    try w.u16be(1);
    try w.u16be(14);
    try w.u16be(1); // coverage: format 1, one glyph
    try w.u16be(1);
    try w.u16be(glyphOf(o, text[0]));
    try w.u16be(1); // set: one ligature
    try w.u16be(4);
    try w.u16be(lig_glyph);
    try w.u16be(n);
    for (text[1..]) |c| try w.u16be(glyphOf(o, c));
}

/// A CFF table of boxes: the same shape as `boxGlyph`, as a Type 2 charstring.
fn cffTable(w: *Buf, advance: u16, num_glyphs: u16, family: []const u8) !void {
    const x1: i16 = @intCast(@max(advance, 100) - 50);
    var code: Buf = .{ .a = w.a };
    // `28` then a word, each: 50 0 rmoveto, x 0 rlineto, 0 700 rlineto, -x 0 rlineto, endchar.
    for ([_]i16{ 50, 0 }) |v| {
        try code.b.append(w.a, 28);
        try code.i16be(v);
    }
    try code.b.append(w.a, 21);
    for ([_]i16{ x1 - 50, 0, 0, 700, 50 - x1, 0 }) |v| {
        try code.b.append(w.a, 28);
        try code.i16be(v);
    }
    try code.b.append(w.a, 5);
    try code.b.append(w.a, 14);
    const one = code.b.items;

    const index16 = struct {
        fn write(o: *Buf, count: u16, each: []const u8) !void {
            try o.u16be(count);
            if (count == 0) return;
            try o.b.append(o.a, 2);
            for (0..count + 1) |i| try o.u16be(@intCast(1 + i * each.len));
            for (0..count) |_| try o.str(each);
        }
    }.write;
    var head: Buf = .{ .a = w.a };
    try head.b.appendSlice(w.a, &.{ 1, 0, 4, 2 });
    try index16(&head, 1, family);
    // Top DICT: CharStrings at a fixed-width offset, known once the rest is laid out.
    const top_len: usize = 6;
    const at = head.b.items.len + 3 + 2 * 2 + top_len + 2 + 2;
    var top: Buf = .{ .a = w.a };
    try top.b.append(w.a, 29);
    try top.u32be(@intCast(at));
    try top.b.append(w.a, 17);
    try index16(&head, 1, top.b.items);
    try head.u16be(0); // strings
    try head.u16be(0); // global subroutines
    try index16(&head, num_glyphs, one);
    try w.b.appendSlice(w.a, head.b.items);
}

/// The font's sfnt, the caller's.
pub fn build(gpa: std.mem.Allocator, o: Options) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var chars: u16 = 0;
    for (o.ranges) |r| chars += r[1] - r[0] + 1;
    const lig_glyphs: u16 = if (o.ligature != null) 1 else 0;
    const num_glyphs: u16 = 1 + chars + lig_glyphs;

    var glyf: Buf = .{ .a = a };
    var loca: Buf = .{ .a = a };
    var hmtx: Buf = .{ .a = a };
    for (0..num_glyphs) |i| {
        try loca.u32be(@intCast(glyf.b.items.len));
        const adv = if (o.ligature != null and i == num_glyphs - 1) o.ligature_advance else o.advance;
        try boxGlyph(&glyf, adv);
        try hmtx.u16be(adv);
        try hmtx.i16be(50);
    }
    try loca.u32be(@intCast(glyf.b.items.len));

    var head: Buf = .{ .a = a };
    try head.u32be(0x00010000);
    try head.u32be(0x00010000);
    try head.u32be(0);
    try head.u32be(0x5F0F3CF5);
    try head.u16be(0);
    try head.u16be(1000);
    for (0..4) |_| try head.u32be(0); // dates
    for ([_]i16{ 0, 0, 2000, 800 }) |v| try head.i16be(v);
    try head.u16be(if (o.italic) 2 else 0);
    try head.u16be(8);
    try head.i16be(2);
    try head.i16be(1); // long loca
    try head.i16be(0);

    var hhea: Buf = .{ .a = a };
    try hhea.u32be(0x00010000);
    try hhea.i16be(o.ascent);
    try hhea.i16be(-o.descent);
    try hhea.i16be(o.gap);
    try hhea.u16be(2000);
    for (0..3) |_| try hhea.i16be(0);
    try hhea.i16be(1); // caret
    for (0..7) |_| try hhea.i16be(0);
    try hhea.u16be(num_glyphs);

    var maxp: Buf = .{ .a = a };
    try maxp.u32be(0x00010000);
    try maxp.u16be(num_glyphs);
    try maxp.u16be(4);
    try maxp.u16be(1);
    for (0..10) |_| try maxp.u16be(0);
    try maxp.u16be(0);

    var os2: Buf = .{ .a = a };
    try os2.u16be(4); // version
    try os2.i16be(500);
    try os2.u16be(o.weight);
    try os2.u16be(5);
    try os2.u16be(0);
    for (0..11) |_| try os2.i16be(0);
    for (0..10) |_| try os2.b.append(a, 0); // panose
    for (0..4) |_| try os2.u32be(0);
    try os2.str("TEST");
    try os2.u16be(if (o.italic) @as(u16, 1) else 0x40);
    try os2.u16be(0x20);
    try os2.u16be(0x7e);
    try os2.i16be(o.ascent);
    try os2.i16be(-o.descent);
    try os2.i16be(o.gap);
    try os2.u16be(@intCast(o.ascent));
    try os2.u16be(@intCast(o.descent));
    try os2.u32be(1);
    try os2.u32be(0);
    try os2.i16be(450); // x height
    try os2.i16be(700); // cap height
    for (0..3) |_| try os2.u16be(0);

    var post: Buf = .{ .a = a };
    try post.u32be(0x00030000);
    for (0..7) |_| try post.u32be(0);

    var name: Buf = .{ .a = a };
    try nameTable(&name, o.family);
    var cmap: Buf = .{ .a = a };
    try cmapTable(&cmap, o);

    var tables: std.ArrayList(sfnt.Table) = .empty;
    const add = struct {
        fn f(l: *std.ArrayList(sfnt.Table), al: std.mem.Allocator, t: *const [4]u8, b: *const Buf) !void {
            try l.append(al, .{ .tag = sfnt.tag(t), .data = b.b.items });
        }
    }.f;
    try add(&tables, a, "cmap", &cmap);
    var cff_data: Buf = .{ .a = a };
    if (o.cff) {
        try cffTable(&cff_data, o.advance, num_glyphs, o.family);
        try add(&tables, a, "CFF ", &cff_data);
        maxp.b.items.len = 6;
        std.mem.writeInt(u32, maxp.b.items[0..4], 0x00005000, .big);
    } else {
        try add(&tables, a, "glyf", &glyf);
        try add(&tables, a, "loca", &loca);
    }
    try add(&tables, a, "head", &head);
    try add(&tables, a, "hhea", &hhea);
    try add(&tables, a, "hmtx", &hmtx);
    try add(&tables, a, "maxp", &maxp);
    try add(&tables, a, "name", &name);
    try add(&tables, a, "OS/2", &os2);
    try add(&tables, a, "post", &post);
    var gsub: Buf = .{ .a = a };
    if (o.ligature) |text| {
        try gsubTable(&gsub, o, text, num_glyphs - 1);
        try add(&tables, a, "GSUB", &gsub);
    }
    return sfnt.assemble(gpa, if (o.cff) sfnt.tag("OTTO") else 0x00010000, tables.items);
}

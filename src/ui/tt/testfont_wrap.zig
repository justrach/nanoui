//! A test font wrapped as WOFF and WOFF2, with no encoder: zlib from std, and
//! brotli in its stored form. The glyph transform below knows only the boxes
//! `testfont.zig` draws, which is all it is given.
const std = @import("std");
const sfnt = @import("sfnt.zig");

fn tablesOf(a: std.mem.Allocator, font: []const u8) ![]sfnt.Table {
    const n = std.mem.readInt(u16, font[4..6], .big);
    const out = try a.alloc(sfnt.Table, n);
    for (out, 0..) |*t, i| {
        const rec = font[12 + 16 * i..][0..16];
        const off = std.mem.readInt(u32, rec[8..12], .big);
        const len = std.mem.readInt(u32, rec[12..16], .big);
        t.* = .{ .tag = std.mem.readInt(u32, rec[0..4], .big), .data = font[off..][0..len] };
    }
    return out;
}

const Out = std.ArrayList(u8);

fn put16(a: std.mem.Allocator, o: *Out, v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .big);
    try o.appendSlice(a, &b);
}

fn put32(a: std.mem.Allocator, o: *Out, v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .big);
    try o.appendSlice(a, &b);
}

/// A zlib stream of `d`: compressed for real.
fn zlibOf(a: std.mem.Allocator, d: []const u8) ![]u8 {
    const flate = std.compress.flate;
    var out = try std.Io.Writer.Allocating.initCapacity(a, 4096);
    var window: [flate.max_window_len]u8 = undefined;
    var c = try flate.Compress.init(&out.writer, &window, .zlib, .default);
    try c.writer.writeAll(d);
    try c.finish();
    return out.toOwnedSlice();
}

/// The font as a WOFF file; each table through zlib, or stored.
pub fn woff(gpa: std.mem.Allocator, font: []const u8, zipped: bool) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tables = try tablesOf(a, font);
    var body: Out = .empty;
    var dir: Out = .empty;
    const start = 44 + 20 * tables.len;
    for (tables) |t| {
        var data = t.data;
        if (zipped) {
            const z = try zlibOf(a, t.data);
            if (z.len < t.data.len) data = z;
        }
        try put32(a, &dir, t.tag);
        try put32(a, &dir, @intCast(start + body.items.len));
        try put32(a, &dir, @intCast(data.len));
        try put32(a, &dir, @intCast(t.data.len));
        try put32(a, &dir, 0);
        try body.appendSlice(a, data);
        while (body.items.len & 3 != 0) try body.append(a, 0);
    }
    var o: Out = .empty;
    try put32(a, &o, sfnt.tag("wOFF"));
    try put32(a, &o, 0x00010000);
    try put32(a, &o, @intCast(start + body.items.len));
    try put16(a, &o, @intCast(tables.len));
    try put16(a, &o, 0);
    try put32(a, &o, @intCast(font.len));
    try put32(a, &o, 0x00010000); // versions
    for (0..5) |_| try put32(a, &o, 0); // metadata and private block
    try o.appendSlice(a, dir.items);
    try o.appendSlice(a, body.items);
    return gpa.dupe(u8, o.items);
}

/// `d` as a brotli stream of stored meta-blocks.
fn storedBrotli(a: std.mem.Allocator, d: []const u8) ![]u8 {
    var o: Out = .empty;
    var at: usize = 0;
    var first = true;
    while (at < d.len) {
        const n = @min(d.len - at, 65536);
        // Lengths go in low bits first: the window's bit, then not last,
        // four nibbles, the length, and stored.
        var bits: u32 = 0;
        var shift: u5 = 0;
        if (first) shift = 1; // WBITS 16
        first = false;
        shift += 3; // ISLAST 0, MNIBBLES 0
        bits |= @as(u32, @intCast(n - 1)) << shift;
        shift += 16;
        bits |= @as(u32, 1) << shift;
        for (0..3) |i| try o.append(a, @truncate(bits >> @intCast(8 * i)));
        try o.appendSlice(a, d[at..][0..n]);
        at += n;
    }
    if (first) try o.append(a, 0x06) else try o.append(a, 0x03);
    return o.items;
}

fn base128(a: std.mem.Allocator, o: *Out, v: u32) !void {
    var started = false;
    var shift: u5 = 28;
    while (true) : (shift -= 7) {
        const part: u8 = @truncate((v >> shift) & 0x7f);
        if (part != 0 or started or shift == 0) {
            try o.append(a, part | (if (shift != 0) @as(u8, 0x80) else 0));
            started = true;
        }
        if (shift == 0) break;
    }
}

/// `glyf` as WOFF2 keeps it, for fonts of boxes alone.
fn transformGlyf(a: std.mem.Allocator, glyf: []const u8, num_glyphs: u16) ![]u8 {
    var contours: Out = .empty;
    var points: Out = .empty;
    var flags: Out = .empty;
    var coords: Out = .empty;
    var at: usize = 0;
    for (0..num_glyphs) |_| {
        // One contour, its bounds, the last point, no instructions, 4 flags,
        // 4 x words, 4 y words, padded.
        const coord_at = at + 10 + 2 + 2 + 4;
        try put16(a, &contours, 1);
        try points.append(a, 4);
        var i: usize = 0;
        var x_at = coord_at;
        var y_at = coord_at + 8;
        while (i < 4) : (i += 1) {
            const dx = std.mem.readInt(i16, glyf[x_at..][0..2], .big);
            const dy = std.mem.readInt(i16, glyf[y_at..][0..2], .big);
            x_at += 2;
            y_at += 2;
            const flag: u8 = 124 + @as(u8, @intFromBool(dx >= 0)) + 2 * @as(u8, @intFromBool(dy >= 0));
            try flags.append(a, flag);
            try put16(a, &coords, @intCast(@abs(dx)));
            try put16(a, &coords, @intCast(@abs(dy)));
        }
        try coords.append(a, 0); // no instructions
        at = (coord_at + 16 + 3) & ~@as(usize, 3);
    }
    var o: Out = .empty;
    try put32(a, &o, 0);
    try put16(a, &o, num_glyphs);
    try put16(a, &o, 1);
    try put32(a, &o, @intCast(contours.items.len));
    try put32(a, &o, @intCast(points.items.len));
    try put32(a, &o, @intCast(flags.items.len));
    try put32(a, &o, @intCast(coords.items.len));
    try put32(a, &o, 0);
    const bitmap = 4 * ((@as(usize, num_glyphs) + 31) / 32);
    try put32(a, &o, @intCast(bitmap));
    try put32(a, &o, 0);
    try o.appendSlice(a, contours.items);
    try o.appendSlice(a, points.items);
    try o.appendSlice(a, flags.items);
    try o.appendSlice(a, coords.items);
    for (0..bitmap) |_| try o.append(a, 0);
    return o.items;
}

/// `hmtx` with every left side bearing left out.
fn transformHmtx(a: std.mem.Allocator, hmtx: []const u8) ![]u8 {
    var o: Out = .empty;
    try o.append(a, 3);
    var i: usize = 0;
    while (i + 4 <= hmtx.len) : (i += 4) try o.appendSlice(a, hmtx[i..][0..2]);
    return o.items;
}

/// The font as a WOFF2 file; its boxes transformed, or not.
pub fn woff2(gpa: std.mem.Allocator, font: []const u8, transform: bool) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tables = try tablesOf(a, font);
    var num_glyphs: u16 = 0;
    for (tables) |t| if (t.tag == sfnt.tag("maxp")) {
        num_glyphs = std.mem.readInt(u16, t.data[4..6], .big);
    };
    // `loca` must directly follow `glyf`.
    var ordered: std.ArrayList(sfnt.Table) = .empty;
    for (tables) |t| {
        if (t.tag == sfnt.tag("loca")) continue;
        try ordered.append(a, t);
        if (t.tag == sfnt.tag("glyf")) for (tables) |l| if (l.tag == sfnt.tag("loca")) try ordered.append(a, l);
    }
    var dir: Out = .empty;
    var plain: Out = .empty;
    for (ordered.items) |t| {
        const is_glyf = t.tag == sfnt.tag("glyf");
        const is_loca = t.tag == sfnt.tag("loca");
        const is_hmtx = t.tag == sfnt.tag("hmtx");
        // An arbitrary tag spelled out; the version in the flags' high bits.
        var version: u8 = 0;
        if (!transform and (is_glyf or is_loca)) version = 3;
        if (transform and is_hmtx) version = 1;
        try dir.append(a, 63 | (version << 6));
        try put32(a, &dir, t.tag);
        try base128(a, &dir, @intCast(t.data.len));
        var data = t.data;
        if (transform and is_glyf) data = try transformGlyf(a, t.data, num_glyphs);
        if (transform and is_loca) data = "";
        if (transform and is_hmtx) data = try transformHmtx(a, t.data);
        if (transform and (is_glyf or is_loca or is_hmtx)) try base128(a, &dir, @intCast(data.len));
        try plain.appendSlice(a, data);
    }
    const compressed = try storedBrotli(a, plain.items);
    var o: Out = .empty;
    try put32(a, &o, sfnt.tag("wOF2"));
    try put32(a, &o, 0x00010000);
    try put32(a, &o, @intCast(48 + dir.items.len + compressed.len));
    try put16(a, &o, @intCast(ordered.items.len));
    try put16(a, &o, 0);
    try put32(a, &o, @intCast(font.len));
    try put32(a, &o, @intCast(compressed.len));
    try put32(a, &o, 0x00010000);
    for (0..5) |_| try put32(a, &o, 0);
    try o.appendSlice(a, dir.items);
    try o.appendSlice(a, compressed);
    return gpa.dupe(u8, o.items);
}

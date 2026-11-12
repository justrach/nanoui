//! Web fonts to the font files nanoui and CoreText read: WOFF (zlib per table)
//! and WOFF2 (`woff2.zig`) back to sfnt, and a check that an sfnt's table
//! directory stays inside its file. Font bytes come from any web server, so
//! nothing here trusts a length or an offset it reads.
const std = @import("std");
const woff2 = @import("woff2.zig");

pub const Error = error{ NotAFont, Corrupt, TooLarge, Unsupported, OutOfMemory };

/// The largest font this accepts, decoded.
pub const max_font: usize = 96 << 20;

fn be16(d: []const u8, at: usize) ?u16 {
    if (at > d.len or d.len - at < 2) return null;
    return std.mem.readInt(u16, d[at..][0..2], .big);
}

fn be32(d: []const u8, at: usize) ?u32 {
    if (at > d.len or d.len - at < 4) return null;
    return std.mem.readInt(u32, d[at..][0..4], .big);
}

pub fn tag(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

pub const Kind = enum { sfnt, collection, woff, woff2, unknown };

/// What a font file's first bytes say it is.
pub fn sniff(d: []const u8) Kind {
    const sig = be32(d, 0) orelse return .unknown;
    if (sig == 0x00010000 or sig == tag("true") or sig == tag("OTTO")) return .sfnt;
    if (sig == tag("ttcf")) return .collection;
    if (sig == tag("wOFF")) return .woff;
    if (sig == tag("wOF2")) return .woff2;
    return .unknown;
}

/// `d` as an sfnt the caller owns: decoded from WOFF or WOFF2, or copied and
/// checked.
pub fn decode(gpa: std.mem.Allocator, d: []const u8) Error![]u8 {
    switch (sniff(d)) {
        .sfnt, .collection => {
            try validate(d);
            return gpa.dupe(u8, d);
        },
        .woff => return decodeWoff(gpa, d),
        .woff2 => return woff2.decode(gpa, d),
        .unknown => return error.NotAFont,
    }
}

/// Every table of an sfnt lies inside it, and the tables that make a font
/// are there.
pub fn validate(d: []const u8) Error!void {
    if (d.len > max_font) return error.TooLarge;
    var at: usize = 0;
    if (sniff(d) == .collection) at = be32(d, 12) orelse return error.Corrupt;
    const version = be32(d, at) orelse return error.Corrupt;
    if (version != 0x00010000 and version != tag("true") and version != tag("OTTO")) return error.NotAFont;
    const n = be16(d, at + 4) orelse return error.Corrupt;
    if (n == 0 or n > 512) return error.Corrupt;
    var seen: u8 = 0;
    for (0..n) |i| {
        const rec = at + 12 + 16 * i;
        const t = be32(d, rec) orelse return error.Corrupt;
        const off = be32(d, rec + 8) orelse return error.Corrupt;
        const len = be32(d, rec + 12) orelse return error.Corrupt;
        if (off > d.len or len > d.len - off) return error.Corrupt;
        if (t == tag("head")) seen |= 1;
        if (t == tag("maxp")) seen |= 2;
        if (t == tag("cmap")) seen |= 4;
        if (t == tag("hhea")) seen |= 8;
        if (t == tag("hmtx")) seen |= 16;
    }
    if (seen != 31) return error.Corrupt;
}

/// A table of a font being put back together.
pub const Table = struct { tag: u32, data: []const u8 };

fn checksum(d: []const u8) u32 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 4 <= d.len) : (i += 4) sum +%= std.mem.readInt(u32, d[i..][0..4], .big);
    if (i < d.len) {
        var last: [4]u8 = @splat(0);
        @memcpy(last[0 .. d.len - i], d[i..]);
        sum +%= std.mem.readInt(u32, &last, .big);
    }
    return sum;
}

/// An sfnt holding `tables` (sorted here), their checksums worked out.
pub fn assemble(gpa: std.mem.Allocator, flavor: u32, tables: []Table) Error![]u8 {
    if (tables.len == 0 or tables.len > 512) return error.Corrupt;
    std.mem.sort(Table, tables, {}, struct {
        fn lt(_: void, a: Table, b: Table) bool {
            return a.tag < b.tag;
        }
    }.lt);
    for (tables[1..], 0..) |t, i| if (t.tag == tables[i].tag) return error.Corrupt;
    var total: usize = 12 + 16 * tables.len;
    for (tables) |t| {
        total += (t.data.len + 3) & ~@as(usize, 3);
        if (total > max_font) return error.TooLarge;
    }
    const out = try gpa.alloc(u8, total);
    errdefer gpa.free(out);
    @memset(out, 0);
    const n: u16 = @intCast(tables.len);
    const log2: u4 = @intCast(std.math.log2_int(u16, n));
    std.mem.writeInt(u32, out[0..4], flavor, .big);
    std.mem.writeInt(u16, out[4..6], n, .big);
    std.mem.writeInt(u16, out[6..8], @as(u16, 16) << log2, .big);
    std.mem.writeInt(u16, out[8..10], log2, .big);
    std.mem.writeInt(u16, out[10..12], (n - (@as(u16, 1) << log2)) * 16, .big);
    var at: usize = 12 + 16 * tables.len;
    var head_at: ?usize = null;
    for (tables, 0..) |t, i| {
        const rec = out[12 + 16 * i ..][0..16];
        std.mem.writeInt(u32, rec[0..4], t.tag, .big);
        @memcpy(out[at..][0..t.data.len], t.data);
        if (t.tag == tag("head") and t.data.len >= 12) {
            head_at = at;
            // The adjustment is worked out with it as zero.
            @memset(out[at + 8 ..][0..4], 0);
        }
        std.mem.writeInt(u32, rec[4..8], checksum(out[at..][0..t.data.len]), .big);
        std.mem.writeInt(u32, rec[8..12], @intCast(at), .big);
        std.mem.writeInt(u32, rec[12..16], @intCast(t.data.len), .big);
        at += (t.data.len + 3) & ~@as(usize, 3);
    }
    if (head_at) |h| std.mem.writeInt(u32, out[h + 8 ..][0..4], 0xB1B0AFBA -% checksum(out), .big);
    return out;
}

fn decodeWoff(gpa: std.mem.Allocator, d: []const u8) Error![]u8 {
    const flavor = be32(d, 4) orelse return error.Corrupt;
    const n = be16(d, 12) orelse return error.Corrupt;
    if (d.len < 44 or n == 0 or n > 512) return error.Corrupt;
    const tables = try gpa.alloc(Table, n);
    defer gpa.free(tables);
    var made: usize = 0;
    defer for (tables[0..made]) |t| gpa.free(t.data);
    var total: usize = 0;
    for (tables, 0..) |*t, i| {
        const rec = 44 + 20 * i;
        const name = be32(d, rec) orelse return error.Corrupt;
        const off = be32(d, rec + 4) orelse return error.Corrupt;
        const comp = be32(d, rec + 8) orelse return error.Corrupt;
        const orig = be32(d, rec + 12) orelse return error.Corrupt;
        if (off > d.len or comp > d.len - off or comp > orig) return error.Corrupt;
        total += orig;
        if (total > max_font) return error.TooLarge;
        const body = d[off..][0..comp];
        const out = try gpa.alloc(u8, orig);
        t.* = .{ .tag = name, .data = out };
        made = i + 1;
        if (comp == orig) {
            @memcpy(out, body);
        } else {
            try inflate(body, out);
        }
    }
    const font = try assemble(gpa, flavor, tables);
    errdefer gpa.free(font);
    try validate(font);
    return font;
}

/// `z` (zlib) inflated into exactly `out`.
fn inflate(z: []const u8, out: []u8) Error!void {
    const flate = std.compress.flate;
    var input: std.Io.Reader = .fixed(z);
    var window: [flate.max_window_len]u8 = undefined;
    var dec: flate.Decompress = .init(&input, .zlib, &window);
    dec.reader.readSliceAll(out) catch return error.Corrupt;
    // Nothing past what the directory promised.
    var one: [1]u8 = undefined;
    const extra = dec.reader.readSliceShort(&one) catch return error.Corrupt;
    if (extra != 0) return error.Corrupt;
}

/// WOFF2's variable-length numbers, over a cursor.
pub const Stream = struct {
    d: []const u8,
    at: usize = 0,

    pub fn left(s: *const Stream) usize {
        return s.d.len - s.at;
    }

    pub fn byte(s: *Stream) Error!u8 {
        if (s.at >= s.d.len) return error.Corrupt;
        s.at += 1;
        return s.d[s.at - 1];
    }

    pub fn u16be(s: *Stream) Error!u16 {
        const v = be16(s.d, s.at) orelse return error.Corrupt;
        s.at += 2;
        return v;
    }

    pub fn u32be(s: *Stream) Error!u32 {
        const v = be32(s.d, s.at) orelse return error.Corrupt;
        s.at += 4;
        return v;
    }

    pub fn take(s: *Stream, n: usize) Error![]const u8 {
        if (n > s.left()) return error.Corrupt;
        s.at += n;
        return s.d[s.at - n ..][0..n];
    }

    /// UIntBase128.
    pub fn base128(s: *Stream) Error!u32 {
        var v: u32 = 0;
        for (0..5) |i| {
            const b = try s.byte();
            if (i == 0 and b == 0x80) return error.Corrupt;
            if (v & 0xFE000000 != 0) return error.Corrupt;
            v = (v << 7) | (b & 0x7f);
            if (b & 0x80 == 0) return v;
        }
        return error.Corrupt;
    }

    /// 255UInt16.
    pub fn uint255(s: *Stream) Error!u16 {
        const c = try s.byte();
        return switch (c) {
            253 => s.u16be(),
            255 => @as(u16, try s.byte()) + 253,
            254 => @as(u16, try s.byte()) + 506,
            else => c,
        };
    }
};

/// True when `d` carries AAT state tables (`morx`/`mort`) or an OpenType `GSUB`
/// ligature of 3+ glyphs whose 2-glyph prefix is not itself a ligature in the
/// same `LigatureSet` (such as an icon font turning `"home"` into one glyph),
/// requiring full CoreText shaping rather than pairwise `shaper.Table`.
pub fn hasUnshieldedMultiLigature(d: []const u8) bool {
    var at: usize = 0;
    if (sniff(d) == .collection) at = be32(d, 12) orelse return true;
    const n = be16(d, at + 4) orelse return true;
    var gsub: ?[]const u8 = null;
    for (0..n) |i| {
        const rec = at + 12 + 16 * i;
        const t = be32(d, rec) orelse return true;
        const off = be32(d, rec + 8) orelse return true;
        const len = be32(d, rec + 12) orelse return true;
        if (off > d.len or len > d.len - off) return true;
        if (t == tag("morx") or t == tag("mort")) return true;
        if (t == tag("GSUB")) gsub = d[off..][0..len];
    }
    const g = gsub orelse return false;
    const llist_off = be16(g, 8) orelse return true;
    if (llist_off > g.len) return true;
    const ll = g[llist_off..];
    const lcount = be16(ll, 0) orelse return true;
    for (0..lcount) |li| {
        const loff = be16(ll, 2 + 2 * li) orelse return true;
        if (loff > ll.len) return true;
        const lk = ll[loff..];
        const ltype = be16(lk, 0) orelse return true;
        const scount = be16(lk, 4) orelse return true;
        for (0..scount) |si| {
            const soff = be16(lk, 6 + 2 * si) orelse return true;
            if (soff > lk.len) return true;
            var sub = lk[soff..];
            var stype = ltype;
            if (stype == 7) {
                if ((be16(sub, 0) orelse return true) != 1) return true;
                stype = be16(sub, 2) orelse return true;
                const eoff = be32(sub, 4) orelse return true;
                if (eoff > sub.len) return true;
                sub = sub[eoff..];
            }
            if (stype == 5 or stype == 6 or stype == 8) return true;
            if (stype != 4) continue;
            if ((be16(sub, 0) orelse return true) != 1) return true;
            const set_count = be16(sub, 4) orelse return true;
            for (0..set_count) |set_i| {
                const set_off = be16(sub, 6 + 2 * set_i) orelse return true;
                if (set_off > sub.len) return true;
                const lset = sub[set_off..];
                const lig_n = be16(lset, 0) orelse return true;
                var pair_g1: [32]u16 = undefined;
                var pair_len: usize = 0;
                for (0..lig_n) |k| {
                    const lig_off = be16(lset, 2 + 2 * k) orelse return true;
                    if (lig_off > lset.len) return true;
                    const lig = lset[lig_off..];
                    const comp_n = be16(lig, 2) orelse return true;
                    if (comp_n == 2 and pair_len < pair_g1.len) {
                        pair_g1[pair_len] = be16(lig, 4) orelse return true;
                        pair_len += 1;
                    }
                }
                for (0..lig_n) |k| {
                    const lig_off = be16(lset, 2 + 2 * k) orelse return true;
                    const lig = lset[lig_off..];
                    const comp_n = be16(lig, 2) orelse return true;
                    if (comp_n >= 3) {
                        const g1 = be16(lig, 4) orelse return true;
                        var shielded = false;
                        for (pair_g1[0..pair_len]) |pg| if (pg == g1) {
                            shielded = true;
                            break;
                        };
                        if (!shielded) return true;
                    }
                }
            }
        }
    }
    return false;
}

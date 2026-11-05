//! WOFF2 (W3C) back to an sfnt: the directory, the one brotli stream holding
//! every table, and the tables stored transformed: `glyf` and `loca`
//! (`woff2_glyf.zig`) and `hmtx`. What a file claims is checked against what
//! it holds, and nothing it asks for exceeds `sfnt.max_font`.
const std = @import("std");
const brotli = @import("brotli.zig");
const sfnt = @import("sfnt.zig");
const glyf = @import("woff2_glyf.zig");

const Error = sfnt.Error;
const Stream = sfnt.Stream;
const tag = sfnt.tag;

/// The tags a directory entry can name by number (WOFF2 §4.1).
const known = [63]*const [4]u8{
    "cmap", "head", "hhea", "hmtx", "maxp", "name", "OS/2", "post", "cvt ", "fpgm", "glyf", "loca", "prep", "CFF ", "VORG", "EBDT",
    "EBLC", "gasp", "hdmx", "kern", "LTSH", "PCLT", "VDMX", "vhea", "vmtx", "BASE", "GDEF", "GPOS", "GSUB", "EBSC", "JSTF", "MATH",
    "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "sbix", "acnt", "avar", "bdat", "bloc", "bsln", "cvar", "fdsc", "feat", "fmtx", "fvar",
    "gvar", "hsty", "just", "lcar", "mort", "morx", "opbd", "prop", "trak", "Zapf", "Silf", "Glat", "Gloc", "Feat", "Sill",
};

const Entry = struct {
    tag: u32,
    version: u2,
    orig: u32,
    /// What it occupies in the decompressed stream.
    stored: u32,
    at: usize = 0,
};

/// The sfnt of a WOFF2 file; the caller owns it.
pub fn decode(gpa: std.mem.Allocator, d: []const u8) Error![]u8 {
    var s: Stream = .{ .d = d };
    if (try s.u32be() != tag("wOF2")) return error.NotAFont;
    const flavor = try s.u32be();
    if (flavor == tag("ttcf")) return error.Unsupported;
    const length = try s.u32be();
    if (length != d.len) return error.Corrupt;
    const n = try s.u16be();
    if (n == 0 or n > 512) return error.Corrupt;
    _ = try s.u16be(); // reserved
    _ = try s.u32be(); // totalSfntSize: a hint, not a promise
    const compressed_len = try s.u32be();
    _ = try s.take(4 + 20); // versions, metadata and private block

    const entries = try gpa.alloc(Entry, n);
    defer gpa.free(entries);
    var total: usize = 0;
    for (entries) |*e| {
        const flags = try s.byte();
        const index = flags & 0x3f;
        const t: u32 = if (index == 63) try s.u32be() else tag(known[index]);
        const version: u2 = @intCast(flags >> 6);
        const orig = try s.base128();
        var stored = orig;
        const is_glyph_table = t == tag("glyf") or t == tag("loca");
        if ((is_glyph_table and version == 0) or (!is_glyph_table and version != 0)) stored = try s.base128();
        if (t == tag("loca") and version == 0 and stored != 0) return error.Corrupt;
        e.* = .{ .tag = t, .version = version, .orig = orig, .stored = stored, .at = total };
        total += stored;
        if (total > sfnt.max_font or orig > sfnt.max_font) return error.TooLarge;
    }
    const body = try s.take(compressed_len);
    const plain = brotli.decode(gpa, body, total) catch |err| return switch (err) {
        error.Corrupt => error.Corrupt,
        error.TooLarge => error.Corrupt,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer gpa.free(plain);
    if (plain.len != total) return error.Corrupt;
    return rebuild(gpa, flavor, entries, plain);
}

fn dataOf(plain: []const u8, e: Entry) []const u8 {
    return plain[e.at..][0..e.stored];
}

fn find(entries: []const Entry, t: u32) ?Entry {
    for (entries) |e| if (e.tag == t) return e;
    return null;
}

fn rebuild(gpa: std.mem.Allocator, flavor: u32, entries: []const Entry, plain: []const u8) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const tables = try a.alloc(sfnt.Table, entries.len);

    const glyf_entry = find(entries, tag("glyf"));
    const loca_entry = find(entries, tag("loca"));
    if ((glyf_entry == null) != (loca_entry == null)) return error.Corrupt;
    var rebuilt: ?glyf.Result = null;
    if (glyf_entry) |g| {
        if (g.version == 0) {
            if (loca_entry.?.version != 0) return error.Corrupt;
            rebuilt = try glyf.rebuild(a, dataOf(plain, g), loca_entry.?.orig);
        } else if (loca_entry.?.version == 0) return error.Corrupt;
    }
    for (entries, tables) |e, *t| {
        var data = dataOf(plain, e);
        if (e.tag == tag("glyf") and rebuilt != null) {
            data = rebuilt.?.glyf;
        } else if (e.tag == tag("loca") and rebuilt != null) {
            data = rebuilt.?.loca;
        } else if (e.tag == tag("hmtx") and e.version == 1) {
            data = try rebuildHmtx(a, data, entries, plain, rebuilt);
        } else if (e.version != 0 and !(e.version == 3 and (e.tag == tag("glyf") or e.tag == tag("loca")))) {
            return error.Corrupt;
        } else if (data.len != e.orig) {
            return error.Corrupt;
        }
        t.* = .{ .tag = e.tag, .data = data };
    }
    const font = try sfnt.assemble(gpa, flavor, tables);
    errdefer gpa.free(font);
    try sfnt.validate(font);
    return font;
}

/// The `hmtx` transform: left side bearings left out where they equal each
/// glyph's own xMin.
fn rebuildHmtx(a: std.mem.Allocator, data: []const u8, entries: []const Entry, plain: []const u8, rebuilt: ?glyf.Result) Error![]const u8 {
    const r = rebuilt orelse return error.Corrupt;
    const hhea = find(entries, tag("hhea")) orelse return error.Corrupt;
    const hhea_data = dataOf(plain, hhea);
    if (hhea_data.len < 36) return error.Corrupt;
    const num_h = std.mem.readInt(u16, hhea_data[34..36], .big);
    const num_glyphs = r.x_mins.len;
    if (num_h == 0 or num_h > num_glyphs) return error.Corrupt;
    var s: Stream = .{ .d = data };
    const flags = try s.byte();
    if (flags & 0xfc != 0 or flags & 3 == 0) return error.Corrupt;
    const advances = try s.take(2 * @as(usize, num_h));
    const prop_lsb: ?[]const u8 = if (flags & 1 == 0) try s.take(2 * @as(usize, num_h)) else null;
    const mono_lsb: ?[]const u8 = if (flags & 2 == 0) try s.take(2 * (num_glyphs - num_h)) else null;
    const out = try a.alloc(u8, 2 * num_glyphs + 2 * @as(usize, num_h));
    var w: usize = 0;
    for (0..num_glyphs) |g| {
        var lsb: i16 = r.x_mins[g];
        if (g < num_h) {
            @memcpy(out[w..][0..2], advances[2 * g..][0..2]);
            w += 2;
            if (prop_lsb) |p| lsb = std.mem.readInt(i16, p[2 * g..][0..2], .big);
        } else if (mono_lsb) |m| {
            lsb = std.mem.readInt(i16, m[2 * (g - num_h)..][0..2], .big);
        }
        std.mem.writeInt(i16, out[w..][0..2], lsb, .big);
        w += 2;
    }
    return out;
}

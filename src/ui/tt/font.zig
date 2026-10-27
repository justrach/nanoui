//! TrueType fonts read directly: the tables a text system needs from a
//! `.ttf` file or one face of a `.ttc` collection — metrics, the character
//! map, advances, kerning, the family's name and style, and glyph outlines
//! (simple and composite) — so text needs no system library on Linux or
//! Windows. Fonts with CFF outlines (most `.otf`) are not read.
const std = @import("std");

pub const Error = error{ NotAFont, Unsupported, Truncated };

pub fn be16(d: []const u8, at: usize) u16 {
    if (at + 2 > d.len) return 0;
    return std.mem.readInt(u16, d[at..][0..2], .big);
}

pub fn bei16(d: []const u8, at: usize) i16 {
    return @bitCast(be16(d, at));
}

pub fn be32(d: []const u8, at: usize) u32 {
    if (at + 4 > d.len) return 0;
    return std.mem.readInt(u32, d[at..][0..4], .big);
}

fn tag(s: *const [4]u8) u32 {
    return std.mem.readInt(u32, s, .big);
}

/// The number of faces in a font file: one, or a collection's count.
pub fn faces(data: []const u8) usize {
    if (data.len >= 12 and be32(data, 0) == tag("ttcf")) return be32(data, 8);
    return 1;
}

/// Where face `index` of the file's table directory starts.
fn faceOffset(data: []const u8, index: usize) Error!usize {
    if (data.len < 12) return error.NotAFont;
    if (be32(data, 0) == tag("ttcf")) {
        if (index >= be32(data, 8)) return error.NotAFont;
        return be32(data, 12 + 4 * index);
    }
    return 0;
}

/// The offset of each table a face needs (0 when it has none), from its
/// table directory: what scanning a font file needs without the rest.
pub const Tables = struct {
    head: u32 = 0,
    hhea: u32 = 0,
    hmtx: u32 = 0,
    maxp: u32 = 0,
    cmap: u32 = 0,
    loca: u32 = 0,
    glyf: u32 = 0,
    kern: u32 = 0,
    name: u32 = 0,
    os2: u32 = 0,
    name_len: u32 = 0,
    /// Color glyphs (`color.zig`): PNG strikes (CBDT and its index CBLC,
    /// Apple's sbix) and layered outlines (COLR with its palettes, CPAL).
    cbdt: u32 = 0,
    cblc: u32 = 0,
    sbix: u32 = 0,
    colr: u32 = 0,
    cpal: u32 = 0,

    pub fn read(data: []const u8, index: usize) Error!Tables {
        const at = try faceOffset(data, index);
        const version = be32(data, at);
        if (version == tag("OTTO")) return error.Unsupported;
        if (version != 0x00010000 and version != tag("true")) return error.NotAFont;
        const n = be16(data, at + 4);
        var t: Tables = .{};
        for (0..n) |i| {
            const rec = at + 12 + 16 * i;
            if (rec + 16 > data.len) return error.Truncated;
            const off = be32(data, rec + 8);
            switch (be32(data, rec)) {
                tag("head") => t.head = off,
                tag("hhea") => t.hhea = off,
                tag("hmtx") => t.hmtx = off,
                tag("maxp") => t.maxp = off,
                tag("cmap") => t.cmap = off,
                tag("loca") => t.loca = off,
                tag("glyf") => t.glyf = off,
                tag("kern") => t.kern = off,
                tag("OS/2") => t.os2 = off,
                tag("CBDT") => t.cbdt = off,
                tag("CBLC") => t.cblc = off,
                tag("sbix") => t.sbix = off,
                tag("COLR") => t.colr = off,
                tag("CPAL") => t.cpal = off,
                tag("name") => {
                    t.name = off;
                    t.name_len = be32(data, rec + 12);
                },
                else => {},
            }
        }
        if (t.head == 0 or t.hhea == 0 or t.hmtx == 0 or t.maxp == 0 or t.cmap == 0) return error.NotAFont;
        // An emoji font may have pictures and no outlines.
        const pictures = (t.cbdt != 0 and t.cblc != 0) or t.sbix != 0;
        if ((t.glyf == 0 or t.loca == 0) and !pictures) return error.Unsupported;
        return t;
    }
};

/// What tells faces of a family apart, and the family's name.
pub const Style = struct {
    family: [64]u8 = undefined,
    family_len: u8 = 0,
    /// 100 thin … 400 regular … 700 bold … 900 black.
    weight: u16 = 400,
    italic: bool = false,
    /// Every glyph as wide as every other.
    mono: bool = false,

    pub fn name(s: *const Style) []const u8 {
        return s.family[0..s.family_len];
    }

    /// Reads it from the `name`, `OS/2` and `post` information of a face.
    pub fn read(data: []const u8, t: Tables) Style {
        var s: Style = .{};
        if (t.os2 != 0) {
            s.weight = be16(data, t.os2 + 4);
            const sel = be16(data, t.os2 + 62);
            s.italic = sel & 1 != 0;
            // PANOSE proportion 9 is monospaced.
            s.mono = data.len > t.os2 + 35 and data[t.os2 + 35] == 9;
        }
        if (t.head != 0 and be16(data, t.head + 44) & 2 != 0) s.italic = true;
        s.readFamily(data, t);
        return s;
    }

    fn readFamily(s: *Style, data: []const u8, t: Tables) void {
        if (t.name == 0) return;
        const count = be16(data, t.name + 2);
        const strings = t.name + be16(data, t.name + 4);
        // The typographic family (16) over the legacy one (1), Windows
        // Unicode names over Mac Roman ones.
        var best: u8 = 0;
        for (0..count) |i| {
            const r = t.name + 6 + 12 * i;
            const platform = be16(data, r);
            const id = be16(data, r + 6);
            if (id != 1 and id != 16) continue;
            const unicode = platform == 3 or platform == 0;
            if (!unicode and platform != 1) continue;
            const rank: u8 = (if (id == 16) @as(u8, 2) else 0) + @intFromBool(unicode) + 1;
            if (rank <= best) continue;
            const len = be16(data, r + 8);
            const off = strings + be16(data, r + 10);
            if (off + len > data.len) continue;
            best = rank;
            s.family_len = 0;
            if (unicode) {
                var k: usize = 0;
                while (k + 1 < len) : (k += 2) {
                    const cu = be16(data, off + k);
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(if (cu >= 0xd800 and cu <= 0xdfff) '?' else cu, &buf) catch 1;
                    if (s.family_len + n > s.family.len) break;
                    @memcpy(s.family[s.family_len..][0..n], buf[0..n]);
                    s.family_len += @intCast(n);
                }
            } else {
                const n = @min(len, s.family.len);
                for (data[off..][0..n], 0..) |ch, k| s.family[k] = if (ch < 0x80) ch else '?';
                s.family_len = @intCast(n);
            }
        }
    }
};

/// A path's commands in font units (y up), as glyph outlines give them.
pub const Sink = struct {
    ctx: *anyopaque,
    move: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    line: *const fn (ctx: *anyopaque, x: f32, y: f32) void,
    quad: *const fn (ctx: *anyopaque, cx: f32, cy: f32, x: f32, y: f32) void,
    close: *const fn (ctx: *anyopaque) void,
};

pub const Font = struct {
    data: []const u8,
    t: Tables,
    units_per_em: f32,
    ascent: f32,
    descent: f32,
    line_gap: f32,
    num_glyphs: u16,
    num_hmetrics: u16,
    long_loca: bool,
    /// The character map's subtable chosen, and its format (4 or 12).
    cmap: u32 = 0,
    cmap_format: u16 = 0,
    style: Style,

    pub fn init(data: []const u8, index: usize) Error!Font {
        const t = try Tables.read(data, index);
        var f: Font = .{
            .data = data,
            .t = t,
            .units_per_em = @floatFromInt(@max(16, be16(data, t.head + 18))),
            .ascent = @floatFromInt(bei16(data, t.hhea + 4)),
            .descent = @floatFromInt(-bei16(data, t.hhea + 6)),
            .line_gap = @floatFromInt(bei16(data, t.hhea + 8)),
            .num_glyphs = be16(data, t.maxp + 4),
            .num_hmetrics = @max(1, be16(data, t.hhea + 34)),
            .long_loca = bei16(data, t.head + 50) != 0,
            .style = Style.read(data, t),
        };
        f.pickCmap();
        if (f.cmap == 0) return error.Unsupported;
        return f;
    }

    /// The Unicode subtable, full repertoire (format 12) first.
    fn pickCmap(f: *Font) void {
        const d = f.data;
        const n = be16(d, f.t.cmap + 2);
        var best: u8 = 0;
        for (0..n) |i| {
            const r = f.t.cmap + 4 + 8 * i;
            const platform = be16(d, r);
            const encoding = be16(d, r + 2);
            const off = f.t.cmap + be32(d, r + 4);
            const format = be16(d, off);
            const unicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10));
            if (!unicode or (format != 4 and format != 12)) continue;
            const rank: u8 = if (format == 12) 2 else 1;
            if (rank > best) {
                best = rank;
                f.cmap = off;
                f.cmap_format = format;
            }
        }
    }

    /// The glyph of a character, 0 (the missing glyph) when it has none.
    pub fn glyphIndex(f: *const Font, cp: u21) u16 {
        const d = f.data;
        const at = f.cmap;
        if (f.cmap_format == 12) {
            var lo: u32 = 0;
            var hi: u32 = be32(d, at + 12);
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const g = at + 16 + 12 * mid;
                const start = be32(d, g);
                const end = be32(d, g + 4);
                if (cp < start) {
                    hi = mid;
                } else if (cp > end) {
                    lo = mid + 1;
                } else return @truncate(be32(d, g + 8) + (cp - start));
            }
            return 0;
        }
        if (cp > 0xffff) return 0;
        const segs = be16(d, at + 6) / 2;
        const ends = at + 14;
        const starts = ends + 2 * @as(usize, segs) + 2;
        const deltas = starts + 2 * @as(usize, segs);
        const ranges = deltas + 2 * @as(usize, segs);
        var lo: usize = 0;
        var hi: usize = segs;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            if (be16(d, ends + 2 * mid) < cp) lo = mid + 1 else hi = mid;
        }
        if (lo >= segs) return 0;
        const start = be16(d, starts + 2 * lo);
        if (cp < start) return 0;
        const delta = be16(d, deltas + 2 * lo);
        const range = be16(d, ranges + 2 * lo);
        if (range == 0) return @truncate(@as(u32, cp) +% delta);
        const g = be16(d, ranges + 2 * lo + range + 2 * (@as(usize, cp) - start));
        return if (g == 0) 0 else g +% delta;
    }

    /// A glyph's advance, in font units.
    pub fn advance(f: *const Font, g: u16) f32 {
        const i = @min(g, f.num_hmetrics - 1);
        return @floatFromInt(be16(f.data, f.t.hmtx + 4 * @as(usize, i)));
    }

    /// The kerning between two glyphs from the `kern` table, in font units.
    pub fn kerning(f: *const Font, left: u16, right: u16) f32 {
        const d = f.data;
        if (f.t.kern == 0 or be16(d, f.t.kern) != 0) return 0;
        const sub = f.t.kern + 4;
        if (be16(d, sub + 4) & 0xff01 != 1 or be16(d, sub) != 0) return 0;
        const pairs = be16(d, sub + 6);
        const want = (@as(u32, left) << 16) | right;
        var lo: usize = 0;
        var hi: usize = pairs;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const p = sub + 14 + 6 * mid;
            const key = be32(d, p);
            if (key < want) lo = mid + 1 else if (key > want) hi = mid else return @floatFromInt(bei16(d, p + 4));
        }
        return 0;
    }

    fn glyphRange(f: *const Font, g: u16) ?[2]usize {
        if (g >= f.num_glyphs or f.t.glyf == 0 or f.t.loca == 0) return null;
        const d = f.data;
        const a: usize, const b: usize = if (f.long_loca)
            .{ be32(d, f.t.loca + 4 * @as(usize, g)), be32(d, f.t.loca + 4 * @as(usize, g) + 4) }
        else
            .{ @as(usize, be16(d, f.t.loca + 2 * @as(usize, g))) * 2, @as(usize, be16(d, f.t.loca + 2 * @as(usize, g) + 2)) * 2 };
        if (b <= a) return null;
        return .{ f.t.glyf + a, f.t.glyf + b };
    }

    /// A glyph's bounds in font units: x0, y0, x1, y1 (null when blank).
    pub fn bounds(f: *const Font, g: u16) ?[4]f32 {
        const r = f.glyphRange(g) orelse return null;
        const d = f.data;
        return .{ @floatFromInt(bei16(d, r[0] + 2)), @floatFromInt(bei16(d, r[0] + 4)), @floatFromInt(bei16(d, r[0] + 6)), @floatFromInt(bei16(d, r[0] + 8)) };
    }

    /// Sends a glyph's outline to `sink`, transformed by `m` (a, b, c, d,
    /// e, f: x' = a x + c y + e, y' = b x + d y + f).
    pub fn outline(f: *const Font, g: u16, m: [6]f32, sink: Sink) void {
        f.outlineDepth(g, m, sink, 0);
    }

    fn outlineDepth(f: *const Font, g: u16, m: [6]f32, sink: Sink, depth: u8) void {
        const r = f.glyphRange(g) orelse return;
        const contours = bei16(f.data, r[0]);
        if (contours >= 0) return f.simple(r[0], @intCast(contours), m, sink);
        if (depth < 8) f.composite(r[0] + 10, m, sink, depth);
    }

    fn simple(f: *const Font, at: usize, contours: usize, m: [6]f32, sink: Sink) void {
        const d = f.data;
        if (contours == 0) return;
        const ends = at + 10;
        const n_points: usize = @as(usize, be16(d, ends + 2 * (contours - 1))) + 1;
        const ins_len = be16(d, ends + 2 * contours);
        var p = ends + 2 * contours + 2 + ins_len;
        // Flags, then x and y coordinates, each as compact as the flags say.
        var flags_buf: [4096]u8 = undefined;
        var xs: [4096]f32 = undefined;
        var ys: [4096]f32 = undefined;
        if (n_points > flags_buf.len) return;
        var i: usize = 0;
        while (i < n_points) {
            if (p >= d.len) return;
            const fl = d[p];
            p += 1;
            flags_buf[i] = fl;
            i += 1;
            if (fl & 8 != 0) {
                if (p >= d.len) return;
                var rep = d[p];
                p += 1;
                while (rep > 0 and i < n_points) : (rep -= 1) {
                    flags_buf[i] = fl;
                    i += 1;
                }
            }
        }
        inline for (.{ .{ &xs, 2, 16 }, .{ &ys, 4, 32 } }) |axis| {
            var v: i32 = 0;
            for (0..n_points) |k| {
                const fl = flags_buf[k];
                if (fl & axis[1] != 0) {
                    const dv: i32 = if (p < d.len) d[p] else 0;
                    p += 1;
                    v += if (fl & axis[2] != 0) dv else -dv;
                } else if (fl & axis[2] == 0) {
                    v += bei16(d, p);
                    p += 2;
                }
                axis[0][k] = @floatFromInt(v);
            }
        }
        var start: usize = 0;
        for (0..contours) |cidx| {
            const end: usize = be16(d, ends + 2 * cidx);
            if (end < start or end >= n_points) return;
            contour(xs[start .. end + 1], ys[start .. end + 1], flags_buf[start .. end + 1], m, sink);
            start = end + 1;
        }
    }

    fn composite(f: *const Font, at_in: usize, m: [6]f32, sink: Sink, depth: u8) void {
        const d = f.data;
        var at = at_in;
        while (true) {
            const flags = be16(d, at);
            const g = be16(d, at + 2);
            at += 4;
            var dx: f32 = 0;
            var dy: f32 = 0;
            if (flags & 1 != 0) {
                dx = @floatFromInt(bei16(d, at));
                dy = @floatFromInt(bei16(d, at + 2));
                at += 4;
            } else {
                dx = @floatFromInt(@as(i8, @bitCast(d[at])));
                dy = @floatFromInt(@as(i8, @bitCast(d[at + 1])));
                at += 2;
            }
            var t: [4]f32 = .{ 1, 0, 0, 1 };
            const f2 = struct {
                fn v(data: []const u8, o: usize) f32 {
                    return @as(f32, @floatFromInt(bei16(data, o))) / 16384;
                }
            }.v;
            if (flags & 8 != 0) {
                t[0] = f2(d, at);
                t[3] = t[0];
                at += 2;
            } else if (flags & 0x40 != 0) {
                t[0] = f2(d, at);
                t[3] = f2(d, at + 2);
                at += 4;
            } else if (flags & 0x80 != 0) {
                t = .{ f2(d, at), f2(d, at + 2), f2(d, at + 4), f2(d, at + 6) };
                at += 8;
            }
            // Point-matched components (ARGS_ARE_XY_VALUES unset) are rare: offset 0.
            if (flags & 2 == 0) {
                dx = 0;
                dy = 0;
            }
            // The component's transform, then the outer one.
            const cm: [6]f32 = .{
                m[0] * t[0] + m[2] * t[1],
                m[1] * t[0] + m[3] * t[1],
                m[0] * t[2] + m[2] * t[3],
                m[1] * t[2] + m[3] * t[3],
                m[0] * dx + m[2] * dy + m[4],
                m[1] * dx + m[3] * dy + m[5],
            };
            f.outlineDepth(g, cm, sink, depth + 1);
            if (flags & 0x20 == 0) break;
        }
    }
};

/// One closed contour of on- and off-curve points (off-curve points
/// between two others imply an on-curve point midway).
fn contour(xs: []const f32, ys: []const f32, flags: []const u8, m: [6]f32, sink: Sink) void {
    const n = xs.len;
    if (n == 0) return;
    const T = struct {
        fn x(mm: [6]f32, px: f32, py: f32) f32 {
            return mm[0] * px + mm[2] * py + mm[4];
        }
        fn y(mm: [6]f32, px: f32, py: f32) f32 {
            return mm[1] * px + mm[3] * py + mm[5];
        }
    };
    const on = struct {
        fn f(fl: []const u8, k: usize) bool {
            return fl[k] & 1 != 0;
        }
    }.f;
    // Start at an on-curve point, or midway between two off-curve ones.
    var first: usize = 0;
    var sx: f32 = undefined;
    var sy: f32 = undefined;
    while (first < n and !on(flags, first)) first += 1;
    if (first == n) {
        sx = (xs[0] + xs[n - 1]) / 2;
        sy = (ys[0] + ys[n - 1]) / 2;
        first = 0;
    } else {
        sx = xs[first];
        sy = ys[first];
        first += 1;
    }
    sink.move(sink.ctx, T.x(m, sx, sy), T.y(m, sx, sy));
    var ctrl: ?[2]f32 = null;
    for (0..n) |k| {
        const idx = (first + k) % n;
        const px = xs[idx];
        const py = ys[idx];
        if (on(flags, idx)) {
            if (ctrl) |cp| sink.quad(sink.ctx, T.x(m, cp[0], cp[1]), T.y(m, cp[0], cp[1]), T.x(m, px, py), T.y(m, px, py)) else sink.line(sink.ctx, T.x(m, px, py), T.y(m, px, py));
            ctrl = null;
        } else {
            if (ctrl) |cp| {
                const mx = (cp[0] + px) / 2;
                const my = (cp[1] + py) / 2;
                sink.quad(sink.ctx, T.x(m, cp[0], cp[1]), T.y(m, cp[0], cp[1]), T.x(m, mx, my), T.y(m, mx, my));
            }
            ctrl = .{ px, py };
        }
    }
    if (ctrl) |cp| sink.quad(sink.ctx, T.x(m, cp[0], cp[1]), T.y(m, cp[0], cp[1]), T.x(m, sx, sy), T.y(m, sx, sy)) else sink.line(sink.ctx, T.x(m, sx, sy), T.y(m, sx, sy));
    sink.close(sink.ctx);
}

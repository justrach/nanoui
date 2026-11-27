//! OpenType's other outlines: the `CFF ` and `CFF2` tables and their Type 2
//! charstrings, read into the same paths as TrueType's. A CFF2 font draws its
//! default instance: `blend` keeps each default and drops the deltas. Cubic curves become quadratics, which is
//! what the rasterizer takes. A font from the web can ask for anything here,
//! so subroutines nest only so deep and a glyph only takes so many steps.
const std = @import("std");

pub const max_stack = 513;
pub const max_depth = 10;
pub const max_steps = 200_000;

pub fn be16(d: []const u8, at: usize) ?u16 {
    if (at > d.len or d.len - at < 2) return null;
    return std.mem.readInt(u16, d[at..][0..2], .big);
}

/// An INDEX: `count` pieces of data after a table of offsets.
pub const Index = struct {
    d: []const u8 = "",
    count: u32 = 0,
    off_size: u8 = 1,
    /// Where the offsets start, and the byte offsets count from.
    offsets: usize = 0,
    base: usize = 0,
    /// The first byte after it.
    end: usize = 0,

    fn read(d: []const u8, at: usize) ?Index {
        return readSized(d, at, 2);
    }

    /// CFF2's, whose count takes four bytes.
    fn read2(d: []const u8, at: usize) ?Index {
        return readSized(d, at, 4);
    }

    fn readSized(d: []const u8, at: usize, count_size: usize) ?Index {
        if (at > d.len or d.len - at < count_size) return null;
        var n: u32 = 0;
        for (d[at..][0..count_size]) |b| n = (n << 8) | b;
        const head = at + count_size;
        if (n == 0) return .{ .d = d, .end = head };
        if (head == d.len) return null;
        const off_size = d[head];
        if (off_size < 1 or off_size > 4) return null;
        var ix: Index = .{ .d = d, .count = n, .off_size = off_size, .offsets = head + 1 };
        // There are count + 1 offset slots. Check before computing their size.
        if (n >= (d.len - ix.offsets) / off_size) return null;
        ix.base = ix.offsets + (@as(usize, n) + 1) * off_size - 1;
        const last = ix.offset(n) orelse return null;
        if (last == 0 or last > d.len - ix.base) return null;
        ix.end = ix.base + last;
        return ix;
    }

    fn offset(ix: *const Index, i: usize) ?usize {
        const at = ix.offsets + i * ix.off_size;
        if (at + ix.off_size > ix.d.len) return null;
        var v: usize = 0;
        for (ix.d[at..][0..ix.off_size]) |b| v = (v << 8) | b;
        return v;
    }

    pub fn get(ix: *const Index, i: usize) ?[]const u8 {
        if (i >= ix.count) return null;
        const a = ix.offset(i) orelse return null;
        const b = ix.offset(i + 1) orelse return null;
        if (a == 0 or b < a or b > ix.end - ix.base) return null;
        return ix.d[ix.base + a .. ix.base + b];
    }
};

/// The operands of each operator of a DICT, as they are handed out.
fn dictFind(dict: []const u8, op: u16, out: []f64) usize {
    var stack: [48]f64 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < dict.len) {
        const b0 = dict[i];
        i += 1;
        // CFF2's blend: the defaults it keeps are never an offset read here.
        if (b0 == 23) {
            n = 0;
            continue;
        }
        // 22 is CFF2's vsindex and 24 its vstore; both are reserved in CFF.
        if (b0 <= 22 or b0 == 24) {
            var code: u16 = b0;
            if (b0 == 12) {
                if (i >= dict.len) return 0;
                code = 0x0c00 | @as(u16, dict[i]);
                i += 1;
            }
            if (code == op) {
                const m = @min(n, out.len);
                @memcpy(out[0..m], stack[0..m]);
                return m;
            }
            n = 0;
            continue;
        }
        const v: f64 = switch (b0) {
            28 => blk: {
                const x = be16(dict, i) orelse return 0;
                i += 2;
                break :blk @floatFromInt(@as(i16, @bitCast(x)));
            },
            29 => blk: {
                if (i + 4 > dict.len) return 0;
                const x = std.mem.readInt(i32, dict[i..][0..4], .big);
                i += 4;
                break :blk @floatFromInt(x);
            },
            30 => blk: {
                // A real number in nibbles: only ever an offset's neighbour here.
                while (i < dict.len) : (i += 1) if (dict[i] & 0x0f == 0x0f or dict[i] >> 4 == 0x0f) break;
                i += 1;
                break :blk 0;
            },
            32...246 => @floatFromInt(@as(i32, b0) - 139),
            247...250 => blk: {
                if (i >= dict.len) return 0;
                const x = (@as(i32, b0) - 247) * 256 + dict[i] + 108;
                i += 1;
                break :blk @floatFromInt(x);
            },
            251...254 => blk: {
                if (i >= dict.len) return 0;
                const x = -(@as(i32, b0) - 251) * 256 - @as(i32, dict[i]) - 108;
                i += 1;
                break :blk @floatFromInt(x);
            },
            else => 0,
        };
        if (n < stack.len) {
            stack[n] = v;
            n += 1;
        }
    }
    return 0;
}

fn usizeOf(v: f64) ?usize {
    if (!(v >= 0) or v > 1 << 31) return null;
    return @intFromFloat(v);
}

pub fn bias(count: u32) i32 {
    return if (count < 1240) 107 else if (count < 33900) 1131 else 32768;
}

pub const Sink = @import("font.zig").Sink;

pub const Cff = struct {
    data: []const u8 = "",
    /// 1 for `CFF `, 2 for `CFF2`.
    version: u8 = 1,
    chars: Index = .{},
    global: Index = .{},
    /// Local subroutines of each font dict (one, unless a CID font). Noto
    /// CJK has about twenty font dicts.
    local: [64]Index = @splat(.{}),
    /// CFF2: each font dict's default vsindex.
    vsindex: [64]u16 = @splat(0),
    local_count: u8 = 0,
    fd_select: usize = 0,
    /// The length-delimited CFF2 ItemVariationStore, when present.
    variation_store: []const u8 = "",

    /// Reads the table, null when it's not one this reads.
    pub fn init(d: []const u8) ?Cff {
        if (d.len >= 5 and d[0] == 2) return init2(d);
        if (d.len < 4 or d[0] != 1) return null;
        const names = Index.read(d, d[2]) orelse return null;
        const tops = Index.read(d, names.end) orelse return null;
        const strings = Index.read(d, tops.end) orelse return null;
        const global = Index.read(d, strings.end) orelse return null;
        const top = tops.get(0) orelse return null;
        var args: [2]f64 = undefined;
        if (dictFind(top, 17, &args) != 1) return null;
        const chars = Index.read(d, usizeOf(args[0]) orelse return null) orelse return null;
        var c: Cff = .{ .data = d, .chars = chars, .global = global };
        if (dictFind(top, 0x0c24, &args) == 1) {
            // A CID font: a private dict per font dict.
            const fds = Index.read(d, usizeOf(args[0]) orelse return null) orelse return null;
            if (dictFind(top, 0x0c25, &args) == 1) c.fd_select = usizeOf(args[0]) orelse 0;
            var i: usize = 0;
            while (i < fds.count and i < c.local.len) : (i += 1) {
                c.local[i] = readLocal(d, fds.get(i) orelse "");
            }
            c.local_count = @intCast(@min(fds.count, c.local.len));
        } else {
            c.local[0] = readLocal(d, top);
            c.local_count = 1;
        }
        return c;
    }

    fn init2(d: []const u8) ?Cff {
        const head = d[2];
        const top_len = be16(d, 3) orelse return null;
        if (head < 5 or head > d.len or top_len > d.len - head) return null;
        const top = d[head..][0..top_len];
        const global = Index.read2(d, head + top_len) orelse return null;
        var args: [2]f64 = undefined;
        if (dictFind(top, 17, &args) != 1) return null;
        const chars = Index.read2(d, usizeOf(args[0]) orelse return null) orelse return null;
        var c: Cff = .{ .data = d, .version = 2, .chars = chars, .global = global };
        if (dictFind(top, 24, &args) == 1) c.variation_store = variationStore(d, usizeOf(args[0]) orelse 0);
        // CFF2 always has font dicts; FDSelect only when there are several.
        if (dictFind(top, 0x0c24, &args) != 1) return null;
        const fds = Index.read2(d, usizeOf(args[0]) orelse return null) orelse return null;
        if (dictFind(top, 0x0c25, &args) == 1) c.fd_select = usizeOf(args[0]) orelse 0;
        var i: usize = 0;
        while (i < fds.count and i < c.local.len) : (i += 1) {
            const fd = fds.get(i) orelse "";
            c.local[i] = readLocal2(d, fd, &c.vsindex[i]);
        }
        c.local_count = @intCast(@min(fds.count, c.local.len));
        return c;
    }

    fn variationStore(data: []const u8, at: usize) []const u8 {
        if (at == 0) return "";
        const length = be16(data, at) orelse return "";
        const tail = data[at + 2 ..];
        if (length > tail.len) return "";
        return tail[0..length];
    }

    fn readLocal(d: []const u8, dict: []const u8) Index {
        const private = privateOf(d, dict) orelse return .{};
        var sub: [1]f64 = undefined;
        if (dictFind(private.dict, 19, &sub) != 1) return .{};
        const off = usizeOf(sub[0]) orelse return .{};
        if (off > d.len - private.at) return .{};
        return Index.read(d, private.at + off) orelse .{};
    }

    fn readLocal2(d: []const u8, dict: []const u8, vsindex: *u16) Index {
        const private = privateOf(d, dict) orelse return .{};
        var sub: [1]f64 = undefined;
        if (dictFind(private.dict, 22, &sub) == 1) vsindex.* = @intCast(@min(usizeOf(sub[0]) orelse 0, 0xffff));
        if (dictFind(private.dict, 19, &sub) != 1) return .{};
        const off = usizeOf(sub[0]) orelse return .{};
        if (off > d.len - private.at) return .{};
        return Index.read2(d, private.at + off) orelse .{};
    }

    const Private = struct { dict: []const u8, at: usize };

    fn privateOf(d: []const u8, dict: []const u8) ?Private {
        var args: [2]f64 = undefined;
        if (dictFind(dict, 18, &args) != 2) return null;
        const size = usizeOf(args[0]) orelse return null;
        const at = usizeOf(args[1]) orelse return null;
        if (at > d.len or size > d.len - at) return null;
        return .{ .dict = d[at..][0..size], .at = at };
    }

    pub fn regionCount(c: *const Cff, vsindex: u16) ?usize {
        const store = c.variation_store;
        if (be16(store, 0) != 1) return null;
        const count = be16(store, 6) orelse return null;
        if (vsindex >= count or count > (store.len - 8) / 4) return null;
        const entry = 8 + 4 * @as(usize, vsindex);
        const offset = std.mem.readInt(u32, store[entry..][0..4], .big);
        if (offset < 8 + 4 * @as(usize, count) or offset > store.len) return null;
        const record = store[offset..];
        if (be16(record, 0) != 0 or be16(record, 2) != 0) return null;
        const regions = be16(record, 4) orelse return null;
        if (regions > (record.len - 6) / 2) return null;
        return regions;
    }

    fn fdOf(c: *const Cff, g: u16) u16 {
        if (c.fd_select == 0) return 0;
        const d = c.data;
        const at = c.fd_select;
        if (at >= d.len) return 0;
        if (d[at] == 0) return if (at + 1 + g < d.len) d[at + 1 + g] else 0;
        if (d[at] == 4) return fdOf4(d, at, g);
        if (d[at] != 3) return 0;
        const n = be16(d, at + 1) orelse return 0;
        // Ranges in glyph order: the last that starts at or before it.
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const first = be16(d, at + 3 + 3 * mid) orelse return 0;
            if (first <= g) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return 0;
        const rec = at + 3 + 3 * (lo - 1);
        return if (rec + 2 < d.len) d[rec + 2] else 0;
    }

    /// FDSelect format 4 (CFF2): 32-bit ranges with 16-bit font dicts.
    fn fdOf4(d: []const u8, at: usize, g: u16) u16 {
        if (at > d.len or d.len - at < 5) return 0;
        const n = std.mem.readInt(u32, d[at + 1 ..][0..4], .big);
        if (n > (d.len - at - 5) / 6) return 0;
        var lo: usize = 0;
        var hi: usize = n;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const rec = at + 5 + 6 * mid;
            const first = std.mem.readInt(u32, d[rec..][0..4], .big);
            if (first <= g) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return 0;
        return be16(d, at + 5 + 6 * (lo - 1) + 4) orelse 0;
    }

    /// Sends a glyph's path to `sink`, transformed by `m` as `Font.outline` does.
    pub fn outline(c: *const Cff, g: u16, m: [6]f32, sink: Sink) void {
        const code = c.chars.get(g) orelse return;
        const fd = c.fdOf(g);
        const known = fd < c.local_count;
        var run: Run = .{
            .c = c,
            .m = m,
            .sink = sink,
            .local = if (known) &c.local[fd] else &c.local[0],
            // CFF2 charstrings carry no width.
            .width_seen = c.version == 2,
            .vsindex = if (known) c.vsindex[fd] else 0,
        };
        run.exec(code, 0);
        run.closePath();
    }

    /// A glyph's bounds in font units (of its path's points), null when blank.
    pub fn bounds(c: *const Cff, g: u16) ?[4]f32 {
        var b: Box = .{};
        c.outline(g, .{ 1, 0, 0, 1, 0, 0 }, b.sink());
        if (b.x0 > b.x1) return null;
        return .{ b.x0, b.y0, b.x1, b.y1 };
    }

    pub fn glyphCount(c: *const Cff) u32 {
        return c.chars.count;
    }
};

const Box = @import("cff_run.zig").Box;
const Run = @import("cff_run.zig").Run;

test "CFF2 INDEX rejects a truncated offset table" {
    const bytes = [_]u8{ 0, 0, 0, 2, 4, 0, 0, 0, 1 };
    try std.testing.expectEqual(null, Index.read2(&bytes, 0));
}

test "CFF2 variation data ignores absent offsets" {
    const bytes = [_]u8{
        0, // Leading byte before the VariationStore.
        0, 12, // Length.
        0, 1, // Format.
        0, 0, 0, 7, // Region list offset.
        0, 1, // ItemVariationData count.
        0, 0, 0, 0, // Missing item offset.
    };
    const c: Cff = .{ .variation_store = Cff.variationStore(&bytes, 1) };
    try std.testing.expectEqual(@as(?usize, null), c.regionCount(0));
}

test "CFF2 variation data supports high indices within its declared length" {
    const count = 33;
    const header = 8 + 4 * count;
    var bytes: [3 + header + 8]u8 = @splat(0);
    std.mem.writeInt(u16, bytes[1..][0..2], header + 8, .big);
    const store = bytes[3..];
    std.mem.writeInt(u16, store[0..2], 1, .big);
    std.mem.writeInt(u16, store[6..8], count, .big);
    std.mem.writeInt(u32, store[8 + 4 * 32 ..][0..4], header, .big);
    std.mem.writeInt(u16, store[header + 4 ..][0..2], 1, .big);
    var c: Cff = .{ .variation_store = Cff.variationStore(&bytes, 1) };
    try std.testing.expectEqual(@as(?usize, 1), c.regionCount(32));
    try std.testing.expectEqual(@as(?usize, null), c.regionCount(33));

    std.mem.writeInt(u16, bytes[1..][0..2], header + 6, .big);
    c.variation_store = Cff.variationStore(&bytes, 1);
    try std.testing.expectEqual(@as(?usize, null), c.regionCount(32));
}

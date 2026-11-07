//! A brotli decoder (RFC 7932), for WOFF2 fonts: one whole input to one whole
//! output. Input is not trusted: whatever it holds, this returns an error
//! rather than reading or writing out of bounds, and the work is bounded by
//! the output limit and the input's length, so it cannot hang.
const std = @import("std");
const tables = @import("brotli_tables.zig");
const huff = @import("brotli_huffman.zig");

pub const Error = error{ Corrupt, TooLarge, OutOfMemory };

const BitReader = huff.BitReader;
const Tree = huff.Tree;

/// The static dictionary (RFC 7932 appendix A), from Google's brotli
/// (`c/common/dictionary.bin`).
pub const dictionary = @embedFile("data/brotli-dictionary.bin");
/// Words of each length: `1 << size_bits[len]` of them (0: none).
const size_bits = [25]u5{ 0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5 };
const offsets = blk: {
    var o: [25]u32 = undefined;
    var at: u32 = 0;
    for (size_bits, 0..) |b, len| {
        o[len] = at;
        if (b != 0) at += @as(u32, len) << b;
    }
    break :blk o;
};

/// Decompresses `input`; the output is the caller's. More than `max_out`
/// bytes is `TooLarge`.
pub fn decode(gpa: std.mem.Allocator, input: []const u8, max_out: usize) Error![]u8 {
    var d: Decoder = .{ .gpa = gpa, .r = .{ .data = input }, .max_out = max_out, .arena = .init(gpa) };
    defer d.arena.deinit();
    errdefer d.out.deinit(gpa);
    try d.run();
    return d.out.toOwnedSlice(gpa);
}

const Blocks = struct {
    types: u16 = 1,
    /// Block types as a code indexes them: the one before last, the last.
    last: [2]u16 = .{ 1, 0 },
    /// What's left of the current block; unbounded with one type.
    left: u32 = std.math.maxInt(u32),
    type_tree: Tree = .{},
    count_tree: Tree = .{},
    current: u16 = 0,
};

const Decoder = struct {
    gpa: std.mem.Allocator,
    r: BitReader,
    out: std.ArrayList(u8) = .empty,
    max_out: usize,
    /// Trees and maps of one meta-block.
    arena: std.heap.ArenaAllocator,
    window: usize = 0,
    /// The last four distances, newest last.
    dist: [4]u32 = .{ 16, 15, 11, 4 },

    fn run(d: *Decoder) Error!void {
        d.window = (@as(usize, 1) << try d.windowBits()) - 16;
        while (true) {
            _ = d.arena.reset(.retain_capacity);
            if (try d.metaBlock()) return;
        }
    }

    fn windowBits(d: *Decoder) Error!u6 {
        if (try d.r.bits(1) == 0) return 16;
        const n = try d.r.bits(3);
        if (n != 0) return @intCast(17 + n);
        const m = try d.r.bits(3);
        if (m == 1) return error.Corrupt; // the large window, not in the RFC
        if (m != 0) return @intCast(8 + m);
        return 17;
    }

    /// One meta-block; true after the last.
    fn metaBlock(d: *Decoder) Error!bool {
        const is_last = try d.r.bits(1) == 1;
        if (is_last and try d.r.bits(1) == 1) return true;
        const nibbles = try d.r.bits(2);
        if (nibbles == 3) {
            if (is_last) return error.Corrupt;
            try d.metadata();
            return false;
        }
        var mlen: u32 = 0;
        const count = nibbles + 4;
        for (0..count) |i| {
            const v = try d.r.bits(4);
            if (i + 1 == count and count > 4 and v == 0) return error.Corrupt;
            mlen |= v << @intCast(4 * i);
        }
        mlen += 1;
        if (!is_last and try d.r.bits(1) == 1) {
            try d.uncompressed(mlen);
            return false;
        }
        try d.compressed(mlen);
        return is_last;
    }

    fn metadata(d: *Decoder) Error!void {
        if (try d.r.bits(1) != 0) return error.Corrupt;
        const skip_bytes = try d.r.bits(2);
        var skip: u32 = 0;
        for (0..skip_bytes) |i| {
            const b = try d.r.bits(8);
            if (i + 1 == skip_bytes and skip_bytes > 1 and b == 0) return error.Corrupt;
            skip |= b << @intCast(8 * i);
        }
        if (skip_bytes > 0) skip += 1;
        try d.r.toByte();
        try d.r.skipBytes(skip);
    }

    fn uncompressed(d: *Decoder, n: u32) Error!void {
        try d.r.toByte();
        const bytes = try d.r.takeBytes(n);
        try d.room(n);
        d.out.appendSliceAssumeCapacity(bytes);
    }

    /// Room for `n` more bytes, within the limit.
    fn room(d: *Decoder, n: usize) Error!void {
        if (d.out.items.len + n > d.max_out) return error.TooLarge;
        try d.out.ensureUnusedCapacity(d.gpa, n);
    }

    fn blockHeader(d: *Decoder, b: *Blocks) Error!void {
        const a = d.arena.allocator();
        b.types = @intCast(try d.r.varLen8() + 1);
        if (b.types < 2) return;
        b.type_tree = try huff.read(a, &d.r, @as(u32, b.types) + 2);
        b.count_tree = try huff.read(a, &d.r, 26);
        b.left = try readCount(&d.r, &b.count_tree);
    }

    fn switchBlock(d: *Decoder, b: *Blocks) Error!void {
        const code = try b.type_tree.read(&d.r);
        var t: u32 = switch (code) {
            0 => b.last[0],
            1 => @as(u32, b.last[1]) + 1,
            else => code - 2,
        };
        if (t >= b.types) t -= b.types;
        if (t >= b.types) return error.Corrupt;
        b.last = .{ b.last[1], @intCast(t) };
        b.current = @intCast(t);
        b.left = try readCount(&d.r, &b.count_tree);
    }

    fn contextMap(d: *Decoder, size: usize, trees: u32) Error![]u8 {
        const a = d.arena.allocator();
        const map = try a.alloc(u8, size);
        if (trees < 2) {
            @memset(map, 0);
            return map;
        }
        const rle_max: u32 = if (try d.r.bits(1) == 1) try d.r.bits(4) + 1 else 0;
        const tree = try huff.read(a, &d.r, trees + rle_max);
        var i: usize = 0;
        while (i < size) {
            const code = try tree.read(&d.r);
            if (code == 0) {
                map[i] = 0;
                i += 1;
            } else if (code <= rle_max) {
                const run_len = (@as(usize, 1) << @intCast(code)) + try d.r.bits(@intCast(code));
                if (i + run_len > size) return error.Corrupt;
                @memset(map[i..][0..run_len], 0);
                i += run_len;
            } else {
                const v = code - rle_max;
                if (v >= trees) return error.Corrupt;
                map[i] = @intCast(v);
                i += 1;
            }
        }
        if (try d.r.bits(1) == 1) inverseMoveToFront(map);
        return map;
    }

    fn compressed(d: *Decoder, mlen_in: u32) Error!void {
        const a = d.arena.allocator();
        var mlen = mlen_in;
        var lit: Blocks = .{};
        var cmd: Blocks = .{};
        var dst: Blocks = .{};
        try d.blockHeader(&lit);
        try d.blockHeader(&cmd);
        try d.blockHeader(&dst);
        const npostfix: u5 = @intCast(try d.r.bits(2));
        const ndirect: u32 = try d.r.bits(4) << npostfix;
        const modes = try a.alloc(u8, lit.types);
        for (modes) |*m| m.* = @intCast(try d.r.bits(2));
        const lit_trees = try d.r.varLen8() + 1;
        const lit_map = try d.contextMap(@as(usize, lit.types) * 64, lit_trees);
        const dist_trees = try d.r.varLen8() + 1;
        const dist_map = try d.contextMap(@as(usize, dst.types) * 4, dist_trees);
        const lit_tree = try readTrees(a, &d.r, lit_trees, 256);
        const cmd_tree = try readTrees(a, &d.r, cmd.types, 704);
        const dist_alphabet = 16 + ndirect + (@as(u32, 48) << npostfix);
        const dist_tree = try readTrees(a, &d.r, dist_trees, dist_alphabet);

        while (mlen > 0) {
            if (cmd.types > 1 and cmd.left == 0) try d.switchBlock(&cmd);
            cmd.left -%= 1;
            const c = try cmd_tree[cmd.current].read(&d.r);
            const lens = try commandLengths(&d.r, c);
            if (lens.insert > mlen) return error.Corrupt;
            try d.room(lens.insert);
            for (0..lens.insert) |_| {
                if (lit.types > 1 and lit.left == 0) try d.switchBlock(&lit);
                lit.left -%= 1;
                const out = d.out.items;
                const p1: u8 = if (out.len > 0) out[out.len - 1] else 0;
                const p2: u8 = if (out.len > 1) out[out.len - 2] else 0;
                const mode = modes[lit.current];
                const ctx = tables.context_lookup[@as(usize, mode) * 512 + p1] | tables.context_lookup[@as(usize, mode) * 512 + 256 + p2];
                const t = lit_map[@as(usize, lit.current) * 64 + ctx];
                d.out.appendAssumeCapacity(@intCast(try lit_tree[t].read(&d.r)));
            }
            mlen -= lens.insert;
            if (mlen == 0) break;

            var code: u32 = 0;
            if (!lens.implicit_zero) {
                if (dst.types > 1 and dst.left == 0) try d.switchBlock(&dst);
                dst.left -%= 1;
                const ctx: usize = if (lens.copy <= 4) lens.copy - 2 else 3;
                const t = dist_map[@as(usize, dst.current) * 4 + ctx];
                code = try dist_tree[t].read(&d.r);
            }
            const distance = try d.distanceOf(code, ndirect, npostfix);
            const reach = @min(d.window, d.out.items.len);
            if (distance > reach) {
                const made = try d.dictionaryWord(lens.copy, distance - reach - 1);
                if (made > mlen) return error.Corrupt;
                mlen -= made;
                continue;
            }
            if (code != 0) {
                d.dist = .{ d.dist[1], d.dist[2], d.dist[3], @intCast(distance) };
            }
            if (lens.copy > mlen) return error.Corrupt;
            try d.room(lens.copy);
            d.copyBack(distance, lens.copy);
            mlen -= lens.copy;
        }
    }

    fn copyBack(d: *Decoder, distance: usize, n: usize) void {
        const start = d.out.items.len;
        d.out.items.len = start + n;
        const out = d.out.items;
        if (distance >= n) {
            @memcpy(out[start..][0..n], out[start - distance..][0..n]);
        } else {
            for (0..n) |i| out[start + i] = out[start + i - distance];
        }
    }

    fn distanceOf(d: *Decoder, code: u32, ndirect: u32, npostfix: u5) Error!usize {
        if (code < 16) {
            const which = [16]u2{ 3, 2, 1, 0, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2 };
            const delta = [16]i32{ 0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3 };
            const v = @as(i64, d.dist[which[code]]) + delta[code];
            if (v <= 0) return error.Corrupt;
            return @intCast(v);
        }
        if (code < 16 + ndirect) return code - 15;
        const dc = code - 16 - ndirect;
        const ndistbits: u5 = @intCast(1 + (dc >> (npostfix + 1)));
        const hcode = dc >> npostfix;
        const lcode = dc & ((@as(u32, 1) << npostfix) - 1);
        const offset = (@as(u64, 2 + (hcode & 1)) << ndistbits) - 4;
        const extra: u64 = try d.r.bits(ndistbits);
        const v = ((offset + extra) << npostfix) + lcode + ndirect + 1;
        if (v > std.math.maxInt(u32)) return error.Corrupt;
        return @intCast(v);
    }

    /// Appends a transformed word of the static dictionary; how long it was.
    fn dictionaryWord(d: *Decoder, len: u32, id: usize) Error!u32 {
        if (len < 4 or len > 24) return error.Corrupt;
        const nbits = size_bits[len];
        if (nbits == 0) return error.Corrupt;
        const index = id & ((@as(usize, 1) << nbits) - 1);
        const transform = id >> nbits;
        if (transform >= tables.transforms.len) return error.Corrupt;
        const word = dictionary[offsets[len] + index * len..][0..len];
        const t = tables.transforms[transform];
        const prefix = stringOf(t[0]);
        const suffix = stringOf(t[2]);
        var body: []const u8 = word;
        if (t[1] >= 1 and t[1] <= 9) body = word[0 .. word.len - @min(word.len, t[1])];
        if (t[1] >= 12) body = word[@min(word.len, t[1] - 11)..];
        const total = prefix.len + body.len + suffix.len;
        try d.room(total);
        d.out.appendSliceAssumeCapacity(prefix);
        const at = d.out.items.len;
        d.out.appendSliceAssumeCapacity(body);
        const made = d.out.items[at..];
        if (t[1] == 10) {
            _ = toUpper(made);
        } else if (t[1] == 11) {
            var i: usize = 0;
            while (i < made.len) i += toUpper(made[i..]);
        }
        d.out.appendSliceAssumeCapacity(suffix);
        return @intCast(total);
    }
};

fn stringOf(i: u8) []const u8 {
    const at = tables.prefix_suffix_map[i];
    const n = tables.prefix_suffix[at];
    return tables.prefix_suffix[at + 1..][0..n];
}

/// The RFC's simple uppercasing of the character at `p`'s start; its length.
fn toUpper(p: []u8) usize {
    if (p[0] < 192) {
        if (p[0] >= 'a' and p[0] <= 'z') p[0] ^= 32;
        return 1;
    }
    if (p[0] < 224) {
        if (p.len > 1) p[1] ^= 32;
        return 2;
    }
    if (p.len > 2) p[2] ^= 5;
    return 3;
}

fn inverseMoveToFront(map: []u8) void {
    var mtf: [256]u8 = undefined;
    for (&mtf, 0..) |*m, i| m.* = @intCast(i);
    for (map) |*v| {
        const i = v.*;
        const value = mtf[i];
        v.* = value;
        std.mem.copyBackwards(u8, mtf[1 .. @as(usize, i) + 1], mtf[0..i]);
        mtf[0] = value;
    }
}

fn readTrees(a: std.mem.Allocator, r: *BitReader, n: u32, alphabet: u32) Error![]Tree {
    const trees = try a.alloc(Tree, n);
    for (trees) |*t| t.* = try huff.read(a, r, alphabet);
    return trees;
}

fn readCount(r: *BitReader, tree: *const Tree) Error!u32 {
    const base = [26]u16{ 1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625 };
    const extra = [26]u5{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };
    const code = try tree.read(r);
    if (code >= base.len) return error.Corrupt;
    return @as(u32, base[code]) + try r.bits(extra[code]);
}

const Lengths = struct { insert: u32, copy: u32, implicit_zero: bool };

fn commandLengths(r: *BitReader, cmd: u32) Error!Lengths {
    const insert_range = [9]u8{ 0, 0, 8, 8, 0, 16, 8, 16, 16 };
    const copy_range = [9]u8{ 0, 8, 0, 8, 16, 0, 16, 8, 16 };
    const insert_base = [24]u16{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };
    const insert_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
    const copy_base = [24]u16{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };
    const copy_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };
    if (cmd >= 704) return error.Corrupt;
    // The two cells below 128 take their distance from the last one's code 0.
    const cell = cmd >> 6;
    const range = if (cell >= 2) cell - 2 else cell;
    const ic = insert_range[range] | ((cmd >> 3) & 7);
    const cc = copy_range[range] | (cmd & 7);
    const insert = @as(u32, insert_base[ic]) + try r.bits(insert_extra[ic]);
    const copy = @as(u32, copy_base[cc]) + try r.bits(copy_extra[cc]);
    return .{ .insert = insert, .copy = copy, .implicit_zero = cmd < 128 };
}

test {
    _ = @import("brotli_tests.zig");
}

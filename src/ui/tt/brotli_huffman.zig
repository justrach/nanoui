//! Brotli's bit stream and prefix codes (RFC 7932, sections 3 and 9): bits read
//! from the low end of each byte, and codes read through a two-level table.
//! Every code the format lets through is complete, which is checked here, so
//! a table has no holes and a read can only run out of input.
const std = @import("std");
const Error = @import("brotli.zig").Error;

pub const BitReader = struct {
    data: []const u8,
    at: usize = 0,
    buf: u64 = 0,
    have: u7 = 0,

    fn fill(r: *BitReader) void {
        while (r.have <= 56 and r.at < r.data.len) {
            r.buf |= @as(u64, r.data[r.at]) << @intCast(r.have);
            r.at += 1;
            r.have += 8;
        }
    }

    /// The next `n` bits (up to 24); running out is corrupt.
    pub fn bits(r: *BitReader, n: u5) Error!u32 {
        if (n == 0) return 0;
        if (r.have < n) {
            r.fill();
            if (r.have < n) return error.Corrupt;
        }
        const v: u32 = @truncate(r.buf & ((@as(u64, 1) << n) - 1));
        r.buf >>= n;
        r.have -= n;
        return v;
    }

    /// Up to `n` bits without taking them; zeros past the end of the input.
    fn peek(r: *BitReader, n: u5) u32 {
        if (r.have < n) r.fill();
        return @truncate(r.buf & ((@as(u64, 1) << n) - 1));
    }

    fn drop(r: *BitReader, n: u5) Error!void {
        if (n > r.have) return error.Corrupt;
        r.buf >>= n;
        r.have -= n;
    }

    /// To the next byte boundary; the bits skipped must be zero.
    pub fn toByte(r: *BitReader) Error!void {
        if (try r.bits(@intCast(r.have % 8)) != 0) return error.Corrupt;
    }

    /// `n` whole bytes, at a byte boundary.
    pub fn takeBytes(r: *BitReader, n: usize) Error![]const u8 {
        // Bytes read ahead go back: they're whole, as `toByte` left it.
        const back = r.have / 8;
        r.at -= back;
        r.have = 0;
        r.buf = 0;
        if (n > r.data.len - r.at) return error.Corrupt;
        const out = r.data[r.at..][0..n];
        r.at += n;
        return out;
    }

    pub fn skipBytes(r: *BitReader, n: usize) Error!void {
        _ = try r.takeBytes(n);
    }

    /// A number from 0 to 255 (the RFC's variable-length code).
    pub fn varLen8(r: *BitReader) Error!u32 {
        if (try r.bits(1) == 0) return 0;
        const n: u5 = @intCast(try r.bits(3));
        if (n == 0) return 1;
        return (@as(u32, 1) << n) + try r.bits(n);
    }
};

const root_bits = 8;

/// One table slot: for a code, its length and symbol; in the root table for a
/// longer code, `len` above `root_bits` and where its second-level table is.
const Entry = packed struct(u32) { len: u8, value: u24 };

pub const Tree = struct {
    table: []const Entry = &.{},
    root: u5 = 0,

    pub fn read(t: *const Tree, r: *BitReader) Error!u32 {
        if (t.table.len == 0) return error.Corrupt;
        const window = r.peek(15);
        var e = t.table[window & ((@as(u32, 1) << t.root) - 1)];
        if (e.len <= t.root) {
            try r.drop(@intCast(e.len));
            return e.value;
        }
        const sub = (window >> t.root) & ((@as(u32, 1) << @intCast(e.len - t.root)) - 1);
        e = t.table[e.value + sub];
        try r.drop(@intCast(e.len));
        return e.value;
    }
};

/// Reads a prefix code over `alphabet` symbols.
pub fn read(a: std.mem.Allocator, r: *BitReader, alphabet: u32) Error!Tree {
    if (alphabet == 0 or alphabet > 1 << 16) return error.Corrupt;
    const lens = try a.alloc(u8, alphabet);
    @memset(lens, 0);
    const hskip = try r.bits(2);
    if (hskip == 1) {
        try simple(r, lens, alphabet);
    } else {
        try complex(r, lens, hskip);
    }
    return build(a, lens);
}

fn simple(r: *BitReader, lens: []u8, alphabet: u32) Error!void {
    const nsym = try r.bits(2) + 1;
    const width: u5 = @intCast(32 - @clz(alphabet - 1));
    var syms: [4]u32 = undefined;
    for (syms[0..nsym], 0..) |*s, i| {
        s.* = try r.bits(width);
        if (s.* >= alphabet) return error.Corrupt;
        for (syms[0..i]) |o| if (o == s.*) return error.Corrupt;
    }
    switch (nsym) {
        1 => lens[syms[0]] = 0xff, // no bits at all
        2 => {
            lens[syms[0]] = 1;
            lens[syms[1]] = 1;
        },
        3 => {
            lens[syms[0]] = 1;
            lens[syms[1]] = 2;
            lens[syms[2]] = 2;
        },
        else => if (try r.bits(1) == 0) {
            for (syms) |s| lens[s] = 2;
        } else {
            lens[syms[0]] = 1;
            lens[syms[1]] = 2;
            lens[syms[2]] = 3;
            lens[syms[3]] = 3;
        },
    }
}

fn complex(r: *BitReader, lens: []u8, hskip: u32) Error!void {
    const order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const prefix_len = [16]u5{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };
    const prefix_value = [16]u8{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };
    var code_lens: [18]u8 = @splat(0);
    var space: i32 = 32;
    var used: u32 = 0;
    var i: usize = hskip;
    while (i < order.len and space > 0) : (i += 1) {
        const ix = r.peek(4);
        try r.drop(prefix_len[ix]);
        const v = prefix_value[ix];
        code_lens[order[i]] = v;
        if (v != 0) {
            space -= @as(i32, 32) >> @intCast(v);
            used += 1;
        }
    }
    if (used != 1 and space != 0) return error.Corrupt;
    if (used == 1) {
        for (&code_lens) |*v| {
            if (v.* != 0) v.* = 0xff;
        }
    }
    var scratch: [64]Entry = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&scratch));
    const code_tree = try build(fba.allocator(), &code_lens);

    var symbol: usize = 0;
    var prev: u8 = 8;
    var repeat: u32 = 0;
    var repeat_len: u8 = 0;
    var room: i32 = 32768;
    while (symbol < lens.len and room > 0) {
        const code = try code_tree.read(r);
        if (code < 16) {
            repeat = 0;
            lens[symbol] = @intCast(code);
            symbol += 1;
            if (code != 0) {
                prev = @intCast(code);
                room -= @as(i32, 32768) >> @intCast(code);
            }
            continue;
        }
        const extra: u5 = @intCast(code - 14);
        const new_len: u8 = if (code == 16) prev else 0;
        if (repeat_len != new_len) {
            repeat = 0;
            repeat_len = new_len;
        }
        const old = repeat;
        if (repeat > 0) {
            repeat -= 2;
            if (repeat > lens.len) return error.Corrupt;
            repeat <<= extra;
        }
        repeat += try r.bits(extra) + 3;
        const delta = repeat - old;
        if (symbol + delta > lens.len) return error.Corrupt;
        @memset(lens[symbol..][0..delta], repeat_len);
        symbol += delta;
        if (repeat_len != 0) room -= @as(i32, @intCast(delta)) << @intCast(15 - repeat_len);
    }
    if (room != 0) return error.Corrupt;
}

fn reverse(code: u32, len: u32) u32 {
    return @bitReverse(code) >> @intCast(32 - len);
}

/// The table of a code given each symbol's length (0xff: the only symbol,
/// taking no bits). Lengths past what a complete code allows are refused.
fn build(a: std.mem.Allocator, lens: []const u8) Error!Tree {
    var count: [16]u32 = @splat(0);
    var max: u32 = 0;
    for (lens, 0..) |l, sym| {
        if (l == 0xff) {
            const one = try a.alloc(Entry, 1);
            one[0] = .{ .len = 0, .value = @intCast(sym) };
            return .{ .table = one, .root = 0 };
        }
        if (l > 15) return error.Corrupt;
        if (l != 0) {
            count[l] += 1;
            max = @max(max, l);
        }
    }
    if (max == 0) return error.Corrupt;
    // The first code of each length, as in RFC 1951; a complete code ends exactly.
    var next: [17]u32 = @splat(0);
    var code: u32 = 0;
    for (1..16) |l| {
        code = (code + count[l - 1]) << 1;
        if (l == 1) code = 0;
        next[l] = code;
        if (code + count[l] > (@as(u32, 1) << @intCast(l))) return error.Corrupt;
    }
    const root: u5 = @intCast(@min(max, root_bits));
    const root_size = @as(u32, 1) << root;

    // How long each first-level slot's second-level table must be.
    var sub_bits: [1 << root_bits]u8 = @splat(0);
    var probe = next;
    if (max > root_bits) for (lens) |l| {
        if (l <= root_bits) {
            if (l != 0) probe[l] += 1;
            continue;
        }
        const rev = reverse(probe[l], l);
        probe[l] += 1;
        const slot = rev & (root_size - 1);
        sub_bits[slot] = @max(sub_bits[slot], l - root_bits);
    };
    var total: u32 = root_size;
    var sub_at: [1 << root_bits]u32 = @splat(0);
    for (sub_bits, 0..) |b, slot| if (b != 0) {
        sub_at[slot] = total;
        total += @as(u32, 1) << @intCast(b);
    };
    const table = try a.alloc(Entry, total);
    @memset(table, .{ .len = 0xff, .value = 0 });
    for (sub_bits, 0..) |b, slot| if (b != 0) {
        table[slot] = .{ .len = root + b, .value = @intCast(sub_at[slot]) };
    };
    for (lens, 0..) |l, sym| {
        if (l == 0) continue;
        const rev = reverse(next[l], l);
        next[l] += 1;
        if (l <= root) {
            const step = @as(u32, 1) << @intCast(l);
            var i = rev;
            while (i < root_size) : (i += step) table[i] = .{ .len = l, .value = @intCast(sym) };
        } else {
            const slot = rev & (root_size - 1);
            const bits_left: u32 = sub_bits[slot];
            const step = @as(u32, 1) << @intCast(l - root);
            var i = rev >> root;
            while (i < (@as(u32, 1) << @intCast(bits_left))) : (i += step) table[sub_at[slot] + i] = .{ .len = l, .value = @intCast(sym) };
        }
    }
    for (table) |e| if (e.len == 0xff) return error.Corrupt;
    return .{ .table = table, .root = root };
}

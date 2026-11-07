//! The entropy-coded part of a JPEG: the bit reader, Huffman tables, and the
//! block decoders for baseline and progressive scans. A scan never fails: on
//! running out of data, or on a code no table has, it picks up at the next
//! restart marker if there is one and otherwise stops, keeping what it got.
//! Each block is charged to a budget, so that a small hostile file (a long
//! run of cheap scans over a big frame) stops instead of hanging.
const std = @import("std");
const pixels = @import("jpeg_pixels.zig");

/// Coefficient `i` of the coded order is at `zigzag[i]` in natural order.
pub const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const BitError = error{ Exhausted, BadCode };

const fast_bits = 9;

pub const Huffman = struct {
    /// By the next `fast_bits` of input: value << 8 | length, or 0 for a code
    /// that is longer (or missing).
    fast: [1 << fast_bits]u16 = @splat(0),
    /// One past the last code of each length, at that length.
    end: [17]u32 = @splat(0),
    /// What to add to a code of each length to get its index in `values`.
    delta: [17]i32 = @splat(0),
    values: [256]u8 = @splat(0),

    /// Builds the table from a DHT's 16 counts and its `values`, whose length
    /// must be their sum. Counts describing more codes than fit are refused.
    pub fn build(counts: *const [16]u8, values: []const u8) error{Corrupt}!Huffman {
        if (values.len > 256) return error.Corrupt;
        var h: Huffman = .{};
        @memcpy(h.values[0..values.len], values);
        var code: u32 = 0;
        var k: u32 = 0;
        for (counts, 1..) |count, len| {
            h.delta[len] = @as(i32, @intCast(k)) - @as(i32, @intCast(code));
            if (code + count > @as(u32, 1) << @intCast(len)) return error.Corrupt;
            for (0..count) |_| {
                if (len <= fast_bits) {
                    const room: u32 = @as(u32, 1) << @intCast(fast_bits - len);
                    const first = code << @intCast(fast_bits - len);
                    const entry: u16 = @as(u16, values[k]) << 8 | @as(u16, @intCast(len));
                    @memset(h.fast[first..][0..room], entry);
                }
                code += 1;
                k += 1;
            }
            h.end[len] = code;
            code <<= 1;
        }
        return h;
    }
};

pub const BitReader = struct {
    bytes: []const u8,
    /// The next unread byte. Never passes a marker, however far it reads ahead.
    pos: usize,
    buf: u64 = 0,
    count: u32 = 0,

    fn fill(r: *BitReader) void {
        while (r.count <= 56) {
            if (r.pos >= r.bytes.len) return;
            const b = r.bytes[r.pos];
            if (b == 0xFF) {
                if (r.pos + 1 >= r.bytes.len) return;
                const next = r.bytes[r.pos + 1];
                if (next == 0xFF) {
                    r.pos += 1;
                    continue;
                }
                if (next != 0) return;
                r.pos += 2;
            } else {
                r.pos += 1;
            }
            r.buf = r.buf << 8 | b;
            r.count += 8;
        }
    }

    /// The next `n` bits (1..16).
    fn bits(r: *BitReader, n: u5) BitError!u32 {
        if (r.count < n) {
            r.fill();
            if (r.count < n) return error.Exhausted;
        }
        r.count -= n;
        const value: u64 = r.buf >> @intCast(r.count);
        return @intCast(value & ((@as(u64, 1) << n) - 1));
    }

    fn bit(r: *BitReader) BitError!bool {
        return try r.bits(1) != 0;
    }

    fn decode(r: *BitReader, h: *const Huffman) BitError!u8 {
        if (r.count < 16) r.fill();
        const peek: u32 = @intCast((if (r.count >= 16) r.buf >> @intCast(r.count - 16) else r.buf << @intCast(16 - r.count)) & 0xffff);
        const entry = h.fast[peek >> (16 - fast_bits)];
        if (entry != 0) {
            const len: u32 = entry & 0xff;
            if (len > r.count) return error.Exhausted;
            r.count -= len;
            return @intCast(entry >> 8);
        }
        var len: u32 = fast_bits + 1;
        while (len <= 16) : (len += 1) {
            const code = peek >> @intCast(16 - len);
            if (code < h.end[len]) {
                if (len > r.count) return error.Exhausted;
                r.count -= len;
                const index = @as(i64, code) + h.delta[len];
                if (index < 0 or index > 255) return error.BadCode;
                return h.values[@intCast(index)];
            }
        }
        return error.BadCode;
    }

    /// `s` bits read as the signed value JPEG's "extend" procedure defines.
    fn extend(r: *BitReader, s: u5) BitError!i32 {
        if (s == 0) return 0;
        const v: i32 = @intCast(try r.bits(s));
        const half = @as(i32, 1) << (s - 1);
        return if (v < half) v - (@as(i32, 1) << s) + 1 else v;
    }

    /// Forgets the buffered bits and moves on to the next marker. If that is
    /// a restart marker, consumes it and returns its number; other markers
    /// stay where they are, for the caller's marker loop.
    fn nextRestart(r: *BitReader) ?u8 {
        r.count = 0;
        var at = r.pos;
        while (at + 1 < r.bytes.len) : (at += 1) {
            if (r.bytes[at] != 0xFF) continue;
            const m = r.bytes[at + 1];
            if (m == 0 or m == 0xFF) continue;
            r.pos = at;
            if (m < 0xD0 or m > 0xD7) return null;
            r.pos = at + 2;
            return m - 0xD0;
        }
        r.pos = r.bytes.len;
        return null;
    }
};

pub const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    tq: u8,
    /// Blocks allocated, padded out to whole MCUs.
    blocks_w: u32 = 0,
    blocks_h: u32 = 0,
    /// Blocks a scan of this component alone covers: no padding.
    scan_w: u32 = 0,
    scan_h: u32 = 0,
    /// `blocks_w * 8` samples a row, starting mid gray.
    plane: []u8 = &.{},
    /// Progressive only: 64 coefficients a block, in natural order.
    coefs: []i16 = &.{},
    /// Natural order. Copied once, when a scan first reaches the component.
    quant: [64]u16 = @splat(1),
    latched: bool = false,
};

pub const Scan = struct {
    reader: BitReader,
    comps: [4]*Component,
    dc: [4]?*const Huffman,
    ac: [4]?*const Huffman,
    count: u8,
    progressive: bool,
    /// Spectral band and successive approximation, as in the SOS header.
    ss: u8 = 0,
    se: u8 = 63,
    ah: u4 = 0,
    al: u4 = 0,
    restart: u32,
    mcux: u32,
    mcuy: u32,
    preds: [4]i32 = @splat(0),
    eobrun: u32 = 0,
    /// Coefficients visited so far in the frame, and the allowance.
    work: *u64,
    budget: u64,
    /// Blocks decoded so far in the frame.
    done: *u64,

    const BlockError = BitError || error{OutOfBudget};

    pub fn run(s: *Scan) void {
        const single = s.count == 1;
        const first = s.comps[0];
        const total: u64 = if (single) @as(u64, first.scan_w) * first.scan_h else @as(u64, s.mcux) * s.mcuy;
        var at: u64 = 0;
        var next_rst: u8 = 0;
        while (at < total) {
            if (s.restart != 0 and at != 0 and at % s.restart == 0) {
                const found = s.reader.nextRestart() orelse return;
                // A later number than expected means intervals were lost.
                const lost = (found -% next_rst) & 7;
                if (lost < 4) at += @as(u64, lost) * s.restart;
                next_rst = (found + 1) & 7;
                s.preds = @splat(0);
                s.eobrun = 0;
                if (at >= total) return;
            }
            s.unit(at, single) catch |err| switch (err) {
                error.OutOfBudget => return,
                error.Exhausted, error.BadCode => {
                    if (s.restart == 0) return;
                    at = (at / s.restart + 1) * s.restart;
                    continue;
                },
            };
            at += 1;
        }
    }

    /// One MCU, which in a scan of a single component is one block.
    fn unit(s: *Scan, index: u64, single: bool) BlockError!void {
        if (single) {
            const w = s.comps[0].scan_w;
            return s.block(0, @intCast(index % w), @intCast(index / w));
        }
        const mx: u32 = @intCast(index % s.mcux);
        const my: u32 = @intCast(index / s.mcux);
        for (0..s.count) |i| {
            const c = s.comps[i];
            for (0..c.v) |vv| {
                for (0..c.h) |hh| {
                    try s.block(i, mx * c.h + @as(u32, @intCast(hh)), my * c.v + @as(u32, @intCast(vv)));
                }
            }
        }
    }

    fn block(s: *Scan, i: usize, bx: u32, by: u32) BlockError!void {
        s.work.* += @as(u64, s.se) - s.ss + 1;
        if (s.work.* > s.budget) return error.OutOfBudget;
        const c = s.comps[i];
        if (s.progressive) {
            const at = (@as(usize, by) * c.blocks_w + bx) * 64;
            const coef = c.coefs[at..][0..64];
            if (s.ss == 0) {
                if (s.ah == 0) try s.dcFirst(i, coef) else try s.dcRefine(coef);
            } else {
                if (s.ah == 0) try s.acFirst(i, coef) else try s.acRefine(i, coef);
            }
        } else {
            try s.baseline(i, bx, by);
        }
        s.done.* += 1;
    }

    /// Decodes a whole block and writes its samples. A block cut short
    /// by the end of the data writes nothing.
    fn baseline(s: *Scan, i: usize, bx: u32, by: u32) BitError!void {
        const c = s.comps[i];
        const r = &s.reader;
        var coef: [64]i32 = @splat(0);
        const t = try r.decode(s.dc[i].?);
        if (t > 15) return error.BadCode;
        s.preds[i] +%= try r.extend(@intCast(t));
        coef[0] = s.preds[i] *% c.quant[0];
        const ac = s.ac[i].?;
        var k: u32 = 1;
        while (k < 64) {
            const rs = try r.decode(ac);
            const size: u5 = @intCast(rs & 15);
            const run_of: u32 = rs >> 4;
            if (size == 0) {
                if (run_of < 15) break;
                k += 16;
                continue;
            }
            k += run_of;
            if (k > 63) return error.BadCode;
            const n = zigzag[k];
            coef[n] = (try r.extend(size)) *% c.quant[n];
            k += 1;
        }
        const stride = @as(usize, c.blocks_w) * 8;
        pixels.idct(&coef, c.plane[@as(usize, by) * 8 * stride + @as(usize, bx) * 8..], stride);
    }

    fn dcFirst(s: *Scan, i: usize, coef: *[64]i16) BitError!void {
        const r = &s.reader;
        const t = try r.decode(s.dc[i].?);
        if (t > 15) return error.BadCode;
        s.preds[i] +%= try r.extend(@intCast(t));
        coef[0] = @truncate(s.preds[i] << s.al);
    }

    fn dcRefine(s: *Scan, coef: *[64]i16) BitError!void {
        if (try s.reader.bit()) coef[0] |= @as(i16, 1) << s.al;
    }

    fn acFirst(s: *Scan, i: usize, coef: *[64]i16) BitError!void {
        if (s.eobrun > 0) {
            s.eobrun -= 1;
            return;
        }
        const r = &s.reader;
        const ac = s.ac[i].?;
        var k: u32 = s.ss;
        while (k <= s.se) {
            const rs = try r.decode(ac);
            const size: u5 = @intCast(rs & 15);
            const run_of: u5 = @intCast(rs >> 4);
            if (size == 0) {
                if (run_of == 15) {
                    k += 16;
                    continue;
                }
                s.eobrun = (@as(u32, 1) << run_of) - 1;
                if (run_of > 0) s.eobrun += try r.bits(run_of);
                return;
            }
            k += run_of;
            if (k > 63) return error.BadCode;
            coef[zigzag[k]] = @truncate((try r.extend(size)) << s.al);
            k += 1;
        }
    }

    fn acRefine(s: *Scan, i: usize, coef: *[64]i16) BitError!void {
        const r = &s.reader;
        const ac = s.ac[i].?;
        const p1: i16 = @as(i16, 1) << s.al;
        const m1: i16 = -p1;
        var k: u32 = s.ss;
        if (s.eobrun == 0) {
            while (k <= s.se) : (k += 1) {
                const rs = try r.decode(ac);
                var zeros: u32 = rs >> 4;
                const size = rs & 15;
                var value: i16 = 0;
                if (size != 0) {
                    value = if (try r.bit()) p1 else m1;
                } else if (zeros != 15) {
                    s.eobrun = @as(u32, 1) << @intCast(zeros);
                    if (zeros > 0) s.eobrun += try r.bits(@intCast(zeros));
                    break;
                }
                // Past `zeros` zero coefficients, refining the others on the way.
                while (k <= s.se) : (k += 1) {
                    const z = &coef[zigzag[k]];
                    if (z.* != 0) {
                        try refine(r, z, p1, m1);
                    } else {
                        if (zeros == 0) break;
                        zeros -= 1;
                    }
                }
                if (value != 0 and k <= 63) coef[zigzag[k]] = value;
            }
        }
        if (s.eobrun > 0) {
            while (k <= s.se) : (k += 1) {
                const z = &coef[zigzag[k]];
                if (z.* != 0) try refine(r, z, p1, m1);
            }
            s.eobrun -= 1;
        }
    }
};

fn refine(r: *BitReader, z: *i16, p1: i16, m1: i16) BitError!void {
    if (try r.bit()) {
        if (z.* & p1 == 0) z.* +%= if (z.* >= 0) p1 else m1;
    }
}

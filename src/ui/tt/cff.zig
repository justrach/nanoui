//! OpenType's other outlines: the `CFF ` table and its Type 2 charstrings, read
//! into the same paths as TrueType's. Cubic curves become quadratics, which is
//! what the rasterizer takes. A font from the web can ask for anything here,
//! so subroutines nest only so deep and a glyph only takes so many steps.
const std = @import("std");

const max_stack = 513;
const max_depth = 10;
const max_steps = 200_000;

fn be16(d: []const u8, at: usize) ?u16 {
    if (at > d.len or d.len - at < 2) return null;
    return std.mem.readInt(u16, d[at..][0..2], .big);
}

/// An INDEX: `count` pieces of data after a table of offsets.
const Index = struct {
    d: []const u8 = "",
    count: u32 = 0,
    off_size: u8 = 1,
    /// Where the offsets start, and the byte offsets count from.
    offsets: usize = 0,
    base: usize = 0,
    /// The first byte after it.
    end: usize = 0,

    fn read(d: []const u8, at: usize) ?Index {
        const n = be16(d, at) orelse return null;
        if (n == 0) return .{ .d = d, .end = at + 2 };
        if (at + 3 > d.len) return null;
        const off_size = d[at + 2];
        if (off_size < 1 or off_size > 4) return null;
        var ix: Index = .{ .d = d, .count = n, .off_size = off_size, .offsets = at + 3 };
        ix.base = ix.offsets + (@as(usize, n) + 1) * off_size - 1;
        const last = ix.offset(n) orelse return null;
        ix.end = ix.base + last;
        if (ix.end > d.len or ix.end < ix.base) return null;
        return ix;
    }

    fn offset(ix: *const Index, i: usize) ?usize {
        const at = ix.offsets + i * ix.off_size;
        if (at + ix.off_size > ix.d.len) return null;
        var v: usize = 0;
        for (ix.d[at..][0..ix.off_size]) |b| v = (v << 8) | b;
        return v;
    }

    fn get(ix: *const Index, i: usize) ?[]const u8 {
        if (i >= ix.count) return null;
        const a = ix.offset(i) orelse return null;
        const b = ix.offset(i + 1) orelse return null;
        if (a == 0 or b < a) return null;
        const from = ix.base + a;
        const to = ix.base + b;
        if (to > ix.d.len) return null;
        return ix.d[from..to];
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
        if (b0 <= 21) {
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

fn bias(count: u32) i32 {
    return if (count < 1240) 107 else if (count < 33900) 1131 else 32768;
}

pub const Sink = @import("font.zig").Sink;

pub const Cff = struct {
    data: []const u8 = "",
    chars: Index = .{},
    global: Index = .{},
    /// Local subroutines of each font dict (one, unless a CID font).
    local: [16]Index = @splat(.{}),
    local_count: u8 = 0,
    fd_select: usize = 0,

    /// Reads the table, null when it's not one this reads.
    pub fn init(d: []const u8) ?Cff {
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

    fn readLocal(d: []const u8, dict: []const u8) Index {
        var args: [2]f64 = undefined;
        if (dictFind(dict, 18, &args) != 2) return .{};
        const size = usizeOf(args[0]) orelse return .{};
        const at = usizeOf(args[1]) orelse return .{};
        if (at > d.len or size > d.len - at) return .{};
        var sub: [1]f64 = undefined;
        if (dictFind(d[at..][0..size], 19, &sub) != 1) return .{};
        return Index.read(d, at + (usizeOf(sub[0]) orelse return .{})) orelse .{};
    }

    fn fdOf(c: *const Cff, g: u16) u8 {
        if (c.fd_select == 0) return 0;
        const d = c.data;
        const at = c.fd_select;
        if (at >= d.len) return 0;
        if (d[at] == 0) return if (at + 1 + g < d.len) d[at + 1 + g] else 0;
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

    /// Sends a glyph's path to `sink`, transformed by `m` as `Font.outline` does.
    pub fn outline(c: *const Cff, g: u16, m: [6]f32, sink: Sink) void {
        const code = c.chars.get(g) orelse return;
        const fd = c.fdOf(g);
        var run: Run = .{ .c = c, .m = m, .sink = sink, .local = if (fd < c.local_count) &c.local[fd] else &c.local[0] };
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

const Box = struct {
    x0: f32 = std.math.inf(f32),
    y0: f32 = std.math.inf(f32),
    x1: f32 = -std.math.inf(f32),
    y1: f32 = -std.math.inf(f32),

    fn add(b: *Box, x: f32, y: f32) void {
        b.x0 = @min(b.x0, x);
        b.y0 = @min(b.y0, y);
        b.x1 = @max(b.x1, x);
        b.y1 = @max(b.y1, y);
    }
    fn move(c: *anyopaque, x: f32, y: f32) void {
        const b: *Box = @ptrCast(@alignCast(c));
        b.add(x, y);
    }
    fn quad(c: *anyopaque, cx: f32, cy: f32, x: f32, y: f32) void {
        const b: *Box = @ptrCast(@alignCast(c));
        b.add(cx, cy);
        b.add(x, y);
    }
    fn close(_: *anyopaque) void {}
    fn sink(b: *Box) Sink {
        return .{ .ctx = b, .move = move, .line = move, .quad = quad, .close = close };
    }
};

const Run = struct {
    c: *const Cff,
    m: [6]f32,
    sink: Sink,
    local: *const Index,
    stack: [max_stack]f32 = undefined,
    n: usize = 0,
    x: f32 = 0,
    y: f32 = 0,
    open: bool = false,
    width_seen: bool = false,
    hints: u32 = 0,
    steps: u32 = 0,
    ended: bool = false,

    fn tx(r: *const Run, x: f32, y: f32) f32 {
        return r.m[0] * x + r.m[2] * y + r.m[4];
    }

    fn ty(r: *const Run, x: f32, y: f32) f32 {
        return r.m[1] * x + r.m[3] * y + r.m[5];
    }

    fn closePath(r: *Run) void {
        if (r.open) r.sink.close(r.sink.ctx);
        r.open = false;
    }

    fn moveBy(r: *Run, dx: f32, dy: f32) void {
        r.closePath();
        r.x += dx;
        r.y += dy;
        r.sink.move(r.sink.ctx, r.tx(r.x, r.y), r.ty(r.x, r.y));
        r.open = true;
    }

    fn lineBy(r: *Run, dx: f32, dy: f32) void {
        r.x += dx;
        r.y += dy;
        r.sink.line(r.sink.ctx, r.tx(r.x, r.y), r.ty(r.x, r.y));
    }

    /// A cubic, by four quadratics meeting at its own points: near enough at
    /// any size glyphs are drawn.
    fn curveBy(r: *Run, d1x: f32, d1y: f32, d2x: f32, d2y: f32, d3x: f32, d3y: f32) void {
        const x0 = r.x;
        const y0 = r.y;
        const x1 = x0 + d1x;
        const y1 = y0 + d1y;
        const x2 = x1 + d2x;
        const y2 = y1 + d2y;
        const x3 = x2 + d3x;
        const y3 = y2 + d3y;
        const pts: f32 = 4;
        var px = x0;
        var py = y0;
        for (1..5) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) / pts;
            const u = 1 - t;
            const nx = u * u * u * x0 + 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t * x3;
            const ny = u * u * u * y0 + 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t * y3;
            // The derivative at the segment's ends meet at its control point:
            // the middle of its cubic, lifted to a quadratic.
            const mid = t - 0.5 / pts;
            const v = 1 - mid;
            const mx = v * v * v * x0 + 3 * v * v * mid * x1 + 3 * v * mid * mid * x2 + mid * mid * mid * x3;
            const my = v * v * v * y0 + 3 * v * v * mid * y1 + 3 * v * mid * mid * y2 + mid * mid * mid * y3;
            const cx = 2 * mx - (px + nx) / 2;
            const cy = 2 * my - (py + ny) / 2;
            r.sink.quad(r.sink.ctx, r.tx(cx, cy), r.ty(cx, cy), r.tx(nx, ny), r.ty(nx, ny));
            px = nx;
            py = ny;
        }
        r.x = x3;
        r.y = y3;
    }

    /// Drops an optional leading width off the stack.
    fn takeWidth(r: *Run, odd_means_width: bool, expect: usize) void {
        if (r.width_seen) return;
        r.width_seen = true;
        const has = if (odd_means_width) r.n % 2 == 1 else r.n > expect;
        if (has and r.n > 0) {
            std.mem.copyForwards(f32, r.stack[0 .. r.n - 1], r.stack[1..r.n]);
            r.n -= 1;
        }
    }

    fn exec(r: *Run, code: []const u8, depth: u8) void {
        var i: usize = 0;
        while (i < code.len and !r.ended) {
            r.steps += 1;
            if (r.steps > max_steps) {
                r.ended = true;
                return;
            }
            const b0 = code[i];
            i += 1;
            switch (b0) {
                28 => {
                    const v = be16(code, i) orelse return;
                    i += 2;
                    r.push(@floatFromInt(@as(i16, @bitCast(v))));
                },
                32...246 => r.push(@floatFromInt(@as(i32, b0) - 139)),
                247...250 => {
                    if (i >= code.len) return;
                    r.push(@floatFromInt((@as(i32, b0) - 247) * 256 + code[i] + 108));
                    i += 1;
                },
                251...254 => {
                    if (i >= code.len) return;
                    r.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, code[i]) - 108));
                    i += 1;
                },
                255 => {
                    if (i + 4 > code.len) return;
                    r.push(@as(f32, @floatFromInt(std.mem.readInt(i32, code[i..][0..4], .big))) / 65536);
                    i += 4;
                },
                1, 3, 18, 23 => {
                    r.takeWidth(true, 0);
                    r.hints += @intCast(r.n / 2);
                    r.n = 0;
                },
                19, 20 => {
                    r.takeWidth(true, 0);
                    r.hints += @intCast(r.n / 2);
                    r.n = 0;
                    i += (r.hints + 7) / 8;
                },
                21 => {
                    r.takeWidth(false, 2);
                    if (r.n >= 2) r.moveBy(r.stack[r.n - 2], r.stack[r.n - 1]);
                    r.n = 0;
                },
                22 => {
                    r.takeWidth(false, 1);
                    if (r.n >= 1) r.moveBy(r.stack[r.n - 1], 0);
                    r.n = 0;
                },
                4 => {
                    r.takeWidth(false, 1);
                    if (r.n >= 1) r.moveBy(0, r.stack[r.n - 1]);
                    r.n = 0;
                },
                5 => {
                    var k: usize = 0;
                    while (k + 2 <= r.n) : (k += 2) r.lineBy(r.stack[k], r.stack[k + 1]);
                    r.n = 0;
                },
                6, 7 => {
                    var horizontal = b0 == 6;
                    for (r.stack[0..r.n]) |v| {
                        if (horizontal) r.lineBy(v, 0) else r.lineBy(0, v);
                        horizontal = !horizontal;
                    }
                    r.n = 0;
                },
                8 => {
                    var k: usize = 0;
                    while (k + 6 <= r.n) : (k += 6) r.curve6(k);
                    r.n = 0;
                },
                24 => {
                    var k: usize = 0;
                    while (k + 8 <= r.n) : (k += 6) r.curve6(k);
                    if (k + 2 <= r.n) r.lineBy(r.stack[k], r.stack[k + 1]);
                    r.n = 0;
                },
                25 => {
                    var k: usize = 0;
                    while (k + 8 <= r.n) : (k += 2) r.lineBy(r.stack[k], r.stack[k + 1]);
                    if (k + 6 <= r.n) r.curve6(k);
                    r.n = 0;
                },
                26 => {
                    var k: usize = 0;
                    var dx1: f32 = 0;
                    if (r.n % 4 == 1) {
                        dx1 = r.stack[0];
                        k = 1;
                    }
                    while (k + 4 <= r.n) : (k += 4) {
                        r.curveBy(dx1, r.stack[k], r.stack[k + 1], r.stack[k + 2], 0, r.stack[k + 3]);
                        dx1 = 0;
                    }
                    r.n = 0;
                },
                27 => {
                    var k: usize = 0;
                    var dy1: f32 = 0;
                    if (r.n % 4 == 1) {
                        dy1 = r.stack[0];
                        k = 1;
                    }
                    while (k + 4 <= r.n) : (k += 4) {
                        r.curveBy(r.stack[k], dy1, r.stack[k + 1], r.stack[k + 2], r.stack[k + 3], 0);
                        dy1 = 0;
                    }
                    r.n = 0;
                },
                30, 31 => {
                    var horizontal = b0 == 31;
                    var k: usize = 0;
                    while (k + 4 <= r.n) : (k += 4) {
                        const last: f32 = if (r.n - k == 5) r.stack[k + 4] else 0;
                        if (horizontal) {
                            r.curveBy(r.stack[k], 0, r.stack[k + 1], r.stack[k + 2], last, r.stack[k + 3]);
                        } else {
                            r.curveBy(0, r.stack[k], r.stack[k + 1], r.stack[k + 2], r.stack[k + 3], last);
                        }
                        horizontal = !horizontal;
                    }
                    r.n = 0;
                },
                10, 29 => {
                    if (r.n == 0 or depth >= max_depth) return;
                    r.n -= 1;
                    const ix = if (b0 == 10) r.local else &r.c.global;
                    const num = @as(i64, @intFromFloat(std.math.clamp(r.stack[r.n], -70000, 70000))) + bias(ix.count);
                    if (num < 0) return;
                    if (ix.get(@intCast(num))) |sub| r.exec(sub, depth + 1);
                },
                11 => return,
                14 => {
                    r.takeWidth(false, 0);
                    r.ended = true;
                    r.n = 0;
                    return;
                },
                12 => {
                    if (i >= code.len) return;
                    const op = code[i];
                    i += 1;
                    r.flex(op);
                },
                else => r.n = 0,
            }
        }
    }

    fn push(r: *Run, v: f32) void {
        if (r.n < r.stack.len) {
            r.stack[r.n] = v;
            r.n += 1;
        }
    }

    fn curve6(r: *Run, k: usize) void {
        const s = r.stack[k..];
        r.curveBy(s[0], s[1], s[2], s[3], s[4], s[5]);
    }

    fn flex(r: *Run, op: u8) void {
        const s = r.stack;
        switch (op) {
            34 => if (r.n >= 7) { // hflex
                r.curveBy(s[0], 0, s[1], s[2], s[3], 0);
                r.curveBy(s[4], 0, s[5], -s[2], s[6], 0);
            },
            35 => if (r.n >= 12) { // flex
                r.curve6(0);
                r.curve6(6);
            },
            36 => if (r.n >= 9) { // hflex1
                r.curveBy(s[0], s[1], s[2], s[3], s[4], 0);
                r.curveBy(s[5], 0, s[6], s[7], s[8], -(s[1] + s[3] + s[7]));
            },
            37 => if (r.n >= 11) { // flex1
                const dx = s[0] + s[2] + s[4] + s[6] + s[8];
                const dy = s[1] + s[3] + s[5] + s[7] + s[9];
                r.curve6(0);
                if (@abs(dx) > @abs(dy)) {
                    r.curveBy(s[6], s[7], s[8], s[9], s[10], -dy);
                } else {
                    r.curveBy(s[6], s[7], s[8], s[9], -dx, s[10]);
                }
            },
            else => {},
        }
        r.n = 0;
    }
};

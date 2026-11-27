//! Type 2 charstrings from `CFF ` and `CFF2` tables, run into a path sink.
const std = @import("std");
const cff = @import("cff.zig");
const Cff = cff.Cff;
const Index = cff.Index;
const Sink = cff.Sink;
const be16 = cff.be16;
const bias = cff.bias;
const max_stack = cff.max_stack;
const max_depth = cff.max_depth;
const max_steps = cff.max_steps;

pub const Box = struct {
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
    pub fn sink(b: *Box) Sink {
        return .{ .ctx = b, .move = move, .line = move, .quad = quad, .close = close };
    }
};

pub const Run = struct {
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
    vsindex: u16 = 0,
    hints: u32 = 0,
    steps: u32 = 0,
    ended: bool = false,

    fn tx(r: *const Run, x: f32, y: f32) f32 {
        return r.m[0] * x + r.m[2] * y + r.m[4];
    }

    fn ty(r: *const Run, x: f32, y: f32) f32 {
        return r.m[1] * x + r.m[3] * y + r.m[5];
    }

    pub fn closePath(r: *Run) void {
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

    pub fn exec(r: *Run, code: []const u8, depth: u8) void {
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
                15 => {
                    // CFF2's vsindex; reserved in CFF.
                    if (r.c.version == 2 and r.n > 0) {
                        r.n -= 1;
                        r.vsindex = @intFromFloat(std.math.clamp(r.stack[r.n], 0, 0xffff));
                    } else r.n = 0;
                },
                16 => if (r.c.version == 2) r.blend() else {
                    r.n = 0;
                },
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

    /// CFF2's blend at the default instance: `n` defaults, then `n` deltas
    /// per region, then `n`. The defaults stay; the deltas go.
    fn blend(r: *Run) void {
        if (r.n == 0) return;
        r.n -= 1;
        const v = r.stack[r.n];
        if (!(v >= 0) or v > max_stack or @trunc(v) != v) {
            r.n = 0;
            return;
        }
        const n: usize = @intFromFloat(v);
        const regions = r.c.regionCount(r.vsindex) orelse {
            r.n = 0;
            return;
        };
        const total = n * (regions + 1);
        if (total > r.n) {
            r.n = 0;
            return;
        }
        r.n = r.n - total + n;
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

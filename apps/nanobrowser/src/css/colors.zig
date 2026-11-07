//! Reading CSS colors. Components come out in 0 to 1 sRGB, gamma encoded;
//! `oklch`, `oklab`, `lab` and `lch` are converted through the real matrices
//! and clipped rather than gamut mapped; `color-mix()` mixes in sRGB whatever
//! space it asks for.
const std = @import("std");
const style = @import("style.zig");
const values = @import("values.zig");
const names = @import("color_names.zig");

const Color = style.Color;
const Ctx = values.Ctx;
const Cur = values.Cur;
const Token = values.Token;

fn fromHex(v: u32) Color {
    return .{
        .r = @as(f32, @floatFromInt((v >> 16) & 255)) / 255,
        .g = @as(f32, @floatFromInt((v >> 8) & 255)) / 255,
        .b = @as(f32, @floatFromInt(v & 255)) / 255,
    };
}

pub fn parseHex(s: []const u8) ?Color {
    var d: [8]u8 = undefined;
    if (s.len != 3 and s.len != 4 and s.len != 6 and s.len != 8) return null;
    for (s, 0..) |c, i| d[i] = std.fmt.charToDigit(c, 16) catch return null;
    const b = struct {
        fn byte(x: u8) f32 {
            return @as(f32, @floatFromInt(x)) / 255;
        }
    };
    if (s.len <= 4) {
        return .{
            .r = b.byte(d[0] * 17),
            .g = b.byte(d[1] * 17),
            .b = b.byte(d[2] * 17),
            .a = if (s.len == 4) b.byte(d[3] * 17) else 1,
        };
    }
    return .{
        .r = b.byte(d[0] * 16 + d[1]),
        .g = b.byte(d[2] * 16 + d[3]),
        .b = b.byte(d[4] * 16 + d[5]),
        .a = if (s.len == 8) b.byte(d[6] * 16 + d[7]) else 1,
    };
}

/// A color with `c` at it. `current` is what `currentcolor` means.
pub fn at(ctx: *const Ctx, c: *Cur) ?Color {
    const t = c.peek() orelse return null;
    switch (t.kind) {
        .hash => {
            const v = parseHex(t.text) orelse return null;
            c.i += 1;
            return v;
        },
        .ident => {
            const v = named_color(ctx, t.text) orelse return null;
            c.i += 1;
            return v;
        },
        .function => {
            const save = c.i;
            c.i += 1;
            const v = function(ctx, t.text, c.body()) orelse {
                c.i = save;
                return null;
            };
            return v;
        },
        else => return null,
    }
}

/// A whole value that is one color.
pub fn of(ctx: *const Ctx, t: []const Token) ?Color {
    var c = Cur.of(t);
    const v = at(ctx, &c) orelse return null;
    return if (c.atEnd()) v else null;
}

fn named_color(ctx: *const Ctx, text: []const u8) ?Color {
    var buf: [32]u8 = undefined;
    if (text.len > buf.len) return null;
    const low = std.ascii.lowerString(&buf, text);
    if (std.mem.eql(u8, low, "transparent")) return Color.transparent;
    if (std.mem.eql(u8, low, "currentcolor")) return ctx.style.color;
    if (names.named.get(low)) |v| return fromHex(v);
    if (names.system.get(low)) |s| return fromHex(if (ctx.style.dark_scheme) s.dark else s.light);
    return null;
}

/// How deep `color-mix(in srgb, color-mix(...` may go before it is refused.
threadlocal var nesting: u32 = 0;

fn function(ctx: *const Ctx, name: []const u8, args: []const Token) ?Color {
    if (nesting > 16) return null;
    nesting += 1;
    defer nesting -= 1;
    var buf: [16]u8 = undefined;
    if (name.len > buf.len) return null;
    const n = std.ascii.lowerString(&buf, name);
    const eql = std.mem.eql;
    if (eql(u8, n, "rgb") or eql(u8, n, "rgba")) return rgb(ctx, args);
    if (eql(u8, n, "hsl") or eql(u8, n, "hsla")) return hsl(ctx, args);
    if (eql(u8, n, "hwb")) return hwb(ctx, args);
    if (eql(u8, n, "oklch")) return lchLike(ctx, args, true);
    if (eql(u8, n, "lch")) return lchLike(ctx, args, false);
    if (eql(u8, n, "oklab")) return labLike(ctx, args, true);
    if (eql(u8, n, "lab")) return labLike(ctx, args, false);
    if (eql(u8, n, "color")) return colorFunction(ctx, args);
    if (eql(u8, n, "color-mix")) return colorMix(ctx, args);
    if (eql(u8, n, "light-dark")) {
        var c = Cur.of(args);
        const light = of(ctx, c.untilComma()) orelse return null;
        const dark = of(ctx, c.untilComma()) orelse return null;
        return if (ctx.style.dark_scheme) dark else light;
    }
    return null;
}

/// The components of a color function, `none` as 0, with an alpha.
const Parts = struct { v: [3]Part = undefined, a: f32 = 1 };
const Part = struct { num: f32 = 0, pct: bool = false, angle: bool = false };

fn parts(ctx: *const Ctx, args: []const Token) ?Parts {
    var c = Cur.of(args);
    var out: Parts = .{};
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        out.v[i] = part(ctx, &c) orelse return null;
        _ = c.takeComma();
    }
    if (c.atEnd()) return out;
    if (!c.takeDelim('/')) {
        // A legacy comma form's alpha needs no slash; the comma went above.
    }
    const a = part(ctx, &c) orelse return null;
    out.a = std.math.clamp(if (a.pct) a.num / 100 else a.num, 0, 1);
    if (!c.atEnd()) return null;
    return out;
}

fn part(ctx: *const Ctx, c: *Cur) ?Part {
    const t = c.peek() orelse return null;
    switch (t.kind) {
        .ident => {
            if (!t.isIdent("none")) return null;
            c.i += 1;
            return .{};
        },
        .percentage => {
            c.i += 1;
            return .{ .num = t.num, .pct = true };
        },
        .dimension => {
            const d = values.angleUnit(t.text) orelse return null;
            c.i += 1;
            return .{ .num = t.num * d, .angle = true };
        },
        else => {
            if (values.numberAt(ctx, c)) |n| return .{ .num = n };
            // `calc()` with a percentage.
            if (values.lengthAt(ctx, c)) |l| return .{ .num = l.pct, .pct = true };
            return null;
        },
    }
}

fn rgb(ctx: *const Ctx, args: []const Token) ?Color {
    const p = parts(ctx, args) orelse return null;
    const comp = struct {
        fn get(x: Part) f32 {
            const v = if (x.pct) x.num / 100 else x.num / 255;
            return std.math.clamp(v, 0, 1);
        }
    };
    return .{ .r = comp.get(p.v[0]), .g = comp.get(p.v[1]), .b = comp.get(p.v[2]), .a = p.a };
}

fn hueOf(x: Part) f32 {
    var h = @mod(x.num, 360);
    if (h < 0) h += 360;
    return h;
}

fn hslToRgb(h: f32, s: f32, l: f32, a: f32) Color {
    const f = struct {
        fn k(n: f32, hh: f32, ss: f32, ll: f32) f32 {
            const kk = @mod(n + hh / 30, 12);
            const aa = ss * @min(ll, 1 - ll);
            return ll - aa * @max(-1, @min(@min(kk - 3, 9 - kk), 1));
        }
    };
    return .{ .r = f.k(0, h, s, l), .g = f.k(8, h, s, l), .b = f.k(4, h, s, l), .a = a };
}

fn hsl(ctx: *const Ctx, args: []const Token) ?Color {
    const p = parts(ctx, args) orelse return null;
    const s = std.math.clamp(p.v[1].num / 100, 0, 1);
    const l = std.math.clamp(p.v[2].num / 100, 0, 1);
    return hslToRgb(hueOf(p.v[0]), s, l, p.a);
}

fn hwb(ctx: *const Ctx, args: []const Token) ?Color {
    const p = parts(ctx, args) orelse return null;
    var w = std.math.clamp(p.v[1].num / 100, 0, 1);
    var b = std.math.clamp(p.v[2].num / 100, 0, 1);
    if (w + b >= 1) {
        const g = w / (w + b);
        return .{ .r = g, .g = g, .b = g, .a = p.a };
    }
    const c = hslToRgb(hueOf(p.v[0]), 1, 0.5, p.a);
    b = 1 - b;
    w = w * 1;
    return .{ .r = c.r * (b - w) + w, .g = c.g * (b - w) + w, .b = c.b * (b - w) + w, .a = p.a };
}

fn gamma(x: f32) f32 {
    const v = std.math.clamp(x, 0, 1);
    return if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

fn fromLinear(r: f32, g: f32, b: f32, a: f32) Color {
    return .{ .r = gamma(r), .g = gamma(g), .b = gamma(b), .a = a };
}

fn oklabToColor(l: f32, a: f32, b: f32, alpha: f32) Color {
    const lp = l + 0.3963377774 * a + 0.2158037573 * b;
    const mp = l - 0.1055613458 * a - 0.0638541728 * b;
    const sp = l - 0.0894841775 * a - 1.2914855480 * b;
    const lc = lp * lp * lp;
    const mc = mp * mp * mp;
    const sc = sp * sp * sp;
    return fromLinear(
        4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc,
        -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc,
        -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc,
        alpha,
    );
}

fn labToColor(l: f32, a: f32, b: f32, alpha: f32) Color {
    const f1 = (l + 16) / 116;
    const fa = a / 500 + f1;
    const fb = f1 - b / 200;
    const finv = struct {
        fn g(t: f32) f32 {
            const c = t * t * t;
            return if (c > 0.008856) c else (116 * t - 16) / 903.3;
        }
    };
    // D50 white, then D50 XYZ to linear sRGB.
    const x = 0.96422 * finv.g(fa);
    const y = 1.0 * finv.g(f1);
    const z = 0.82521 * finv.g(fb);
    return fromLinear(
        3.1338561 * x - 1.6168667 * y - 0.4906146 * z,
        -0.9787684 * x + 1.9161415 * y + 0.0334540 * z,
        0.0719453 * x - 0.2289914 * y + 1.4052427 * z,
        alpha,
    );
}

fn lchLike(ctx: *const Ctx, args: []const Token, ok: bool) ?Color {
    const p = parts(ctx, args) orelse return null;
    const l = if (ok) (if (p.v[0].pct) p.v[0].num / 100 else p.v[0].num) else p.v[0].num;
    const scale: f32 = if (ok) 0.4 else 150;
    const ch = if (p.v[1].pct) p.v[1].num / 100 * scale else p.v[1].num;
    const h = std.math.degreesToRadians(hueOf(p.v[2]));
    const a = ch * @cos(h);
    const b = ch * @sin(h);
    return if (ok) oklabToColor(l, a, b, p.a) else labToColor(l, a, b, p.a);
}

fn labLike(ctx: *const Ctx, args: []const Token, ok: bool) ?Color {
    const p = parts(ctx, args) orelse return null;
    const l = if (ok) (if (p.v[0].pct) p.v[0].num / 100 else p.v[0].num) else p.v[0].num;
    const scale: f32 = if (ok) 0.4 else 125;
    const a = if (p.v[1].pct) p.v[1].num / 100 * scale else p.v[1].num;
    const b = if (p.v[2].pct) p.v[2].num / 100 * scale else p.v[2].num;
    return if (ok) oklabToColor(l, a, b, p.a) else labToColor(l, a, b, p.a);
}

/// `color(srgb r g b / a)` and the wide-gamut spaces read as if sRGB.
fn colorFunction(ctx: *const Ctx, args: []const Token) ?Color {
    var c = Cur.of(args);
    const space = c.next() orelse return null;
    if (space.kind != .ident) return null;
    const p = parts(ctx, c.t[c.i..]) orelse return null;
    const f = struct {
        fn v(x: Part) f32 {
            return std.math.clamp(if (x.pct) x.num / 100 else x.num, 0, 1);
        }
    };
    if (space.isIdent("srgb-linear")) return fromLinear(f.v(p.v[0]), f.v(p.v[1]), f.v(p.v[2]), p.a);
    return .{ .r = f.v(p.v[0]), .g = f.v(p.v[1]), .b = f.v(p.v[2]), .a = p.a };
}

fn colorMix(ctx: *const Ctx, args: []const Token) ?Color {
    var c = Cur.of(args);
    _ = c.untilComma(); // `in <space>`
    const a = mixPart(ctx, c.untilComma()) orelse return null;
    const b = mixPart(ctx, c.untilComma()) orelse return null;
    var pa = a.pct;
    var pb = b.pct;
    if (pa == null and pb == null) {
        pa = 50;
        pb = 50;
    } else if (pa == null) {
        pa = 100 - pb.?;
    } else if (pb == null) {
        pb = 100 - pa.?;
    }
    const total = pa.? + pb.?;
    if (total <= 0) return null;
    const wa = pa.? / total;
    const wb = pb.? / total;
    const alpha = a.color.a * wa + b.color.a * wb;
    const scale = if (total < 100) total / 100 else 1;
    if (alpha <= 0) return .{ .a = 0 };
    const premul = struct {
        fn mix(x: f32, xa: f32, wx: f32, y: f32, ya: f32, wy: f32, al: f32) f32 {
            return (x * xa * wx + y * ya * wy) / al;
        }
    };
    return .{
        .r = premul.mix(a.color.r, a.color.a, wa, b.color.r, b.color.a, wb, alpha),
        .g = premul.mix(a.color.g, a.color.a, wa, b.color.g, b.color.a, wb, alpha),
        .b = premul.mix(a.color.b, a.color.a, wa, b.color.b, b.color.a, wb, alpha),
        .a = alpha * scale,
    };
}

const MixPart = struct { color: Color, pct: ?f32 };

fn mixPart(ctx: *const Ctx, t: []const Token) ?MixPart {
    var c = Cur.of(t);
    var pct: ?f32 = null;
    if (c.peek()) |p| if (p.kind == .percentage) {
        pct = p.num;
        c.i += 1;
    };
    const col = at(ctx, &c) orelse return null;
    if (c.peek()) |p| if (p.kind == .percentage) {
        pct = p.num;
        c.i += 1;
    };
    if (!c.atEnd()) return null;
    return .{ .color = col, .pct = pct };
}

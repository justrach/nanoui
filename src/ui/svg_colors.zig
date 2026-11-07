//! CSS's colors, as SVG reads them: every name, `#rgb`, `#rgba`, `#rrggbb`,
//! `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()` and `hsla()`, commas or not.
const std = @import("std");

/// Straight RGBA from 0 to 1, or null if it isn't a color.
pub fn parse(v_in: []const u8) ?[4]f32 {
    const v = std.mem.trim(u8, v_in, " \t\r\n");
    if (v.len == 0) return null;
    if (v[0] == '#') return hex(v[1..]);
    const open = std.mem.indexOfScalar(u8, v, '(');
    if (open) |o| {
        const close = std.mem.lastIndexOfScalar(u8, v, ')') orelse v.len;
        if (close < o) return null;
        const name = v[0..o];
        const body = v[o + 1 .. close];
        if (std.ascii.eqlIgnoreCase(name, "rgb") or std.ascii.eqlIgnoreCase(name, "rgba")) return rgb(body);
        if (std.ascii.eqlIgnoreCase(name, "hsl") or std.ascii.eqlIgnoreCase(name, "hsla")) return hsl(body);
        return null;
    }
    if (std.ascii.eqlIgnoreCase(v, "transparent")) return .{ 0, 0, 0, 0 };
    var buf: [24]u8 = undefined;
    if (v.len > buf.len) return null;
    const x = names.get(std.ascii.lowerString(&buf, v)) orelse return null;
    return .{ ch(x >> 16 & 255), ch(x >> 8 & 255), ch(x & 255), 1 };
}

fn ch(x: u32) f32 {
    return @as(f32, @floatFromInt(x)) / 255;
}

fn hex(h: []const u8) ?[4]f32 {
    const x = std.fmt.parseInt(u32, h, 16) catch return null;
    return switch (h.len) {
        3 => .{ ch((x >> 8 & 15) * 17), ch((x >> 4 & 15) * 17), ch((x & 15) * 17), 1 },
        4 => .{ ch((x >> 12 & 15) * 17), ch((x >> 8 & 15) * 17), ch((x >> 4 & 15) * 17), ch((x & 15) * 17) },
        6 => .{ ch(x >> 16 & 255), ch(x >> 8 & 255), ch(x & 255), 1 },
        8 => .{ ch(x >> 24 & 255), ch(x >> 16 & 255), ch(x >> 8 & 255), ch(x & 255) },
        else => null,
    };
}

const Num = struct { v: f32, pct: bool };

/// Numbers in a function's body, by commas, spaces or `/`.
fn numbers(body: []const u8, out: *[4]Num) usize {
    var it = std.mem.tokenizeAny(u8, body, " ,/\t\r\n");
    var n: usize = 0;
    while (it.next()) |w| {
        if (n == out.len) break;
        var t = w;
        const pct = t.len > 0 and t[t.len - 1] == '%';
        if (pct) t = t[0 .. t.len - 1];
        var end = t.len;
        while (end > 0 and std.ascii.isAlphabetic(t[end - 1])) end -= 1;
        out[n] = .{ .v = std.fmt.parseFloat(f32, t[0..end]) catch return 0, .pct = pct };
        n += 1;
    }
    return n;
}

fn alpha(n: Num) f32 {
    return std.math.clamp(if (n.pct) n.v / 100 else n.v, 0, 1);
}

fn rgb(body: []const u8) ?[4]f32 {
    var n: [4]Num = undefined;
    const count = numbers(body, &n);
    if (count < 3) return null;
    var c: [4]f32 = .{ 0, 0, 0, 1 };
    for (0..3) |i| c[i] = std.math.clamp(if (n[i].pct) n[i].v / 100 else n[i].v / 255, 0, 1);
    if (count > 3) c[3] = alpha(n[3]);
    return c;
}

fn hsl(body: []const u8) ?[4]f32 {
    var n: [4]Num = undefined;
    const count = numbers(body, &n);
    if (count < 3) return null;
    const h = @mod(n[0].v, 360) / 60;
    const s = std.math.clamp(n[1].v / 100, 0, 1);
    const l = std.math.clamp(n[2].v / 100, 0, 1);
    const k = (1 - @abs(2 * l - 1)) * s;
    const x = k * (1 - @abs(@mod(h, 2) - 1));
    const m = l - k / 2;
    const rgb1: [3]f32 = switch (@as(u32, @intFromFloat(h))) {
        0 => .{ k, x, 0 },
        1 => .{ x, k, 0 },
        2 => .{ 0, k, x },
        3 => .{ 0, x, k },
        4 => .{ x, 0, k },
        else => .{ k, 0, x },
    };
    return .{ rgb1[0] + m, rgb1[1] + m, rgb1[2] + m, if (count > 3) alpha(n[3]) else 1 };
}

const names = std.StaticStringMap(u32).initComptime(.{
    .{ "aliceblue", 0xf0f8ff },       .{ "antiquewhite", 0xfaebd7 },   .{ "aqua", 0x00ffff },            .{ "aquamarine", 0x7fffd4 },
    .{ "azure", 0xf0ffff },           .{ "beige", 0xf5f5dc },          .{ "bisque", 0xffe4c4 },          .{ "black", 0x000000 },
    .{ "blanchedalmond", 0xffebcd },  .{ "blue", 0x0000ff },           .{ "blueviolet", 0x8a2be2 },      .{ "brown", 0xa52a2a },
    .{ "burlywood", 0xdeb887 },       .{ "cadetblue", 0x5f9ea0 },      .{ "chartreuse", 0x7fff00 },      .{ "chocolate", 0xd2691e },
    .{ "coral", 0xff7f50 },           .{ "cornflowerblue", 0x6495ed }, .{ "cornsilk", 0xfff8dc },        .{ "crimson", 0xdc143c },
    .{ "cyan", 0x00ffff },            .{ "darkblue", 0x00008b },       .{ "darkcyan", 0x008b8b },        .{ "darkgoldenrod", 0xb8860b },
    .{ "darkgray", 0xa9a9a9 },        .{ "darkgreen", 0x006400 },      .{ "darkgrey", 0xa9a9a9 },        .{ "darkkhaki", 0xbdb76b },
    .{ "darkmagenta", 0x8b008b },     .{ "darkolivegreen", 0x556b2f }, .{ "darkorange", 0xff8c00 },      .{ "darkorchid", 0x9932cc },
    .{ "darkred", 0x8b0000 },         .{ "darksalmon", 0xe9967a },     .{ "darkseagreen", 0x8fbc8f },    .{ "darkslateblue", 0x483d8b },
    .{ "darkslategray", 0x2f4f4f },   .{ "darkslategrey", 0x2f4f4f },  .{ "darkturquoise", 0x00ced1 },   .{ "darkviolet", 0x9400d3 },
    .{ "deeppink", 0xff1493 },        .{ "deepskyblue", 0x00bfff },    .{ "dimgray", 0x696969 },         .{ "dimgrey", 0x696969 },
    .{ "dodgerblue", 0x1e90ff },      .{ "firebrick", 0xb22222 },      .{ "floralwhite", 0xfffaf0 },     .{ "forestgreen", 0x228b22 },
    .{ "fuchsia", 0xff00ff },         .{ "gainsboro", 0xdcdcdc },      .{ "ghostwhite", 0xf8f8ff },      .{ "gold", 0xffd700 },
    .{ "goldenrod", 0xdaa520 },       .{ "gray", 0x808080 },           .{ "green", 0x008000 },           .{ "greenyellow", 0xadff2f },
    .{ "grey", 0x808080 },            .{ "honeydew", 0xf0fff0 },       .{ "hotpink", 0xff69b4 },         .{ "indianred", 0xcd5c5c },
    .{ "indigo", 0x4b0082 },          .{ "ivory", 0xfffff0 },          .{ "khaki", 0xf0e68c },           .{ "lavender", 0xe6e6fa },
    .{ "lavenderblush", 0xfff0f5 },   .{ "lawngreen", 0x7cfc00 },      .{ "lemonchiffon", 0xfffacd },    .{ "lightblue", 0xadd8e6 },
    .{ "lightcoral", 0xf08080 },      .{ "lightcyan", 0xe0ffff },      .{ "lightgoldenrodyellow", 0xfafad2 }, .{ "lightgray", 0xd3d3d3 },
    .{ "lightgreen", 0x90ee90 },      .{ "lightgrey", 0xd3d3d3 },      .{ "lightpink", 0xffb6c1 },       .{ "lightsalmon", 0xffa07a },
    .{ "lightseagreen", 0x20b2aa },   .{ "lightskyblue", 0x87cefa },   .{ "lightslategray", 0x778899 },  .{ "lightslategrey", 0x778899 },
    .{ "lightsteelblue", 0xb0c4de },  .{ "lightyellow", 0xffffe0 },    .{ "lime", 0x00ff00 },            .{ "limegreen", 0x32cd32 },
    .{ "linen", 0xfaf0e6 },           .{ "magenta", 0xff00ff },        .{ "maroon", 0x800000 },          .{ "mediumaquamarine", 0x66cdaa },
    .{ "mediumblue", 0x0000cd },      .{ "mediumorchid", 0xba55d3 },   .{ "mediumpurple", 0x9370db },    .{ "mediumseagreen", 0x3cb371 },
    .{ "mediumslateblue", 0x7b68ee }, .{ "mediumspringgreen", 0x00fa9a }, .{ "mediumturquoise", 0x48d1cc }, .{ "mediumvioletred", 0xc71585 },
    .{ "midnightblue", 0x191970 },    .{ "mintcream", 0xf5fffa },      .{ "mistyrose", 0xffe4e1 },       .{ "moccasin", 0xffe4b5 },
    .{ "navajowhite", 0xffdead },     .{ "navy", 0x000080 },           .{ "oldlace", 0xfdf5e6 },         .{ "olive", 0x808000 },
    .{ "olivedrab", 0x6b8e23 },       .{ "orange", 0xffa500 },         .{ "orangered", 0xff4500 },       .{ "orchid", 0xda70d6 },
    .{ "palegoldenrod", 0xeee8aa },   .{ "palegreen", 0x98fb98 },      .{ "paleturquoise", 0xafeeee },   .{ "palevioletred", 0xdb7093 },
    .{ "papayawhip", 0xffefd5 },      .{ "peachpuff", 0xffdab9 },      .{ "peru", 0xcd853f },            .{ "pink", 0xffc0cb },
    .{ "plum", 0xdda0dd },            .{ "powderblue", 0xb0e0e6 },     .{ "purple", 0x800080 },          .{ "rebeccapurple", 0x663399 },
    .{ "red", 0xff0000 },             .{ "rosybrown", 0xbc8f8f },      .{ "royalblue", 0x4169e1 },       .{ "saddlebrown", 0x8b4513 },
    .{ "salmon", 0xfa8072 },          .{ "sandybrown", 0xf4a460 },     .{ "seagreen", 0x2e8b57 },        .{ "seashell", 0xfff5ee },
    .{ "sienna", 0xa0522d },          .{ "silver", 0xc0c0c0 },         .{ "skyblue", 0x87ceeb },         .{ "slateblue", 0x6a5acd },
    .{ "slategray", 0x708090 },       .{ "slategrey", 0x708090 },      .{ "snow", 0xfffafa },            .{ "springgreen", 0x00ff7f },
    .{ "steelblue", 0x4682b4 },       .{ "tan", 0xd2b48c },            .{ "teal", 0x008080 },            .{ "thistle", 0xd8bfd8 },
    .{ "tomato", 0xff6347 },          .{ "turquoise", 0x40e0d0 },      .{ "violet", 0xee82ee },          .{ "wheat", 0xf5deb3 },
    .{ "white", 0xffffff },           .{ "whitesmoke", 0xf5f5f5 },     .{ "yellow", 0xffff00 },          .{ "yellowgreen", 0x9acd32 },
});

test "colors, by every spelling" {
    const near = std.testing.expectApproxEqAbs;
    try near(@as(f32, 1), parse("#f00").?[0], 1e-4);
    try near(@as(f32, 0.5), parse("rgb(0 0 0 / 50%)").?[3], 1e-4);
    try near(@as(f32, 1), parse("rgba(255, 0, 0, .25)").?[0], 1e-4);
    try near(@as(f32, 0.25), parse("rgba(255, 0, 0, .25)").?[3], 1e-4);
    try near(@as(f32, 0.5), parse("rgb(50%, 0%, 0%)").?[0], 1e-4);
    try near(@as(f32, 1), parse("hsl(120deg 100% 50%)").?[1], 1e-4);
    try near(@as(f32, 0x66) / 255.0, parse("RebeccaPurple").?[0], 1e-4);
    try std.testing.expect(parse("nonsense") == null);
    try std.testing.expect(parse("url(#a)") == null);
}

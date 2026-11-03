//! PNG to pixels, where nanoui decodes images itself (Linux, Windows, Android, and
//! `-Dportable`): every color type (gray, RGB, palette with transparency,
//! gray and RGB with alpha) at 1–16 bits, the five row filters, Adam7
//! interlacing. Out: premultiplied BGRA, as the renderers draw.
const std = @import("std");

pub const Decoded = struct {
    width: u32,
    height: u32,
    /// Premultiplied BGRA, `width * 4` bytes a row.
    bgra: []u8,

    pub fn deinit(d: Decoded, gpa: std.mem.Allocator) void {
        gpa.free(d.bgra);
    }
};

pub const Error = error{ NotPng, Unsupported, Corrupt, TooLarge, OutOfMemory };

const signature = "\x89PNG\r\n\x1a\n";
/// Larger images are refused rather than decoded (64 megapixels).
const max_pixels = 64 * 1024 * 1024;

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.NotPng;
    var pos: usize = signature.len;
    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var interlace: u8 = 0;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var trns_gray: ?u16 = null;
    var trns_rgb: ?[3]u16 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    while (pos + 12 <= bytes.len) {
        const len = be32(bytes[pos..]);
        const kind = bytes[pos + 4 .. pos + 8];
        if (pos + 12 + len > bytes.len) return error.Corrupt;
        const data = bytes[pos + 8 .. pos + 8 + len];
        pos += 12 + len;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len < 13) return error.Corrupt;
            width = be32(data);
            height = be32(data[4..]);
            depth = data[8];
            color = data[9];
            interlace = data[12];
            if (width == 0 or height == 0) return error.Corrupt;
            if (@as(u64, width) * height > max_pixels) return error.TooLarge;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            var i: usize = 0;
            while (i < 256 and i * 3 + 2 < len) : (i += 1) palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (color) {
                3 => for (data, 0..) |a, i| if (i < 256) {
                    palette[i][3] = a;
                },
                0 => if (len >= 2) {
                    trns_gray = std.mem.readInt(u16, data[0..2], .big);
                },
                2 => if (len >= 6) {
                    trns_rgb = .{ std.mem.readInt(u16, data[0..2], .big), std.mem.readInt(u16, data[2..4], .big), std.mem.readInt(u16, data[4..6], .big) };
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) break;
    }
    if (width == 0) return error.Corrupt;
    const channels: u8 = switch (color) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.Unsupported,
    };
    switch (depth) {
        1, 2, 4 => if (color != 0 and color != 3) return error.Unsupported,
        8 => {},
        16 => if (color == 3) return error.Unsupported,
        else => return error.Unsupported,
    }
    if (interlace > 1) return error.Unsupported;

    // Inflate the zlib stream of every IDAT.
    var input: std.Io.Reader = .fixed(idat.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var z: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    const raw = z.reader.allocRemaining(gpa, .limited(max_pixels * 8 + height * 8)) catch return error.Corrupt;
    defer gpa.free(raw);

    const bits_pp: usize = @as(usize, channels) * depth;
    const bpp: usize = @max(1, bits_pp / 8);
    const out = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(out);
    const pass = Pass{ .palette = &palette, .trns_gray = trns_gray, .trns_rgb = trns_rgb, .color = color, .depth = depth, .channels = channels, .out = out, .width = width };

    var at: usize = 0;
    if (interlace == 0) {
        at = try pass.run(gpa, raw, at, width, height, bits_pp, bpp, 0, 0, 1, 1);
    } else {
        // Adam7: seven sub-images, each a grid of every so many pixels.
        const starts = [7][2]u32{ .{ 0, 0 }, .{ 4, 0 }, .{ 0, 4 }, .{ 2, 0 }, .{ 0, 2 }, .{ 1, 0 }, .{ 0, 1 } };
        const steps = [7][2]u32{ .{ 8, 8 }, .{ 8, 8 }, .{ 4, 8 }, .{ 4, 4 }, .{ 2, 4 }, .{ 2, 2 }, .{ 1, 2 } };
        for (starts, steps) |s, st| {
            if (s[0] >= width or s[1] >= height) continue;
            const pw = (width - s[0] + st[0] - 1) / st[0];
            const ph = (height - s[1] + st[1] - 1) / st[1];
            at = try pass.run(gpa, raw, at, pw, ph, bits_pp, bpp, s[0], s[1], st[0], st[1]);
        }
    }
    return .{ .width = width, .height = height, .bgra = out };
}

const Pass = struct {
    palette: *const [256][4]u8,
    trns_gray: ?u16,
    trns_rgb: ?[3]u16,
    color: u8,
    depth: u8,
    channels: u8,
    out: []u8,
    width: u32,

    /// Unfilters a (sub-)image of `w`×`h` from `raw` at `at` and writes its
    /// pixels at (x0 + x·dx, y0 + y·dy); returns where the next one starts.
    fn run(p: Pass, gpa: std.mem.Allocator, raw: []const u8, at_in: usize, w: u32, h: u32, bits_pp: usize, bpp: usize, x0: u32, y0: u32, dx: u32, dy: u32) Error!usize {
        const stride = (@as(usize, w) * bits_pp + 7) / 8;
        const prev = try gpa.alloc(u8, stride);
        defer gpa.free(prev);
        @memset(prev, 0);
        var at = at_in;
        for (0..h) |y| {
            if (at + 1 + stride > raw.len) return error.Corrupt;
            const filter = raw[at];
            const line: []u8 = @constCast(raw[at + 1 .. at + 1 + stride]);
            at += 1 + stride;
            unfilter(filter, line, prev, bpp) catch return error.Corrupt;
            for (0..w) |x| {
                const px = p.pixel(line, x);
                const ox = x0 + @as(u32, @intCast(x)) * dx;
                const oy = y0 + @as(u32, @intCast(y)) * dy;
                const o = (@as(usize, oy) * p.width + ox) * 4;
                // Premultiplied BGRA.
                const a: u32 = px[3];
                p.out[o] = @intCast((@as(u32, px[2]) * a + 127) / 255);
                p.out[o + 1] = @intCast((@as(u32, px[1]) * a + 127) / 255);
                p.out[o + 2] = @intCast((@as(u32, px[0]) * a + 127) / 255);
                p.out[o + 3] = px[3];
            }
            @memcpy(prev, line);
        }
        return at;
    }

    /// Sample `i` of a row as 16 bits (or an index, for palettes).
    fn sample(p: Pass, line: []const u8, i: usize) u16 {
        return switch (p.depth) {
            16 => std.mem.readInt(u16, line[i * 2 ..][0..2], .big),
            8 => line[i],
            else => blk: {
                const per = 8 / p.depth;
                const byte = line[i / per];
                const shift: u3 = @intCast(8 - p.depth * (1 + i % per));
                const mask: u8 = (@as(u8, 1) << @intCast(p.depth)) - 1;
                break :blk (byte >> shift) & mask;
            },
        };
    }

    /// A sample scaled to 8 bits.
    fn to8(p: Pass, v: u16) u8 {
        return switch (p.depth) {
            16 => @intCast(v >> 8),
            8 => @intCast(v),
            else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(p.depth)) - 1)),
        };
    }

    fn pixel(p: Pass, line: []const u8, x: usize) [4]u8 {
        const n = p.channels;
        return switch (p.color) {
            3 => p.palette[p.sample(line, x) & 0xff],
            0 => blk: {
                const v = p.sample(line, x);
                const g = p.to8(v);
                break :blk .{ g, g, g, if (p.trns_gray != null and p.trns_gray.? == v) 0 else 255 };
            },
            4 => blk: {
                const g = p.to8(p.sample(line, x * n));
                break :blk .{ g, g, g, p.to8(p.sample(line, x * n + 1)) };
            },
            2 => blk: {
                const r = p.sample(line, x * n);
                const g = p.sample(line, x * n + 1);
                const b = p.sample(line, x * n + 2);
                const clear = if (p.trns_rgb) |t| t[0] == r and t[1] == g and t[2] == b else false;
                break :blk .{ p.to8(r), p.to8(g), p.to8(b), if (clear) 0 else 255 };
            },
            else => .{ p.to8(p.sample(line, x * n)), p.to8(p.sample(line, x * n + 1)), p.to8(p.sample(line, x * n + 2)), p.to8(p.sample(line, x * n + 3)) },
        };
    }
};

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn unfilter(filter: u8, line: []u8, prev: []const u8, bpp: usize) !void {
    switch (filter) {
        0 => {},
        1 => for (bpp..line.len) |i| {
            line[i] +%= line[i - bpp];
        },
        2 => for (line, prev) |*l, u| {
            l.* +%= u;
        },
        3 => for (line, 0..) |*l, i| {
            const left: u16 = if (i >= bpp) line[i - bpp] else 0;
            l.* +%= @intCast((left + prev[i]) / 2);
        },
        4 => for (line, 0..) |*l, i| {
            const left = if (i >= bpp) line[i - bpp] else 0;
            const ul = if (i >= bpp) prev[i - bpp] else 0;
            l.* +%= paeth(left, prev[i], ul);
        },
        else => return error.Corrupt,
    }
}

test "PNGs nanoui writes read back, and a palette with transparency" {
    const gpa = std.testing.allocator;
    // A 3×2 image through nanoui's own encoder.
    var px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 10, 20, 30, 255, 0, 0, 0, 0, 40, 40, 40, 128 };
    const bytes = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 3, .height = 2 });
    defer gpa.free(bytes);
    const d = try decode(gpa, bytes);
    defer d.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 3), d.width);
    try std.testing.expectEqualSlices(u8, &px, d.bgra);

    // 1×2, palette (2 bits): red opaque, then index 1 half transparent green.
    const pal_png = [_]u8{
        0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n',
        0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 2, 2, 3, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 6, 'P', 'L', 'T', 'E', 255, 0, 0, 0, 255, 0, 0, 0, 0, 0,
        0, 0, 0, 2, 't', 'R', 'N', 'S', 255, 128, 0, 0, 0, 0,
    };
    var with_data: std.ArrayList(u8) = .empty;
    defer with_data.deinit(gpa);
    try with_data.appendSlice(gpa, &pal_png);
    // IDAT: rows "0 00" and "0 40" (filter none; index in the top 2 bits), stored deflate.
    const zlib = [_]u8{ 0x78, 0x01, 0x01, 4, 0, 0xfb, 0xff, 0, 0x00, 0, 0x40 } ++ adler(&.{ 0, 0x00, 0, 0x40 });
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, zlib.len, .big);
    try with_data.appendSlice(gpa, &len);
    try with_data.appendSlice(gpa, "IDAT");
    try with_data.appendSlice(gpa, &zlib);
    try with_data.appendSlice(gpa, &.{ 0, 0, 0, 0 });
    try with_data.appendSlice(gpa, &.{ 0, 0, 0, 0, 'I', 'E', 'N', 'D', 0, 0, 0, 0 });
    const p = try decode(gpa, with_data.items);
    defer p.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, p.bgra[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 128, 0, 128 }, p.bgra[4..8]);
}

fn adler(data: []const u8) [4]u8 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |x| {
        a = (a + x) % 65521;
        b = (b + a) % 65521;
    }
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, b << 16 | a, .big);
    return out;
}

//! GIF to pixels, where nanoui decodes images itself (Linux, Windows, Android,
//! and `-Dportable`): the first frame of a GIF87a or GIF89a, composited on
//! transparent at its offset in the logical screen. Global and local palettes,
//! interlacing and the transparency index are honored; later frames and the
//! background color are not (browsers ignore the background too). Out:
//! premultiplied BGRA, as the renderers draw.
//!
//! Bytes come from arbitrary web servers. The dictionary and its stack have
//! fixed sizes, every code is checked before use and decoding ends when the
//! frame is full, so a file can't make this run past its data or the frame. A
//! frame cut short or gone bad keeps the rows that were read. A first frame
//! larger than the logical screen grows the picture, as browsers do.
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

pub const Size = struct { width: u32, height: u32 };

pub const Error = error{ NotGif, Corrupt, TooLarge, OutOfMemory };

/// Larger images are refused rather than decoded (64 megapixels).
const max_pixels = 64 * 1024 * 1024;

const max_codes = 4096;

/// Whether `bytes` start with a GIF signature and version.
pub fn matches(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, "GIF87a") or std.mem.startsWith(u8, bytes, "GIF89a");
}

/// The picture's size, read from the headers without touching any pixels.
/// Null if the headers are cut short before any size is known.
pub fn size(bytes: []const u8) ?Size {
    const screen = readScreen(bytes) orelse return null;
    const frame = firstFrame(bytes, screen) catch return if (screen.width > 0 and screen.height > 0) .{ .width = screen.width, .height = screen.height } else null;
    const s = canvas(screen, frame);
    return if (s.width > 0 and s.height > 0) s else null;
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Decoded {
    if (!matches(bytes)) return error.NotGif;
    const screen = readScreen(bytes) orelse return error.Corrupt;
    const frame = try firstFrame(bytes, screen);
    const c = canvas(screen, frame);
    if (c.width == 0 or c.height == 0) return error.Corrupt;
    if (@as(u64, c.width) * c.height > max_pixels) return error.TooLarge;
    const min_size = bytes[frame.data];
    if (min_size < 1 or min_size > 8) return error.Corrupt;

    const out = try gpa.alloc(u8, @as(usize, c.width) * c.height * 4);
    errdefer gpa.free(out);
    @memset(out, 0);
    drawFrame(bytes, frame, min_size, out, c.width);
    return .{ .width = c.width, .height = c.height, .bgra = out };
}

const Screen = struct {
    width: u32,
    height: u32,
    /// Where the global palette starts and how many colors it has.
    palette_at: usize,
    colors: u32,
    /// Where the blocks after the header start.
    next: usize,
};

fn le16(b: []const u8) u32 {
    return std.mem.readInt(u16, b[0..2], .little);
}

fn readScreen(bytes: []const u8) ?Screen {
    if (!matches(bytes) or bytes.len < 13) return null;
    const flags = bytes[10];
    const colors: u32 = if (flags & 0x80 != 0) @as(u32, 2) << @intCast(flags & 7) else 0;
    return .{
        .width = le16(bytes[6..]),
        .height = le16(bytes[8..]),
        .palette_at = 13,
        .colors = colors,
        .next = 13 + @as(usize, colors) * 3,
    };
}

const Frame = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    interlaced: bool,
    transparent: ?u8,
    palette_at: usize,
    colors: u32,
    /// The byte holding the LZW minimum code size.
    data: usize,
};

fn canvas(screen: Screen, frame: Frame) Size {
    return .{
        .width = @max(screen.width, frame.x + frame.width),
        .height = @max(screen.height, frame.y + frame.height),
    };
}

/// Walks past extensions to the first image's descriptor.
fn firstFrame(bytes: []const u8, screen: Screen) error{Corrupt}!Frame {
    var at = screen.next;
    var transparent: ?u8 = null;
    while (true) {
        if (at >= bytes.len) return error.Corrupt;
        const kind = bytes[at];
        at += 1;
        switch (kind) {
            0x21 => {
                if (at >= bytes.len) return error.Corrupt;
                const label = bytes[at];
                at += 1;
                // A graphic control extension: its size, flags, a 2-byte delay, the index.
                if (label == 0xF9 and at + 5 <= bytes.len and bytes[at] == 4) {
                    transparent = if (bytes[at + 1] & 1 != 0) bytes[at + 4] else null;
                }
                at = try skipBlocks(bytes, at);
            },
            0x2C => {
                if (at + 9 > bytes.len) return error.Corrupt;
                const d = bytes[at..][0..9];
                const flags = d[8];
                const colors: u32 = if (flags & 0x80 != 0) @as(u32, 2) << @intCast(flags & 7) else 0;
                const table = at + 9;
                const data = table + @as(usize, colors) * 3;
                if (data >= bytes.len) return error.Corrupt;
                const local = colors != 0;
                return .{
                    .x = le16(d[0..]),
                    .y = le16(d[2..]),
                    .width = le16(d[4..]),
                    .height = le16(d[6..]),
                    .interlaced = flags & 0x40 != 0,
                    .transparent = transparent,
                    .palette_at = if (local) table else screen.palette_at,
                    .colors = if (local) colors else screen.colors,
                    .data = data,
                };
            },
            else => return error.Corrupt, // The trailer, or not a GIF block: no frame here.
        }
    }
}

/// Past a chain of length-prefixed blocks and the empty block that ends it.
fn skipBlocks(bytes: []const u8, start: usize) error{Corrupt}!usize {
    var at = start;
    while (true) {
        if (at >= bytes.len) return error.Corrupt;
        const n = bytes[at];
        at += 1 + @as(usize, n);
        if (n == 0) return at;
    }
}

/// LSB-first codes out of a chain of sub-blocks; null when the chain ends.
const CodeReader = struct {
    bytes: []const u8,
    at: usize,
    left: u32 = 0,
    bits: u32 = 0,
    count: u5 = 0,
    ended: bool = false,

    fn byte(r: *CodeReader) ?u8 {
        if (r.ended) return null;
        if (r.left == 0) {
            if (r.at >= r.bytes.len) return r.end();
            r.left = r.bytes[r.at];
            r.at += 1;
            if (r.left == 0) return r.end();
        }
        if (r.at >= r.bytes.len) return r.end();
        r.left -= 1;
        r.at += 1;
        return r.bytes[r.at - 1];
    }

    fn end(r: *CodeReader) ?u8 {
        r.ended = true;
        return null;
    }

    fn code(r: *CodeReader, width: u4) ?u32 {
        while (r.count < width) {
            const b = r.byte() orelse return null;
            r.bits |= @as(u32, b) << r.count;
            r.count += 8;
        }
        const value = r.bits & ((@as(u32, 1) << width) - 1);
        r.bits >>= width;
        r.count -= width;
        return value;
    }
};

/// Where the next pixel of a frame goes, row by row and pass by pass.
const Painter = struct {
    bytes: []const u8,
    frame: Frame,
    out: []u8,
    stride: usize,
    x: u32 = 0,
    y: u32 = 0,
    pass: u2 = 0,
    full: bool = false,

    /// Writes one palette index; sets `full` after the frame's last pixel.
    /// An index with no color, as well as the transparent one, leaves the
    /// canvas clear.
    fn put(p: *Painter, index: u8) void {
        if (p.full) return;
        const f = p.frame;
        if (index < f.colors and f.transparent != index) {
            const rgb = p.bytes[f.palette_at + @as(usize, index) * 3..][0..3];
            const o = (@as(usize, f.y + p.y)) * p.stride + @as(usize, f.x + p.x) * 4;
            const px = p.out[o..][0..4];
            px[0] = rgb[2];
            px[1] = rgb[1];
            px[2] = rgb[0];
            px[3] = 255;
        }
        p.x += 1;
        if (p.x == f.width) {
            p.x = 0;
            p.nextRow();
        }
    }

    fn nextRow(p: *Painter) void {
        const h = p.frame.height;
        if (!p.frame.interlaced) {
            p.y += 1;
            if (p.y >= h) p.full = true;
            return;
        }
        const steps = [4]u32{ 8, 8, 4, 2 };
        const starts = [4]u32{ 4, 2, 1, 0 };
        p.y += steps[p.pass];
        while (p.y >= h) {
            if (p.pass == 3) {
                p.full = true;
                return;
            }
            p.y = starts[p.pass];
            p.pass += 1;
        }
    }
};

/// Decodes the frame's LZW data onto the canvas until the frame is full or the
/// data ends or goes bad, whichever is first.
fn drawFrame(bytes: []const u8, f: Frame, min_size: u8, out: []u8, canvas_width: u32) void {
    if (f.width == 0 or f.height == 0) return;
    const clear: u32 = @as(u32, 1) << @intCast(min_size);
    const eoi = clear + 1;

    var prefix: [max_codes]u16 = undefined;
    var suffix: [max_codes]u8 = undefined;
    var stack: [max_codes + 1]u8 = undefined;

    var reader: CodeReader = .{ .bytes = bytes, .at = f.data + 1 };
    var painter: Painter = .{ .bytes = bytes, .frame = f, .out = out, .stride = @as(usize, canvas_width) * 4 };
    var avail = clear + 2;
    var width: u4 = @intCast(min_size + 1);
    var old: ?u32 = null;
    var first: u8 = 0;

    while (!painter.full) {
        const in = reader.code(width) orelse return;
        if (in == clear) {
            avail = clear + 2;
            width = @intCast(min_size + 1);
            old = null;
            continue;
        }
        if (in == eoi) return;
        const prev = old orelse {
            if (in >= clear) return;
            first = @intCast(in);
            painter.put(first);
            old = in;
            continue;
        };
        if (in > avail) return;
        var depth: usize = 0;
        var c = in;
        if (c == avail) {
            // The one code the decoder hasn't made yet: the previous string plus its own start.
            stack[depth] = first;
            depth += 1;
            c = prev;
        }
        while (c >= clear) {
            stack[depth] = suffix[c];
            depth += 1;
            c = prefix[c];
        }
        first = @intCast(c);
        stack[depth] = first;
        depth += 1;
        if (avail < max_codes) {
            prefix[avail] = @intCast(prev);
            suffix[avail] = first;
            avail += 1;
            if (avail == @as(u32, 1) << width and width < 12) width += 1;
        }
        old = in;
        while (depth > 0) {
            depth -= 1;
            painter.put(stack[depth]);
        }
    }
}

const testing = std.testing;

/// A byte stream under construction, with a real LZW encoder's code widths:
/// it sends literals only, growing its width exactly as the decoder must.
const TestGif = struct {
    list: std.ArrayList(u8) = .empty,

    fn deinit(g: *TestGif) void {
        g.list.deinit(testing.allocator);
    }

    fn add(g: *TestGif, b: []const u8) !void {
        try g.list.appendSlice(testing.allocator, b);
    }

    fn lzw(g: *TestGif, min_size: u8, pixels: []const u8) !void {
        const gpa = testing.allocator;
        try g.list.append(gpa, min_size);
        var packed_bytes: std.ArrayList(u8) = .empty;
        defer packed_bytes.deinit(gpa);
        const clear: u32 = @as(u32, 1) << @intCast(min_size);
        var width: u5 = @intCast(min_size + 1);
        var avail: u32 = clear + 2;
        var bits: u64 = clear;
        var count: u6 = width;
        var started = false;
        for (pixels) |p| {
            if (started and avail < max_codes) {
                avail += 1;
            }
            bits |= @as(u64, p) << count;
            count += width;
            if (started and avail == @as(u32, 1) << width and width < 12) width += 1;
            started = true;
            while (count >= 8) {
                try packed_bytes.append(gpa, @truncate(bits));
                bits >>= 8;
                count -= 8;
            }
        }
        bits |= @as(u64, clear + 1) << count;
        count += width;
        while (count > 0) {
            try packed_bytes.append(gpa, @truncate(bits));
            bits >>= 8;
            count -|= 8;
        }
        var rest = packed_bytes.items;
        while (rest.len > 0) {
            const n = @min(rest.len, 255);
            try g.list.append(gpa, @intCast(n));
            try g.add(rest[0..n]);
            rest = rest[n..];
        }
        try g.list.append(gpa, 0);
        try g.list.append(gpa, 0x3B);
    }
};

fn expectPixel(d: Decoded, x: u32, y: u32, bgra: [4]u8) !void {
    try testing.expectEqualSlices(u8, &bgra, d.bgra[(@as(usize, y) * d.width + x) * 4..][0..4]);
}

/// The worked example of the format's usual explanation, a real encoder's bytes.
const sample = [_]u8{
    'G', 'I', 'F', '8', '9', 'a', 10, 0, 10, 0, 0x91, 0, 0,
    0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0, 0xFF, 0, 0, 0,
    0x21, 0xF9, 4, 0, 0, 0, 0, 0,
    0x2C, 0, 0, 0, 0, 10, 0, 10, 0, 0,
    2, 22, 0x8C, 0x2D, 0x99, 0x87, 0x2A, 0x1C, 0xDC, 0x33, 0xA0, 0x02, 0x75, 0xEC, 0x95, 0xFA, 0xA8, 0xDE, 0x60, 0x8C, 0x04, 0x91, 0x4C, 0x01, 0,
    0x3B,
};

test "a real encoder's GIF, palette and LZW and its clear and end codes" {
    const gpa = testing.allocator;
    try testing.expect(matches(&sample));
    try testing.expect(!matches("GIF88a"));
    const s = size(&sample).?;
    try testing.expectEqual(@as(u32, 10), s.width);
    const d = try decode(gpa, &sample);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(u32, 10), d.width);
    try testing.expectEqual(@as(u32, 10), d.height);
    const rows = [10]*const [10]u8{
        "1111122222", "1111122222", "1111122222", "1110000222", "1110000222",
        "2220000111", "2220000111", "2222211111", "2222211111", "2222211111",
    };
    const colors = [3][4]u8{ .{ 255, 255, 255, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 0, 0, 255 } };
    for (rows, 0..) |row, y| for (row, 0..) |ch, x| try expectPixel(d, @intCast(x), @intCast(y), colors[ch - '0']);
}

fn header(g: *TestGif, w: u8, h: u8, palette: []const u8, table_bits: u8) !void {
    try g.add("GIF89a");
    try g.add(&.{ w, 0, h, 0, 0x80 | table_bits, 0, 0 });
    try g.add(palette);
}

test "a frame at an offset, its transparency index, and an interlaced frame's row order" {
    const gpa = testing.allocator;
    const palette = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120 };

    var g: TestGif = .{};
    defer g.deinit();
    try header(&g, 4, 3, &palette, 1);
    try g.add(&.{ 0x21, 0xF9, 4, 1, 0, 0, 2, 0 }); // index 2 is transparent
    try g.add(&.{ 0x2C, 1, 0, 1, 0, 2, 0, 2, 0, 0 });
    try g.lzw(2, &.{ 0, 1, 2, 3 });
    const d = try decode(gpa, g.list.items);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(u32, 4), d.width);
    try testing.expectEqual(@as(u32, 3), d.height);
    try expectPixel(d, 0, 0, .{ 0, 0, 0, 0 });
    try expectPixel(d, 1, 1, .{ 30, 20, 10, 255 });
    try expectPixel(d, 2, 1, .{ 60, 50, 40, 255 });
    try expectPixel(d, 1, 2, .{ 0, 0, 0, 0 });
    try expectPixel(d, 2, 2, .{ 120, 110, 100, 255 });
    try expectPixel(d, 3, 2, .{ 0, 0, 0, 0 });

    // Nine rows in the order 0 8, 4, 2 6, 1 3 5 7: coded index is the true row mod 4.
    var il: TestGif = .{};
    defer il.deinit();
    try header(&il, 1, 9, &palette, 1);
    try il.add(&.{ 0x2C, 0, 0, 0, 0, 1, 0, 9, 0, 0x40 });
    const order = [_]u8{ 0, 8, 4, 2, 6, 1, 3, 5, 7 };
    var coded: [9]u8 = undefined;
    for (order, &coded) |row, *c| c.* = row % 4;
    try il.lzw(2, &coded);
    const di = try decode(gpa, il.list.items);
    defer di.deinit(gpa);
    for (0..9) |y| try testing.expectEqual(palette[(y % 4) * 3 + 2], di.bgra[y * 4]);
}

test "a local palette, a full dictionary without a clear, a cut-short frame, a frame past the screen" {
    const gpa = testing.allocator;
    const palette = [_]u8{ 1, 1, 1, 2, 2, 2 };
    const local = [_]u8{ 9, 8, 7, 6, 5, 4 };

    var g: TestGif = .{};
    defer g.deinit();
    try header(&g, 100, 100, &palette, 0);
    try g.add(&.{ 0x2C, 0, 0, 0, 0, 100, 0, 100, 0, 0x80 });
    try g.add(&local);
    var noise: [10000]u8 = undefined;
    var rng = std.Random.DefaultPrng.init(1);
    for (&noise) |*n| n.* = rng.random().int(u1);
    try g.lzw(2, &noise);
    const d = try decode(gpa, g.list.items);
    defer d.deinit(gpa);
    for (noise, 0..) |n, i| try testing.expectEqual(local[@as(usize, n) * 3 + 2], d.bgra[i * 4]);

    const cut = try decode(gpa, g.list.items[0 .. g.list.items.len / 2]);
    defer cut.deinit(gpa);
    try testing.expectEqual(@as(u8, 255), cut.bgra[3]);
    try testing.expectEqual(@as(u8, 0), cut.bgra[cut.bgra.len - 1]);

    var big: TestGif = .{};
    defer big.deinit();
    try header(&big, 1, 1, &palette, 0);
    try big.add(&.{ 0x2C, 1, 0, 0, 0, 2, 0, 1, 0, 0 });
    try big.lzw(2, &.{ 0, 1 });
    try testing.expectEqual(@as(u32, 3), size(big.list.items).?.width);
    const db = try decode(gpa, big.list.items);
    defer db.deinit(gpa);
    try testing.expectEqual(@as(u32, 3), db.width);
    try expectPixel(db, 2, 0, .{ 2, 2, 2, 255 });
}

test "refusals" {
    const gpa = testing.allocator;
    try testing.expectError(error.NotGif, decode(gpa, "PNG"));
    try testing.expectError(error.Corrupt, decode(gpa, "GIF89a"));
    try testing.expectEqual(@as(?Size, null), size("GIF89a"));
    var g: TestGif = .{};
    defer g.deinit();
    try g.add("GIF89a");
    try g.add(&.{ 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2 });
    try testing.expectError(error.TooLarge, decode(gpa, g.list.items));
    try testing.expectEqual(@as(u32, 65535), size(g.list.items).?.width);
}

/// PIL's encoder: 32x20, interlaced, index 3 transparent, a pattern of 16 colors.
const real_interlaced = [_]u8{
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x20, 0x00, 0x14, 0x00, 0x83, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x10, 0xEF, 0x08, 0x20, 0xDF, 0x10, 0x30, 0xCF,
    0x18, 0x40, 0xBF, 0x20, 0x50, 0xAF, 0x28, 0x60, 0x9F, 0x30, 0x70, 0x8F, 0x38, 0x80, 0x7F, 0x40, 0x90, 0x6F, 0x48, 0xA0, 0x5F, 0x50, 0xB0, 0x4F,
    0x58, 0xC0, 0x3F, 0x60, 0xD0, 0x2F, 0x68, 0xE0, 0x1F, 0x70, 0xF0, 0x0F, 0x78, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x03, 0x00, 0x2C, 0x00, 0x00,
    0x00, 0x00, 0x20, 0x00, 0x14, 0x00, 0x40, 0x08, 0xF1, 0x00, 0x01, 0x08, 0x0C, 0x40, 0x50, 0x80, 0xC1, 0x01, 0x08, 0x09, 0x28, 0x2C, 0xC0, 0xD0,
    0x80, 0xC3, 0x03, 0x10, 0x11, 0x48, 0x4C, 0x40, 0x51, 0x81, 0x02, 0x85, 0x04, 0x18, 0x16, 0x70, 0x68, 0x00, 0xE2, 0x01, 0x89, 0x08, 0x28, 0x26,
    0xB0, 0xA8, 0x60, 0x81, 0x49, 0x06, 0x28, 0x1B, 0xA8, 0x74, 0xE0, 0x00, 0xA4, 0x48, 0x92, 0x26, 0x17, 0xA0, 0x64, 0xA0, 0xB2, 0x01, 0x4B, 0x07,
    0x0F, 0x72, 0x0A, 0x04, 0x40, 0x30, 0x80, 0xC1, 0x9F, 0x08, 0x07, 0x60, 0xD4, 0xC8, 0xD1, 0xA3, 0xCB, 0x8A, 0x16, 0x63, 0xA2, 0x2C, 0x1A, 0x71,
    0x22, 0xD2, 0x92, 0x27, 0x53, 0xAE, 0x64, 0x99, 0xF3, 0xC1, 0xC0, 0x82, 0x07, 0x13, 0x2E, 0x6C, 0xF8, 0xB0, 0x69, 0xC8, 0xA7, 0x26, 0x83, 0x0E,
    0xE5, 0xDA, 0xD1, 0xEB, 0xCB, 0xA4, 0x51, 0x69, 0x36, 0x20, 0xDA, 0xF5, 0xA3, 0xD3, 0x91, 0x68, 0x65, 0x4A, 0xB5, 0x49, 0xF5, 0x81, 0xD1, 0xB7,
    0x30, 0xD3, 0xD6, 0xBC, 0x59, 0x75, 0x27, 0xC1, 0xB3, 0x50, 0xE5, 0xAA, 0xA5, 0x8B, 0x53, 0xE7, 0x55, 0x9F, 0x59, 0xFD, 0x62, 0x15, 0x20, 0x76,
    0xEB, 0xC6, 0xB6, 0x47, 0xE1, 0xF6, 0x04, 0xAA, 0x35, 0x23, 0xD9, 0xBB, 0x5F, 0xE1, 0x42, 0xA5, 0x2C, 0xD4, 0x31, 0x53, 0xB7, 0x99, 0xF3, 0xCA,
    0x6D, 0x6C, 0xF9, 0x71, 0x59, 0xD0, 0x80, 0x95, 0x4A, 0x1D, 0x6B, 0x1A, 0x73, 0x6A, 0xBD, 0x53, 0xD9, 0x9E, 0x8E, 0x2C, 0x7A, 0xE6, 0xDE, 0xBA,
    0x9F, 0x69, 0xC7, 0xB5, 0x3D, 0xB5, 0xB0, 0x55, 0x00, 0xAE, 0xC1, 0xC2, 0x26, 0xDC, 0xF7, 0xAA, 0xEE, 0xC0, 0xBC, 0x89, 0x1B, 0xE6, 0x89, 0xF5,
    0xB5, 0xE0, 0xDB, 0xBE, 0x15, 0x23, 0x66, 0x3C, 0x20, 0x20, 0x00, 0x3B,
};

/// PIL's encoder: 12x10 of random indices.
const real_noise = [_]u8{
    0x47, 0x49, 0x46, 0x38, 0x37, 0x61, 0x0C, 0x00, 0x0A, 0x00, 0x83, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x10, 0xEF, 0x08, 0x20, 0xDF, 0x10, 0x30, 0xCF,
    0x18, 0x40, 0xBF, 0x20, 0x50, 0xAF, 0x28, 0x60, 0x9F, 0x30, 0x70, 0x8F, 0x38, 0x80, 0x7F, 0x40, 0x90, 0x6F, 0x48, 0xA0, 0x5F, 0x50, 0xB0, 0x4F,
    0x58, 0xC0, 0x3F, 0x60, 0xD0, 0x2F, 0x68, 0xE0, 0x1F, 0x70, 0xF0, 0x0F, 0x78, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x00, 0x0A, 0x00, 0x00, 0x08,
    0x79, 0x00, 0x11, 0x2C, 0x00, 0xE0, 0xE0, 0x40, 0x80, 0x02, 0x03, 0x16, 0x3C, 0x38, 0xC0, 0x60, 0xC0, 0x01, 0x00, 0x06, 0x1A, 0x20, 0x28, 0xC0,
    0xA0, 0x80, 0x00, 0x02, 0x0E, 0x08, 0x10, 0x00, 0x00, 0xD1, 0x40, 0x81, 0x02, 0x09, 0x14, 0x18, 0xF0, 0x68, 0x80, 0x41, 0x02, 0x00, 0x0B, 0x1A,
    0x14, 0x20, 0x80, 0x40, 0x80, 0x82, 0x93, 0x0A, 0x04, 0x24, 0x58, 0x90, 0xE0, 0x81, 0x82, 0x02, 0x0F, 0x1E, 0x14, 0x08, 0x80, 0x00, 0x25, 0x03,
    0x00, 0x0D, 0x16, 0xFC, 0x74, 0x70, 0xD0, 0x80, 0x43, 0x07, 0x0B, 0x16, 0x20, 0x70, 0x90, 0x30, 0x41, 0x80, 0x06, 0x02, 0x0C, 0x28, 0x58, 0x40,
    0x40, 0x41, 0xCB, 0x90, 0x09, 0x2C, 0x12, 0xA8, 0xB9, 0x53, 0x00, 0x83, 0x00, 0x07, 0x94, 0x3A, 0x68, 0x40, 0x20, 0x40, 0x00, 0x9B, 0x06, 0x08,
    0x04, 0x04, 0x00, 0x3B,
};

test "a real interlaced, transparent GIF" {
    const gpa = testing.allocator;
    const d = try decode(gpa, &real_interlaced);
    defer d.deinit(gpa);
    try testing.expectEqual(@as(u32, 32), d.width);
    try testing.expectEqual(@as(u32, 20), d.height);
    for (0..20) |y| for (0..32) |x| {
        const i: u8 = @intCast((x / 3 + y / 2) % 16);
        const want: [4]u8 = if (i == 3) .{ 0, 0, 0, 0 } else .{ i * 8, 255 - i * 16, i * 16, 255 };
        try expectPixel(d, @intCast(x), @intCast(y), want);
    };
}

fn mustNotCrash(gpa: std.mem.Allocator, bytes: []const u8) void {
    _ = matches(bytes);
    _ = size(bytes);
    const d = decode(gpa, bytes) catch return;
    std.debug.assert(d.bgra.len == @as(usize, d.width) * d.height * 4);
    d.deinit(gpa);
}

test "every byte mutated and every truncation of real files: no crash, no leak" {
    const gpa = testing.allocator;
    for ([_][]const u8{ &sample, &real_interlaced, &real_noise }) |file| {
        const copy = try gpa.dupe(u8, file);
        defer gpa.free(copy);
        for (copy, 0..) |*b, i| {
            const was = b.*;
            for ([_]u8{ was ^ 0xFF, was ^ 0x01, was ^ 0x80, 0xFF, 0x00 }) |v| {
                b.* = v;
                mustNotCrash(gpa, copy);
            }
            b.* = was;
            mustNotCrash(gpa, copy[0..i]);
        }
    }
}

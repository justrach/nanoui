//! WOFF2's transformed `glyf` table back to TrueType's `glyf` and `loca`: seven
//! streams of contour counts, point counts, flags, coordinates, components,
//! bounding boxes and instructions, read glyph by glyph into the plain form.
const std = @import("std");
const sfnt = @import("sfnt.zig");

const Error = sfnt.Error;
const Stream = sfnt.Stream;

pub const Result = struct {
    glyf: []const u8,
    loca: []const u8,
    /// Each glyph's xMin, which a transformed `hmtx` may leave out.
    x_mins: []const i16,
};

const Point = struct { x: i32, y: i32, on: bool };

fn withSign(flag: u8, magnitude: i32) i32 {
    return if (flag & 1 != 0) magnitude else -magnitude;
}

/// One point's move from the flag and glyph streams (WOFF2 §5.2).
fn triplet(flag_in: u8, g: *Stream) Error![2]i32 {
    const flag = flag_in & 0x7f;
    if (flag < 84) {
        const b = try g.byte();
        if (flag < 10) return .{ 0, withSign(flag, (@as(i32, flag & 14) << 7) + b) };
        if (flag < 20) return .{ withSign(flag, (@as(i32, (flag - 10) & 14) << 7) + b), 0 };
        const b0: i32 = flag - 20;
        return .{ withSign(flag, 1 + (b0 & 0x30) + (b >> 4)), withSign(flag >> 1, 1 + ((b0 & 0x0c) << 2) + (b & 0x0f)) };
    }
    if (flag < 120) {
        const b = try g.take(2);
        const b0: i32 = flag - 84;
        return .{ withSign(flag, 1 + (@divTrunc(b0, 12) << 8) + b[0]), withSign(flag >> 1, 1 + ((@rem(b0, 12) >> 2) << 8) + b[1]) };
    }
    if (flag < 124) {
        const b = try g.take(3);
        return .{ withSign(flag, (@as(i32, b[0]) << 4) + (b[1] >> 4)), withSign(flag >> 1, (@as(i32, b[1] & 0x0f) << 8) + b[2]) };
    }
    const b = try g.take(4);
    return .{ withSign(flag, (@as(i32, b[0]) << 8) + b[1]), withSign(flag >> 1, (@as(i32, b[2]) << 8) + b[3]) };
}

const Writer = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn u16be(w: *Writer, v: anytype) Error!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, @truncate(@as(u32, @bitCast(@as(i32, v)))), .big);
        try w.bytes(&b);
    }

    fn bytes(w: *Writer, b: []const u8) Error!void {
        if (w.out.items.len + b.len > sfnt.max_font) return error.TooLarge;
        try w.out.appendSlice(w.a, b);
    }

    fn pad4(w: *Writer) Error!void {
        while (w.out.items.len & 3 != 0) try w.bytes(&.{0});
    }
};

/// The plain coordinates of a simple glyph, as compactly as TrueType allows.
fn writeCoords(w: *Writer, points: []const Point, overlap: bool) Error!void {
    var last_flag: ?u8 = null;
    var repeat: u8 = 0;
    var x0: i32 = 0;
    var y0: i32 = 0;
    // Flags, each run of equals one flag and a count.
    var flags_at = w.out.items.len;
    for (points, 0..) |p, i| {
        const dx = p.x - x0;
        const dy = p.y - y0;
        var flag: u8 = if (p.on) 1 else 0;
        if (overlap and i == 0) flag |= 0x40;
        if (dx == 0) {
            flag |= 0x10;
        } else if (dx >= -255 and dx <= 255) {
            flag |= 0x02 | (if (dx > 0) @as(u8, 0x10) else 0);
        }
        if (dy == 0) {
            flag |= 0x20;
        } else if (dy >= -255 and dy <= 255) {
            flag |= 0x04 | (if (dy > 0) @as(u8, 0x20) else 0);
        }
        if (last_flag == flag and repeat < 255) {
            if (repeat == 0) w.out.items[flags_at - 1] |= 0x08 else w.out.items.len -= 1;
            repeat += 1;
            try w.bytes(&.{repeat});
        } else {
            repeat = 0;
            try w.bytes(&.{flag});
            last_flag = flag;
        }
        flags_at = w.out.items.len;
        x0 = p.x;
        y0 = p.y;
    }
    x0 = 0;
    for (points) |p| {
        const dx = p.x - x0;
        if (dx != 0) {
            if (dx >= -255 and dx <= 255) {
                try w.bytes(&.{@intCast(@abs(dx))});
            } else {
                if (dx < std.math.minInt(i16) or dx > std.math.maxInt(i16)) return error.Corrupt;
                try w.u16be(dx);
            }
        }
        x0 = p.x;
    }
    y0 = 0;
    for (points) |p| {
        const dy = p.y - y0;
        if (dy != 0) {
            if (dy >= -255 and dy <= 255) {
                try w.bytes(&.{@intCast(@abs(dy))});
            } else {
                if (dy < std.math.minInt(i16) or dy > std.math.maxInt(i16)) return error.Corrupt;
                try w.u16be(dy);
            }
        }
        y0 = p.y;
    }
}

/// Puts the table back together. `loca_len` is the length the `loca` entry
/// promised, which must fit the glyph count.
pub fn rebuild(a: std.mem.Allocator, data: []const u8, loca_len: u32) Error!Result {
    var h: Stream = .{ .d = data };
    _ = try h.u16be();
    const options = try h.u16be();
    const num_glyphs = try h.u16be();
    const index_format = try h.u16be();
    if (index_format > 1) return error.Corrupt;
    const entry: usize = if (index_format == 0) 2 else 4;
    if (loca_len != (@as(usize, num_glyphs) + 1) * entry) return error.Corrupt;
    var sizes: [7]u32 = undefined;
    for (&sizes) |*n| n.* = try h.u32be();
    var streams: [7]Stream = undefined;
    for (&streams, sizes) |*st, n| st.* = .{ .d = try h.take(n) };
    const n_contour = &streams[0];
    const n_points = &streams[1];
    const flags = &streams[2];
    const glyph = &streams[3];
    const composite = &streams[4];
    const bbox = &streams[5];
    const instructions = &streams[6];
    const bitmap = try bbox.take(4 * ((@as(usize, num_glyphs) + 31) / 32));
    const overlap: ?[]const u8 = if (options & 1 != 0) try h.take((@as(usize, num_glyphs) + 7) / 8) else null;

    var w: Writer = .{ .a = a };
    const offsets = try a.alloc(u32, @as(usize, num_glyphs) + 1);
    const x_mins = try a.alloc(i16, num_glyphs);
    var points: std.ArrayList(Point) = .empty;
    var ends: std.ArrayList(u16) = .empty;
    for (0..num_glyphs) |g| {
        offsets[g] = @intCast(w.out.items.len);
        x_mins[g] = 0;
        const has_box = bitmap[g / 8] & (@as(u8, 0x80) >> @intCast(g % 8)) != 0;
        const contours = try n_contour.u16be();
        if (contours == 0) {
            if (has_box) return error.Corrupt;
            continue;
        }
        if (contours == 0xffff) {
            if (!has_box) return error.Corrupt;
            const box = try bbox.take(8);
            x_mins[g] = std.mem.readInt(i16, box[0..2], .big);
            try w.bytes(&.{ 0xff, 0xff });
            try w.bytes(box);
            var has_instructions = false;
            var more = true;
            while (more) {
                const f = try composite.u16be();
                const glyph_id = try composite.u16be();
                var b: [2]u8 = undefined;
                std.mem.writeInt(u16, &b, f, .big);
                try w.bytes(&b);
                std.mem.writeInt(u16, &b, glyph_id, .big);
                try w.bytes(&b);
                var extra: usize = if (f & 1 != 0) 4 else 2;
                if (f & 8 != 0) extra += 2 else if (f & 0x40 != 0) extra += 4 else if (f & 0x80 != 0) extra += 8;
                try w.bytes(try composite.take(extra));
                if (f & 0x100 != 0) has_instructions = true;
                more = f & 0x20 != 0;
            }
            if (has_instructions) {
                const n = try glyph.uint255();
                try w.u16be(@as(i32, n));
                try w.bytes(try instructions.take(n));
            }
            try w.pad4();
            continue;
        }
        if (contours > 0x7fff) return error.Corrupt;
        // Simple: the contours' lengths, then their points.
        ends.clearRetainingCapacity();
        points.clearRetainingCapacity();
        var total: u32 = 0;
        for (0..contours) |_| {
            total += try n_points.uint255();
            if (total == 0 or total > 0xffff) return error.Corrupt;
            try ends.append(a, @intCast(total - 1));
        }
        if (total > flags.left()) return error.Corrupt;
        var x: i32 = 0;
        var y: i32 = 0;
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);
        for (0..total) |_| {
            const f = try flags.byte();
            const move = try triplet(f, glyph);
            x += move[0];
            y += move[1];
            try points.append(a, .{ .x = x, .y = y, .on = f & 0x80 == 0 });
            min_x = @min(min_x, x);
            min_y = @min(min_y, y);
            max_x = @max(max_x, x);
            max_y = @max(max_y, y);
        }
        const ins_len = try glyph.uint255();
        const ins = try instructions.take(ins_len);
        try w.u16be(@as(i32, contours));
        if (has_box) {
            const box = try bbox.take(8);
            x_mins[g] = std.mem.readInt(i16, box[0..2], .big);
            try w.bytes(box);
        } else {
            for ([_]i32{ min_x, min_y, max_x, max_y }) |v| {
                if (v < std.math.minInt(i16) or v > std.math.maxInt(i16)) return error.Corrupt;
                try w.u16be(v);
            }
            x_mins[g] = @intCast(min_x);
        }
        for (ends.items) |e| try w.u16be(@as(i32, e));
        try w.u16be(@as(i32, ins_len));
        try w.bytes(ins);
        const overlaps = if (overlap) |o| o[g / 8] & (@as(u8, 0x80) >> @intCast(g % 8)) != 0 else false;
        try writeCoords(&w, points.items, overlaps);
        try w.pad4();
    }
    offsets[num_glyphs] = @intCast(w.out.items.len);
    const loca = try a.alloc(u8, loca_len);
    for (offsets, 0..) |o, i| {
        if (index_format == 0) {
            if (o / 2 > 0xffff) return error.Corrupt;
            std.mem.writeInt(u16, loca[2 * i..][0..2], @intCast(o / 2), .big);
        } else {
            std.mem.writeInt(u32, loca[4 * i..][0..4], o, .big);
        }
    }
    return .{ .glyf = w.out.items, .loca = loca, .x_mins = x_mins };
}

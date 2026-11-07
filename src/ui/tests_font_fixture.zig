//! A tiny made-up TrueType font: one rectangular glyph, ASCII mapped to
//! it, and a space. No installed font files or user state in parity tests.
const std = @import("std");

pub const family = "Nano Parity Fixture";
pub const Bytes = [1536]u8;

fn u16At(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .big);
}

fn u32At(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .big);
}

fn sum(b: []const u8) u32 {
    var out: u32 = 0;
    var i: usize = 0;
    while (i < b.len) : (i += 4) {
        var word: u32 = 0;
        for (0..4) |j| word = (word << 8) | (if (i + j < b.len) @as(u32, b[i + j]) else 0);
        out +%= word;
    }
    return out;
}

/// A complete sfnt with valid checksums; only its glyph advance varies.
pub fn make(advance: u16) Bytes {
    @setEvalBranchQuota(100000);
    var b: Bytes = @splat(0);
    u32At(&b, 0, 0x00010000);
    u16At(&b, 4, 10);
    u16At(&b, 6, 128);
    u16At(&b, 8, 3);
    u16At(&b, 10, 32);
    const tables = .{
        .{ "OS/2", 78 }, .{ "cmap", 234 }, .{ "glyf", 34 },
        .{ "head", 54 }, .{ "hhea", 36 },  .{ "hmtx", 12 },
        .{ "loca", 8 },  .{ "maxp", 32 },  .{ "name", 256 },
        .{ "post", 32 },
    };
    var at: usize = 12 + tables.len * 16;
    var head: usize = 0;
    inline for (tables, 0..) |entry, i| {
        const tag = entry[0];
        const len = entry[1];
        const record = 12 + i * 16;
        @memcpy(b[record..][0..4], tag);
        u32At(&b, record + 8, @intCast(at));
        u32At(&b, record + 12, len);
        if (comptime std.mem.eql(u8, tag, "OS/2")) {
            u16At(&b, at + 2, advance);
            u16At(&b, at + 4, 400);
            u16At(&b, at + 6, 5);
            u32At(&b, at + 42, 1);
            @memcpy(b[at + 58 ..][0..4], "TEST");
            u16At(&b, at + 62, 0x40);
            u16At(&b, at + 64, 32);
            u16At(&b, at + 66, 126);
            u16At(&b, at + 68, 800);
            u16At(&b, at + 70, @bitCast(@as(i16, -200)));
            u16At(&b, at + 74, 800);
            u16At(&b, at + 76, 200);
        } else if (comptime std.mem.eql(u8, tag, "cmap")) {
            u16At(&b, at + 2, 1);
            u16At(&b, at + 4, 3);
            u16At(&b, at + 6, 1);
            u32At(&b, at + 8, 12);
            const f = at + 12;
            u16At(&b, f, 4);
            u16At(&b, f + 2, 222);
            u16At(&b, f + 6, 4);
            u16At(&b, f + 8, 4);
            u16At(&b, f + 10, 1);
            u16At(&b, f + 14, 126);
            u16At(&b, f + 16, 0xffff);
            u16At(&b, f + 20, 32);
            u16At(&b, f + 22, 0xffff);
            u16At(&b, f + 26, 1);
            u16At(&b, f + 28, 4);
            for (0..95) |c| u16At(&b, f + 32 + c * 2, if (c == 0) 2 else 1);
        } else if (comptime std.mem.eql(u8, tag, "glyf")) {
            u16At(&b, at, 1);
            u16At(&b, at + 6, 500);
            u16At(&b, at + 8, 700);
            u16At(&b, at + 10, 3);
            @memset(b[at + 14 ..][0..4], 1);
            u16At(&b, at + 20, 500);
            u16At(&b, at + 24, @bitCast(@as(i16, -500)));
            u16At(&b, at + 30, 700);
        } else if (comptime std.mem.eql(u8, tag, "head")) {
            head = at;
            u32At(&b, at, 0x00010000);
            u32At(&b, at + 4, 0x00010000);
            u32At(&b, at + 12, 0x5f0f3cf5);
            u16At(&b, at + 16, 3);
            u16At(&b, at + 18, 1000);
            u16At(&b, at + 40, 500);
            u16At(&b, at + 42, 700);
            u16At(&b, at + 46, 8);
            u16At(&b, at + 48, 2);
        } else if (comptime std.mem.eql(u8, tag, "hhea")) {
            u32At(&b, at, 0x00010000);
            u16At(&b, at + 4, 800);
            u16At(&b, at + 6, @bitCast(@as(i16, -200)));
            u16At(&b, at + 10, advance);
            u16At(&b, at + 16, 500);
            u16At(&b, at + 18, 1);
            u16At(&b, at + 34, 3);
        } else if (comptime std.mem.eql(u8, tag, "hmtx")) {
            u16At(&b, at, advance);
            u16At(&b, at + 4, advance);
            u16At(&b, at + 8, advance / 2);
        } else if (comptime std.mem.eql(u8, tag, "loca")) {
            u16At(&b, at + 4, 17);
            u16At(&b, at + 6, 17);
        } else if (comptime std.mem.eql(u8, tag, "maxp")) {
            u32At(&b, at, 0x00010000);
            u16At(&b, at + 4, 3);
            u16At(&b, at + 6, 4);
            u16At(&b, at + 8, 1);
            u16At(&b, at + 14, 1);
        } else if (comptime std.mem.eql(u8, tag, "name")) {
            const names = .{ .{ 1, family }, .{ 2, "Regular" }, .{ 4, family ++ " Regular" }, .{ 6, "NanoParityFixture-Regular" } };
            u16At(&b, at + 2, names.len);
            u16At(&b, at + 4, 6 + names.len * 12);
            var off: usize = 0;
            inline for (names, 0..) |name, j| {
                const r = at + 6 + j * 12;
                u16At(&b, r, 3);
                u16At(&b, r + 2, 1);
                u16At(&b, r + 4, 0x409);
                u16At(&b, r + 6, name[0]);
                u16At(&b, r + 8, name[1].len * 2);
                u16At(&b, r + 10, @intCast(off));
                for (name[1]) |c| {
                    u16At(&b, at + 6 + names.len * 12 + off, c);
                    off += 2;
                }
            }
        } else if (comptime std.mem.eql(u8, tag, "post")) {
            u32At(&b, at, 0x00030000);
        }
        u32At(&b, record + 4, sum(b[at .. at + len]));
        at = (at + len + 3) & ~@as(usize, 3);
    }
    u32At(&b, head + 8, 0xb1b0afba -% sum(&b));
    return b;
}

test "the synthetic parity font has its requested metrics and outline" {
    const bytes = make(900);
    const f = try @import("tt/font.zig").Font.init(&bytes, 0);
    try std.testing.expectEqualStrings(family, f.style.name());
    try std.testing.expectEqual(@as(f32, 900), f.advance(f.glyphIndex('A')));
    try std.testing.expect(f.bounds(f.glyphIndex('A')) != null);
    try std.testing.expectEqual(@as(u32, 0xb1b0afba), sum(&bytes));
}

//! Brotli's decoder against streams Node's zlib made, and against hostile ones:
//! every byte of each small stream changed and every truncation, under the leak
//! checker, ending in an answer or an error.
const std = @import("std");
const brotli = @import("brotli.zig");

/// Pairs of a text and its brotli, each with two little-endian lengths before.
const fixtures = @embedFile("data/brotli-fixtures.bin");

const Pair = struct { raw: []const u8, comp: []const u8 };

fn next(at: *usize) ?Pair {
    if (at.* + 8 > fixtures.len) return null;
    const raw_len = std.mem.readInt(u32, fixtures[at.*..][0..4], .little);
    const comp_len = std.mem.readInt(u32, fixtures[at.* + 4..][0..4], .little);
    const raw = fixtures[at.* + 8..][0..raw_len];
    const comp = fixtures[at.* + 8 + raw_len..][0..comp_len];
    at.* += 8 + raw_len + comp_len;
    return .{ .raw = raw, .comp = comp };
}

test "brotli decodes what a real encoder made, text, dictionary words and all" {
    const gpa = std.testing.allocator;
    var at: usize = 0;
    var n: usize = 0;
    while (next(&at)) |p| : (n += 1) {
        const got = try brotli.decode(gpa, p.comp, 1 << 20);
        defer gpa.free(got);
        try std.testing.expectEqualSlices(u8, p.raw, got);
    }
    try std.testing.expectEqual(@as(usize, 9), n);
}

test "the static dictionary is the RFC's" {
    try std.testing.expectEqual(@as(usize, 122784), brotli.dictionary.len);
    try std.testing.expectEqual(@as(u32, 0x5136cb04), std.hash.Crc32.hash(brotli.dictionary));
}

test "brotli refuses a stream past the output limit" {
    const gpa = std.testing.allocator;
    var at: usize = 0;
    while (next(&at)) |p| {
        if (p.raw.len < 100) continue;
        try std.testing.expectError(error.TooLarge, brotli.decode(gpa, p.comp, p.raw.len / 2));
    }
}

test "brotli survives every changed byte and every truncation" {
    const gpa = std.testing.allocator;
    var at: usize = 0;
    while (next(&at)) |p| {
        // The big one comes next, with fewer changes per byte.
        const stream = p.comp;
        var buf: [256]u8 = undefined;
        if (stream.len > buf.len) continue;
        for (0..stream.len) |i| {
            @memcpy(buf[0..stream.len], stream);
            for ([_]u8{ 0, 0xff, stream[i] ^ 1, stream[i] ^ 0x80, stream[i] +% 1 }) |v| {
                buf[i] = v;
                if (brotli.decode(gpa, buf[0..stream.len], 1 << 20)) |out| {
                    gpa.free(out);
                } else |_| {}
            }
            if (brotli.decode(gpa, stream[0..i], 1 << 20)) |out| {
                gpa.free(out);
            } else |_| {}
        }
    }
}

test "brotli's big stream survives changes across it" {
    const gpa = std.testing.allocator;
    var at: usize = 0;
    while (next(&at)) |p| {
        if (p.comp.len <= 256) continue;
        const buf = try gpa.dupe(u8, p.comp);
        defer gpa.free(buf);
        for (0..buf.len) |i| {
            buf[i] ^= 0x55;
            if (brotli.decode(gpa, buf, 1 << 20)) |out| {
                gpa.free(out);
            } else |_| {}
            buf[i] ^= 0x55;
            if (brotli.decode(gpa, p.comp[0..i], 1 << 20)) |out| {
                gpa.free(out);
            } else |_| {}
        }
    }
}

test "out of memory is an error at every allocation, nothing leaked" {
    var at: usize = 0;
    while (next(&at)) |p| {
        if (p.comp.len > 200) continue;
        var i: usize = 0;
        while (i < 64) : (i += 1) {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
            if (brotli.decode(failing.allocator(), p.comp, 1 << 20)) |out| {
                failing.allocator().free(out);
                break;
            } else |e| try std.testing.expect(e == error.OutOfMemory);
        }
    }
}

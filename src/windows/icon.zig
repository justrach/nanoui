//! A window's icon from an ICO's bytes (`Options.icon`): the frame nearest
//! the size the system asks for.
const std = @import("std");
const w = @import("win32.zig");

/// An `HICON` from an ICO's bytes, at the frame nearest `cx` × `cy`.
pub fn iconFrame(ico: []const u8, cx: i32, cy: i32) ?w.HICON {
    if (ico.len < 6) return null;
    const count = readU16(ico, 4);
    var best: ?struct { offset: u32, size: u32 } = null;
    var best_score: u32 = std.math.maxInt(u32);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const entry = 6 + i * 16;
        if (entry + 16 > ico.len) break;
        const width: i32 = if (ico[entry] == 0) 256 else ico[entry];
        const height: i32 = if (ico[entry + 1] == 0) 256 else ico[entry + 1];
        const size = readU32(ico, entry + 8);
        const offset = readU32(ico, entry + 12);
        if (offset > ico.len or size > ico.len - offset) continue;
        const score: u32 = @abs(width - cx) + @abs(height - cy);
        if (score < best_score) {
            best_score = score;
            best = .{ .offset = offset, .size = size };
        }
    }
    const frame = best orelse return null;
    const data: *const anyopaque = @ptrCast(ico.ptr + @as(usize, frame.offset));
    return w.CreateIconFromResourceEx(data, frame.size, 1, 0x00030000, cx, cy, 0);
}

fn readU16(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | (@as(u16, bytes[at + 1]) << 8);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) |
        (@as(u32, bytes[at + 3]) << 24);
}

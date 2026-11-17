//! Texture scenes use CPU-visible reference pixels for borrowed GPU sources.
const std = @import("std");
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const color = @import("color.zig");
extern "nanoui_test" fn fill(encoder: u32, texture: u32) void;
pub const Scene = struct {
    mode: u32 = 5,
    handle: u32 = 0,
    external: u32 = 0,
    external_rgb: [3]u8 = .{ 128, 128, 128 },
    bytes: [128 * 128 * 4]u8 = undefined,
    reference: [128 * 128 * 4]u8 = undefined,
    lut1: [2 * 2 * 2 * 4]f16 = undefined,
    lut2: [2 * 2 * 2 * 4]f16 = undefined,
    pub fn prepare(s: *Scene, mode: u32) void {
        s.mode = mode;
        for (0..24) |y| for (0..32) |x| {
            var rgb: [3]u8 = .{ @intCast(x * 8), @intCast(y * 10), 64 };
            if (mode == 17 or mode == 18) rgb = .{ color.unorm8(@as(f32, @floatFromInt(x)) / 32), color.unorm8(@as(f32, @floatFromInt(y)) / 24), color.unorm8(0.5) };
            if (mode == 8 or mode == 10) rgb = .{ color.unorm8(color.linearToSrgb(@as(f32, @floatFromInt(x)) / 32)), color.unorm8(color.linearToSrgb(@as(f32, @floatFromInt(y)) / 24)), color.unorm8(color.linearToSrgb(0.5)) };
            if (mode == 9 or mode == 11 or mode == 12 or mode == 14 or mode == 15) rgb = s.external_rgb;
            s.bytes[(y * 32 + x) * 4 ..][0..4].* = .{ rgb[2], rgb[1], rgb[0], 255 };
        };
        if (mode == 14 or mode == 15) @memcpy(&s.bytes, &s.reference);
        for (0..8) |k| {
            const r: f16 = @floatFromInt(k & 1);
            const g: f16 = @floatFromInt((k >> 1) & 1);
            const b: f16 = @floatFromInt((k >> 2) & 1);
            s.lut1[k * 4 ..][0..4].* = .{ b, g, r, 1 };
            s.lut2[k * 4 ..][0..4].* = .{ 1 - r, g, b, 1 };
        }
    }
    pub fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).sizeFull().bg(.hex(0xdde1ea));
        defer root.end();
        var source: gpu.Texture = .{ .width = 32, .height = 24, .bgra = s.bytes[0 .. 32 * 24 * 4], .tone_map = false };
        if (s.mode == 14 or s.mode == 15) {
            source.width = 128;
            source.height = 128;
            source.bgra = &s.bytes;
        }
        if (s.mode == 8 or s.mode == 10 or s.mode == 17 or s.mode == 18) source.web_texture = s.handle;
        if (s.mode == 9 or s.mode == 11 or s.mode == 12 or s.mode == 14 or s.mode == 15) source.web_external = s.external;
        if (s.mode == 17) source.encoding = .display_sdr;
        if (s.mode == 18) source.encoding = .surface_linear;
        if (s.mode == 7 or s.mode == 11 or s.mode == 17) {
            source.source_lut = .{ .key = 101, .size = 2, .data = &s.lut1 };
            source.lut = .{ .key = 102, .size = 2, .data = &s.lut2 };
        }
        const style: ui.Style = .{ .absolute = true, .offset = .{ .x = 40, .y = 40 }, .width = .{ .px = 256 }, .height = .{ .px = 192 }, .radius = 12 };
        if (s.mode == 6) ui.textureAffine(c, style, source, .{ 0, 0, 1, 1 }, 0.8, .{ 0.9, 0.2, -0.1, 0.9 }) else ui.texture(c, style, source, .{ 0, 0, 1, 1 }, 0.8);
    }
    pub fn encode(ctx: *anyopaque, encoder: *anyopaque) void {
        const s: *Scene = @ptrCast(@alignCast(ctx));
        fill(@intCast(@intFromPtr(encoder)), s.handle);
    }
};

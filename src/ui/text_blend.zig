//! Direct2D alpha correction, applied at draw time because it depends on
//! foreground color. Adapted from Microsoft's Windows Terminal renderer:
//! src/renderer/atlas/dwrite_helpers.{cpp,hlsl}. See third_party/licenses/Windows-Terminal-MIT.txt.
const std = @import("std");

pub const Params = struct {
    gamma: [4]f32 = .{ 0, 0, 0, 0 },
    contrast: f32 = 0,
    grayscale_contrast: f32 = 0,

    pub fn coverage(p: Params, a: f32, intensity: f32, lightness: f32, subpixel: bool) f32 {
        const k = (if (subpixel) p.contrast else p.grayscale_contrast) * std.math.clamp(3 - 4 * lightness, 0, 1);
        const v = a * (k + 1) / (a * k + 1);
        const g = p.gamma;
        return std.math.clamp(v + v * (1 - v) * ((g[0] * intensity + g[1]) * v + (g[2] * intensity + g[3])), 0, 1);
    }
};

pub fn gammaRatios(gamma: f32) [4]f32 {
    const table = [13][4]f32{
        .{ 0, 0, 0, 0 },
        .{ 0.0166, -0.0807, 0.2227, -0.0751 },
        .{ 0.0350, -0.1760, 0.4325, -0.1370 },
        .{ 0.0543, -0.2821, 0.6302, -0.1876 },
        .{ 0.0739, -0.3963, 0.8167, -0.2287 },
        .{ 0.0933, -0.5161, 0.9926, -0.2616 },
        .{ 0.1121, -0.6395, 1.1588, -0.2877 },
        .{ 0.1300, -0.7649, 1.3159, -0.3080 },
        .{ 0.1469, -0.8911, 1.4644, -0.3234 },
        .{ 0.1627, -1.0170, 1.6051, -0.3347 },
        .{ 0.1773, -1.1420, 1.7385, -0.3426 },
        .{ 0.1908, -1.2652, 1.8650, -0.3476 },
        .{ 0.2031, -1.3864, 1.9851, -0.3501 },
    };
    const i: usize = @intFromFloat(std.math.clamp(@round(gamma * 10), 10, 22) - 10);
    const r = table[i];
    return .{ r[0] * (65536.0 / 65025.0), r[1] * (256.0 / 255.0), r[2] * (65536.0 / 65025.0), r[3] * (256.0 / 255.0) };
}

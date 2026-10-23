//! Verifies the continuous-corner SDF against reference points sampled along
//! Apple's `RoundedRectangle(cornerRadius: r, style: .continuous)` curve.
const std = @import("std");
const testing = std.testing;
const raster = @import("raster.zig");

/// Normalized unit points `(x/r, y/r)` along the corner curve (inward distance
/// from the box's top-left or bottom-right edges).
const ref_points = [_][2]f32{
    .{ 0.0, 1.52866495 },
    .{ 0.002286, 1.173301 },
    .{ 0.018312, 0.903425 },
    .{ 0.061685, 0.675827 },
    .{ 0.0749114, 0.63149399 },
    .{ 0.151889, 0.470190 },
    .{ 0.29150718, 0.29150718 },
    .{ 0.470190, 0.151889 },
    .{ 0.63149399, 0.0749114 },
    .{ 0.675827, 0.061685 },
    .{ 0.903425, 0.018312 },
    .{ 1.173301, 0.002286 },
    .{ 1.52866495, 0.0 },
};

const radii = [_]f32{ 6, 8, 9, 10, 12, 14, 16, 22 };

test "continuous corner SDF zero-crossing is within 0.25 device px at 2x of Apple's curve" {
    const hw: f32 = 100;
    const hh: f32 = 100;
    for (radii) |r| {
        for (ref_points) |pt| {
            const px = hw - pt[0] * r;
            const py = hh - pt[1] * r;
            const d = raster.cornerSdf(px, py, hw, hh, r)[0];
            try testing.expect(@abs(d * 2.0) <= 0.25);
        }
        // Negative radius opts back into circular corners.
        const diag = r * (1.0 - @sqrt(0.5));
        const d_circ = raster.cornerSdf(hw - diag, hh - diag, hw, hh, -r)[0];
        try testing.expect(@abs(d_circ) < 1e-4);
    }
}

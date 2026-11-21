//! CPU reference for the web motion scene. The portable rasterizer has no
//! clock/perspective input; evaluate those transforms before its shared SDF.
const std = @import("std");
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");

pub const Scene = struct {
    pub fn view(_: *Scene, c: *ui.Context) void {
        const root = ui.div(c).sizeFull().bg(.hex(0xeeeeee));
        defer root.end();
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 30, .y = 30 }, .width = .{ .px = 50 }, .height = .{ .px = 40 }, .radius = 12, .background = .hex(0xdd3355), .rotation = 0.13, .spin = 0.7 }, .none, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 160, .y = 35 }, .width = .{ .px = 65 }, .height = .{ .px = 45 }, .radius = 10, .background = .hex(0x3366dd), .pulse = .{ .period = 1.3, .scale_amp = 0.2, .alpha_low = 0.3 } }, .none, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 25, .y = 150 }, .width = .{ .px = 70 }, .height = .{ .px = 40 }, .radius = 12, .background = .hex(0x9955dd) }, .none, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 240, .y = 140 }, .width = .{ .px = 70 }, .height = .{ .px = 75 }, .radius = 6, .background = .hex(0xdd9911), .turn = 0.8, .perspective = 500 }, .none, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 120, .y = 160 }, .width = .{ .px = 45 }, .height = .{ .px = 50 }, .background = .hex(0xff0000), .turn = 2.3, .face = .front }, .none, null);
        _ = c.leaf(.{ .absolute = true, .offset = .{ .x = 160, .y = 235 }, .width = .{ .px = 50 }, .height = .{ .px = 40 }, .background = .hex(0x00aa44), .turn = 2.3, .face = .back }, .none, null);
    }
};
pub fn render(t: *ui.Tester, gpa: std.mem.Allocator) !gpu.Pixels {
    const w: usize = @intFromFloat(t.size.w * t.scale);
    const h: usize = @intFromFloat(t.size.h * t.scale);
    const out: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, w * h * 4), .width = w, .height = h };
    raster.draw(out, &.{}, t.text.atlas.mask(), t.text.images.pictures(), t.scale, t.theme.background);
    for (t.instances.items) |*i| {
        if (i.kind == gpu.Kind.quad and (i.xf[1] != 0 or i.pulse[0] > 0 or i.turn[0] != 0 or i.vel[0] != 0 or i.vel[1] != 0)) quad(out, i, t.scale, @floatCast(t.ctx.time)) else raster.drawOne(out, i, t.text.atlas.mask(), t.text.images.pictures(), t.scale, .{ 0, 0, w, h });
    }
    return out;
}
fn quad(out: gpu.Pixels, i: *const gpu.Instance, scale: f32, time: f32) void {
    const angle = i.xf[0] + i.xf[1] * time;
    const ca = @cos(angle);
    const sa = @sin(angle);
    const ct = @cos(i.turn[0]);
    const st = @sin(i.turn[0]);
    if ((i.vel[2] == 1 and ct < 0) or (i.vel[2] == 2 and ct >= 0) or @abs(ct) < 1e-6) return;
    var pulse: f32 = 1;
    var alpha: f32 = 1;
    if (i.pulse[0] > 0) {
        const s = 0.5 - 0.5 * @cos(2 * std.math.pi * time / i.pulse[0]);
        pulse = 1 + i.pulse[1] * (2 * s - 1);
        alpha = i.pulse[2] + (1 - i.pulse[2]) * s;
    }
    var vx = i.vel[0];
    var vy = i.vel[1];
    const length = @sqrt(vx * vx + vy * vy);
    if (length > 24) {
        vx *= 24 / length;
        vy *= 24 / length;
    }
    const blur = length > 0.5;
    const samples: u32 = if (blur) 5 else 1;
    const grow: f32 = 0;
    const hw = i.rect[2] * 0.5;
    const hh = i.rect[3] * 0.5;
    for (0..out.height) |y| for (0..out.width) |x| {
        var px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
        var py = (@as(f32, @floatFromInt(y)) + 0.5) / scale;
        if (i.turn[0] != 0) {
            const sx = px - i.turn[2];
            const sy = py - i.turn[3];
            const inv: f32 = if (i.turn[1] > 0) st / i.turn[1] else 0;
            const dx = sx / (ct - sx * inv);
            const w = 1 + dx * inv;
            px = i.turn[2] + dx;
            py = i.turn[3] + sy * w;
        }
        if (px < i.clip[0] or py < i.clip[1] or px > i.clip[2] or py > i.clip[3]) continue;
        const dx = px - i.xf[2];
        const dy = py - i.xf[3];
        var ux = i.xf[2] + (ca * dx + sa * dy) / pulse;
        const uy = i.xf[3] + (-sa * dx + ca * dy) / pulse;
        if (i.vel[2] == 2) ux = 2 * i.vel[3] - ux;
        const gx = grow + if (blur) @abs(vx) * 0.5 else 0;
        const gy = grow + if (blur) @abs(vy) * 0.5 else 0;
        if (ux < i.rect[0] - gx or uy < i.rect[1] - gy or ux > i.rect[0] + i.rect[2] + gx or uy > i.rect[1] + i.rect[3] + gy) continue;
        const localx = ux - i.rect[0] - hw;
        const localy = uy - i.rect[1] - hh;
        const center = raster.cornerSdf(localx, localy, hw, hh, i.radius);
        const aa = @max(center[1] / scale, 0.0001) * 0.5;
        var coverage: f32 = 0;
        for (0..samples) |k| {
            const offset: f32 = if (blur) @as(f32, @floatFromInt(k)) * 0.25 - 0.5 else 0;
            const d = raster.cornerSdf(localx - vx * offset, localy - vy * offset, hw, hh, i.radius)[0];
            coverage += 1 - raster.smoothstep(-aa, aa, d);
        }
        coverage /= @floatFromInt(samples);
        const a = coverage * i.color[3] * alpha * raster.clipCover(i, px, py, 1 / scale);
        raster.blend(out.bytes, (y * out.width + x) * 4, i.color[0] * a, i.color[1] * a, i.color[2] * a, a);
    };
}

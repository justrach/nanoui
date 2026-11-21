//! Render targets and per-pass uniforms shared by WebGPU passes.
const api = @import("webgpu_api.zig");
pub const Target = struct {
    texture: api.Handle,
    view: api.Handle,
    width: u32,
    height: u32,
    format: api.Format,
    owned: bool = true,
    pub fn canvas(width: u32, height: u32) Target {
        const texture = api.canvas_texture();
        return .{ .texture = texture, .view = api.canvas_view(texture), .width = width, .height = height, .format = api.preferred_format(), .owned = false };
    }
    pub fn init(width: u32, height: u32, format: api.Format) !Target {
        if (width == 0 or height == 0 or (format != .bgra8unorm and format != .rgba8unorm)) return error.InvalidTarget;
        const texture = api.texture_create(&.{ .width = width, .height = height, .format = format, .usage = 1 | 4 | 16 });
        return .{ .texture = texture, .view = api.texture_view(texture), .width = width, .height = height, .format = format };
    }
    pub fn deinit(t: Target) void {
        if (!t.owned) return;
        api.release(t.view);
        api.release(t.texture);
    }
};
pub const Params = extern struct {
    viewport: [2]f32,
    scale: f32,
    time: f32,
    origin: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 0, 0 },
    area: [4]i32 = .{ 0, 0, 0, 0 },
    down: f32 = 1,
    sigma: f32 = 0,
    radius: i32 = 0,
    frame_height: i32 = 0,
    dir: [2]i32 = .{ 0, 0 },
    pad: [2]i32 = .{ 0, 0 },
    progressive: [4]f32 = @splat(0),
    padding: [40]f32 = @splat(0),
};
comptime {
    @import("std").debug.assert(@sizeOf(Params) == 256);
}

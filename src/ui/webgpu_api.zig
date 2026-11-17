//! WebGPU object handles and the thin JavaScript import boundary.
pub const Handle = u32;
pub const Format = enum(u32) { bgra8unorm, rgba8unorm, r8unorm, rgba16float };
pub const TextureDesc = extern struct { width: u32, height: u32, format: Format, usage: u32, depth: u32 = 1, dimension: u32 = 2 };
pub const WriteDesc = extern struct { width: u32, height: u32, bytes_per_row: u32, depth: u32 = 1, x: u32 = 0, y: u32 = 0 };
/// kind: 0 dynamic uniform, 1 storage, 2 texture, 3 sampler,
/// 4 external texture, 5 3D texture, 6 non-filtering sampler.
pub const LayoutEntry = extern struct { binding: u32, visibility: u32, kind: u32 };
/// kind: 0 buffer, 1 texture view, 2 sampler, 3 external texture.
/// size=0 binds the whole buffer.
pub const BindEntry = extern struct { binding: u32, kind: u32, resource: Handle, offset: u32 = 0, size: u32 = 0 };
pub const PipelineDesc = extern struct { shader: Handle, layout: Handle, format: Format, kind: u32 = 0, sample_layout: Handle = 0 };
comptime {
    const assert = @import("std").debug.assert;
    assert(@sizeOf(TextureDesc) == 24 and @sizeOf(WriteDesc) == 24);
    assert(@sizeOf(LayoutEntry) == 12 and @sizeOf(BindEntry) == 20 and @sizeOf(PipelineDesc) == 20);
}

pub extern "nanoui_gpu" fn device() Handle;
pub extern "nanoui_gpu" fn device_generation() u32;
pub extern "nanoui_gpu" fn preferred_format() Format;
pub extern "nanoui_gpu" fn canvas_texture() Handle;
pub extern "nanoui_gpu" fn canvas_view(texture: Handle) Handle;
pub extern "nanoui_gpu" fn release(h: Handle) void;
pub extern "nanoui_gpu" fn buffer_create(size: u32, usage: u32) Handle;
pub extern "nanoui_gpu" fn buffer_write(buf: Handle, offset: u32, ptr: [*]const u8, len: u32) void;
pub extern "nanoui_gpu" fn texture_create(desc: *const TextureDesc) Handle;
pub extern "nanoui_gpu" fn texture_write(tex: Handle, desc: *const WriteDesc, ptr: [*]const u8, len: u32) void;
pub extern "nanoui_gpu" fn texture_view(tex: Handle) Handle;
pub extern "nanoui_gpu" fn texture_format(tex: Handle) Format;
pub extern "nanoui_gpu" fn texture_srgb(tex: Handle) bool;
pub extern "nanoui_gpu" fn resource_generation(resource: Handle) u32;
pub extern "nanoui_gpu" fn resource_serial(resource: Handle) u32;
pub extern "nanoui_gpu" fn resource_content_serial(resource: Handle) u32;
pub extern "nanoui_gpu" fn external_import(source: Handle) Handle;
pub extern "nanoui_gpu" fn external_copy(source: Handle, texture: Handle) u32;
pub extern "nanoui_gpu" fn sampler_create(filter: u32) Handle;
pub extern "nanoui_gpu" fn shader_create(ptr: [*]const u8, len: u32) Handle;
pub extern "nanoui_gpu" fn layout_create(entries: [*]const LayoutEntry, n: u32) Handle;
pub extern "nanoui_gpu" fn pipeline_create(desc: *const PipelineDesc) Handle;
pub extern "nanoui_gpu" fn bind_group_create(layout: Handle, entries: [*]const BindEntry, n: u32) Handle;
pub extern "nanoui_gpu" fn encoder_begin() Handle;
pub extern "nanoui_gpu" fn pass_begin(enc: Handle, view: Handle, load: u32, r: f32, g: f32, b: f32, a: f32) Handle;
pub extern "nanoui_gpu" fn pass_set_pipeline(pass: Handle, pipeline: Handle) void;
pub extern "nanoui_gpu" fn pass_set_bind_group(pass: Handle, index: u32, group: Handle, dynamic_offset: u32) void;
pub extern "nanoui_gpu" fn pass_draw(pass: Handle, vertices: u32, instances: u32, first_instance: u32) void;
pub extern "nanoui_gpu" fn pass_end(pass: Handle) void;
pub extern "nanoui_gpu" fn pass_viewport(pass: Handle, width: u32, height: u32) void;
pub extern "nanoui_gpu" fn pass_scissor(pass: Handle, x: u32, y: u32, width: u32, height: u32) void;
pub extern "nanoui_gpu" fn encoder_copy_texture(enc: Handle, src: Handle, dst: Handle, width: u32, height: u32) void;
pub extern "nanoui_gpu" fn encoder_submit(enc: Handle) void;
pub extern "nanoui_gpu" fn read_begin(tex: Handle, w: u32, h: u32, format: Format, dest: [*]u8, token: u32) void;

const Completion = struct {
    token: u32,
    ctx: *anyopaque,
    done: *const fn (*anyopaque, bool) void,
};
var pending: [32]?Completion = @splat(null);
var serial: u32 = 0;

pub fn completion(ctx: *anyopaque, done: *const fn (*anyopaque, bool) void) ?u32 {
    for (&pending, 0..) |*slot, i| if (slot.* == null) {
        serial = (serial +% 1) & 0x7ffffff;
        const token = (serial << 5) | @as(u32, @intCast(i));
        slot.* = .{ .token = token, .ctx = ctx, .done = done };
        return token;
    };
    return null;
}

export fn nanoui_gpu_done(token: u32, status: u32) void {
    const slot = &pending[token & 31];
    const call = slot.* orelse return;
    if (call.token != token) return;
    slot.* = null;
    call.done(call.ctx, status == 0);
}

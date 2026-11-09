//! The app's own GPU work in nanoui's frame: a compute pass encoded in
//! `before_encode` fills an RGBA16Float texture on `ui.metalDevice()`, and
//! the same frame shows it (`Texture.mtl_texture`) encoded for the
//! display: in the offscreen readback a snapshot sees, and on the CPU
//! renderer (read back from the GPU).
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const color = @import("color.zig");

const n = 64;

const kernel_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\kernel void fill(texture2d<half, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    \\    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    \\    out.write(half4(float(gid.x) / 64.0, float(gid.y) / 64.0, 0.5, 1.0), gid);
    \\}
;

const Fill = struct {
    pipeline: *anyopaque,
    texture: *anyopaque,
    runs: u32 = 0,

    fn encode(ctx: *anyopaque, cmd_buffer: *anyopaque) void {
        const objc = @import("../objc.zig");
        const f: *Fill = @ptrCast(@alignCast(ctx));
        f.runs += 1;
        const MTLSize = extern struct { w: objc.NSUInteger, h: objc.NSUInteger, d: objc.NSUInteger };
        const enc = objc.msg(objc.Object, @as(objc.Object, @ptrCast(cmd_buffer)), "computeCommandEncoder", .{});
        objc.msg(void, enc, "setComputePipelineState:", .{@as(objc.Object, @ptrCast(f.pipeline))});
        objc.msg(void, enc, "setTexture:atIndex:", .{ @as(objc.Object, @ptrCast(f.texture)), @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "dispatchThreads:threadsPerThreadgroup:", .{ MTLSize{ .w = n, .h = n, .d = 1 }, MTLSize{ .w = 8, .h = 8, .d = 1 } });
        objc.msg(void, enc, "endEncoding", .{});
    }
};

const Scene = struct {
    source: ui.Texture,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        ui.texture(c, .{ .width = .{ .px = n }, .height = .{ .px = n } }, s.source, .{ 0, 0, 1, 1 }, 1);
    }
};

test "a compute pass in before_encode fills an RGBA16F texture the same frame shows" {
    if (text.portable) return error.SkipZigTest;
    const objc = @import("../objc.zig");
    const gpa = testing.allocator;
    const device: objc.Object = @ptrCast(ui.metalDevice() orelse return error.SkipZigTest);
    try testing.expectEqual(ui.metalDevice(), ui.metalDevice());
    var err: ?objc.Object = null;
    const library = objc.msg(?objc.Object, device, "newLibraryWithSource:options:error:", .{ objc.nsString(kernel_source), @as(?objc.Object, null), &err }) orelse return error.ShaderCompile;
    defer objc.release(library);
    const func = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString("fill")});
    defer objc.release(func);
    const pipeline = objc.msg(?objc.Object, device, "newComputePipelineStateWithFunction:error:", .{ func, &err }) orelse return error.PipelineCreate;
    defer objc.release(pipeline);
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(objc.NSUInteger, 115), @as(objc.NSUInteger, n), @as(objc.NSUInteger, n), objc.NO });
    objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 2)}); // shader read, write
    objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private: only the GPU sees it
    const tex = objc.msg(objc.Object, device, "newTextureWithDescriptor:", .{desc});
    defer objc.release(tex);

    var fill: Fill = .{ .pipeline = @ptrCast(pipeline), .texture = @ptrCast(tex) };
    var s: Scene = .{ .source = .{ .width = n, .height = n, .mtl_texture = @ptrCast(tex), .tone_map = false } };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = n, .height = n, .scale = 1 });
    defer t.deinit();
    t.renderer.before_encode = .{ .ctx = &fill, .func = Fill.encode };
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    try testing.expectEqual(@as(u32, 1), fill.runs);
    // The CPU renderer reads the texture back (through a shared copy).
    const cpu: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, shown.bytes.len), .width = shown.width, .height = shown.height };
    defer cpu.deinit(gpa);
    var pictures = t.text.images.pictures();
    pictures.textures = t.ctx.textures.items;
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, pictures, t.scale, t.theme.background);
    for (0..n) |y| for (0..n) |x| {
        const lin = [3]f32{
            @floatCast(@as(f16, @floatCast(@as(f32, @floatFromInt(x)) / 64))),
            @floatCast(@as(f16, @floatCast(@as(f32, @floatFromInt(y)) / 64))),
            0.5,
        };
        for ([_]gpu.Pixels{ shown, cpu }) |px| {
            const got = px.bytes[(y * px.width + x) * 4 ..][0..4];
            for (0..3) |k| try testing.expect(@abs(@as(f32, @floatFromInt(got[2 - k])) - color.linearToSrgb(lin[k]) * 255) <= 1.01);
        }
    };
}

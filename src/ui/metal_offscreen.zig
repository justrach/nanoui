//! The Metal renderer without a window (`metal.zig`): a target kept across
//! frames for benchmarks, a frame drawn into it and timed, and a frame
//! drawn into a new texture and read back (the Tester's, snapshots'),
//! colour stage, app passes (`before_encode`) and gradients included.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");
const metal = @import("metal.zig");
const Renderer = metal.Renderer;
const Instance = metal.Instance;
const Pixels = metal.Pixels;

/// A render target of `size` points at `scale`, kept by the caller
/// across frames (release it): for benchmarks drawing without a window.
pub fn newTarget(self: *Renderer, size: types.Size, scale: f32) objc.Object {
    const w: usize = @intFromFloat(@max(1, @round(size.w * scale)));
    const h: usize = @intFromFloat(@max(1, @round(size.h * scale)));
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
        metal.pixel_format, w, h, objc.NO,
    });
    objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
    objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private: GPU only, as a drawable
    return objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
}

pub const Timing = struct {
    /// CPU time to upload the instances and encode the frame.
    encode_ms: f64,
    /// GPU time of the frame, from the command buffer's timestamps.
    gpu_ms: f64,
};

/// Draws a frame into `target` as a window's frame is drawn (the ring
/// of instance buffers, one command buffer), waits for it, and times it.
pub fn drawTimed(self: *Renderer, target: objc.Object, instances: []const Instance, atlas: objc.Object, size: types.Size, clear: types.Color) Timing {
    const pool = objc.Pool.push();
    defer pool.pop();
    _ = objc.dispatch_semaphore_wait(self.in_flight, objc.DISPATCH_TIME_FOREVER);
    defer _ = objc.dispatch_semaphore_signal(self.in_flight);
    const t0 = cf.CACurrentMediaTime();
    const held = &self.held[self.next_buffer];
    self.frame_textures.release(held);
    const buffer = self.upload(instances);
    const cmd = self.encode(target, buffer, instances, atlas, size, clear, held);
    objc.msg(void, cmd, "commit", .{});
    const t1 = cf.CACurrentMediaTime();
    objc.msg(void, cmd, "waitUntilCompleted", .{});
    self.frame_textures.release(held);
    const gpu_s = objc.msg(f64, cmd, "GPUEndTime", .{}) - objc.msg(f64, cmd, "GPUStartTime", .{});
    return .{ .encode_ms = (t1 - t0) * 1000, .gpu_ms = gpu_s * 1000 };
}

/// Draws into a new offscreen texture and returns its BGRA pixels,
/// premultiplied, `width * 4` bytes per row: frames without a window.
pub fn drawOffscreen(self: *Renderer, gpa: std.mem.Allocator, instances: []const Instance, atlas: objc.Object, size: types.Size, scale: f32, clear: types.Color) !Pixels {
    const pool = objc.Pool.push();
    defer pool.pop();
    const w: usize = @intFromFloat(@max(1, @round(size.w * scale)));
    const h: usize = @intFromFloat(@max(1, @round(size.h * scale)));
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
        metal.pixel_format, w, h, objc.NO,
    });
    objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 4)}); // shader read, render target
    objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 0)}); // shared
    const texture = objc.msg(objc.Object, self.device, "newTextureWithDescriptor:", .{desc});
    defer objc.release(texture);
    const buffer: ?objc.Object = if (instances.len == 0) null else objc.msg(objc.Object, self.device, "newBufferWithLength:options:", .{
        @as(objc.NSUInteger, self.packedLen(instances)), @as(objc.NSUInteger, 0),
    });
    defer if (buffer) |b| objc.release(b);
    if (buffer) |b| self.pack(@ptrCast(objc.msg(*anyopaque, b, "contents", .{})), instances);
    var held: std.ArrayList(*anyopaque) = .empty;
    defer held.deinit(self.frame_textures.gpa);
    const cmd = self.encode(texture, buffer, instances, atlas, size, clear, &held);
    objc.msg(void, cmd, "commit", .{});
    objc.msg(void, cmd, "waitUntilCompleted", .{});
    self.frame_textures.release(&held);
    const bytes = try gpa.alloc(u8, w * h * 4);
    const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
    objc.msg(void, texture, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{
        @as(*anyopaque, bytes.ptr), w * 4, Region{ .x = 0, .y = 0, .z = 0, .w = w, .h = h, .d = 1 }, @as(objc.NSUInteger, 0),
    });
    return .{ .bytes = bytes, .width = w, .height = h };
}

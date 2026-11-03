//! Panes of glass in the Metal renderer (`glass.metal`): the frame is
//! drawn up to a pane, the pane's backdrop is averaged and blurred from
//! what was drawn (two textures, kept and grown), the pane is drawn from
//! it, and the frame goes on. A frame without glass is drawn in one pass,
//! as before.
const std = @import("std");
const objc = @import("../objc.zig");
const gpu = @import("gpu.zig");
const glass = @import("glass.zig");

const MTLSize = extern struct { w: objc.NSUInteger, h: objc.NSUInteger, d: objc.NSUInteger };

/// What `glass.metal`'s kernels read (its GlassBackdrop).
const BackdropArgs = extern struct {
    area: [4]i32,
    size: [2]i32,
    down: i32,
    radius: i32,
    sigma: f32,
};

/// What `fs_glass` reads (its GlassPane).
pub const Pane = extern struct {
    origin: [2]f32,
    size: [2]f32,
    down: f32,
    scale: f32,
};

pub const Glass = struct {
    pipeline: objc.Object,
    down: objc.Object,
    blur: objc.Object,
    /// The backdrop ends in `a`; `b` holds the blur between its passes.
    a: ?objc.Object = null,
    b: ?objc.Object = null,
    w: usize = 0,
    h: usize = 0,

    pub fn init(device: objc.Object, library: objc.Object, pipeline: objc.Object) !Glass {
        return .{ .pipeline = pipeline, .down = try kernel(device, library, "glass_down"), .blur = try kernel(device, library, "glass_blur") };
    }

    pub fn releaseTextures(g: *Glass) void {
        for ([_]*?objc.Object{ &g.a, &g.b }) |slot| if (slot.*) |tex| {
            objc.release(tex);
            slot.* = null;
        };
        g.w = 0;
        g.h = 0;
    }

    pub fn deinit(g: *Glass) void {
        g.releaseTextures();
        objc.release(g.pipeline);
        objc.release(g.down);
        objc.release(g.blur);
    }

    fn kernel(device: objc.Object, library: objc.Object, comptime name: []const u8) !objc.Object {
        const f = objc.msg(objc.Object, library, "newFunctionWithName:", .{objc.nsString(name)});
        defer objc.release(f);
        var err: ?objc.Object = null;
        return objc.msg(?objc.Object, device, "newComputePipelineStateWithFunction:error:", .{ f, &err }) orelse error.PipelineCreate;
    }

    /// Room for a backdrop of `w` × `h` texels.
    fn reserve(g: *Glass, device: objc.Object, w: usize, h: usize) void {
        if (g.a != null and w <= g.w and h <= g.h) return;
        g.w = @max(w, g.w);
        g.h = @max(h, g.h);
        for ([_]*?objc.Object{ &g.a, &g.b }) |slot| {
            if (slot.*) |t| objc.release(t);
            const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{
                @as(objc.NSUInteger, 70), g.w, g.h, objc.NO, // RGBA8Unorm
            });
            objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1 | 2)}); // shader read, shader write
            objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 2)}); // private
            slot.* = objc.msg(objc.Object, device, "newTextureWithDescriptor:", .{desc});
        }
    }

    /// Encodes the backdrop of pane `i` from `target` (what the frame drew
    /// so far) into `a`, and returns where it lies; null when none shows.
    pub fn backdrop(g: *Glass, device: objc.Object, cmd: objc.Object, target: objc.Object, i: gpu.Instance, scale: f32) ?Pane {
        const fw = objc.msg(objc.NSUInteger, target, "width", .{});
        const fh = objc.msg(objc.NSUInteger, target, "height", .{});
        const b = glass.backdropOf(i.rect, i.border_width, scale, fw, fh) orelse return null;
        const w: usize = @intCast(b.w);
        const h: usize = @intCast(b.h);
        g.reserve(device, w, h);
        const args: BackdropArgs = .{ .area = b.area, .size = .{ b.w, b.h }, .down = b.down, .radius = b.radius, .sigma = b.sigma };
        const enc = objc.msg(objc.Object, cmd, "computeCommandEncoder", .{});
        g.pass(enc, g.down, target, g.a.?, &args, null, w, h);
        if (b.sigma > 0) {
            g.pass(enc, g.blur, g.a.?, g.b.?, &args, .{ 1, 0 }, w, h);
            g.pass(enc, g.blur, g.b.?, g.a.?, &args, .{ 0, 1 }, w, h);
        }
        objc.msg(void, enc, "endEncoding", .{});
        return .{
            .origin = .{ @floatFromInt(b.area[0]), @floatFromInt(b.area[1]) },
            .size = .{ @floatFromInt(b.w), @floatFromInt(b.h) },
            .down = @floatFromInt(b.down),
            .scale = scale,
        };
    }

    fn pass(_: *Glass, enc: objc.Object, pipeline: objc.Object, src: objc.Object, dst: objc.Object, args: *const BackdropArgs, dir: ?[2]i32, w: usize, h: usize) void {
        objc.msg(void, enc, "setComputePipelineState:", .{pipeline});
        objc.msg(void, enc, "setTexture:atIndex:", .{ src, @as(objc.NSUInteger, 0) });
        objc.msg(void, enc, "setTexture:atIndex:", .{ dst, @as(objc.NSUInteger, 1) });
        objc.msg(void, enc, "setBytes:length:atIndex:", .{ @as(*const anyopaque, args), @as(objc.NSUInteger, @sizeOf(BackdropArgs)), @as(objc.NSUInteger, 0) });
        if (dir) |d| objc.msg(void, enc, "setBytes:length:atIndex:", .{ @as(*const anyopaque, &d), @as(objc.NSUInteger, 8), @as(objc.NSUInteger, 1) });
        // Whole groups of 16 × 16 (the kernels skip what's past the edge).
        objc.msg(void, enc, "dispatchThreadgroups:threadsPerThreadgroup:", .{ MTLSize{ .w = (w + 15) / 16, .h = (h + 15) / 16, .d = 1 }, MTLSize{ .w = 16, .h = 16, .d = 1 } });
    }
};

/// The index of the first pane of glass at or after `from`, if any.
pub fn next(instances: []const gpu.Instance, from: usize) ?usize {
    for (instances[from..], from..) |inst, k| if (inst.kind == gpu.Kind.glass) return k;
    return null;
}

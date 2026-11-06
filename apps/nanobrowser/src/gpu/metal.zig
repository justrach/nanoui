//! Direct Objective-C Metal calls. All temporary objects stay inside a pool;
//! only new/retained resource objects cross it. No view, layer or window.
const std = @import("std");
const objc = @import("nanoui").objc;
const ctx = @import("context.zig");
const Obj = ctx.Obj;
const Size = extern struct { width: usize, height: usize, depth: usize };
const Origin = extern struct { x: usize = 0, y: usize = 0, z: usize = 0 };
const Region = extern struct { origin: Origin = .{}, size: Size };
const Color = extern struct { red: f64, green: f64, blue: f64, alpha: f64 };
extern "c" fn MTLCreateSystemDefaultDevice() ?Obj;
pub fn createDevice() ?Obj {
    return MTLCreateSystemDefaultDevice();
}
pub fn createQueue(d: Obj) ?Obj {
    return objc.msg(?Obj, d, "newCommandQueue", .{});
}
pub fn release(o: Obj) void {
    objc.release(o);
}
pub fn buffer(d: Obj, len: usize) ?Obj {
    return objc.msg(?Obj, d, "newBufferWithLength:options:", .{ len, @as(usize, 0) });
}
pub fn bytes(b: Obj, len: usize) []u8 {
    return objc.msg([*]u8, b, "contents", .{})[0..len];
}
fn diagnostic(c: *ctx.Context, err: ?Obj) void {
    c.note(if (err) |e| objc.fromNSString(objc.msg(?Obj, e, "localizedDescription", .{})) else "Metal operation failed");
}
pub fn library(c: *ctx.Context, source: []const u8) ?Obj {
    const pool = objc.Pool.push();
    defer pool.pop();
    var err: ?Obj = null;
    const lib = objc.msg(?Obj, c.device.?, "newLibraryWithSource:options:error:", .{ objc.nsString(source), @as(?Obj, null), &err });
    if (lib == null) diagnostic(c, err);
    return lib;
}
fn function(c: *ctx.Context, lib: Obj, name: []const u8) ?Obj {
    const translated = std.fmt.allocPrint(c.gpa, "__wgsl_{s}", .{name}) catch {
        c.note("Entry point allocation failed");
        return null;
    };
    defer c.gpa.free(translated);
    const f = objc.msg(?Obj, lib, "newFunctionWithName:", .{objc.nsString(translated)});
    if (f == null) c.note("Metal entry point not found");
    return f;
}
pub fn compute(c: *ctx.Context, lib: Obj, name: []const u8) ?Obj {
    const pool = objc.Pool.push();
    defer pool.pop();
    const f = function(c, lib, name) orelse return null;
    defer release(f);
    var err: ?Obj = null;
    const p = objc.msg(?Obj, c.device.?, "newComputePipelineStateWithFunction:error:", .{ f, &err });
    if (p == null) diagnostic(c, err);
    return p;
}
pub fn render(c: *ctx.Context, vl: Obj, vn: []const u8, fl: Obj, fn_: []const u8) ?Obj {
    const pool = objc.Pool.push();
    defer pool.pop();
    const v = function(c, vl, vn) orelse return null;
    defer release(v);
    const f = function(c, fl, fn_) orelse return null;
    defer release(f);
    const desc = objc.new("MTLRenderPipelineDescriptor");
    defer release(desc);
    objc.msg(void, desc, "setVertexFunction:", .{v});
    objc.msg(void, desc, "setFragmentFunction:", .{f});
    const colors = objc.msg(Obj, desc, "colorAttachments", .{});
    const color = objc.msg(Obj, colors, "objectAtIndexedSubscript:", .{@as(usize, 0)});
    objc.msg(void, color, "setPixelFormat:", .{@as(usize, 80)});
    var err: ?Obj = null;
    const p = objc.msg(?Obj, c.device.?, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err });
    if (p == null) diagnostic(c, err);
    return p;
}
pub fn texture(d: Obj, width: u32, height: u32) ?Obj {
    const pool = objc.Pool.push();
    defer pool.pop();
    const desc = objc.msg(Obj, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(usize, 80), @as(usize, width), @as(usize, height), false });
    objc.msg(void, desc, "setUsage:", .{@as(usize, 5)}); // shader-read | render-target
    objc.msg(void, desc, "setStorageMode:", .{@as(usize, 0)}); // shared CPU/GPU
    const t = objc.msg(?Obj, d, "newTextureWithDescriptor:", .{desc}) orelse return null;
    // WebGPU resources start zero-initialized; render targets must not leak VRAM.
    const zeros = std.heap.page_allocator.alloc(u8, @as(usize, width) * height * 4) catch {
        release(t);
        return null;
    };
    defer std.heap.page_allocator.free(zeros);
    @memset(zeros, 0);
    const region: Region = .{ .size = .{ .width = width, .height = height, .depth = 1 } };
    objc.msg(void, t, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, @as(usize, 0), zeros.ptr, @as(usize, width) * 4 });
    return t;
}
pub fn readTexture(t: Obj, width: u32, height: u32, out: []u8) void {
    const region: Region = .{ .size = .{ .width = width, .height = height, .depth = 1 } };
    objc.msg(void, t, "getBytes:bytesPerRow:fromRegion:mipmapLevel:", .{ out.ptr, @as(usize, width) * 4, region, @as(usize, 0) });
}
fn command(c: *ctx.Context) ctx.Error!Obj {
    return objc.msg(?Obj, c.queue.?, "commandBuffer", .{}) orelse c.fail("Metal command buffer creation failed");
}
fn complete(c: *ctx.Context, cmd: Obj) ctx.Error!void {
    objc.msg(void, cmd, "commit", .{});
    objc.msg(void, cmd, "waitUntilCompleted", .{});
    if (objc.msg(usize, cmd, "status", .{}) != 4) {
        diagnostic(c, objc.msg(?Obj, cmd, "error", .{}));
        return error.DeviceLost;
    }
}
pub fn validWorkgroup(c: *ctx.Context, p: Obj, wg: [3]usize) bool {
    const max = objc.msg(Size, c.device.?, "maxThreadsPerThreadgroup", .{});
    return wg[0] <= max.width and wg[1] <= max.height and wg[2] <= max.depth and wg[0] * wg[1] * wg[2] <= objc.msg(usize, p, "maxTotalThreadsPerThreadgroup", .{});
}
pub fn dispatch(c: *ctx.Context, p: Obj, buffers: [8]?Obj, lengths: [8]u32, groups: [3]usize, wg: [3]usize) ctx.Error!void {
    const pool = objc.Pool.push();
    defer pool.pop();
    if (!validWorkgroup(c, p, wg)) return c.fail("workgroup exceeds device limit");
    const cmd = try command(c);
    const enc = objc.msg(?Obj, cmd, "computeCommandEncoder", .{}) orelse return c.fail("Metal compute encoder failed");
    objc.msg(void, enc, "setComputePipelineState:", .{p});
    for (buffers, 0..) |buffer_, slot| if (buffer_) |b| {
        objc.msg(void, enc, "setBuffer:offset:atIndex:", .{ b, @as(usize, 0), slot });
        objc.msg(void, enc, "setBytes:length:atIndex:", .{ &lengths[slot], @as(usize, 4), slot + 8 });
    };
    const grid: Size = .{ .width = groups[0], .height = groups[1], .depth = groups[2] };
    const local: Size = .{ .width = wg[0], .height = wg[1], .depth = wg[2] };
    objc.msg(void, enc, "dispatchThreadgroups:threadsPerThreadgroup:", .{ grid, local });
    objc.msg(void, enc, "endEncoding", .{});
    try complete(c, cmd);
}
pub fn copy(c: *ctx.Context, src: Obj, so: usize, dst: Obj, do: usize, n: usize) ctx.Error!void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const cmd = try command(c);
    const enc = objc.msg(?Obj, cmd, "blitCommandEncoder", .{}) orelse return c.fail("Metal blit encoder failed");
    objc.msg(void, enc, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:", .{ src, so, dst, do, n });
    objc.msg(void, enc, "endEncoding", .{});
    try complete(c, cmd);
}
pub fn draw(c: *ctx.Context, t: Obj, p: ?Obj, count: usize, first: usize, clear: ?[4]f64, vertex_buffers: [8]?Obj, fragment_buffers: [8]?Obj) ctx.Error!void {
    const pool = objc.Pool.push();
    defer pool.pop();
    const desc = objc.msg(Obj, objc.class("MTLRenderPassDescriptor"), "renderPassDescriptor", .{});
    const colors = objc.msg(Obj, desc, "colorAttachments", .{});
    const color = objc.msg(Obj, colors, "objectAtIndexedSubscript:", .{@as(usize, 0)});
    objc.msg(void, color, "setTexture:", .{t});
    objc.msg(void, color, "setLoadAction:", .{@as(usize, if (clear != null) 2 else 1)});
    objc.msg(void, color, "setStoreAction:", .{@as(usize, 1)});
    if (clear) |v| objc.msg(void, color, "setClearColor:", .{Color{ .red = v[0], .green = v[1], .blue = v[2], .alpha = v[3] }});
    const cmd = try command(c);
    const enc = objc.msg(?Obj, cmd, "renderCommandEncoderWithDescriptor:", .{desc}) orelse return c.fail("Metal render encoder failed");
    if (p) |pipeline| {
        objc.msg(void, enc, "setRenderPipelineState:", .{pipeline});
        for (vertex_buffers, 0..) |buffer_, slot| if (buffer_) |b| {
            objc.msg(void, enc, "setVertexBuffer:offset:atIndex:", .{ b, @as(usize, 0), slot });
        };
        for (fragment_buffers, 0..) |buffer_, slot| if (buffer_) |b| {
            objc.msg(void, enc, "setFragmentBuffer:offset:atIndex:", .{ b, @as(usize, 0), slot });
        };
        if (count > 0) objc.msg(void, enc, "drawPrimitives:vertexStart:vertexCount:", .{ @as(usize, 3), first, count });
    }
    objc.msg(void, enc, "endEncoding", .{});
    try complete(c, cmd);
}

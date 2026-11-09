//! An app's ID3D11Texture2D in the frame (`Texture.d3d11_texture`): made
//! on the device the frame is drawn with, it is copied (BGRA) or converted
//! by the colour stage (NV12) on the GPU, held until the next frame, and
//! drawn as the CPU renderer draws the same texture read back. The slot
//! tests need a device but no shader compiler, so they run under Wine too
//! (where the colour stage falls back on the CPU); the renderer's parity
//! test needs both, and skips as `tests_d3d11.zig`'s do.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const api = @import("d3d11_glue.zig");
const video = @import("d3d11_video.zig");
const d3d11_device = @import("d3d11_device.zig");
const d3d11_texture = @import("d3d11_texture.zig");
const texture_cpu = @import("texture_cpu.zig");
const base = @import("tests_d3d11.zig");

const Com = api.Com;
const HRESULT = api.HRESULT;
const SubresourceData = extern struct { mem: *const anyopaque, pitch: u32, slice: u32 = 0 };

/// A texture of `desc` with one buffer per subresource; null where the
/// device won't make one (Wine's may not make NV12).
fn makeTexture(device: *Com, desc: api.Texture2DDesc, data: []const SubresourceData) ?*Com {
    var tex: ?*Com = null;
    if (device.slot(*const fn (*Com, *const api.Texture2DDesc, ?[*]const SubresourceData, *?*Com) callconv(.winapi) HRESULT, api.CreateTexture2D)(device, &desc, data.ptr, &tex) < 0) return null;
    return tex;
}

/// `tex`'s top-left `w` × `h` BGRA texels, read back.
fn readBgra(device: *Com, ctx: *Com, tex: *Com, w: u32, h: u32) ![]u8 {
    const gpa = testing.allocator;
    const sd: api.Texture2DDesc = .{ .width = w, .height = h, .usage = api.usage_staging, .cpu = api.cpu_read };
    var staging: ?*Com = null;
    try api.must(device.slot(*const fn (*Com, *const api.Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateTexture2D)(device, &sd, null, &staging), "CreateTexture2D(test staging)");
    defer staging.?.release();
    const box: api.Box = .{ .right = w, .bottom = h };
    ctx.slot(*const fn (*Com, *Com, u32, u32, u32, u32, *Com, u32, ?*const api.Box) callconv(.winapi) void, api.CopySubresourceRegion)(ctx, staging.?, 0, 0, 0, 0, tex, 0, &box);
    var mapped: api.Mapped = undefined;
    try api.must(ctx.slot(*const fn (*Com, *Com, u32, u32, u32, *api.Mapped) callconv(.winapi) HRESULT, api.Map)(ctx, staging.?, 0, api.map_read, 0, &mapped), "Map(test staging)");
    defer ctx.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, api.Unmap)(ctx, staging.?, 0);
    const out = try gpa.alloc(u8, w * h * 4);
    for (0..h) |y| @memcpy(out[y * w * 4 ..][0 .. w * 4], mapped.data[y * mapped.row_pitch ..][0 .. w * 4]);
    return out;
}

fn refCount(c: *Com) u32 {
    _ = c.slot(*const fn (*Com) callconv(.winapi) u32, 1)(c);
    return c.slot(*const fn (*Com) callconv(.winapi) u32, 2)(c);
}

/// A BGRA test card, `w` × `h`, its colours from `seed`.
fn card(comptime w: usize, comptime h: usize, seed: u8) [w * h * 4]u8 {
    var px: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        px[(y * w + x) * 4 ..][0..4].* = .{ @intCast((x * 30 + seed) % 256), @intCast((y * 50 + seed) % 256), seed, 255 };
    };
    return px;
}

/// An NV12 frame in memory, as a decoder writes one: luma rows, then
/// interleaved chroma, `pitch` bytes a row.
fn nv12Frame(comptime w: usize, comptime h: usize) [w * h * 3 / 2]u8 {
    var px: [w * h * 3 / 2]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        px[y * w + x] = @intCast(16 + (x * 219) / (w - 1));
    };
    for (0..h / 2) |y| for (0..w / 2) |x| {
        px[w * h + y * w + x * 2] = @intCast(64 + x * 20);
        px[w * h + y * w + x * 2 + 1] = @intCast(200 - y * 30);
    };
    return px;
}

test "d3d11: a BGRA texture on the device is copied into its slot on the GPU, a slice of an array, and held a frame" {
    const pair = d3d11_device.create() catch return error.SkipZigTest;
    defer pair.context.release();
    defer pair.device.release();
    const a = card(8, 4, 10);
    const b = card(8, 4, 90);
    const data = [_]SubresourceData{ .{ .mem = &a, .pitch = 32 }, .{ .mem = &b, .pitch = 32 } };
    const tex = makeTexture(pair.device, .{ .width = 8, .height = 4, .array = 2, .bind = api.bind_shader_resource }, &data) orelse return error.NoTexture;
    defer tex.release();
    var slots: d3d11_texture.Slots = .{ .gpa = testing.allocator };
    defer slots.deinit();
    const before = refCount(tex);
    slots.prepare(pair.device, pair.context, &.{.{ .width = 0, .height = 0, .d3d11_texture = tex, .subresource = 1 }});
    try testing.expectEqual(d3d11_texture.Path.gpu_copy, slots.paths.items[0]);
    try testing.expect(slots.get(0) != null);
    // Held until the next frame.
    try testing.expectEqual(before + 1, refCount(tex));
    const got = try readBgra(pair.device, pair.context, slots.entries.items[0].target.texture.?, 8, 4);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &b, got);
    slots.prepare(pair.device, pair.context, &.{});
    try testing.expectEqual(before, refCount(tex));
}

test "d3d11: an NV12 surface is converted as the CPU converts it, on the GPU where the colour stage compiles" {
    const pair = d3d11_device.create() catch return error.SkipZigTest;
    defer pair.context.release();
    defer pair.device.release();
    const w = 16;
    const h = 8;
    const frame = nv12Frame(w, h);
    const data = [_]SubresourceData{.{ .mem = &frame, .pitch = w }};
    const tex = makeTexture(pair.device, .{ .width = w, .height = h, .format = video.nv12, .bind = api.bind_shader_resource }, &data) orelse {
        std.debug.print("no NV12 textures on this device ", .{});
        return error.SkipZigTest;
    };
    defer tex.release();
    const t: gpu.Texture = .{ .width = w, .height = h, .d3d11_texture = tex };
    // The CPU's reading of it: the staging copy's planes where they belong.
    var cpu = video.readBack(testing.allocator, t) orelse return error.NoReadBack;
    defer cpu.deinit(testing.allocator);
    var want = texture_cpu.fromPlanes(testing.allocator, .{ .width = w, .height = h, .format = .ycbcr420_8 }, .{ .bytes = &frame, .width = w, .height = h, .stride = w }, .{ .bytes = frame[w * h ..].ptr, .width = w / 2, .height = h / 2, .stride = w }).?;
    defer want.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, want.bgra.pixels, cpu.bgra.pixels);

    var slots: d3d11_texture.Slots = .{ .gpa = testing.allocator };
    defer slots.deinit();
    slots.prepare(pair.device, pair.context, &.{t});
    const path = slots.paths.items[0];
    std.debug.print("NV12 slot path: {t} ", .{path});
    try testing.expect(path == .gpu_post or path == .cpu);
    const e = &slots.entries.items[0];
    const out_tex = if (path == .gpu_post) e.target.texture.? else e.texture.?;
    const got = try readBgra(pair.device, pair.context, out_tex, w, h);
    defer testing.allocator.free(got);
    var worst: u8 = 0;
    for (got, want.bgra.pixels) |x, y| worst = @max(worst, if (x > y) x - y else y - x);
    std.debug.print("worst {d} ", .{worst});
    // The GPU rounds the transfer's powers a little differently.
    try testing.expect(worst <= 2);
}

const Scene = struct {
    textures: [2]gpu.Texture,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull().p(8).gap(12);
        defer root.end();
        ui.texture(c, .{ .width = .{ .px = 96 }, .height = .{ .px = 48 }, .radius = 8 }, s.textures[0], .{ 0, 0, 1, 1 }, 1);
        ui.texture(c, .{ .width = .{ .px = 96 }, .height = .{ .px = 48 } }, s.textures[1], .{ 0, 0, 1, 1 }, 0.75);
    }
};

test "d3d11: a texture made on the renderer's device draws as the CPU renderer draws it read back" {
    const gpa = testing.allocator;
    var maybe = try base.renderer();
    if (maybe == null) return error.SkipZigTest;
    var r = &maybe.?;
    defer r.deinit();
    const bgra = card(32, 16, 60);
    const bgra_tex = makeTexture(r.device, .{ .width = 32, .height = 16, .bind = api.bind_shader_resource }, &.{.{ .mem = &bgra, .pitch = 32 * 4 }}) orelse return error.NoTexture;
    defer bgra_tex.release();
    const frame = nv12Frame(32, 16);
    const nv12_tex = makeTexture(r.device, .{ .width = 32, .height = 16, .format = video.nv12, .bind = api.bind_shader_resource }, &.{.{ .mem = &frame, .pitch = 32 }}) orelse return error.NoTexture;
    defer nv12_tex.release();
    var s: Scene = .{ .textures = .{ .{ .width = 32, .height = 16, .d3d11_texture = bgra_tex }, .{ .width = 32, .height = 16, .d3d11_texture = nv12_tex } } };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 240, .height = 64 });
    defer t.deinit();
    t.settle(0.1);
    r.textures = t.ctx.textures.items;
    const ours = try base.drawThenRead(r, &t, t.theme.background);
    defer ours.deinit(gpa);
    try testing.expectEqual(d3d11_texture.Path.gpu_copy, r.slots.paths.items[0]);
    try testing.expectEqual(d3d11_texture.Path.gpu_post, r.slots.paths.items[1]);
    var pictures = t.text.images.pictures();
    pictures.textures = t.ctx.textures.items;
    const cpu = try gpa.alloc(u8, ours.bytes.len);
    defer gpa.free(cpu);
    raster.draw(.{ .bytes = cpu, .width = ours.width, .height = ours.height }, t.instances.items, t.text.atlas.mask(), pictures, t.scale, t.theme.background);
    var total: u64 = 0;
    var off: usize = 0;
    for (ours.bytes, cpu) |x, y| {
        const d = if (x > y) x - y else y - x;
        total += d;
        if (d > 8) off += 1;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(cpu.len));
    std.debug.print("d3d11 vs cpu (app textures): mean {d:.4}, {d} of {d} off ", .{ mean, off, cpu.len });
    try testing.expect(mean <= 1.0);
    try testing.expect(off * 40 < cpu.len);
}

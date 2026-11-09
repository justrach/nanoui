//! The frame's textures on Direct3D 11 (`ui.texture`, a video's frames).
//!
//! Pixels the app holds in memory go into one dynamic BGRA texture per slot,
//! written each frame by mapping it (`Map` with WRITE_DISCARD: the driver
//! hands over a fresh buffer, so a texture still being read by the last
//! frame is never waited on). A texture whose pixels are not display BGRA
//! (Y'CbCr planes, half floats, a LUT) is first made BGRA on the CPU by the
//! colour stage the CPU renderer uses (`texture_cpu.zig`), so both
//! renderers sample the same texels. A slot's texture is remade only when
//! its size changes.
//!
//! An app's own ID3D11Texture2D (`Texture.d3d11_texture`, a decoder's
//! surface on `ui.d3d11Device()`) never leaves the GPU: BGRA is copied into
//! the slot's target, anything else is copied out of the decoder's array
//! into a texture the colour stage can sample and converted into the
//! target by `texture_post.hlsl` (`d3d11_video.zig`). Each is held (AddRef)
//! until the window's next frame is prepared, which is after this one was
//! presented. A window that stops drawing (idle, minimized, paused) keeps
//! its last frame's textures held until it draws again or is closed: an
//! app decoding into a fixed pool must expect that many of its surfaces
//! (one per texture the last frame drew) to stay pinned meanwhile. Where the colour stage can't be compiled (Wine), or the
//! texture is another device's, it is read back and uploaded as above.
const std = @import("std");
const gpu = @import("gpu.zig");
const texture_cpu = @import("texture_cpu.zig");
const api = @import("d3d11_glue.zig");
const video = @import("d3d11_video.zig");
const d3d11_device = @import("d3d11_device.zig");

const Com = api.Com;
const HRESULT = api.HRESULT;

/// One slot's GPU textures: the dynamic one the CPU writes and its view,
/// the size it was made at, and for an app's D3D11 texture the target the
/// GPU copies or converts it into (with the copy the colour stage reads).
const Entry = struct {
    texture: ?*Com = null,
    srv: ?*Com = null,
    w: u32 = 0,
    h: u32 = 0,
    target: api.Target = .{},
    source: video.Source = .{},

    fn release(e: *Entry) void {
        e.releaseDynamic();
        e.target.deinit();
        e.source.deinit();
    }

    fn releaseDynamic(e: *Entry) void {
        if (e.srv) |v| v.release();
        if (e.texture) |t| t.release();
        e.texture = null;
        e.srv = null;
        e.w = 0;
        e.h = 0;
    }
};

/// How the slots drew their textures last frame (for the tests).
pub const Path = enum { none, cpu, gpu_copy, gpu_post };

pub const Slots = struct {
    gpa: std.mem.Allocator = std.heap.page_allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// What each slot samples this frame (`prepare`): null when its pixels
    /// could not be read or uploaded, and the instance then draws nothing.
    ready: std.ArrayList(?*Com) = .empty,
    paths: std.ArrayList(Path) = .empty,
    /// The app's textures this frame drew, each with a reference of ours
    /// until the next frame is prepared.
    held: std.ArrayList(*Com) = .empty,
    /// The colour stage, made the first time a texture needs it; `post_failed`
    /// once it could not be (the CPU converts from then on).
    post: ?video.Post = null,
    post_failed: bool = false,

    pub fn deinit(s: *Slots) void {
        for (s.entries.items) |*e| e.release();
        s.entries.deinit(s.gpa);
        s.ready.deinit(s.gpa);
        s.paths.deinit(s.gpa);
        s.releaseHeld();
        s.held.deinit(s.gpa);
        if (s.post) |*p| p.deinit();
        s.post = null;
    }

    fn releaseHeld(s: *Slots) void {
        for (s.held.items) |t| t.release();
        s.held.clearRetainingCapacity();
    }

    /// Uploads every texture of the frame into its slot's texture. The views
    /// and render targets this binds are the renderer's to set again after.
    pub fn prepare(s: *Slots, device: *Com, context: *Com, textures: []const gpu.Texture) void {
        // The last frame was presented before this one is prepared: what it
        // drew from the app may go back to the app.
        s.releaseHeld();
        s.ready.clearRetainingCapacity();
        s.paths.clearRetainingCapacity();
        for (textures, 0..) |t, slot| {
            var path: Path = .none;
            const v = s.upload(device, context, t, slot, &path);
            s.ready.append(s.gpa, v) catch return;
            s.paths.append(s.gpa, if (v == null) .none else path) catch return;
        }
    }

    /// The view slot `slot` samples this frame.
    pub fn get(s: *const Slots, slot: usize) ?*Com {
        return if (slot < s.ready.items.len) s.ready.items[slot] else null;
    }

    fn entry(s: *Slots, slot: usize) ?*Entry {
        while (s.entries.items.len <= slot) s.entries.append(s.gpa, .{}) catch return null;
        return &s.entries.items[slot];
    }

    fn upload(s: *Slots, device: *Com, context: *Com, t: gpu.Texture, slot: usize, path: *Path) ?*Com {
        if (t.d3d11_texture) |raw| {
            const tex: *Com = @ptrCast(@alignCast(raw));
            if (d3d11_device.deviceOf(tex) == device) {
                if (s.uploadGpu(device, context, t, tex, slot, path)) |v| return v;
            }
        }
        path.* = .cpu;
        return s.uploadCpu(device, context, t, slot);
    }

    /// An app's texture on this device: copied, or through the colour stage,
    /// into the slot's target. Null to fall back on the CPU — decided before
    /// the slot's textures are touched, so a frame that always falls back
    /// (no colour stage, a copy that fails) keeps the CPU's dynamic texture
    /// instead of remaking it and the target every frame.
    fn uploadGpu(s: *Slots, device: *Com, context: *Com, t: gpu.Texture, tex: *Com, slot: usize, path: *Path) ?*Com {
        const d = video.describe(tex);
        if (!video.usable(t, d)) return null;
        const e = video.effective(t, d);
        const copy = d.format == api.bgra8 and !e.needsPost();
        if (!copy and s.post == null) {
            if (s.post_failed) return null;
            s.post = video.Post.init(device) catch |err| {
                s.post_failed = true;
                std.log.warn("nanoui: the Direct3D 11 colour stage could not be made ({t}): video frames are converted on the CPU", .{err});
                return null;
            };
        }
        const en = s.entry(slot) orelse return null;
        // The planes into the colour stage's copy first: it is the slot's
        // own texture, so failing here leaves the CPU path's alone.
        if (!copy and !en.source.take(device, context, tex, t.subresource, d.format, video.boxOf(e, d))) return null;
        en.target.reserve(device, e.width, e.height, true);
        const rtv = en.target.rtv orelse return null;
        en.releaseDynamic();
        s.hold(tex);
        if (copy) {
            video.copyBgra(context, en.target.texture.?, tex, t.subresource, .{ .right = e.width, .bottom = e.height });
            path.* = .gpu_copy;
        } else {
            s.post.?.run(device, context, e, &en.source, rtv, e.width, e.height);
            path.* = .gpu_post;
        }
        return en.target.srv;
    }

    fn hold(s: *Slots, tex: *Com) void {
        s.held.append(s.gpa, d3d11_device.addRef(tex)) catch {};
    }

    /// Pixels in memory (or read back from a texture) into the slot's
    /// dynamic texture.
    fn uploadCpu(s: *Slots, device: *Com, context: *Com, t: gpu.Texture, slot: usize) ?*Com {
        var held = texture_cpu.resolve(s.gpa, t) orelse return null;
        defer held.deinit(s.gpa);
        const b = held.bgra;
        if (b.width == 0 or b.height == 0) return null;
        const e = s.entry(slot) orelse return null;
        e.target.deinit();
        const w: u32 = @intCast(b.width);
        const h: u32 = @intCast(b.height);
        if (e.texture == null or e.w != w or e.h != h) {
            e.releaseDynamic();
            const desc: api.Texture2DDesc = .{ .width = w, .height = h, .usage = api.usage_dynamic, .bind = api.bind_shader_resource, .cpu = api.cpu_write };
            var tex: ?*Com = null;
            api.must(device.slot(*const fn (*Com, *const api.Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateTexture2D)(device, &desc, null, &tex), "CreateTexture2D(frame texture)") catch return null;
            e.texture = tex;
            e.srv = api.textureSrv(device, tex.?);
            e.w = w;
            e.h = h;
            if (e.srv == null) {
                e.releaseDynamic();
                return null;
            }
        }
        var mapped: api.Mapped = undefined;
        api.must(context.slot(*const fn (*Com, *Com, u32, u32, u32, *api.Mapped) callconv(.winapi) HRESULT, api.Map)(context, e.texture.?, 0, api.map_write_discard, 0, &mapped), "Map(frame texture)") catch return null;
        defer context.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, api.Unmap)(context, e.texture.?, 0);
        copyRows(mapped.data, mapped.row_pitch, b.pixels, b.stride, b.width * 4, b.height);
        return e.srv;
    }
};

/// `rows` rows of `row_bytes` from `src` (`src_stride` apart) into `dst`
/// (`dst_pitch` apart): a mapped texture's rows are padded as the driver
/// likes, which need not be the app's stride.
pub fn copyRows(dst: [*]u8, dst_pitch: usize, src: []const u8, src_stride: usize, row_bytes: usize, rows: usize) void {
    for (0..rows) |y| @memcpy(dst[y * dst_pitch ..][0..row_bytes], src[y * src_stride ..][0..row_bytes]);
}

test "copyRows moves each row to the driver's pitch" {
    const src = [_]u8{ 1, 2, 3, 4, 9, 9, 5, 6, 7, 8, 9, 9 };
    var dst: [16]u8 = @splat(0);
    copyRows(&dst, 8, &src, 6, 4, 2);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 0, 0, 0, 0, 5, 6, 7, 8, 0, 0, 0, 0 }, &dst);
}

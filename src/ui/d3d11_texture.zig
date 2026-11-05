//! The frame's textures on Direct3D 11 (`ui.texture`, a video's frames): one
//! dynamic BGRA texture and its shader resource view per slot, written each
//! frame by mapping it (`Map` with WRITE_DISCARD: the driver hands over a
//! fresh buffer, so a texture still being read by the last frame is never
//! waited on). A texture whose pixels are not display BGRA (Y'CbCr planes,
//! half floats, a LUT) is first made BGRA on the CPU by the colour stage
//! the CPU renderer uses (`texture_cpu.zig`), so both renderers sample the
//! same texels. A slot's texture is remade only when its size changes.
const std = @import("std");
const gpu = @import("gpu.zig");
const texture_cpu = @import("texture_cpu.zig");
const api = @import("d3d11_glue.zig");

const Com = api.Com;
const HRESULT = api.HRESULT;

/// One slot's GPU texture: its view, and the size it was made at.
const Entry = struct {
    texture: ?*Com = null,
    srv: ?*Com = null,
    w: u32 = 0,
    h: u32 = 0,

    fn release(e: *Entry) void {
        if (e.srv) |v| v.release();
        if (e.texture) |t| t.release();
        e.* = .{};
    }
};

pub const Slots = struct {
    gpa: std.mem.Allocator = std.heap.page_allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// What each slot samples this frame (`prepare`): null when its pixels
    /// could not be read or uploaded, and the instance then draws nothing.
    ready: std.ArrayList(?*Com) = .empty,

    pub fn deinit(s: *Slots) void {
        for (s.entries.items) |*e| e.release();
        s.entries.deinit(s.gpa);
        s.ready.deinit(s.gpa);
    }

    /// Uploads every texture of the frame into its slot's texture.
    pub fn prepare(s: *Slots, device: *Com, context: *Com, textures: []const gpu.Texture) void {
        s.ready.clearRetainingCapacity();
        for (textures, 0..) |t, slot| {
            const v = s.upload(device, context, t, slot);
            s.ready.append(s.gpa, v) catch return;
        }
    }

    /// The view slot `slot` samples this frame.
    pub fn get(s: *const Slots, slot: usize) ?*Com {
        return if (slot < s.ready.items.len) s.ready.items[slot] else null;
    }

    fn upload(s: *Slots, device: *Com, context: *Com, t: gpu.Texture, slot: usize) ?*Com {
        var held = texture_cpu.resolve(s.gpa, t) orelse return null;
        defer held.deinit(s.gpa);
        const b = held.bgra;
        if (b.width == 0 or b.height == 0) return null;
        while (s.entries.items.len <= slot) s.entries.append(s.gpa, .{}) catch return null;
        const e = &s.entries.items[slot];
        const w: u32 = @intCast(b.width);
        const h: u32 = @intCast(b.height);
        if (e.texture == null or e.w != w or e.h != h) {
            e.release();
            const desc: api.Texture2DDesc = .{ .width = w, .height = h, .usage = api.usage_dynamic, .bind = api.bind_shader_resource, .cpu = api.cpu_write };
            var tex: ?*Com = null;
            api.must(device.slot(*const fn (*Com, *const api.Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, api.CreateTexture2D)(device, &desc, null, &tex), "CreateTexture2D(frame texture)") catch return null;
            e.texture = tex;
            e.srv = api.textureSrv(device, tex.?);
            e.w = w;
            e.h = h;
            if (e.srv == null) {
                e.release();
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

//! The one Direct3D 11 device a Windows app draws and presents with
//! (`ui.d3d11Device()`), as macOS shares one Metal device: every window's
//! swap chain and renderer is made on it, so an app's textures — a Media
//! Foundation decoder's, bound to it through `IMFDXGIDeviceManager` — can
//! be drawn by any window without crossing devices, which D3D refuses.
//!
//! It is made with video support (a decoder and the video processor need
//! it) and multithread protection: the decoder runs on its own thread, and
//! the immediate context then serializes its calls with the main thread's.
//! Made on the main thread when the first window first draws. A lost device
//! (a driver update, a GPU reset) is dropped by `checkLost`; the next frame
//! makes another, and `generation` moves on so the app can bind its
//! decoder again.
const std = @import("std");
const api = @import("d3d11_glue.zig");
const Com = api.Com;
const HRESULT = api.HRESULT;

/// D3D11_CREATE_DEVICE_VIDEO_SUPPORT.
pub const video_support: u32 = 0x800;
const iid_multithread: api.Guid = .{ .a = 0x9b7e4e00, .b = 0x342c, .c = 0x4106, .d = .{ 0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0 } };

pub const Pair = struct { device: *Com, context: *Com };

var shared_pair: ?Pair = null;
var shared_generation: u64 = 0;

/// A new device and its immediate context: hardware, else WARP, each with
/// video support when the driver has it (a WARP or a virtual machine's may
/// not), multithread protected. `error.NoDevice` when none can be made.
pub fn create() !Pair {
    // D3D_DRIVER_TYPE_HARDWARE 1, D3D_DRIVER_TYPE_WARP 5.
    for ([_]u32{ 1, 5 }) |driver| for ([_]u32{ api.bgra_support | video_support, api.bgra_support }) |flags| {
        var device: ?*Com = null;
        var context: ?*Com = null;
        if (api.D3D11CreateDevice(null, driver, null, flags, null, 0, api.sdk_version, &device, null, &context) < 0) continue;
        const pair: Pair = .{ .device = device orelse continue, .context = context orelse {
            device.?.release();
            continue;
        } };
        protect(pair.device);
        return pair;
    };
    return error.NoDevice;
}

/// `ID3D10Multithread::SetMultithreadProtected(TRUE)` on `device`'s
/// immediate context: what lets a decoder on another thread share it.
fn protect(device: *Com) void {
    var mt: ?*Com = null;
    if (device.slot(*const fn (*Com, *const api.Guid, *?*Com) callconv(.winapi) HRESULT, 0)(device, &iid_multithread, &mt) < 0) return;
    const m = mt orelse return;
    defer m.release();
    _ = m.slot(*const fn (*Com, i32) callconv(.winapi) i32, 5)(m, 1);
}

/// Whether `device` is multithread protected (for the tests).
pub fn isProtected(device: *Com) bool {
    var mt: ?*Com = null;
    if (device.slot(*const fn (*Com, *const api.Guid, *?*Com) callconv(.winapi) HRESULT, 0)(device, &iid_multithread, &mt) < 0) return false;
    const m = mt orelse return false;
    defer m.release();
    return m.slot(*const fn (*Com) callconv(.winapi) i32, 6)(m) != 0;
}

/// The shared device, made the first time it is asked for; null where
/// Direct3D 11 can't be had. Main thread only. The pair is the module's:
/// keep it with `addRef`.
pub fn shared() ?Pair {
    if (shared_pair) |p| return p;
    shared_pair = create() catch return null;
    shared_generation += 1;
    return shared_pair;
}

/// The shared device as it is now, without making one.
pub fn current() ?Pair {
    return shared_pair;
}

/// Moves on each time a shared device is made: an app that bound the last
/// one to its decoder binds the new one.
pub fn generation() u64 {
    return shared_generation;
}

/// After a failed present: if the shared device was removed, it is let go
/// (the windows holding it let go of theirs) and the next frame makes
/// another.
pub fn checkLost() void {
    const p = shared_pair orelse return;
    if (p.device.slot(*const fn (*Com) callconv(.winapi) HRESULT, 39)(p.device) >= 0) return; // GetDeviceRemovedReason
    std.log.warn("nanoui: the Direct3D 11 device was removed: a new one is made", .{});
    shared_pair = null;
    p.context.release();
    p.device.release();
}

pub fn addRef(c: *Com) *Com {
    _ = c.slot(*const fn (*Com) callconv(.winapi) u32, 1)(c);
    return c;
}

/// The device `child` (a texture, a view) was made on, without a reference.
pub fn deviceOf(child: *Com) ?*Com {
    var dev: ?*Com = null;
    child.slot(*const fn (*Com, *?*Com) callconv(.winapi) void, 3)(child, &dev); // ID3D11DeviceChild::GetDevice
    const d = dev orelse return null;
    d.release();
    return d;
}

/// `device`'s immediate context, without a reference.
pub fn contextOf(device: *Com) *Com {
    var ctx: ?*Com = null;
    device.slot(*const fn (*Com, *?*Com) callconv(.winapi) void, 40)(device, &ctx); // GetImmediateContext
    const c = ctx.?;
    c.release();
    return c;
}

test "the shared device is made once, multithread protected, and outlives a check" {
    const a = shared() orelse return error.SkipZigTest;
    const g = generation();
    const b = shared().?;
    try std.testing.expectEqual(a.device, b.device);
    try std.testing.expectEqual(g, generation());
    try std.testing.expect(isProtected(a.device));
    try std.testing.expectEqual(a.context, contextOf(a.device));
    // Not removed: kept.
    checkLost();
    try std.testing.expectEqual(a.device, current().?.device);
}

//! What the display under a Windows swap chain can show (`DisplayInfo`):
//! the output's colour space, peak luminance and primaries from
//! `IDXGIOutput6::GetDesc1`, and the SDR white level the Windows HDR slider
//! sets from `DisplayConfigGetDeviceInfo(DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL)`.
//! scRGB's 1.0 is 80 nits, and the level's 1000 is 80 nits too: SDR white
//! is `level / 1000 · 80` nits, drawn at `level / 1000` (`sdr_white_scale`).
//! A value the system does not give leaves the SDR display's default, and a
//! line is logged.
const std = @import("std");
const gpu = @import("../ui/gpu.zig");

const HRESULT = i32;
const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

/// IDXGIOutput6 (dxgi1_6.h).
const iid_output6: Guid = .{ .a = 0x068346e8, .b = 0xaaec, .c = 0x4b84, .d = .{ 0xad, 0xd7, 0x13, 0x7f, 0x51, 0x3f, 0x77, 0xa1 } };

/// DXGI_COLOR_SPACE_RGB_FULL_G2084_NONE_P2020: an HDR10 output.
pub const colour_space_hdr10: u32 = 12;

const Com = extern struct {
    vtable: [*]const *const anyopaque,
    fn slot(c: *Com, comptime T: type, i: usize) T {
        return @ptrCast(@alignCast(c.vtable[i]));
    }
    fn release(c: *Com) void {
        _ = c.slot(*const fn (*Com) callconv(.winapi) u32, 2)(c);
    }
};

/// DXGI_OUTPUT_DESC1.
pub const OutputDesc1 = extern struct {
    device_name: [32]u16,
    desktop: [4]i32,
    attached: i32,
    rotation: u32,
    monitor: ?*anyopaque,
    bits_per_color: u32,
    colour_space: u32,
    red: [2]f32,
    green: [2]f32,
    blue: [2]f32,
    white: [2]f32,
    min_luminance: f32,
    max_luminance: f32,
    max_full_frame_luminance: f32,
};

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(OutputDesc1) == 152);
}

const Luid = extern struct { low: u32, high: i32 };

/// DISPLAYCONFIG_DEVICE_INFO_HEADER.
const InfoHeader = extern struct { kind: u32, size: u32, adapter: Luid, id: u32 };

/// DISPLAYCONFIG_PATH_INFO: its source, its target, its flags.
const PathInfo = extern struct {
    source_adapter: Luid,
    source_id: u32,
    source_mode: u32,
    source_status: u32,
    target_adapter: Luid,
    target_id: u32,
    target_mode: u32,
    technology: u32,
    rotation: u32,
    scaling: u32,
    refresh: [2]u32,
    scanline: u32,
    available: i32,
    target_status: u32,
    flags: u32,
};

/// DISPLAYCONFIG_MODE_INFO: only counted here.
const ModeInfo = extern struct { bytes: [64]u8 align(8) };

comptime {
    std.debug.assert(@sizeOf(InfoHeader) == 20);
    std.debug.assert(@sizeOf(PathInfo) == 72);
}

const SourceName = extern struct { header: InfoHeader, name: [32]u16 };
const SdrWhite = extern struct { header: InfoHeader, level: u32 };

const get_source_name: u32 = 1;
const get_sdr_white_level: u32 = 11;
const qdc_only_active_paths: u32 = 2;

extern "user32" fn GetDisplayConfigBufferSizes(flags: u32, paths: *u32, modes: *u32) callconv(.winapi) i32;
extern "user32" fn QueryDisplayConfig(flags: u32, paths: *u32, path_array: [*]PathInfo, modes: *u32, mode_array: [*]ModeInfo, topology: ?*u32) callconv(.winapi) i32;
extern "user32" fn DisplayConfigGetDeviceInfo(packet: *InfoHeader) callconv(.winapi) i32;

/// The output a swap chain is on (`IDXGISwapChain::GetContainingOutput`),
/// described (`IDXGIOutput6::GetDesc1`); null where it can't say (no
/// output yet, a remote session, an old DXGI).
pub fn describe(swap: *anyopaque) ?OutputDesc1 {
    const sc: *Com = @ptrCast(@alignCast(swap));
    var output: ?*Com = null;
    if (sc.slot(*const fn (*Com, *?*Com) callconv(.winapi) HRESULT, 15)(sc, &output) < 0) return null; // GetContainingOutput
    const o = output orelse return null;
    defer o.release();
    var o6: ?*Com = null;
    if (o.slot(*const fn (*Com, *const Guid, *?*Com) callconv(.winapi) HRESULT, 0)(o, &iid_output6, &o6) < 0) return null;
    const out6 = o6 orelse return null;
    defer out6.release();
    var desc: OutputDesc1 = undefined;
    if (out6.slot(*const fn (*Com, *OutputDesc1) callconv(.winapi) HRESULT, 27)(out6, &desc) < 0) return null; // GetDesc1
    return desc;
}

/// The SDR white level (1000 = 80 nits) of the display GDI names
/// `device_name` (`\\.\DISPLAY1`), or null when the system won't say.
pub fn sdrWhiteLevel(device_name: []const u16) ?u32 {
    var np: u32 = 0;
    var nm: u32 = 0;
    if (GetDisplayConfigBufferSizes(qdc_only_active_paths, &np, &nm) != 0 or np == 0) return null;
    const gpa = std.heap.page_allocator;
    const paths = gpa.alloc(PathInfo, np) catch return null;
    defer gpa.free(paths);
    const modes = gpa.alloc(ModeInfo, @max(nm, 1)) catch return null;
    defer gpa.free(modes);
    if (QueryDisplayConfig(qdc_only_active_paths, &np, paths.ptr, &nm, modes.ptr, null) != 0) return null;
    for (paths[0..np]) |p| {
        var name: SourceName = .{ .header = .{ .kind = get_source_name, .size = @sizeOf(SourceName), .adapter = p.source_adapter, .id = p.source_id }, .name = @splat(0) };
        if (DisplayConfigGetDeviceInfo(&name.header) != 0) continue;
        if (!sameName(&name.name, device_name)) continue;
        var white: SdrWhite = .{ .header = .{ .kind = get_sdr_white_level, .size = @sizeOf(SdrWhite), .adapter = p.target_adapter, .id = p.target_id }, .level = 0 };
        if (DisplayConfigGetDeviceInfo(&white.header) != 0 or white.level == 0) return null;
        return white.level;
    }
    return null;
}

fn sameName(a: []const u16, b: []const u16) bool {
    const la = std.mem.indexOfScalar(u16, a, 0) orelse a.len;
    const lb = std.mem.indexOfScalar(u16, b, 0) orelse b.len;
    return std.mem.eql(u16, a[0..la], b[0..lb]);
}

/// `DisplayInfo` from an output's description and its SDR white level
/// (null: not given, the default 80 nits, scale 1).
pub fn infoOf(desc: OutputDesc1, white_level: ?u32) gpu.DisplayInfo {
    const level: f32 = @floatFromInt(white_level orelse 1000);
    const white_nits = level / 1000.0 * 80.0;
    const hdr = desc.colour_space == colour_space_hdr10;
    const peak = if (hdr and desc.max_luminance > 0) desc.max_luminance else white_nits;
    const headroom = @max(1.0, peak / white_nits);
    return .{
        .headroom_now = if (hdr) headroom else 1,
        .headroom_potential = if (hdr) headroom else 1,
        .sdr_white_nits = white_nits,
        .max_nits = peak,
        .hdr_output = hdr,
        // Display P3's red is at x 0.680, sRGB's at 0.640.
        .wide_gamut = hdr or desc.red[0] >= 0.66,
        .sdr_white_scale = level / 1000.0,
    };
}

test "scRGB display info: SDR white from its level, headroom to the output's peak" {
    var d: OutputDesc1 = std.mem.zeroes(OutputDesc1);
    d.colour_space = colour_space_hdr10;
    d.max_luminance = 1000;
    d.red = .{ 0.708, 0.292 };
    // The slider at 200 nits: 2500 (k 2.5), 5x headroom to a 1000-nit peak.
    const i = infoOf(d, 2500);
    try std.testing.expectEqual(@as(f32, 200), i.sdr_white_nits);
    try std.testing.expectEqual(@as(f32, 2.5), i.sdr_white_scale);
    try std.testing.expectEqual(@as(f32, 5), i.headroom_potential);
    try std.testing.expect(i.hdr_output and i.wide_gamut and i.hasHeadroom());
    // No level given: 80 nits, scRGB's 1.0.
    const none = infoOf(d, null);
    try std.testing.expectEqual(@as(f32, 80), none.sdr_white_nits);
    try std.testing.expectEqual(@as(f32, 1), none.sdr_white_scale);
    // An SDR output: no headroom, its gamut from its primaries.
    d.colour_space = 0;
    d.red = .{ 0.64, 0.33 };
    const sdr = infoOf(d, 1000);
    try std.testing.expect(!sdr.hdr_output and !sdr.wide_gamut and !sdr.hasHeadroom());
}

//! Renderer selection on Linux: decides between OpenGL (`GtkGLArea`) and the
//! CPU rasterizer (`GtkDrawingArea`), and sets `GSK_RENDERER=cairo` before GTK
//! loads when drawing on the CPU unless the caller already set `GSK_RENDERER`.
//! Formally verified across all 72 combinations in `NanoUI.LinuxStartup`.
const std = @import("std");
const builtin = @import("builtin");

pub const EnvRenderer = enum { auto, cpu, gl };
pub const Backend = enum { cpu, gl };

pub const Decision = struct {
    backend: Backend,
    set_gsk_cairo: bool,
};

/// Parses `NANOUI_RENDERER` (`"cpu"`, `"gl"`, else `.auto`).
pub fn parseEnv(value: ?[]const u8) EnvRenderer {
    const v = value orelse return .auto;
    if (std.mem.eql(u8, v, "cpu")) return .cpu;
    if (std.mem.eql(u8, v, "gl")) return .gl;
    return .auto;
}

/// True when the environment explicitly asks Mesa / libGL for software GL
/// (`LIBGL_ALWAYS_SOFTWARE` truthy or `GALLIUM_DRIVER` set to a SW rasterizer).
pub fn softwareHint(libgl_always_software: ?[]const u8, gallium_driver: ?[]const u8) bool {
    if (libgl_always_software) |v| {
        if (std.mem.eql(u8, v, "1") or
            std.ascii.eqlIgnoreCase(v, "true") or
            std.ascii.eqlIgnoreCase(v, "yes"))
        {
            return true;
        }
    }
    if (gallium_driver) |d| {
        if (std.mem.eql(u8, d, "llvmpipe") or
            std.mem.eql(u8, d, "softpipe") or
            std.mem.eql(u8, d, "swr"))
        {
            return true;
        }
    }
    return false;
}

/// Pure decision function mirrored by `NanoUI.LinuxStartup.selectRenderer`:
/// shaped windows always use CPU; otherwise `.cpu`/`.gl` honor explicit choices
/// and `.auto` uses OpenGL only when a hardware GPU is present without SW hints.
pub fn decide(
    env: EnvRenderer,
    has_hw_gpu: bool,
    sw_hint: bool,
    transparent_shape: bool,
    user_gsk_set: bool,
) Decision {
    const want_cairo = !user_gsk_set;
    if (transparent_shape) return .{ .backend = .cpu, .set_gsk_cairo = want_cairo };
    return switch (env) {
        .cpu => .{ .backend = .cpu, .set_gsk_cairo = want_cairo },
        .gl => .{ .backend = .gl, .set_gsk_cairo = false },
        .auto => if (has_hw_gpu and !sw_hint)
            .{ .backend = .gl, .set_gsk_cairo = false }
        else
            .{ .backend = .cpu, .set_gsk_cairo = want_cairo },
    };
}

/// True when a sysfs DRM device `uevent` identifies a virtual test driver
/// (`vgem` or `vkms`) rather than physical display/render hardware.
pub fn isVirtualDrmDriver(uevent: []const u8) bool {
    var it = std.mem.splitScalar(u8, uevent, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r ");
        if (std.mem.eql(u8, line, "DRIVER=vgem") or std.mem.eql(u8, line, "DRIVER=vkms")) {
            return true;
        }
    }
    return false;
}

/// Checks for an accessible non-virtual hardware GPU render node on Linux
/// (`/dev/nvidiactl` or a readable `/dev/dri/renderD*` not backed by `vgem`/`vkms`).
pub fn hasHardwareGpu(io: std.Io) bool {
    if (comptime builtin.os.tag != .linux) return true;
    if (std.Io.Dir.cwd().access(io, "/dev/nvidiactl", .{ .read = true })) |_| {
        return true;
    } else |_| {}

    var dri = std.Io.Dir.cwd().openDir(io, "/dev/dri", .{ .iterate = true }) catch return false;
    defer dri.close(io);

    var it = dri.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "renderD")) continue;
        dri.access(io, entry.name, .{ .read = true }) catch continue;
        var path_buf: [128]u8 = undefined;
        const uevent_path = std.fmt.bufPrint(&path_buf, "/sys/class/drm/{s}/device/uevent", .{entry.name}) catch continue;
        if (std.Io.Dir.cwd().openFile(io, uevent_path, .{})) |file| {
            defer file.close(io);
            var uevent_buf: [512]u8 = undefined;
            const n = file.readPositionalAll(io, &uevent_buf, 0) catch 0;
            if (n > 0 and isVirtualDrmDriver(uevent_buf[0..n])) continue;
        } else |_| {}
        return true;
    }
    return false;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

/// Sets `GSK_RENDERER=cairo` before GTK initializes without clobbering any
/// explicit caller setting (`overwrite = 0`).
pub fn configureGskForCpu() void {
    if (comptime builtin.os.tag != .linux) return;
    _ = setenv("GSK_RENDERER", "cairo", 0);
}

test "parseEnv maps cpu, gl and auto" {
    try std.testing.expectEqual(EnvRenderer.auto, parseEnv(null));
    try std.testing.expectEqual(EnvRenderer.auto, parseEnv(""));
    try std.testing.expectEqual(EnvRenderer.auto, parseEnv("auto"));
    try std.testing.expectEqual(EnvRenderer.cpu, parseEnv("cpu"));
    try std.testing.expectEqual(EnvRenderer.gl, parseEnv("gl"));
}

test "softwareHint recognizes software GL overrides" {
    try std.testing.expect(!softwareHint(null, null));
    try std.testing.expect(!softwareHint("0", "radeonsi"));
    try std.testing.expect(softwareHint("1", null));
    try std.testing.expect(softwareHint("TRUE", null));
    try std.testing.expect(softwareHint("Yes", null));
    try std.testing.expect(softwareHint(null, "llvmpipe"));
    try std.testing.expect(softwareHint(null, "softpipe"));
    try std.testing.expect(softwareHint(null, "swr"));
}

test "isVirtualDrmDriver flags vgem and vkms only" {
    try std.testing.expect(isVirtualDrmDriver("PCI_SLOT_NAME=0\nDRIVER=vgem\nMODALIAS=platform:vgem\n"));
    try std.testing.expect(isVirtualDrmDriver("DRIVER=vkms\r\n"));
    try std.testing.expect(!isVirtualDrmDriver("DRIVER=i915\nPCI_CLASS=30000\n"));
    try std.testing.expect(!isVirtualDrmDriver("DRIVER=amdgpu\n"));
}

test "decide satisfies all 72 Lean model invariants" {
    const Trans = enum { none, alpha, shape };
    const envs = [_]EnvRenderer{ .auto, .cpu, .gl };
    const gpus = [_]bool{ false, true };
    const hints = [_]bool{ false, true };
    const trans_modes = [_]Trans{ .none, .alpha, .shape };
    const gsks = [_]bool{ false, true };

    var count: usize = 0;
    for (envs) |env| {
        for (gpus) |gpu| {
            for (hints) |hint| {
                for (trans_modes) |tmode| {
                    const shape = tmode == .shape;
                    for (gsks) |user_gsk| {
                        count += 1;
                        const d = decide(env, gpu, hint, shape, user_gsk);
                        if (shape) try std.testing.expectEqual(Backend.cpu, d.backend);
                        if (env == .cpu) try std.testing.expectEqual(Backend.cpu, d.backend);
                        if (env == .gl and !shape) try std.testing.expectEqual(Backend.gl, d.backend);
                        if (env == .auto and gpu and !hint and !shape) try std.testing.expectEqual(Backend.gl, d.backend);
                        if (env == .auto and (!gpu or hint)) try std.testing.expectEqual(Backend.cpu, d.backend);
                        if (user_gsk) try std.testing.expect(!d.set_gsk_cairo);
                        if (d.backend == .gl) try std.testing.expect(!d.set_gsk_cairo);
                    }
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 72), count);
}

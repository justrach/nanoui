//! Browser build helper for applications consuming nanoui as a dependency.
const std = @import("std");

/// Installs a wasm32-wasi command and its browser ES modules side by side.
/// Pass the nanoui dependency's root so this works outside nanoui's tree:
/// `nanoui.web.install(b, exe, dependency.path("."))`.
/// Both the executable and nanoui modules must be single-threaded wasm32-wasi.
pub fn install(b: *std.Build, exe: *std.Build.Step.Compile, nanoui_root: std.Build.LazyPath) *std.Build.Step {
    const target = exe.root_module.resolved_target.?.result;
    if (target.cpu.arch != .wasm32 or target.os.tag != .wasi) @panic("web.install needs wasm32-wasi");
    exe.rdynamic = true;
    const output = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    for ([_][]const u8{ "gpu.js", "gpu_timing.js", "external.js", "wasi.js", "nanoui.js", "host.js" }) |name| {
        const source = nanoui_root.path(b, b.fmt("src/web/{s}", .{name}));
        output.step.dependOn(&b.addInstallFile(source, b.fmt("web/{s}", .{name})).step);
    }
    return &output.step;
}

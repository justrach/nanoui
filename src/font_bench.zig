//! Headless release measurements:
//! `zig build font-bench -Doptimize=ReleaseFast -- scan --cache=PATH`
//! `zig build font-bench -Doptimize=ReleaseFast -- memory --cache=PATH`
const std = @import("std");
const builtin = @import("builtin");
const fontdb = @import("ui/tt/fontdb.zig");
const atlas_mod = @import("ui/atlas_tt.zig");

const Counters = extern struct {
    cb: u32 = @sizeOf(Counters),
    faults: u32 = 0,
    peak_working: usize = 0,
    working: usize = 0,
    peak_paged: usize = 0,
    paged: usize = 0,
    peak_nonpaged: usize = 0,
    nonpaged: usize = 0,
    pagefile: usize = 0,
    peak_pagefile: usize = 0,
    private: usize = 0,
};
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;
extern "psapi" fn GetProcessMemoryInfo(process: *anyopaque, counters: *Counters, size: u32) callconv(.winapi) i32;

fn privateBytes() usize {
    if (builtin.os.tag != .windows) return 0;
    var counters: Counters = .{};
    if (GetProcessMemoryInfo(GetCurrentProcess(), &counters, @sizeOf(Counters)) == 0) return 0;
    return counters.private;
}

fn arg(args: []const []const u8, name: []const u8) ?[]const u8 {
    for (args) |a| if (std.mem.startsWith(u8, a, name)) return a[name.len..];
    return null;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(gpa);
    const mode = if (args.len > 1) args[1] else "scan";
    if (std.mem.eql(u8, mode, "memory")) return memory(init, args);
    return scan(init, args);
}

fn defaultFonts() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "C:\\Windows\\Fonts",
        .macos => "/System/Library/Fonts",
        .ios => "/System/Library/Fonts",
        .linux => if (builtin.abi.isAndroid()) "/system/fonts" else "/usr/share/fonts",
        else => unreachable,
    };
}

fn scan(init: std.process.Init, args: []const []const u8) !void {
    var db = fontdb.Db.init(init.gpa, init.io);
    defer db.deinit();
    db.fonts_dir = arg(args, "--fonts=") orelse defaultFonts();
    db.cache_path = arg(args, "--cache=");
    const before = privateBytes();
    const start = @import("ui/clock.zig").now();
    db.scan();
    const elapsed = (@import("ui/clock.zig").now() - start) * std.time.ns_per_s;
    std.debug.print("scan_ns={d:.0} scan_ms={d:.3} faces={d} private_delta={d}", .{ elapsed, elapsed / std.time.ns_per_ms, db.faces.items.len, privateBytes() -| before });
    std.debug.print(" cache={s}\n", .{@tagName(db.cache.state)});
}

fn memory(init: std.process.Init, args: []const []const u8) !void {
    if (builtin.os.tag != .windows) return error.WindowsOnly;
    var atlas = atlas_mod.Atlas.init(init.gpa);
    defer atlas.deinit();
    var db = fontdb.Db.init(init.gpa, init.io);
    defer db.deinit();
    db.fonts_dir = arg(args, "--fonts=") orelse defaultFonts();
    db.cache_path = arg(args, "--cache=");
    const family = arg(args, "--family=") orelse "Microsoft YaHei UI";
    const face = db.family(family, 400, false) orelse return error.FontNotFound;
    const before_load = privateBytes();
    const f = db.load(face) orelse return error.FontLoadFailed;
    const after_load = privateBytes();
    const glyph = f.glyphIndex('中');
    const rf: atlas_mod.RunFont = .{ .font = f, .size = 24 };
    _ = atlas.glyph(0, rf, glyph, 0) orelse return error.GlyphFailed;
    const after_glyph = privateBytes();
    std.debug.print("family={s} bytes={d} load_delta={d} glyph_delta={d} total_delta={d} failures={d}\n", .{ family, f.data.len, after_load -| before_load, after_glyph -| after_load, after_glyph -| before_load, atlas.native.failures });
}

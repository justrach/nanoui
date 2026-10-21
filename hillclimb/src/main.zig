//! nanoui's hill-climb: a terminal app that renders benchmark scenes
//! offscreen with nanoui and with mygo, and lays them out with Clay, frame
//! after frame, and compares their CPU and GPU costs with each other and
//! with earlier runs. No window opens, nothing takes focus.
//!
//!   zig build run                          all scenes, nanoui and mygo
//!   zig build run -- --label "glyph atlas" name this run in the history
//!   zig build run -- --scene text --frames 600 --only nanoui
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const scenes = @import("scenes.zig");
const report = @import("report.zig");
const mygo = @import("mygo.zig");
const clay = @import("clay.zig");
const cpu = @import("cpu.zig");
const nanoui_run = if (builtin.os.tag == .macos) @import("metal_run.zig") else cpu;

pub const width = 900;
pub const height = 640;
pub const scale = 2;
pub const warmup = 30;

pub const Result = struct {
    fw: []const u8,
    scene: []const u8,
    frames: usize,
    /// Median CPU time of building, laying out and painting a frame.
    frame_ms: f64,
    frame_p95: f64,
    frame_p99: f64 = 0,
    /// Median CPU time of encoding it for the GPU.
    encode_ms: f64,
    /// Median GPU time of drawing it.
    gpu_ms: f64,
    /// The process's CPU time (user + system) per frame, all included.
    cpu_ms: f64,
    /// What the GPU draws: nanoui's instances, mygo's scene operations,
    /// Clay's render commands.
    ops: usize,
    /// nanoui's phases of a frame (medians); mygo reports none.
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
    /// Who drew it: "metal", "cpu", "opengl", "llvmpipe".
    renderer: []const u8 = "",
};

const Options = struct {
    frames: usize = 300,
    /// Runs of each scene; the one with the lowest median frame is kept,
    /// the others being the same work disturbed by the rest of the system.
    repeat: usize = 3,
    only: ?[]const u8 = null,
    scenes: []const scenes.Scene = std.enums.values(scenes.Scene),
    label: []const u8 = "",
    /// 1 Y-sample CPU shadows (faster encode; does not match Metal).
    cheap_shadow: bool = false,
};

pub fn cpuSeconds() f64 {
    const ru = std.posix.getrusage(0);
    const tv = struct {
        fn s(t: anytype) f64 {
            return @as(f64, @floatFromInt(t.sec)) + @as(f64, @floatFromInt(t.usec)) / 1e6;
        }
    }.s;
    return tv(ru.utime) + tv(ru.stime);
}

pub fn medianOf(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

pub fn p95Of(xs: []f64) f64 {
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len * 95 / 100];
}

pub fn p99Of(xs: []f64) f64 {
    if (xs.len == 0) return 0;
    std.mem.sort(f64, xs, {}, std.sort.asc(f64));
    return xs[@min(xs.len - 1, xs.len * 99 / 100)];
}

fn runNanoui(gpa: std.mem.Allocator, scene: scenes.Scene, frames: usize) !Result {
    return nanoui_run.run(gpa, scene, frames);
}

fn better(a: ?Result, b: Result) Result {
    return if (a) |x| (if (x.frame_ms <= b.frame_ms) x else b) else b;
}

fn parseArgs(init: std.process.Init) !Options {
    const arena = init.arena.allocator();
    var o: Options = .{};
    const args = try init.minimal.args.toSlice(arena);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--repeat")) {
            o.repeat = @max(1, try std.fmt.parseInt(usize, next, 10));
            i += 1;
        } else if (std.mem.eql(u8, a, "--frames")) {
            o.frames = try std.fmt.parseInt(usize, next, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--only")) {
            o.only = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--label")) {
            o.label = next;
            i += 1;
        } else if (std.mem.eql(u8, a, "--scene")) {
            var list: std.ArrayList(scenes.Scene) = .empty;
            var it = std.mem.splitScalar(u8, next, ',');
            while (it.next()) |name| try list.append(arena, std.meta.stringToEnum(scenes.Scene, name) orelse return error.UnknownScene);
            o.scenes = list.items;
            i += 1;
        } else if (std.mem.eql(u8, a, "--cheap-shadow")) {
            o.cheap_shadow = true;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print("usage: hillclimb [--scene boxes,text,scroll,list,dashboard,springs,letters] [--frames N] [--only nanoui|mygo|clay] [--label NAME] [--cheap-shadow]\n", .{});
            std.process.exit(0);
        } else return error.UnknownArgument;
    }
    return o;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const opts = try parseArgs(init);
    if (opts.cheap_shadow) ui.raster.shadows.samples = 1;
    const want = struct {
        fn f(o: Options, fw: []const u8) bool {
            return o.only == null or std.mem.eql(u8, o.only.?, fw);
        }
    }.f;

    report.header(opts.frames);
    var results: std.ArrayList(Result) = .empty;
    var mygo_error: ?anyerror = null;
    if (want(opts, "mygo")) {
        report.status("building mygo's twin (go test -c)…");
        mygo.build(init) catch |err| {
            report.status("");
            mygo_error = err;
            std.debug.print("mygo skipped: {s}\n", .{@errorName(err)});
        };
    }
    for (opts.scenes) |scene| {
        var n_best: ?Result = null;
        var m_best: ?Result = null;
        var c_best: ?Result = null;
        for (0..opts.repeat) |rep| {
            if (want(opts, "nanoui")) {
                report.status(try std.fmt.allocPrint(arena, "nanoui · {s} · run {d}/{d}…", .{ @tagName(scene), rep + 1, opts.repeat }));
                n_best = better(n_best, try runNanoui(gpa, scene, opts.frames));
            }
            if (want(opts, "mygo") and mygo.ready) {
                report.status(try std.fmt.allocPrint(arena, "mygo · {s} · run {d}/{d}…", .{ @tagName(scene), rep + 1, opts.repeat }));
                if (mygo.run(init, scene, opts.frames)) |r| {
                    m_best = better(m_best, r);
                } else |err| std.debug.print("mygo {s}: {s}\n", .{ @tagName(scene), @errorName(err) });
            }
            if (want(opts, "clay")) {
                report.status(try std.fmt.allocPrint(arena, "clay · {s} · run {d}/{d}…", .{ @tagName(scene), rep + 1, opts.repeat }));
                c_best = better(c_best, try clay.run(gpa, scene, opts.frames));
            }
        }
        if (n_best) |r| try results.append(arena, r);
        if (m_best) |r| try results.append(arena, r);
        if (c_best) |r| try results.append(arena, r);
    }
    report.status("");
    const history = report.loadHistory(init) catch &.{};
    report.table(results.items, history);
    if (mygo_error) |err| std.debug.print("\x1b[31mmygo's twin did not build ({s}): its columns are empty.\x1b[0m\n", .{@errorName(err)});
    try report.appendHistory(init, opts.label, results.items);
}

//! The terminal report: one table per run, nanoui against mygo and Clay
//! (its layout and render commands only: it draws nothing), and
//! nanoui against its own earlier runs (history.jsonl), so each change is
//! kept only if it climbs.
const std = @import("std");
const main = @import("main.zig");


const history_path = "history.jsonl";

const Entry = struct {
    time: u64,
    label: []const u8 = "",
    results: []const main.Result,
};

const green = "\x1b[32m";
const red = "\x1b[31m";
const dim = "\x1b[2m";
const bold = "\x1b[1m";
const reset = "\x1b[0m";

pub fn header(frames: usize) void {
    std.debug.print("\n{s}nanoui hill-climb{s} {s}· {d} frames after {d} of warm-up · {d}×{d} at {d}x · offscreen, no window{s}\n\n", .{
        bold, reset, dim, frames, 30, main.width, main.height, main.scale, reset,
    });
}

/// A transient progress line, rewritten in place.
pub fn status(text: []const u8) void {
    std.debug.print("\r\x1b[2K{s}{s}{s}", .{ dim, text, reset });
}

pub fn loadHistory(init: std.process.Init) ![]const Entry {
    const arena = init.arena.allocator();
    const data = std.Io.Dir.cwd().readFileAlloc(init.io, history_path, arena, .limited(64 << 20)) catch return &.{};
    var list: std.ArrayList(Entry) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r").len == 0) continue;
        const e = std.json.parseFromSliceLeaky(Entry, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
        try list.append(arena, e);
    }
    return list.items;
}

pub fn appendHistory(init: std.process.Init, label: []const u8, results: []const main.Result) !void {
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();
    const old = cwd.readFileAlloc(init.io, history_path, gpa, .limited(64 << 20)) catch try gpa.dupe(u8, "");
    defer gpa.free(old);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try aw.writer.writeAll(old);
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const entry: Entry = .{ .time = @intCast(ts.sec), .label = label, .results = results };
    try std.json.Stringify.value(entry, .{}, &aw.writer);
    try aw.writer.writeByte('\n');
    try cwd.writeFile(init.io, .{ .sub_path = history_path, .data = aw.written() });
}

fn find(results: []const main.Result, fw: []const u8, scene: []const u8) ?main.Result {
    for (results) |r| if (std.mem.eql(u8, r.fw, fw) and std.mem.eql(u8, r.scene, scene)) return r;
    return null;
}

const Metric = struct { name: []const u8, get: *const fn (main.Result) f64, unit: []const u8 };

const metrics = [_]Metric{
    .{ .name = "frame CPU (median)", .get = struct {
        fn f(r: main.Result) f64 {
            return r.frame_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "frame CPU (p95)", .get = struct {
        fn f(r: main.Result) f64 {
            return r.frame_p95;
        }
    }.f, .unit = "ms" },
    .{ .name = "  build", .get = struct {
        fn f(r: main.Result) f64 {
            return r.build_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "  layout", .get = struct {
        fn f(r: main.Result) f64 {
            return r.layout_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "  paint", .get = struct {
        fn f(r: main.Result) f64 {
            return r.paint_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "encode CPU", .get = struct {
        fn f(r: main.Result) f64 {
            return r.encode_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "GPU", .get = struct {
        fn f(r: main.Result) f64 {
            return r.gpu_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "process CPU / frame", .get = struct {
        fn f(r: main.Result) f64 {
            return r.cpu_ms;
        }
    }.f, .unit = "ms" },
    .{ .name = "draw items", .get = struct {
        fn f(r: main.Result) f64 {
            return @floatFromInt(r.ops);
        }
    }.f, .unit = "" },
};

/// Another framework's value, and nanoui's against it.
fn compare(n: ?main.Result, other: ?main.Result, metric: Metric) void {
    if (other != null and metric.get(other.?) > 0) std.debug.print("{d:>9.3} ", .{metric.get(other.?)}) else std.debug.print("{s:>9} ", .{"—"});
    if (n != null and other != null and metric.get(other.?) > 0) {
        const ratio = metric.get(n.?) / metric.get(other.?);
        const col = if (ratio < 0.95) green else if (ratio > 1.05) red else dim;
        std.debug.print("{s}{d:>8.2}×{s} ", .{ col, ratio, reset });
    } else std.debug.print("{s:>9} ", .{""});
}

fn pct(now: f64, then: f64) f64 {
    return if (then == 0) 0 else (now - then) / then * 100;
}

fn signed(buf: []u8, d: f64) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d:.1}%", .{ if (d < 0) "-" else "+", @abs(d) }) catch "?";
}

/// Changes within ±5% are noise on a machine doing other work.
fn deltaColor(d: f64) []const u8 {
    return if (d < -5) green else if (d > 5) red else dim;
}

pub fn table(results: []const main.Result, history: []const Entry) void {
    const last: ?Entry = if (history.len > 0) history[history.len - 1] else null;
    std.debug.print("{s}{s:<10} {s:<20} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>8} {s:>8}{s}\n", .{ bold, "scene", "metric", "nanoui", "mygo", "n / m", "clay", "n / c", "Δ last", "Δ best", reset });
    var scenes_seen: [8][]const u8 = undefined;
    var n_scenes: usize = 0;
    for (results) |r| {
        var seen = false;
        for (scenes_seen[0..n_scenes]) |s| if (std.mem.eql(u8, s, r.scene)) {
            seen = true;
        };
        if (seen or n_scenes == scenes_seen.len) continue;
        scenes_seen[n_scenes] = r.scene;
        n_scenes += 1;
    }
    for (scenes_seen[0..n_scenes]) |scene| {
        const n = find(results, "nanoui", scene);
        const m = find(results, "mygo", scene);
        const cl = find(results, "clay", scene);
        for (metrics, 0..) |metric, mi| {
            std.debug.print("{s:<10} {s:<20} ", .{ if (mi == 0) scene else "", metric.name });
            if (n) |nr| std.debug.print("{d:>9.3} ", .{metric.get(nr)}) else std.debug.print("{s:>9} ", .{"—"});
            if (m != null and metric.get(m.?) > 0) std.debug.print("{d:>9.3} ", .{metric.get(m.?)}) else std.debug.print("{s:>9} ", .{"—"});
            if (n != null and m != null and metric.get(m.?) > 0) {
                const ratio = metric.get(n.?) / metric.get(m.?);
                const col = if (ratio < 0.95) green else if (ratio > 1.05) red else dim;
                std.debug.print("{s}{d:>8.2}×{s} ", .{ col, ratio, reset });
            } else std.debug.print("{s:>9} ", .{""});
            compare(n, cl, metric);
            if (n) |nr| {
                const v = metric.get(nr);
                if (last) |l| if (find(l.results, "nanoui", scene)) |lr| {
                    const d = pct(v, metric.get(lr));
                    var b: [16]u8 = undefined;
                    std.debug.print("{s}{s:>8}{s} ", .{ deltaColor(d), signed(&b, d), reset });
                } else std.debug.print("{s:>8} ", .{""});
                var best: ?f64 = null;
                for (history) |e| if (find(e.results, "nanoui", scene)) |hr| {
                    const hv = metric.get(hr);
                    // Runs from before a metric existed recorded 0.
                    if (hv > 0) best = if (best) |b| @min(b, hv) else hv;
                };
                if (best) |b| {
                    const d = pct(v, b);
                    var buf: [16]u8 = undefined;
                    std.debug.print("{s}{s:>8}{s}", .{ deltaColor(d), signed(&buf, d), reset });
                }
            }
            std.debug.print("\n", .{});
        }
        std.debug.print("\n", .{});
    }
    if (last) |l| std.debug.print("{s}Δ against the previous run{s}{s}{s}, and the best of {d} runs.{s}\n", .{
        dim, if (l.label.len > 0) " (" else "", l.label, if (l.label.len > 0) ")" else "", history.len, reset,
    });
}

//! Per-frame timing and presentation log (`Surface.frame_log`).
//! Off by default (a single null check); enabled by `NANOUI_FRAMES=<path>`
//! or `Surface.recordFrames(gpa)`.
const std = @import("std");

pub const Kind = enum {
    link,
    input,
    retained,
};

pub const Record = struct {
    t: f64,
    kind: Kind,
    interval_ms: f64,
    duration: f64,
    dt: f32,
    build_ms: f64,
    layout_ms: f64,
    paint_ms: f64,
    after_frame_ms: f64,
    drawable_wait_ms: f64,
    encode_ms: f64,
    sync: bool,
    gpu_ms: f64 = 0,
    nodes: usize,
    instances: usize,
    atlas_reset: bool,
    animating: bool = false,
    queued: u8 = 0,

    pub fn cpuMs(r: Record) f64 {
        return r.build_ms + r.layout_ms + r.paint_ms + r.after_frame_ms + r.encode_ms;
    }
};

pub const Percentiles = struct {
    p50: f64 = 0,
    p90: f64 = 0,
    p99: f64 = 0,
    max: f64 = 0,
    /// Skipping the first frame of a span (cold layout/atlas frame).
    steady_p99: f64 = 0,
    steady_max: f64 = 0,
};

pub const Summary = struct {
    frames: usize = 0,
    retained: usize = 0,
    animating_frames: usize = 0,
    missed_vsyncs: usize = 0,
    missed_share: f64 = 0,
    interval: Percentiles = .{},
    cpu: Percentiles = .{},
    drawable_wait: Percentiles = .{},
    gpu: Percentiles = .{},
    sync_share: f64 = 0,
};

pub const FrameLog = struct {
    gpa: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    path: ?[]u8 = null,
    jsonl: std.ArrayList(u8) = .empty,
    flushed: usize = 0,
    last_t: f64 = 0,
    prev_last_t: f64 = 0,
    buffered_since_flush: usize = 0,
    lock: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: std.mem.Allocator, file_path: ?[]const u8) !FrameLog {
        var self: FrameLog = .{
            .gpa = gpa,
            .path = if (file_path) |p| try gpa.dupe(u8, p) else null,
        };
        errdefer if (self.path) |p| gpa.free(p);
        try self.records.ensureTotalCapacity(gpa, 4096);
        return self;
    }

    pub fn deinit(self: *FrameLog) void {
        self.flush();
        if (self.path) |p| self.gpa.free(p);
        self.jsonl.deinit(self.gpa);
        self.records.deinit(self.gpa);
    }

    fn acquire(self: *FrameLog) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn release(self: *FrameLog) void {
        self.lock.store(false, .release);
    }

    pub fn append(self: *FrameLog, rec: Record) usize {
        self.acquire();
        const idx = self.records.items.len;
        self.prev_last_t = self.last_t;
        self.last_t = rec.t;
        self.records.append(self.gpa, rec) catch {
            self.release();
            return idx;
        };
        self.buffered_since_flush += 1;
        const need_flush = self.path != null and self.buffered_since_flush >= 4096;
        self.release();
        if (need_flush) self.flush();
        return idx;
    }

    pub fn dropLast(self: *FrameLog) void {
        self.acquire();
        defer self.release();
        if (self.records.items.len > self.flushed) {
            _ = self.records.pop();
            if (self.buffered_since_flush > 0) self.buffered_since_flush -= 1;
            self.last_t = self.prev_last_t;
        }
    }

    pub fn setGpuMs(self: *FrameLog, idx: usize, gpu_ms: f64) void {
        self.acquire();
        defer self.release();
        if (idx < self.records.items.len) {
            self.records.items[idx].gpu_ms = gpu_ms;
        }
    }


    pub fn setDraw(self: *FrameLog, idx: usize, drawable_wait_ms: f64, encode_ms: f64, sync: bool, queued: u8) void {
        self.acquire();
        defer self.release();
        if (idx < self.records.items.len) {
            self.records.items[idx].drawable_wait_ms = drawable_wait_ms;
            self.records.items[idx].encode_ms = encode_ms;
            self.records.items[idx].sync = sync;
            self.records.items[idx].queued = queued;
        }
    }
    pub fn mark(self: *FrameLog) usize {
        self.acquire();
        defer self.release();
        return self.records.items.len;
    }

    pub fn span(self: *FrameLog, start: usize, end: usize) []const Record {
        const items = self.records.items;
        const s = @min(start, items.len);
        const e = @min(@max(s, end), items.len);
        return items[s..e];
    }

    pub fn spanFrom(self: *FrameLog, start: usize) []const Record {
        return self.span(start, self.records.items.len);
    }

    pub fn flush(self: *FrameLog) void {
        const p = self.path orelse return;
        self.acquire();
        defer self.release();
        if (self.flushed >= self.records.items.len) return;
        var aw: std.Io.Writer.Allocating = .fromArrayList(self.gpa, &self.jsonl);
        for (self.records.items[self.flushed..]) |r| {
            aw.writer.print(
                "{{\"t\":{d:.6},\"kind\":\"{s}\",\"interval_ms\":{d:.3},\"duration\":{d:.6},\"dt\":{d:.6},\"build_ms\":{d:.3},\"layout_ms\":{d:.3},\"paint_ms\":{d:.3},\"after_frame_ms\":{d:.3},\"drawable_wait_ms\":{d:.3},\"encode_ms\":{d:.3},\"sync\":{},\"gpu_ms\":{d:.3},\"nodes\":{d},\"instances\":{d},\"atlas_reset\":{},\"queued\":{d}}}\n",
                .{
                    r.t,              @tagName(r.kind), r.interval_ms,    r.duration,
                    r.dt,             r.build_ms,       r.layout_ms,      r.paint_ms,
                    r.after_frame_ms, r.drawable_wait_ms, r.encode_ms,    r.sync,
                    r.gpu_ms,         r.nodes,          r.instances,      r.atlas_reset,
                    r.queued,
                },
            ) catch break;
        }
        self.jsonl = aw.toArrayList();
        self.flushed = self.records.items.len;
        self.buffered_since_flush = 0;
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = self.jsonl.items }) catch {};
    }

    pub fn summary(records: []const Record) Summary {
        if (records.len == 0) return .{};
        var out: Summary = .{};
        var sync_count: usize = 0;
        var interval_buf: [8192]f64 = undefined;
        var cpu_buf: [8192]f64 = undefined;
        var wait_buf: [8192]f64 = undefined;
        var gpu_buf: [8192]f64 = undefined;
        const cap = @min(records.len, interval_buf.len);
        var interval_n: usize = 0;

        for (records) |r| {
            if (r.kind == .retained) out.retained += 1 else out.frames += 1;
        }
        for (records[0..cap], 0..) |r, i| {
            if (r.sync) sync_count += 1;
            const dur_ms = if (r.duration > 0) r.duration * 1000.0 else 1000.0 / 60.0;
            // Count intervals and missed vsyncs on frames paced while animating.
            if (r.animating) {
                out.animating_frames += 1;
                if (i > 0 and records[i - 1].animating and r.interval_ms > 0) {
                    interval_buf[interval_n] = r.interval_ms;
                    interval_n += 1;
                    if (r.interval_ms > 1.5 * dur_ms) out.missed_vsyncs += 1;
                }
            }
            cpu_buf[i] = r.cpuMs();
            wait_buf[i] = r.drawable_wait_ms;
            gpu_buf[i] = r.gpu_ms;
        }
        if (interval_n == 0 and cap > 1) {
            for (records[1..cap]) |r| {
                if (r.interval_ms > 0) {
                    interval_buf[interval_n] = r.interval_ms;
                    interval_n += 1;
                }
            }
        }
        out.missed_share = if (out.animating_frames > 1)
            @as(f64, @floatFromInt(out.missed_vsyncs)) / @as(f64, @floatFromInt(out.animating_frames - 1))
        else
            0;
        out.sync_share = @as(f64, @floatFromInt(sync_count)) / @as(f64, @floatFromInt(records.len));
        out.interval = percentiles(interval_buf[0..interval_n]);
        out.cpu = percentilesWithSteady(cpu_buf[0..cap]);
        out.drawable_wait = percentilesWithSteady(wait_buf[0..cap]);
        out.gpu = percentilesWithSteady(gpu_buf[0..cap]);
        return out;
    }
};

fn percentilesWithSteady(values: []f64) Percentiles {
    if (values.len == 0) return .{};
    var steady_p99: f64 = 0;
    var steady_max: f64 = 0;
    if (values.len > 1) {
        var tmp: [8192]f64 = undefined;
        const n = values.len - 1;
        @memcpy(tmp[0..n], values[1..]);
        std.mem.sort(f64, tmp[0..n], {}, comptime std.sort.asc(f64));
        steady_p99 = pick(tmp[0..n], 0.99);
        steady_max = tmp[n - 1];
    }
    std.mem.sort(f64, values, {}, comptime std.sort.asc(f64));
    return .{
        .p50 = pick(values, 0.50),
        .p90 = pick(values, 0.90),
        .p99 = pick(values, 0.99),
        .max = values[values.len - 1],
        .steady_p99 = if (values.len > 1) steady_p99 else values[0],
        .steady_max = if (values.len > 1) steady_max else values[0],
    };
}

fn percentiles(values: []f64) Percentiles {
    if (values.len == 0) return .{};
    std.mem.sort(f64, values, {}, comptime std.sort.asc(f64));
    const p99 = pick(values, 0.99);
    const mx = values[values.len - 1];
    return .{
        .p50 = pick(values, 0.50),
        .p90 = pick(values, 0.90),
        .p99 = p99,
        .max = mx,
        .steady_p99 = p99,
        .steady_max = mx,
    };
}

fn pick(sorted: []const f64, q: f64) f64 {
    if (sorted.len == 0) return 0;
    if (sorted.len == 1) return sorted[0];
    const idx_f = q * @as(f64, @floatFromInt(sorted.len - 1));
    const lo: usize = @intFromFloat(@floor(idx_f));
    const hi: usize = @min(sorted.len - 1, lo + 1);
    const frac = idx_f - @as(f64, @floatFromInt(lo));
    return sorted[lo] * (1.0 - frac) + sorted[hi] * frac;
}

test "FrameLog summary computes percentiles and missed vsyncs" {
    var log = try FrameLog.init(std.testing.allocator, null);
    defer log.deinit();
    _ = log.append(.{
        .t = 1.0,
        .kind = .input,
        .interval_ms = 0,
        .duration = 1.0 / 120.0,
        .dt = 1.0 / 120.0,
        .build_ms = 1.0,
        .layout_ms = 0.5,
        .paint_ms = 0.5,
        .after_frame_ms = 0.1,
        .drawable_wait_ms = 0.2,
        .encode_ms = 0.3,
        .sync = true,
        .gpu_ms = 0.4,
        .nodes = 10,
        .instances = 8,
        .atlas_reset = false,
        .animating = true,
    });
    const idx = log.append(.{
        .t = 1.020,
        .kind = .link,
        .interval_ms = 20.0,
        .duration = 1.0 / 120.0,
        .dt = 0.020,
        .build_ms = 0.5,
        .layout_ms = 0.2,
        .paint_ms = 0.2,
        .after_frame_ms = 0.05,
        .drawable_wait_ms = 0.1,
        .encode_ms = 0.15,
        .sync = false,
        .gpu_ms = 0,
        .nodes = 10,
        .instances = 8,
        .atlas_reset = false,
        .animating = true,
    });
    log.setGpuMs(idx, 0.35);
    const s = FrameLog.summary(log.spanFrom(0));
    try std.testing.expectEqual(@as(usize, 2), s.frames);
    try std.testing.expectEqual(@as(usize, 1), s.missed_vsyncs);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), s.sync_share, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f64, 1.1), s.cpu.steady_max, 1e-6);
}

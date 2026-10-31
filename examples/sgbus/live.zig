//! Live arrivals from arrivelah (arrivelah2.busrouter.sg, LTA DataMall's
//! Bus Arrival API passed through): a board per stop, fetched when a view
//! wants it and again every 20 seconds while it is still wanted.
const std = @import("std");
const nanoui = @import("nanoui");

pub const Load = enum { sea, sda, lsd, unknown };

pub const Bus = struct {
    /// Milliseconds to arrival when fetched (negative: it has left).
    ms: i64,
    lat: f64,
    lng: f64,
    load: Load,
    monitored: bool,
    /// "DD" (double deck), "BD" (bendy) or "SD".
    kind: [2]u8,
    wab: bool,
};

pub const Svc = struct {
    no_buf: [6]u8 = undefined,
    no_len: u8 = 0,
    dest_buf: [5]u8 = undefined,
    dest_len: u8 = 0,
    buses: [3]?Bus = .{ null, null, null },

    pub fn no(s: *const Svc) []const u8 {
        return s.no_buf[0..s.no_len];
    }
    pub fn dest(s: *const Svc) []const u8 {
        return s.dest_buf[0..s.dest_len];
    }
};

pub const State = enum { loading, ok, failed };

pub const Board = struct {
    live: *Live,
    code_buf: [5]u8,
    svcs: std.ArrayList(Svc) = .empty,
    state: State = .loading,
    /// `Live.now` when the answer was taken in.
    at: f64 = 0,
    /// The wall clock then, seconds since midnight (from the answer's times).
    clock: ?f64 = null,
    fresh: bool = false,
    inflight: bool = false,
    /// `Live.now` when a view last asked for it.
    wanted: f64 = 0,

    pub fn code(b: *const Board) []const u8 {
        return &b.code_buf;
    }

    /// Minutes to bus `i` of `s` as of now (floored; can be negative).
    pub fn minutes(b: *const Board, bus: Bus) i64 {
        const left: f64 = @as(f64, @floatFromInt(bus.ms)) - (b.live.now - b.at) * 1000;
        return @intFromFloat(@floor(left / 60000));
    }

    pub fn find(b: *const Board, no: []const u8) ?*const Svc {
        for (b.svcs.items) |*s| if (std.mem.eql(u8, s.no(), no)) return s;
        return null;
    }
};

pub const Live = struct {
    gpa: std.mem.Allocator,
    boards: std.ArrayList(*Board) = .empty,
    window: ?*nanoui.Window = null,
    /// The frame clock (`c.time`), seconds.
    now: f64 = 0,
    /// Answers since start: a refresh's haptic and the "Updated" line read it.
    answers: u32 = 0,
    /// Today as OneMap wants it (MM-DD-YYYY), from an answer's times.
    date: ?[10]u8 = null,

    pub fn deinit(l: *Live) void {
        for (l.boards.items) |b| {
            b.svcs.deinit(l.gpa);
            l.gpa.destroy(b);
        }
        l.boards.deinit(l.gpa);
    }

    /// Each frame, before the views: stamps answers that came in.
    pub fn frame(l: *Live, time: f64) void {
        l.now = time;
        for (l.boards.items) |b| if (b.fresh) {
            b.fresh = false;
            b.at = time;
        };
    }

    /// The board for `code`, fetched the first time it is asked for.
    pub fn want(l: *Live, code: []const u8) ?*Board {
        if (code.len != 5) return null;
        for (l.boards.items) |b| if (std.mem.eql(u8, b.code(), code)) {
            b.wanted = l.now;
            return b;
        };
        const b = l.gpa.create(Board) catch return null;
        b.* = .{ .live = l, .code_buf = code[0..5].*, .wanted = l.now };
        l.boards.append(l.gpa, b) catch {
            l.gpa.destroy(b);
            return null;
        };
        l.fetch(b);
        return b;
    }

    /// Fetches again every board a view asked for in the last 30 seconds.
    pub fn refresh(l: *Live) void {
        for (l.boards.items) |b| if (l.now - b.wanted < 30) l.fetch(b);
    }

    /// The wall clock, seconds since midnight, from the latest answer.
    pub fn clock(l: *const Live) ?f64 {
        var best: ?*const Board = null;
        for (l.boards.items) |b| if (b.clock != null and (best == null or b.at > best.?.at)) {
            best = b;
        };
        const b = best orelse return null;
        return b.clock.? + (l.now - b.at);
    }

    fn fetch(l: *Live, b: *Board) void {
        if (b.inflight) return;
        b.inflight = true;
        var buf: [96]u8 = undefined;
        const url = std.fmt.bufPrint(&buf, "https://arrivelah2.busrouter.sg/?id={s}", .{b.code()}) catch return;
        nanoui.http.fetch(l.gpa, .{ .url = url, .timeout = 12 }, b, loaded);
    }

    fn loaded(b: *Board, r: nanoui.http.Response) void {
        const l = b.live;
        b.inflight = false;
        b.fresh = true;
        if (r.status == 200 and parse(l.gpa, b, r.body)) {
            b.state = .ok;
            l.answers += 1;
        } else if (b.state != .ok) b.state = .failed;
        if (l.window) |w| w.redraw();
    }
};

fn parse(gpa: std.mem.Allocator, b: *Board, body: []const u8) bool {
    const p = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return false;
    defer p.deinit();
    const list = (p.value.object.get("services") orelse return false).array.items;
    b.svcs.clearRetainingCapacity();
    b.clock = null;
    for (list) |v| {
        var s: Svc = .{};
        const no = str(v, "no");
        s.no_len = @intCast(@min(no.len, s.no_buf.len));
        @memcpy(s.no_buf[0..s.no_len], no[0..s.no_len]);
        inline for (.{ "next", "next2", "next3" }, 0..) |k, i| {
            if (v.object.get(k)) |n| if (n == .object) {
                s.buses[i] = busOf(n);
                if (i == 0) {
                    const d = str(n, "destination_code");
                    s.dest_len = @intCast(@min(d.len, 5));
                    @memcpy(s.dest_buf[0..s.dest_len], d[0..s.dest_len]);
                    if (b.clock == null) b.clock = clockOf(str(n, "time"), s.buses[0].?.ms);
                    const t = str(n, "time");
                    if (t.len >= 10) {
                        var day: [10]u8 = undefined;
                        @memcpy(day[0..2], t[5..7]);
                        day[2] = '-';
                        @memcpy(day[3..5], t[8..10]);
                        day[5] = '-';
                        @memcpy(day[6..10], t[0..4]);
                        b.live.date = day;
                    }
                }
            };
        }
        b.svcs.append(gpa, s) catch return false;
    }
    return true;
}

fn busOf(n: std.json.Value) Bus {
    const load = str(n, "load");
    const kind = str(n, "type");
    return .{
        .ms = @intFromFloat(num(n, "duration_ms")),
        .lat = num(n, "lat"),
        .lng = num(n, "lng"),
        .load = if (std.mem.eql(u8, load, "SEA")) .sea else if (std.mem.eql(u8, load, "SDA")) .sda else if (std.mem.eql(u8, load, "LSD")) .lsd else .unknown,
        .monitored = num(n, "monitored") != 0,
        .kind = if (kind.len == 2) kind[0..2].* else "SD".*,
        .wab = std.mem.eql(u8, str(n, "feature"), "WAB"),
    };
}

/// "2026-10-31T20:00:21+08:00" less `ms`: the time of the answer, in
/// seconds since midnight, Singapore time as the API gives it.
fn clockOf(t: []const u8, ms: i64) ?f64 {
    if (t.len < 19) return null;
    const h = std.fmt.parseInt(u32, t[11..13], 10) catch return null;
    const m = std.fmt.parseInt(u32, t[14..16], 10) catch return null;
    const s = std.fmt.parseInt(u32, t[17..19], 10) catch return null;
    const at: f64 = @floatFromInt(h * 3600 + m * 60 + s);
    return @mod(at - @as(f64, @floatFromInt(ms)) / 1000, 86400);
}

fn str(v: std.json.Value, k: []const u8) []const u8 {
    const x = v.object.get(k) orelse return "";
    return if (x == .string) x.string else "";
}

fn num(v: std.json.Value, k: []const u8) f64 {
    const x = v.object.get(k) orelse return 0;
    return switch (x) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => 0,
    };
}

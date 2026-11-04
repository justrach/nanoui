//! What the user allows, and what agents did. Stopped refuses everything;
//! input (clicks, keys, launching) is refused until the user turns it on;
//! the whole screen (the real pointer and keyboard, pictures of the display)
//! is refused until they turn that on too, so by default agents stay inside
//! one app; nanocua's own windows are never acted on (an agent can't press
//! its own Resume). Every call is logged: what, with what, and how it went.
const std = @import("std");
const tools = @import("tools.zig");

pub const Policy = struct {
    /// The kill switch: nothing runs until the user resumes.
    stopped: bool = false,
    /// Clicks, keys, scrolling, launching apps.
    allow_input: bool = false,
    /// The real pointer and keyboard, and pictures of the whole display.
    allow_whole_screen: bool = false,

    /// Why `tool` may not run now, or null if it may. `whole_screen`: the
    /// call asked for more than one app.
    pub fn denial(p: Policy, tool: tools.Tool, whole_screen: bool) ?[]const u8 {
        if (p.stopped) return "nanocua is stopped: the user pressed Stop. Wait for them to resume it.";
        if (tool.kind() == .act and !p.allow_input)
            return "Input is off in nanocua: you may look (list_apps, get_ui_tree, screenshot) but not act. Ask the user to turn on \"Allow input\".";
        if (whole_screen and !p.allow_whole_screen and tool != .list_apps and tool != .get_ui_tree)
            return "The whole screen is off in nanocua: work inside one app (leave out whole_screen). If that can't work, ask the user to turn on \"Allow whole screen\".";
        return null;
    }
};

pub const Status = enum { running, ok, failed, denied };

pub const Entry = struct {
    seq: u64,
    tool: tools.Tool,
    status: Status = .running,
    /// When it started, by the hub's clock; how long it took.
    at: f64,
    ms: f32 = 0,
    summary_buf: [96]u8 = undefined,
    summary_len: u8 = 0,
    detail_buf: [120]u8 = undefined,
    detail_len: u8 = 0,

    pub fn summary(e: *const Entry) []const u8 {
        return e.summary_buf[0..e.summary_len];
    }

    pub fn detail(e: *const Entry) []const u8 {
        return e.detail_buf[0..e.detail_len];
    }
};

/// The last `capacity` calls, newest last.
pub const Log = struct {
    pub const capacity = 200;
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    /// Where the oldest entry is once the ring is full.
    head: usize = 0,
    next_seq: u64 = 1,
    /// Counts since launch.
    calls: u64 = 0,
    denied: u64 = 0,

    pub fn add(l: *Log, tool: tools.Tool, summary: []const u8, at: f64) u64 {
        const e: Entry = .{ .seq = l.next_seq, .tool = tool, .at = at };
        l.next_seq += 1;
        l.calls += 1;
        const slot = if (l.len < capacity) blk: {
            l.len += 1;
            break :blk l.len - 1;
        } else blk: {
            const s = l.head;
            l.head = (l.head + 1) % capacity;
            break :blk s;
        };
        l.entries[slot] = e;
        const n = clip(&l.entries[slot].summary_buf, summary);
        l.entries[slot].summary_len = @intCast(n);
        return e.seq;
    }

    pub fn finish(l: *Log, seq: u64, status: Status, detail: []const u8, now: f64) void {
        const e = l.find(seq) orelse return;
        e.status = status;
        if (status == .denied) l.denied += 1;
        e.ms = @floatCast(@max(0, (now - e.at) * 1000));
        e.detail_len = @intCast(clip(&e.detail_buf, detail));
    }

    pub fn find(l: *Log, seq: u64) ?*Entry {
        for (l.entries[0..l.len]) |*e| if (e.seq == seq) return e;
        return null;
    }

    /// The `i`th newest entry (0 is the newest).
    pub fn newest(l: *Log, i: usize) ?*const Entry {
        if (i >= l.len) return null;
        const oldest_first = l.len - 1 - i;
        return &l.entries[(l.head + oldest_first) % l.len];
    }

    pub fn clear(l: *Log) void {
        l.len = 0;
        l.head = 0;
    }
};

/// Copies `s` into `buf`, cut at a character's start with "…" when long,
/// on one line.
fn clip(buf: []u8, s: []const u8) usize {
    const ell = "…";
    var n = s.len;
    var cut = false;
    if (n > buf.len) {
        n = buf.len - ell.len;
        while (n > 0 and (s[n] & 0xc0) == 0x80) n -= 1;
        cut = true;
    }
    for (s[0..n], 0..) |ch, i| buf[i] = if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch;
    if (cut) {
        @memcpy(buf[n..][0..ell.len], ell);
        n += ell.len;
    }
    return n;
}

test "stopped refuses everything; input waits for the user" {
    var p: Policy = .{};
    try std.testing.expect(p.denial(.get_ui_tree, false) == null);
    try std.testing.expect(p.denial(.click, false) != null);
    p.allow_input = true;
    try std.testing.expect(p.denial(.click, false) == null);
    p.stopped = true;
    try std.testing.expect(p.denial(.screenshot, false) != null);
    try std.testing.expect(p.denial(.click, false) != null);
}

test "the whole screen waits for the user, one app doesn't" {
    var p: Policy = .{ .allow_input = true };
    try std.testing.expect(p.denial(.screenshot, false) == null);
    try std.testing.expect(p.denial(.click, false) == null);
    try std.testing.expect(p.denial(.screenshot, true) != null);
    try std.testing.expect(p.denial(.click, true) != null);
    try std.testing.expect(p.denial(.press_key, true) != null);
    try std.testing.expect(p.denial(.get_ui_tree, true) == null); // reading an app is one app anyway
    p.allow_whole_screen = true;
    try std.testing.expect(p.denial(.screenshot, true) == null);
    try std.testing.expect(p.denial(.click, true) == null);
    p.allow_input = false;
    try std.testing.expect(p.denial(.click, true) != null); // input stays its own switch
}

test "the log keeps the newest calls, clipped to a line" {
    var l: Log = .{};
    const first = l.add(.click, "a\nb", 1);
    l.finish(first, .ok, "pressed", 1.25);
    try std.testing.expectEqualStrings("a b", l.newest(0).?.summary());
    try std.testing.expectEqual(@as(f32, 250), l.newest(0).?.ms);
    const long: [200]u8 = @splat('x');
    for (0..Log.capacity + 5) |i| _ = l.add(.scroll, &long, @floatFromInt(i));
    try std.testing.expectEqual(@as(usize, Log.capacity), l.len);
    try std.testing.expect(l.find(first) == null);
    const e = l.newest(0).?;
    try std.testing.expectEqual(l.next_seq - 1, e.seq);
    try std.testing.expect(std.mem.endsWith(u8, e.summary(), "…"));
    try std.testing.expect(e.summary().len <= 96);
    try std.testing.expectEqual(l.next_seq - Log.capacity, l.newest(Log.capacity - 1).?.seq);
}

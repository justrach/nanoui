//! The switches from outside the panel, so graff and Harness can show them.
//! Anything on the user's socket may turn something off or read the state.
//! Nothing but a real click in nanocua's own window turns something on: a
//! program only asks, and the question waits in the panel. Agents have shells,
//! so a command that turned input on would let them turn on their own input.
const std = @import("std");

pub const Want = enum {
    input,
    whole_screen,
    @"resume",

    pub fn parse(s: []const u8) ?Want {
        return std.meta.stringToEnum(Want, s);
    }

    pub fn question(w: Want) []const u8 {
        return switch (w) {
            .input => "Turn on input? Agents could click, type, press keys and open apps, one app at a time.",
            .whole_screen => "Turn on the whole screen? Agents could use your pointer and keyboard, and take pictures of everything.",
            .@"resume" => "Resume? Agents' calls run again, as far as the switches below allow.",
        };
    }
};

/// Allow does nothing this long after the question appears, so a click meant
/// for whatever was under the pointer can't answer it.
pub const armed_after: f64 = 0.7;
/// An unanswered question goes away: it can't be answered by accident later.
pub const lifetime: f64 = 60;
/// After a Deny, new questions are refused this long, so nothing can keep
/// raising the window until the user gives in.
pub const quiet_after_deny: f64 = 15;

/// One question, and who is waiting for its answer.
pub const Request = struct {
    want: Want,
    at: f64,
    /// 0: nobody's waiting, the user asked in the panel (connections start at 1).
    conn: u64,
    from_buf: [32]u8 = undefined,
    from_len: u8 = 0,
    id_buf: [64]u8 = undefined,
    id_len: u8 = 0,

    /// Who says it's asking. Programs name themselves: this isn't proof.
    pub fn from(r: *const Request) []const u8 {
        return r.from_buf[0..r.from_len];
    }

    pub fn id(r: *const Request) []const u8 {
        return r.id_buf[0..r.id_len];
    }
};

pub const Gate = struct {
    request: ?Request = null,
    quiet_until: f64 = 0,

    pub const Asked = enum { waiting, busy, quiet };

    pub fn ask(g: *Gate, want: Want, from: []const u8, conn: u64, id: []const u8, now: f64) Asked {
        if (g.request != null) return if (g.expired(now)) .busy else .busy;
        if (now < g.quiet_until) return .quiet;
        if (id.len > 64) return .busy;
        var r: Request = .{ .want = want, .at = now, .conn = conn };
        @memcpy(r.id_buf[0..id.len], id);
        r.id_len = @intCast(id.len);
        // Shown to the user: plain characters only, and never empty.
        for (from[0..@min(from.len, r.from_buf.len)]) |ch| {
            if (ch < 0x20 or ch > 0x7e) continue;
            r.from_buf[r.from_len] = ch;
            r.from_len += 1;
        }
        if (r.from_len == 0) {
            const unknown = "A program";
            @memcpy(r.from_buf[0..unknown.len], unknown);
            r.from_len = unknown.len;
        }
        g.request = r;
        return .waiting;
    }

    pub fn armed(g: *const Gate, now: f64) bool {
        const r = g.request orelse return false;
        return now - r.at >= armed_after;
    }

    pub fn expired(g: *const Gate, now: f64) bool {
        const r = g.request orelse return false;
        return now - r.at >= lifetime;
    }

    /// The question, answered with Allow or gone away.
    pub fn take(g: *Gate) ?Request {
        const r = g.request;
        g.request = null;
        return r;
    }

    pub fn deny(g: *Gate, now: f64) ?Request {
        g.quiet_until = now + quiet_after_deny;
        return g.take();
    }
};

/// What graff and Harness read: the reply to every control call. Its field
/// names are the wire format.
pub const Status = struct {
    installed: bool = true,
    running: bool = true,
    stopped: bool = false,
    input: bool = false,
    wholeScreen: bool = false,
    accessibility: bool = false,
    screenRecording: bool = false,
    agents: usize = 0,
    calls: u64 = 0,
    /// Whether ⌃⌥⌘. was registered.
    stopKey: bool = false,
    /// What's waiting for an answer in the panel.
    pending: ?[]const u8 = null,
    /// How this call went: allowed, denied, expired, busy, quiet, already_on,
    /// opened, already_allowed, not_running, unreachable.
    outcome: ?[]const u8 = null,
};

pub fn statusJson(a: std.mem.Allocator, s: Status) ![]u8 {
    return std.json.Stringify.valueAlloc(a, s, .{});
}

/// nanoui's `--nanoui-*` flags drive a window from the command line, which is
/// for tests. In a release they'd be a way round the panel: `nanocua
/// --nanoui-play=…` clicks its own switches.
pub fn devFlagRefused(mode: std.lang.Optimize, arg: []const u8) bool {
    return mode != .debug and std.mem.startsWith(u8, arg, "--nanoui-");
}

test "a question: asked once, armed after a moment, gone after a while" {
    var g: Gate = .{};
    try std.testing.expect(!g.armed(10));
    try std.testing.expectEqual(Gate.Asked.waiting, g.ask(.input, "graff", 7, "\"a\"", 10));
    try std.testing.expectEqualStrings("graff", g.request.?.from());
    try std.testing.expectEqualStrings("\"a\"", g.request.?.id());
    try std.testing.expectEqual(@as(u64, 7), g.request.?.conn);
    try std.testing.expect(!g.armed(10.5));
    try std.testing.expect(g.armed(10.71));
    try std.testing.expectEqual(Gate.Asked.busy, g.ask(.whole_screen, "other", 8, "1", 10.8));
    try std.testing.expectEqual(Want.input, g.request.?.want);
    try std.testing.expect(!g.expired(69));
    try std.testing.expect(g.expired(70));
    try std.testing.expectEqual(Want.input, g.take().?.want);
    try std.testing.expect(g.take() == null);
}

test "a deny keeps new questions away for a while" {
    var g: Gate = .{};
    _ = g.ask(.input, "x", 1, "1", 0);
    try std.testing.expect(g.deny(1) != null);
    try std.testing.expectEqual(Gate.Asked.quiet, g.ask(.input, "x", 1, "2", 15));
    try std.testing.expectEqual(Gate.Asked.waiting, g.ask(.input, "x", 1, "2", 16));
}

test "who's asking is cut to plain characters" {
    var g: Gate = .{};
    _ = g.ask(.input, "gr\x1baff\xc3\xa9", 1, "1", 0);
    try std.testing.expectEqualStrings("graff", g.request.?.from());
    _ = g.take();
    _ = g.ask(.input, "\x01", 1, "1", 0);
    try std.testing.expectEqualStrings("A program", g.request.?.from());
    _ = g.take();
    const long: [80]u8 = @splat('x');
    _ = g.ask(.input, &long, 1, "1", 0);
    try std.testing.expectEqual(@as(usize, 32), g.request.?.from().len);
}

test "the status is the wire format" {
    const gpa = std.testing.allocator;
    const out = try statusJson(gpa, .{ .input = true, .pending = "resume" });
    defer gpa.free(out);
    const parsed = try std.json.parseFromSlice(Status, gpa, out, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.input and !parsed.value.wholeScreen);
    try std.testing.expectEqualStrings("resume", parsed.value.pending.?);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"wholeScreen\":false") != null);
}

test "dev flags only in debug builds" {
    try std.testing.expect(!devFlagRefused(.debug, "--nanoui-play=click:Stop"));
    try std.testing.expect(devFlagRefused(.fast, "--nanoui-play=click:Stop"));
    try std.testing.expect(devFlagRefused(.safe, "--nanoui-script=x"));
    try std.testing.expect(!devFlagRefused(.fast, "mcp"));
}

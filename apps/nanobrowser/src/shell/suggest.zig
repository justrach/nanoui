//! What the search engine suggests for what's being typed. An address is never
//! sent: it may be private, and suggestions wouldn't help. Answers that come after
//! the text moved on are dropped. An answer may land after the browser has gone,
//! so this lives on the heap and the last one out frees it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const address = @import("address.zig");
const search = @import("search.zig");

const Allocator = std.mem.Allocator;

/// A pause in typing long enough to ask, in seconds.
const pause: f32 = 0.12;
/// Longer than this isn't a search anyone wants finished.
const longest = 200;
const most = 8;

pub const Suggest = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    rows: []const []const u8 = &.{},
    text: std.ArrayList(u8) = .empty,
    engine: search.Engine = .google,
    /// When to ask; 0 when nothing's waiting.
    due: f64 = 0,
    /// Which text an answer has to be for.
    asked: u32 = 0,
    pending: u32 = 0,
    dead: bool = false,
    redraw_ctx: *anyopaque,
    redraw: *const fn (*anyopaque) void,

    pub fn create(gpa: Allocator, ctx: *anyopaque, redraw: *const fn (*anyopaque) void) !*Suggest {
        const s = try gpa.create(Suggest);
        s.* = .{ .gpa = gpa, .arena = .init(gpa), .redraw_ctx = ctx, .redraw = redraw };
        return s;
    }

    pub fn release(s: *Suggest) void {
        s.dead = true;
        if (s.pending == 0) s.free();
    }

    fn free(s: *Suggest) void {
        s.text.deinit(s.gpa);
        s.arena.deinit();
        s.gpa.destroy(s);
    }

    /// Each frame the field shows: asks when typing has paused on something new.
    pub fn watch(s: *Suggest, c: *ui.Context, typed: []const u8, engine: search.Engine) void {
        if (engine != s.engine or !std.mem.eql(u8, typed, s.text.items)) {
            s.engine = engine;
            s.text.clearRetainingCapacity();
            s.text.appendSlice(s.gpa, typed) catch {};
            s.asked +%= 1;
            if (worthAsking(s.gpa, typed)) {
                s.due = c.time + pause;
            } else {
                s.due = 0;
                s.clear();
            }
        }
        if (s.due == 0) return;
        if (c.time < s.due) return c.frameIn(@floatCast(@max(s.due - c.time, 0.001)));
        s.due = 0;
        s.ask();
    }

    fn clear(s: *Suggest) void {
        s.rows = &.{};
        _ = s.arena.reset(.retain_capacity);
    }

    fn ask(s: *Suggest) void {
        const url = search.suggestUrl(s.gpa, s.engine, std.mem.trim(u8, s.text.items, " \t\r\n")) catch return;
        defer s.gpa.free(url);
        const r = s.gpa.create(Request) catch return;
        r.* = .{ .s = s, .asked = s.asked };
        s.pending += 1;
        nanoui.http.fetch(s.gpa, .{ .url = url, .timeout = 5 }, r, answered);
    }

    /// The answer for the text as it is now.
    pub fn take(s: *Suggest, body: []const u8) void {
        s.clear();
        s.rows = search.parseSuggestions(s.arena.allocator(), body, most);
    }
};

const Request = struct { s: *Suggest, asked: u32 };

fn answered(r: *Request, res: nanoui.http.Response) void {
    const s = r.s;
    const asked = r.asked;
    s.gpa.destroy(r);
    s.pending -= 1;
    if (s.dead) {
        if (s.pending == 0) s.free();
        return;
    }
    // A refusal (Google's wall answers 429) is no suggestions, not an error to show.
    if (asked != s.asked or res.status != 200) return;
    s.take(res.body);
    s.redraw(s.redraw_ctx);
}

fn worthAsking(gpa: Allocator, typed: []const u8) bool {
    const t = std.mem.trim(u8, typed, " \t\r\n");
    if (t.len == 0 or t.len > longest) return false;
    const url = address.parse(gpa, t) catch return false;
    if (url) |u| {
        gpa.free(u);
        return false;
    }
    return true;
}

test "only what isn't an address is worth asking about" {
    const gpa = std.testing.allocator;
    try std.testing.expect(worthAsking(gpa, "birds"));
    try std.testing.expect(worthAsking(gpa, "how do birds fly"));
    try std.testing.expect(!worthAsking(gpa, "  "));
    try std.testing.expect(!worthAsking(gpa, "example.com/private/page"));
    try std.testing.expect(!worthAsking(gpa, "https://example.com/a?token=b"));
    try std.testing.expect(!worthAsking(gpa, "localhost:3000"));
}

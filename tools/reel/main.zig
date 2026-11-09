//! A 30-second reel of `ui.motion` and `nanoui.kit` at work in six mock
//! apps drawn by nanoui (scenes.zig): it runs in a Tester, offscreen, 30 frames a second, and each
//! frame's pixels go to standard output for ffmpeg. A script moves the
//! pointer and clicks as a person would, through the Tester alone: no
//! window shows and nothing reaches the screen or the mouse.
//!
//!     zig build reel && zig-out/bin/nanoui-reel | ffmpeg -f rawvideo \
//!       -pix_fmt bgra -s 1920x1080 -r 30 -i - -pix_fmt yuv420p out.mp4
//!     zig-out/bin/nanoui-reel --still=4.5:/tmp/frame.png   # one frame
//!     zig-out/bin/nanoui-reel --cues    # when clicks and cuts come
//!     zig-out/bin/nanoui-reel --dark
//!
//! tools/reel.sh adds the sounds and a soundtrack.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const kit = nanoui.kit;
const scenes = @import("scenes.zig");
const Director = scenes.Director;
const at = scenes.at;

const fps = 30;
const scale = 1.5;

const Target = union(enum) {
    point: [2]f32,
    text: []const u8,
    /// Settings' other theme: Dark in the light reel, Light in the dark.
    other_theme,
};

const Act = enum { none, click, lift_ship, lift_docs, play, next, save, morph };

const Move = struct { at: f32, dur: f32, to: Target, act: Act = .none };

const moves = [_]Move{
    // nanotrade: ranges switched, the candles morph.
    .{ .at = at.trade + 1.5, .dur = 0.6, .to = .{ .text = "1M" }, .act = .click },
    .{ .at = at.trade + 2.9, .dur = 0.4, .to = .{ .text = "1Y" }, .act = .click },
    // Chat: Send.
    .{ .at = at.chat + 2.0, .dur = 0.5, .to = .{ .point = .{ 987, 611 } }, .act = .click },
    // Board: a card lifted and carried to Done, another to In progress.
    .{ .at = at.board + 0.4, .dur = 0.6, .to = .{ .text = "Ship ui.motion" }, .act = .lift_ship },
    .{ .at = at.board + 1.3, .dur = 0.6, .to = .{ .point = .{ 999, 203 } } },
    .{ .at = at.board + 2.1, .dur = 0.5, .to = .{ .text = "Write the kit docs" }, .act = .lift_docs },
    .{ .at = at.board + 2.8, .dur = 0.5, .to = .{ .point = .{ 640, 297 } } },
    // Music: play, then the next track.
    .{ .at = at.music + 0.4, .dur = 0.6, .to = .{ .point = .{ 398, 542 } }, .act = .play },
    .{ .at = at.music + 2.2, .dur = 0.4, .to = .{ .point = .{ 473, 542 } }, .act = .next },
    // Glass: interactive glass pressed; a button morphs into a panel.
    .{ .at = at.glass + 0.3, .dur = 0.5, .to = .{ .text = "Share" }, .act = .click },
    .{ .at = at.glass + 1.0, .dur = 0.3, .to = .{ .text = "Save" }, .act = .click },
    .{ .at = at.glass + 1.5, .dur = 0.4, .to = .{ .point = .{ 1034, 569 } }, .act = .morph },
    .{ .at = at.glass + 2.4, .dur = 0.4, .to = .{ .text = "Albums" }, .act = .click },
    .{ .at = at.glass + 3.1, .dur = 0.35, .to = .{ .point = .{ 1042, 405 } }, .act = .morph },
    // Weather: other days, the lens sliding.
    .{ .at = at.weather + 0.9, .dur = 0.6, .to = .{ .text = "Tomorrow" }, .act = .click },
    .{ .at = at.weather + 2.3, .dur = 0.4, .to = .{ .text = "Weekend" }, .act = .click },
    // Settings: a theme, a toggle, Advanced, Save.
    .{ .at = at.settings + 0.3, .dur = 0.5, .to = .other_theme, .act = .click },
    .{ .at = at.settings + 1.0, .dur = 0.4, .to = .{ .text = "Play sounds" }, .act = .click },
    .{ .at = at.settings + 1.6, .dur = 0.4, .to = .{ .text = "Advanced" }, .act = .click },
    .{ .at = at.settings + 2.1, .dur = 0.4, .to = .{ .text = "Save changes" }, .act = .save },
};

/// When the pointer shows.
const shown = [_][2]f32{
    .{ at.trade + 1.2, at.trade + 3.8 },       .{ at.chat + 1.7, at.chat + 3.0 },
    .{ at.board + 0.2, at.board + 3.7 },       .{ at.music + 0.1, at.music + 3.0 },
    .{ at.glass + 0.1, at.glass + 3.8 },       .{ at.weather + 0.6, at.weather + 3.2 },
    .{ at.settings + 0.1, at.settings + 2.9 },
};

/// What happens without a click, and when.
fn events(d: *Director, now: f32, prev: f32) void {
    const crossed = struct {
        fn f(p: f32, n: f32, t: f32) bool {
            return p < t and n >= t;
        }
    }.f;
    // nanotrade's ticks, while it shows.
    var t: f32 = at.trade + 0.3;
    while (t < at.chat) : (t += 0.3) if (crossed(prev, now, t)) {
        const before = d.market.price;
        d.market.tick(0.05);
        d.last_up = d.market.price >= before;
        d.tick_at = now;
    };
    // Chat: Leo types, a message arrives; later another.
    if (crossed(prev, now, at.chat + 0.4)) d.chat.typing = true;
    if (crossed(prev, now, at.chat + 1.2)) {
        d.chat.typing = false;
        d.chat.shown = 4;
    }
    if (crossed(prev, now, at.chat + 1.6)) d.chat.draft = "Looks great. Ship it.";
    // Sent as Send is let go, so its press shows before it dims again.
    if (crossed(prev, now, at.chat + 2.65)) {
        d.chat.shown = 5;
        d.chat.draft = "";
    }
    if (crossed(prev, now, at.chat + 2.9)) d.chat.typing = true;
    if (crossed(prev, now, at.chat + 3.7)) {
        d.chat.typing = false;
        d.chat.shown = 6;
    }
    // Board: cards carried and dropped.
    if (crossed(prev, now, at.board + 1.3)) d.board.move(0, 2, 0);
    if (crossed(prev, now, at.board + 1.95)) d.board.lifted = null;
    if (crossed(prev, now, at.board + 2.8)) d.board.move(1, 1, 1);
    if (crossed(prev, now, at.board + 3.35)) d.board.lifted = null;
    // Music: the track moves on while it plays.
    if (d.music.playing) d.music.pos += 1.0 / @as(f32, fps);
}

/// The times sounds go with: clicks, chimes for messages and the toast,
/// air at each change of app and at the end.
fn cues(io: std.Io) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const o = &w.interface;
    for (moves) |m| if (m.act != .none) try o.print("click {d:.3}\n", .{m.at + m.dur});
    for ([_]f32{ at.chat + 1.2, at.chat + 3.7, at.settings + 2.5 }) |x| try o.print("chime {d:.3}\n", .{x});
    for ([_]f32{ at.trade, at.chat, at.board, at.music, at.glass, at.weather, at.settings, at.end }) |x| try o.print("cut {d:.3}\n", .{x});
    try o.flush();
}

const Script = struct {
    next: usize = 0,
    started: ?usize = null,
    start: [2]f32 = .{ 0, 0 },
    to: [2]f32 = .{ 0, 0 },
    held: u32 = 0,
    prev: f32 = -1,

    fn step(s: *Script, t: *ui.Tester, d: *Director, now: f32) void {
        d.now = now;
        if (s.held > 0) {
            s.held -= 1;
            if (s.held == 0) t.ctx.pointerUp();
        }
        events(d, now, s.prev);
        s.prev = now;
        d.cursor_alpha = 0;
        for (shown) |w| {
            const v = @min(clamp01((now - w[0]) / 0.25), clamp01((w[1] - now) / 0.25));
            d.cursor_alpha = @max(d.cursor_alpha, v);
        }
        while (s.next < moves.len) {
            const m = moves[s.next];
            if (now < m.at) break;
            if (s.started != s.next) {
                s.started = s.next;
                s.start = d.cursor;
                s.to = resolve(t, d, m.to) orelse d.cursor;
            }
            const p = clamp01((now - m.at) / m.dur);
            const e = p * p * (3 - 2 * p);
            d.cursor = .{ s.start[0] + (s.to[0] - s.start[0]) * e, s.start[1] + (s.to[1] - s.start[1]) * e };
            if (p < 1) break;
            if (m.act != .none) {
                t.ctx.input.mouse = .{ .x = d.cursor[0], .y = d.cursor[1] };
                t.ctx.updateHot();
                t.ctx.input.click_count = 1;
                t.ctx.pointerDown();
                s.held = 4;
                switch (m.act) {
                    .lift_ship => d.board.lifted = 0,
                    .lift_docs => d.board.lifted = 1,
                    .play => d.music.playing = true,
                    .next => {
                        d.music.track = 1;
                        d.music.pos = 2;
                    },
                    .morph => d.glass.open = !d.glass.open,
                    .save => d.toaster.push(.{ .status = .success, .title = "Settings saved", .message = "Synced to your 3 devices.", .duration = 0.6 }),
                    else => {},
                }
            }
            s.next += 1;
        }
        t.ctx.input.mouse = if (d.cursor_alpha > 0) .{ .x = d.cursor[0], .y = d.cursor[1] } else .{ .x = -100, .y = -100 };
        t.ctx.updateHot();
    }
};

fn clamp01(v: f32) f32 {
    return std.math.clamp(v, 0, 1);
}

fn resolve(t: *ui.Tester, d: *Director, to: Target) ?[2]f32 {
    switch (to) {
        .other_theme => return resolve(t, d, .{ .text = if (d.dark) "Light" else "Dark" }),
        .point => |p| return p,
        .text => |s| {
            const r = t.findText(s) orelse {
                std.debug.print("reel: no \"{s}\" on screen\n", .{s});
                return null;
            };
            return .{ r.x + r.w / 2, r.y + r.h / 2 };
        },
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var stills: std.ArrayList(struct { frame: usize, path: []const u8 }) = .empty;
    defer stills.deinit(gpa);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var dark = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--cues")) return cues(io);
        if (std.mem.eql(u8, arg, "--dark")) {
            dark = true;
            continue;
        }
        const prefix = "--still=";
        if (!std.mem.startsWith(u8, arg, prefix)) return error.UnknownArgument;
        const v = arg[prefix.len..];
        const colon = std.mem.indexOfScalar(u8, v, ':') orelse return error.BadStill;
        const secs = try std.fmt.parseFloat(f32, v[0..colon]);
        try stills.append(gpa, .{ .frame = @intFromFloat(@round(secs * fps)), .path = v[colon + 1 ..] });
    }
    var d: Director = .{ .dark = dark, .market = .init(), .toaster = .{ .gpa = gpa, .width = 340, .corner = .top_right } };
    defer d.toaster.deinit();
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&d, Director.draw), .{ .width = scenes.width, .height = scenes.height, .scale = scale, .theme = @import("theme.zig").ui_(dark) });
    defer t.deinit();
    t.dt = 1.0 / @as(f32, fps);
    t.time = 0;
    var last: usize = @intFromFloat(at.done * fps);
    if (stills.items.len > 0) {
        last = 0;
        for (stills.items) |s| last = @max(last, s.frame + 1);
    }
    var script: Script = .{};
    const out = std.Io.File.stdout();
    for (0..last) |i| {
        script.step(&t, &d, @as(f32, @floatFromInt(i)) / fps);
        t.frame();
        if (stills.items.len > 0) {
            for (stills.items) |s| if (s.frame == i) try t.screenshot(s.path);
            continue;
        }
        const pixels = try t.render(gpa);
        defer pixels.deinit(gpa);
        try out.writeStreamingAll(io, pixels.bytes);
    }
}

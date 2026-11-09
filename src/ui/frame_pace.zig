//! A display-paced frame clock's decisions, without the clock itself: when
//! an input builds its frame at once and when it is gathered for the next
//! refresh, when a beat builds a frame, when the clock may stop, and the
//! refresh period read off the beats. Windows' surface paces with it
//! (`windows/surface_pace.zig`), a thread waiting for each vertical blank
//! (`windows/vblank.zig`) — what the display link is on macOS.
//!
//! A pointer moves several times a refresh on a fast mouse, and building a
//! frame for each is work no one sees. So the first move after a quiet spell
//! is built at once (nothing waits for a beat that may be 16 ms away) and
//! starts the clock; the moves after it, while the clock runs, only mark the
//! next beat as having something to build, and that beat builds one frame
//! for all of them. Presses, releases and keys are never gathered: each is
//! built as it comes.
const std = @import("std");

/// How long the clock runs after the last input: moves come unevenly, and
/// a clock started cold builds the next one at once again.
pub const linger: f64 = 0.15;

pub const Pace = struct {
    running: bool = false,
    /// An input arrived since the last beat built a frame.
    pending: bool = false,
    /// The clock runs at least until then (`linger` past the last input).
    until: f64 = 0,
    /// The refresh period, as the beats keep it (seconds): 60 Hz until
    /// measured.
    period: f64 = 1.0 / 60.0,
    last_beat: f64 = 0,

    pub const Input = enum { now, next_beat };

    /// A move or a wheel at `now`: `.now` to build it at once (the clock is
    /// idle; start it), `.next_beat` to leave it to the beat.
    pub fn input(p: *Pace, now: f64) Input {
        p.until = now + linger;
        if (p.running) {
            p.pending = true;
            return .next_beat;
        }
        return .now;
    }

    /// A beat at `now`: whether it builds a frame, for an animation or for
    /// what was gathered since the last.
    pub fn beat(p: *Pace, now: f64, animating: bool) bool {
        if (p.last_beat > 0) p.observe(now - p.last_beat);
        p.last_beat = now;
        const build = animating or p.pending;
        p.pending = false;
        return build;
    }

    /// Whether the clock keeps running after a beat at `now`.
    pub fn keep(p: *const Pace, now: f64, animating: bool) bool {
        return animating or p.pending or now < p.until;
    }

    pub fn start(p: *Pace) void {
        p.running = true;
        p.last_beat = 0;
    }

    pub fn stop(p: *Pace) void {
        p.running = false;
        p.pending = false;
    }

    /// One interval between beats into the period. A long one is the clock
    /// having stood still (or a beat missed) and says nothing of the
    /// display; a short one is a beat that came early.
    fn observe(p: *Pace, dt: f64) void {
        if (dt < 1.0 / 500.0 or dt > 1.0 / 20.0) return;
        p.period = p.period * 0.9 + dt * 0.1;
    }

    /// The refresh rate the beats keep, in frames a second.
    pub fn hz(p: Pace) f64 {
        return 1 / p.period;
    }
};

test "the first move is built at once, the next ones on the beat, one frame for all" {
    var p: Pace = .{};
    try std.testing.expectEqual(Pace.Input.now, p.input(10.0));
    p.start();
    try std.testing.expectEqual(Pace.Input.next_beat, p.input(10.002));
    try std.testing.expectEqual(Pace.Input.next_beat, p.input(10.005));
    try std.testing.expect(p.beat(10.008, false));
    // Nothing since: the next beat builds nothing, and the clock lingers.
    try std.testing.expect(!p.beat(10.016, false));
    try std.testing.expect(p.keep(10.016, false));
    try std.testing.expect(!p.keep(10.005 + linger + 0.001, false));
    // An animation keeps it, and builds every beat.
    try std.testing.expect(p.beat(10.3, true));
    try std.testing.expect(p.keep(10.3, true));
    p.stop();
    try std.testing.expectEqual(Pace.Input.now, p.input(11.0));
}

test "the period follows the beats, and a pause says nothing of it" {
    var p: Pace = .{};
    p.start();
    var t: f64 = 1;
    for (0..200) |_| {
        _ = p.beat(t, true);
        t += 1.0 / 144.0;
    }
    try std.testing.expectApproxEqAbs(@as(f64, 144), p.hz(), 1);
    _ = p.beat(t + 2, true);
    try std.testing.expectApproxEqAbs(@as(f64, 144), p.hz(), 1);
}

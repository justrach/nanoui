//! The display's beat on Windows: a thread that waits for each vertical
//! blank of the monitor a window is on (`IDXGIOutput::WaitForVBlank` on
//! its swap chain's output, else `DwmFlush`, the compositor's next pass)
//! and posts `WM_VBLANK` to the window, one at a time — never a second
//! while the first is unhandled, so a slow frame skips beats rather than
//! queueing them. What the display link is on macOS, and what replaces a
//! 16 ms `SetTimer` (whose beats land anywhere in the refresh, and on a
//! 120 Hz or 240 Hz display at a quarter of its rate).
//!
//! It runs only while the surface asks (`run`): animating, or just after
//! input. Stopped, it waits on an event and uses nothing. Where there is no
//! blank to wait for (a hidden desktop, Wine), a wait that returns at once
//! is made up with a sleep, so the clock never spins.
const std = @import("std");
const w = @import("win32.zig");
const api = @import("../ui/d3d11_glue.zig");
const clock = @import("../ui/clock.zig");
const Com = api.Com;

pub const WM_VBLANK: u32 = w.WM_APP + 3;

extern "dwmapi" fn DwmFlush() callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(attrs: ?*anyopaque, manual: w.BOOL, initial: w.BOOL, name: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn SetEvent(event: *anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn ResetEvent(event: *anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn WaitForSingleObject(handle: *anyopaque, ms: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: *anyopaque) callconv(.winapi) w.BOOL;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;

const infinite: u32 = 0xffffffff;

pub const Clock = struct {
    gpa: std.mem.Allocator,
    hwnd: w.HWND,
    /// Set while the clock runs (manual reset): the thread waits on it.
    event: *anyopaque,
    thread: ?std.Thread = null,
    quit: std.atomic.Value(bool) = .init(false),
    /// A `WM_VBLANK` is in the window's queue: no other is posted until the
    /// window has handled it (`consumed`).
    posted: std.atomic.Value(bool) = .init(false),
    /// Guards `output`, which the main thread swaps and the thread waits on.
    lock: std.atomic.Value(bool) = .init(false),
    output: ?*Com = null,
    /// The beats posted, for the tests and `NANOUI_TRACE`.
    beats: std.atomic.Value(u64) = .init(0),

    /// A clock for `hwnd`, stopped. Null if its thread can't be had (the
    /// surface keeps its timer then).
    pub fn create(gpa: std.mem.Allocator, hwnd: w.HWND) ?*Clock {
        const event = CreateEventW(null, 1, 0, null) orelse return null;
        const c = gpa.create(Clock) catch {
            _ = CloseHandle(event);
            return null;
        };
        c.* = .{ .gpa = gpa, .hwnd = hwnd, .event = event };
        c.thread = std.Thread.spawn(.{}, loop, .{c}) catch {
            _ = CloseHandle(event);
            gpa.destroy(c);
            return null;
        };
        return c;
    }

    pub fn destroy(c: *Clock) void {
        c.quit.store(true, .release);
        _ = SetEvent(c.event);
        if (c.thread) |t| t.join();
        c.setOutput(null);
        _ = CloseHandle(c.event);
        c.gpa.destroy(c);
    }

    /// Runs the clock, or stops it at its next beat.
    pub fn run(c: *Clock, on: bool) void {
        _ = if (on) SetEvent(c.event) else ResetEvent(c.event);
    }

    /// The window handled its `WM_VBLANK`: the next beat may post another.
    pub fn consumed(c: *Clock) void {
        c.posted.store(false, .release);
    }

    /// The output (an IDXGIOutput) the beats are that monitor's; the clock
    /// takes the reference. Null for the compositor's beat.
    pub fn setOutput(c: *Clock, out: ?*Com) void {
        c.acquire();
        const old = c.output;
        c.output = out;
        c.release();
        if (old) |o| o.release();
    }

    fn acquire(c: *Clock) void {
        while (c.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(c: *Clock) void {
        c.lock.store(false, .release);
    }

    /// The output to wait on, with a reference of the caller's.
    fn takeOutput(c: *Clock) ?*Com {
        c.acquire();
        defer c.release();
        const o = c.output orelse return null;
        _ = o.slot(*const fn (*Com) callconv(.winapi) u32, 1)(o);
        return o;
    }

    fn loop(c: *Clock) void {
        while (true) {
            _ = WaitForSingleObject(c.event, infinite);
            if (c.quit.load(.acquire)) return;
            const t0 = clock.now();
            var waited = false;
            if (c.takeOutput()) |o| {
                waited = o.slot(*const fn (*Com) callconv(.winapi) i32, 10)(o) >= 0; // WaitForVBlank
                o.release();
            }
            if (!waited) waited = DwmFlush() >= 0;
            const took = clock.now() - t0;
            if (took < 0.002) Sleep(@intFromFloat(@max(1, (1.0 / 60.0 - took) * 1000)));
            if (c.quit.load(.acquire)) return;
            _ = c.beats.fetchAdd(1, .monotonic);
            if (!c.posted.swap(true, .acq_rel)) _ = w.PostMessageW(c.hwnd, WM_VBLANK, 0, 0);
        }
    }
};

/// The output (monitor) a swap chain is mostly on, with a reference of the
/// caller's: `IDXGISwapChain::GetContainingOutput`.
pub fn outputOf(swap: *Com) ?*Com {
    var out: ?*Com = null;
    if (swap.slot(*const fn (*Com, *?*Com) callconv(.winapi) i32, 15)(swap, &out) < 0) return null;
    return out;
}

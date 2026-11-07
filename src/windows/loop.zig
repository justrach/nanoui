//! Running the message loop for a while, between headless frames: messages
//! (input, timers, fdwatch's posts) are handled as they come, and the wait
//! between them sleeps in MsgWaitForMultipleObjects.
const std = @import("std");
const w = @import("win32.zig");
const clock = @import("../ui/clock.zig");

extern "user32" fn MsgWaitForMultipleObjects(n: u32, handles: ?[*]const *anyopaque, all: w.BOOL, ms: u32, wake: u32) callconv(.winapi) u32;
const QS_ALLINPUT = 0x04FF;

pub fn runFor(seconds: f64) void {
    const end = clock.now() + seconds;
    var msg: w.MSG = undefined;
    while (true) {
        while (w.PeekMessageW(&msg, null, 0, 0, 1) != 0) {
            // A quit asked for during this run is not ours to eat: put it
            // back, for `App.run` — the loop that must see it — and stop.
            if (msg.message == w.WM_QUIT) {
                w.PostQuitMessage(@intCast(msg.wParam));
                return;
            }
            _ = w.TranslateMessage(&msg);
            _ = w.DispatchMessageW(&msg);
        }
        const left = end - clock.now();
        if (left <= 0) return;
        _ = MsgWaitForMultipleObjects(0, null, 0, @intFromFloat(@ceil(left * 1000)), QS_ALLINPUT);
    }
}

test "a quit asked for during a runFor is put back for App.run" {
    var msg: w.MSG = undefined;
    w.PostQuitMessage(7);
    runFor(0.1);
    try std.testing.expectEqual(@as(i32, 0), w.GetMessageW(&msg, null, 0, 0));
    try std.testing.expectEqual(@as(usize, 7), msg.wParam);
}

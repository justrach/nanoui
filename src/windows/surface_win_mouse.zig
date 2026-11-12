//! A Windows surface's mouse buttons: the left and middle buttons' presses
//! and releases, and the capture going elsewhere mid-press. One press is
//! in flight at a time, as on the Mac (`ui/pointer_press.zig`): another
//! button's press while it is held is ignored, and so is its release.
const w = @import("win32.zig");
const input = @import("../ui/input.zig");
const pointer_press = @import("../ui/pointer_press.zig");
const Surface = @import("surface.zig").Surface;

/// The buttons a mouse message says were held (its wParam's MK_ flags).
pub fn held(wp: w.WPARAM) pointer_press.Held {
    return .{ .left = wp & w.MK_LBUTTON != 0, .right = wp & w.MK_RBUTTON != 0, .middle = wp & w.MK_MBUTTON != 0 };
}

/// WM_LBUTTONDOWN/UP/DBLCLK, WM_MBUTTONDOWN/UP/DBLCLK and
/// WM_CAPTURECHANGED; null for any other message.
pub fn message(self: *Surface, h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
    switch (msg) {
        w.WM_LBUTTONDOWN, w.WM_LBUTTONDBLCLK => press(self, h, .left, msg == w.WM_LBUTTONDBLCLK, wp, lp),
        w.WM_MBUTTONDOWN, w.WM_MBUTTONDBLCLK => press(self, h, .middle, msg == w.WM_MBUTTONDBLCLK, wp, lp),
        w.WM_LBUTTONUP => release(self, .left, lp),
        w.WM_MBUTTONUP => release(self, .middle, lp),
        w.WM_CAPTURECHANGED => {
            // Another window took the capture (Alt+Tab, a modal loop, focus
            // lost mid-drag): the press in flight will see no release, so
            // it ends here, with no click. Taking the capture ourselves
            // again (a press while one is stale) is not that.
            if (@as(usize, @bitCast(lp)) == @intFromPtr(h)) return 0;
            if (pointer_press.cancel(&self.ctx.input)) self.frame();
        },
        else => return null,
    }
    return 0;
}

/// A press of `button`: the box under the pointer takes it, and the
/// window the capture, so the moves and the release come here wherever
/// the pointer goes. The left button's may instead start the system's
/// move loop over a borderless window's drag handle; the middle one has
/// no such affordance.
fn press(self: *Surface, h: w.HWND, button: input.Button, double: bool, wp: w.WPARAM, lp: w.LPARAM) void {
    if (!pointer_press.starts(&self.ctx.input, button, held(wp))) return;
    self.setMouse(lp);
    if (self.ctx.input.alt) self.alt_used = true;
    self.ctx.input.click_count = if (double) 2 else 1;
    // Set on every press, so a left press after a middle drag is the left's.
    self.ctx.input.button = button;
    self.ctx.updateHot();
    // A borderless window's drag handle (`window_drag`): the press
    // belongs to the system's move loop, the way macOS hands the
    // event to `performWindowDragWithEvent`. A double click zooms.
    if (button == .left and self.ctx.startsWindowDrag()) {
        if (double) {
            self.window.zoom();
        } else {
            _ = w.ReleaseCapture();
            _ = w.SendMessageW(h, w.WM_NCLBUTTONDOWN, w.HTCAPTION, 0);
        }
        return;
    }
    _ = w.SetCapture(h);
    self.ctx.pointerDown();
    self.frame();
}

/// A release of `button`: it ends the press in flight only when that is
/// its own. The press ends before the capture goes, so the
/// WM_CAPTURECHANGED that `ReleaseCapture` sends finds none to cancel.
fn release(self: *Surface, button: input.Button, lp: w.LPARAM) void {
    if (!pointer_press.ends(&self.ctx.input, button)) return;
    self.setMouse(lp);
    self.ctx.updateHot();
    self.ctx.pointerUp();
    _ = w.ReleaseCapture();
    self.frame();
}

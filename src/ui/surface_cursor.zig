//! The AppKit cursor for each of nanoui's cursors.
const Cursor = @import("context.zig").Cursor;

/// The `NSCursor` class method that returns `c`.
pub fn name(c: Cursor) [:0]const u8 {
    return switch (c) {
        // `.custom` without its image (`Surface.applyCursor`).
        .arrow, .custom => "arrowCursor",
        .hand => "pointingHandCursor",
        .text => "IBeamCursor",
        .resize_left_right => "resizeLeftRightCursor",
        .resize_up_down => "resizeUpDownCursor",
        .open_hand => "openHandCursor",
        .closed_hand => "closedHandCursor",
        .not_allowed => "operationNotAllowedCursor",
        .crosshair => "crosshairCursor",
    };
}

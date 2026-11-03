//! Rolling digits, as a departure board or an odometer turns: each digit
//! is a strip of 0 to 9 behind a one-line window, and a changed digit rolls
//! its strip to the new one. Places are kept from the right, so 12 going to
//! 9 rolls the ones and lets the tens go. Other characters are drawn still.
//!
//!     ui.motion.roll(c, "eta", c.print("{d}", .{minutes}), .{ .size = 34, .weight = .bold }, .{});
//!
//! Reduced motion turns it straight to the new digit.
const std = @import("std");
const Context = @import("../context.zig").Context;
const types = @import("../types.zig");
const motion = @import("motion.zig");
const widgets = @import("../widgets.zig");
const div_mod = @import("../div.zig");

pub const Options = struct {
    transition: motion.Transition = .{ .spring = .snappy },
};

const strip = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

/// The window's height for `style`: its line height, else 1.25 of its size.
pub fn lineOf(style: types.TextStyle) f32 {
    return if (style.line_height > 0) style.line_height else style.size * 1.25 * style.leading;
}

/// Draws `str` with its digits rolling, keyed `key` under the box now open.
pub fn roll(c: *Context, key: []const u8, str: []const u8, style: types.TextStyle, opts: Options) void {
    var st = style;
    st.tabular = true;
    const lh = lineOf(st);
    const row = div_mod.div(c).row().itemsCenter();
    defer row.end();
    var i: usize = 0;
    while (i < str.len) {
        if (!isDigit(str[i])) {
            // A run of anything else, drawn as it is.
            const start = i;
            while (i < str.len and !isDigit(str[i])) i += 1;
            widgets.text(c, str[start..i], st);
            continue;
        }
        const ch = str[i];
        i += 1;
        const place = digitsAfter(str[i..]);
        c.next_key = c.print("{s}.{d}", .{ key, place });
        const cell = div_mod.div(c).h(lh).clip();
        defer cell.end();
        const v = motion.number(c, "roll", @floatFromInt(ch - '0'), opts.transition);
        const col = div_mod.div(c).column().offset(0, -v * lh);
        defer col.end();
        for (strip) |d| {
            const b = div_mod.div(c).h(lh).itemsCenter().justifyCenter();
            defer b.end();
            widgets.text(c, d, st);
        }
    }
}

fn isDigit(b: u8) bool {
    return b >= '0' and b <= '9';
}

/// How many digits follow: a digit's place from the right.
fn digitsAfter(rest: []const u8) usize {
    var n: usize = 0;
    for (rest) |b| {
        if (b >= '0' and b <= '9') n += 1;
    }
    return n;
}

test "places count from the right" {
    try std.testing.expectEqual(@as(usize, 1), digitsAfter("2 min"));
    try std.testing.expectEqual(@as(usize, 0), digitsAfter(" min"));
    try std.testing.expectEqual(@as(usize, 2), digitsAfter(":45"));
}

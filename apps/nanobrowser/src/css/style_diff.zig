//! Comparing two computed styles: nothing changed, only paint, or layout.
const std = @import("std");
const style = @import("style.zig");
const cascade = @import("cascade.zig");

const Style = style.Style;
const Change = cascade.Change;

/// The fields that cannot move a box.
const paint_only = std.StaticStringMap(void).initComptime(.{
    .{"visibility"},      .{"inherited_visibility"}, .{"opacity"},           .{"z_index"},
    .{"cursor"},          .{"pointer_events"},       .{"radius"},            .{"radius_pct"},
    .{"outline"},         .{"background"},           .{"background_image"},  .{"background_gradient"},
    .{"background_size"}, .{"background_repeat"},    .{"background_x"},      .{"background_y"},
    .{"background_x_px"}, .{"background_y_px"},      .{"background_size_x"}, .{"background_size_y"},
    .{"shadow"},          .{"object_fit"},           .{"transform"},         .{"color"},
    .{"underline"},       .{"line_through"},         .{"overline"},          .{"text_decoration_color"},
    .{"dark_scheme"},     .{"background_more"},      .{"background_clip"},   .{"mask_image"},
});

fn borderDiff(a: style.Border, b: style.Border) Change {
    if (a.width != b.width or (a.style == .none) != (b.style == .none)) return .layout;
    if (a.style != b.style or !std.meta.eql(a.color, b.color)) return .paint;
    return .none;
}

/// Whether two values of a style field are equal, looking inside slices.
fn same(comptime T: type, a: T, b: T) bool {
    const info = @typeInfo(T);
    switch (info) {
        .@"struct" => |st| {
            inline for (st.field_names) |n| {
                if (!same(@TypeOf(@field(a, n)), @field(a, n), @field(b, n))) return false;
            }
            return true;
        },
        .optional => |o| {
            if (a == null or b == null) return a == null and b == null;
            return same(o.child, a.?, b.?);
        },
        .pointer => |p| {
            if (p.size != .slice) @compileError("no such field in Style");
            if (a.len != b.len) return false;
            if (a.ptr == b.ptr) return true;
            for (a, b) |x, y| if (!same(p.child, x, y)) return false;
            return true;
        },
        .array => {
            for (a, b) |x, y| if (!same(@TypeOf(x), x, y)) return false;
            return true;
        },
        else => return a == b,
    }
}

/// What changed from `a` to `b`.
pub fn compare(a: *const Style, b: *const Style) Change {
    var change: Change = .none;
    const names = @typeInfo(Style).@"struct".field_names;
    inline for (names) |n| {
        const x = @field(a, n);
        const y = @field(b, n);
        if (@TypeOf(x) == style.Border and !comptime std.mem.eql(u8, n, "outline")) {
            change = change.max(borderDiff(x, y));
            if (change == .layout) return change;
        } else if (!same(@TypeOf(x), x, y)) {
            if (paint_only.has(n)) {
                change = change.max(.paint);
            } else {
                return .layout;
            }
        }
    }
    return change;
}

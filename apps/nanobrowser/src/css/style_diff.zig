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
    .{"radius_y"},        .{"radius_y_pct"},         .{"outline_offset"},    .{"background_origin"},
    .{"background_fixed"},.{"bg_sizes"},             .{"bg_positions"},      .{"bg_repeats"},
    .{"bg_clips"},        .{"bg_origins"},           .{"bg_fixed"},          .{"shadows"},
    .{"translate_x"},     .{"translate_y"},          .{"rotate"},            .{"scale_x"},
    .{"scale_y"},         .{"transform_origin_x"},   .{"transform_origin_y"},.{"clip_rect"},
    .{"clip_path"},       .{"filters"},              .{"backdrop_blur"},     .{"appearance_none"},
    .{"animations"},      .{"transitions"},          .{"text_fill"},         
    .{"text_shadows"},    .{"accent"},               .{"placeholder"},       .{"makes_context"},
    .{"svg"},             .{"object_x"},             .{"object_y"},          .{"object_x_px"},
    .{"object_y_px"},
});

fn borderDiff(a: style.Border, b: style.Border) Change {
    if (a.width != b.width or (a.style == .none) != (b.style == .none)) return .layout;
    if (a.style != b.style or !std.meta.eql(a.color, b.color)) return .paint;
    return .none;
}

/// Whether two values of a style field are equal, looking inside slices.
pub fn same(comptime T: type, a: T, b: T) bool {
    const info = @typeInfo(T);
    switch (info) {
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |x, tag| return same(@TypeOf(x), x, @field(b, @tagName(tag))),
            }
        },
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
            if (p.size == .one) return a == b or same(p.child, a.*, b.*);
            if (p.size != .slice) return a == b;
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
    // A transform is a containing block for what's in it, whatever it does.
    if (a.hasTransform() != b.hasTransform()) return .layout;
    const names = @typeInfo(Style).@"struct".field_names;
    inline for (names) |n| {
        // What they come to is compared instead.
        if (comptime std.mem.eql(u8, n, "anim_raw") or std.mem.eql(u8, n, "trans_raw")) continue;
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

//! `filter` on what is already a list of things to draw: nanoui has no way to run
//! a picture of a subtree through a filter, so each function is done to what it
//! can be: colors adjust at once; `opacity` fades; `drop-shadow` adds a shadow to
//! each thing with a shape; `blur` turns a plain fill into a soft shadow of itself
//! and lays a frosted pane over what has no such shape. A picture has one tint: it
//! follows a filter that leaves only its shape (`brightness(0)`, `invert` after it).
const std = @import("std");
const css = @import("../css/style.zig");
const box = @import("../layout/box.zig");
const display = @import("display.zig");
const boxes = @import("boxes.zig");
const Builder = display.Builder;
const At = display.At;
const Item = display.Item;
const Kind = display.Kind;
const fx = css.fx;
const Allocator = std.mem.Allocator;

/// `items` as `x`'s filters make them.
pub fn apply(b: *Builder, x: *const box.Box, at: At, items: []const Item) Allocator.Error![]const Item {
    var out = try b.arena.dupe(Item, items);
    for (x.style.filters) |f| {
        switch (f.kind) {
            .blur => out = try blur(b, x, at, out, f.amount),
            .drop_shadow => out = try dropShadow(b, out, f.shadow),
            .opacity => for (out) |*it| {
                it.opacity *= std.math.clamp(f.amount, 0, 1);
            },
            else => try adjust(b.arena, out, f),
        }
    }
    return out;
}

fn blur(b: *Builder, x: *const box.Box, at: At, items: []Item, radius: f32) Allocator.Error![]Item {
    if (radius <= 0) return items;
    var has_plain = false;
    var has_other = false;
    for (items) |*it| switch (it.kind) {
        .fill => |f| {
            if (f.color.a > 0 and f.shadow == null) {
                // A soft shadow of itself and nothing else.
                has_plain = true;
                const k = f.color;
                it.kind = .{ .fill = .{ .color = .transparent, .radius = f.radius, .shadow = .{ .color = k, .blur = radius * 2 }, .solid_shadow = true } };
            }
        },
        .hit, .group_begin, .group_end => {},
        else => has_other = true,
    };
    if (!has_other) return items;
    // What has no such shape shows through a frosted pane over the whole.
    const out = try b.arena.alloc(Item, items.len + 1);
    @memcpy(out[0..items.len], items);
    out[items.len] = .{ .kind = .{ .frost = .{ .blur = radius, .radius = 0 } }, .rect = .{ .x = x.x + at.tx, .y = x.y + at.ty, .w = x.w, .h = x.h }, .clip = at.clip, .xform = at.xform };
    return out;
}

fn dropShadow(b: *Builder, items: []Item, sh: css.Shadow) Allocator.Error![]Item {
    var shadows: std.ArrayList(Item) = .empty;
    try shadows.ensureTotalCapacity(b.arena, items.len);
    for (items) |it| {
        var sc = it;
        sc.node = null;
        switch (it.kind) {
            .fill => |f| {
                if (f.color.a <= 0) continue;
                sc.kind = .{ .fill = .{ .color = .transparent, .radius = f.radius, .shadow = .{ .x = sh.x, .y = sh.y, .blur = sh.blur, .color = sh.color } } };
            },
            .text => |t| {
                var moved = t;
                moved.color = sh.color;
                moved.color.a *= if (sh.blur > 1) 0.6 else 1;
                moved.baseline += sh.y;
                moved.gradient = null;
                sc.kind = .{ .text = moved };
                sc.rect.x += sh.x;
                sc.rect.y += sh.y;
            },
            .image => |im| {
                var moved = im;
                moved.tint = sh.color;
                sc.kind = .{ .image = moved };
                sc.rect.x += sh.x;
                sc.rect.y += sh.y;
            },
            else => continue,
        }
        try shadows.append(b.arena, sc);
    }
    if (shadows.items.len == 0) return items;
    const out = try b.arena.alloc(Item, shadows.items.len + items.len);
    @memcpy(out[0..shadows.items.len], shadows.items);
    @memcpy(out[shadows.items.len..], items);
    return out;
}

/// What the color functions make of one color.
pub fn colorOf(c: css.Color, f: fx.Filter) css.Color {
    const a = f.amount;
    const clamp = struct {
        fn v(x: f32) f32 {
            return std.math.clamp(x, 0, 1);
        }
    }.v;
    var r = c.r;
    var g = c.g;
    var bl = c.b;
    switch (f.kind) {
        .brightness => {
            r *= a;
            g *= a;
            bl *= a;
        },
        .contrast => {
            r = (r - 0.5) * a + 0.5;
            g = (g - 0.5) * a + 0.5;
            bl = (bl - 0.5) * a + 0.5;
        },
        .invert => {
            const k = clamp(a);
            r = r * (1 - k) + (1 - r) * k;
            g = g * (1 - k) + (1 - g) * k;
            bl = bl * (1 - k) + (1 - bl) * k;
        },
        .grayscale => {
            const k = 1 - clamp(a);
            const m = [9]f32{ 0.2126 + 0.7874 * k, 0.7152 - 0.7152 * k, 0.0722 - 0.0722 * k, 0.2126 - 0.2126 * k, 0.7152 + 0.2848 * k, 0.0722 - 0.0722 * k, 0.2126 - 0.2126 * k, 0.7152 - 0.7152 * k, 0.0722 + 0.9278 * k };
            return times(c, m);
        },
        .sepia => {
            const k = 1 - clamp(a);
            const m = [9]f32{ 0.393 + 0.607 * k, 0.769 - 0.769 * k, 0.189 - 0.189 * k, 0.349 - 0.349 * k, 0.686 + 0.314 * k, 0.168 - 0.168 * k, 0.272 - 0.272 * k, 0.534 - 0.534 * k, 0.131 + 0.869 * k };
            return times(c, m);
        },
        .saturate => {
            const m = [9]f32{ 0.213 + 0.787 * a, 0.715 - 0.715 * a, 0.072 - 0.072 * a, 0.213 - 0.213 * a, 0.715 + 0.285 * a, 0.072 - 0.072 * a, 0.213 - 0.213 * a, 0.715 - 0.715 * a, 0.072 + 0.928 * a };
            return times(c, m);
        },
        .hue_rotate => {
            const t = a * std.math.pi / 180;
            const cs = @cos(t);
            const sn = @sin(t);
            const m = [9]f32{
                0.213 + cs * 0.787 - sn * 0.213, 0.715 - cs * 0.715 - sn * 0.715, 0.072 - cs * 0.072 + sn * 0.928,
                0.213 - cs * 0.213 + sn * 0.143, 0.715 + cs * 0.285 + sn * 0.140, 0.072 - cs * 0.072 - sn * 0.283,
                0.213 - cs * 0.213 - sn * 0.787, 0.715 - cs * 0.715 + sn * 0.715, 0.072 + cs * 0.928 + sn * 0.072,
            };
            return times(c, m);
        },
        else => {},
    }
    return .{ .r = clamp(r), .g = clamp(g), .b = clamp(bl), .a = c.a };
}

fn times(c: css.Color, m: [9]f32) css.Color {
    const k = struct {
        fn v(x: f32) f32 {
            return std.math.clamp(x, 0, 1);
        }
    }.v;
    return .{
        .r = k(m[0] * c.r + m[1] * c.g + m[2] * c.b),
        .g = k(m[3] * c.r + m[4] * c.g + m[5] * c.b),
        .b = k(m[6] * c.r + m[7] * c.g + m[8] * c.b),
        .a = c.a,
    };
}

fn adjust(a: Allocator, items: []Item, f: fx.Filter) Allocator.Error!void {
    for (items) |*it| switch (it.kind) {
        .fill => |*x| {
            x.color = colorOf(x.color, f);
            if (x.shadow) |*sh| sh.color = colorOf(sh.color, f);
        },
        .rounded => |*x| x.color = colorOf(x.color, f),
        .polygon => |*x| x.color = colorOf(x.color, f),
        .border => |*x| {
            x.top.color = colorOf(x.top.color, f);
            x.right.color = colorOf(x.right.color, f);
            x.bottom.color = colorOf(x.bottom.color, f);
            x.left.color = colorOf(x.left.color, f);
        },
        .inset_shadow => |*x| x.shadow.color = colorOf(x.shadow.color, f),
        .text => |*x| x.color = colorOf(x.color, f),
        .bullet => |*x| x.color = colorOf(x.color, f),
        .mask => |*x| x.color = colorOf(x.color, f),
        .gradient => |*x| {
            const stops = try a.dupe(css.GradientStop, x.g.stops);
            for (stops) |*s| s.color = colorOf(s.color, f);
            x.g.stops = stops;
        },
        .image => |*x| {
            // What is left of black and of white, the same: only the shape stays.
            const dark = colorOf(if (x.tint) |t| t else .{}, f);
            const light = colorOf(if (x.tint) |t| t else .{ .r = 1, .g = 1, .b = 1 }, f);
            if (@abs(dark.r - light.r) < 0.02 and @abs(dark.g - light.g) < 0.02 and @abs(dark.b - light.b) < 0.02) x.tint = dark;
        },
        else => {},
    };
}

test "colors through filters" {
    const red: css.Color = .{ .r = 1 };
    try std.testing.expectEqual(@as(f32, 0), colorOf(red, .{ .kind = .brightness, .amount = 0 }).r);
    try std.testing.expectEqual(@as(f32, 0), colorOf(red, .{ .kind = .invert, .amount = 1 }).r);
    try std.testing.expectEqual(@as(f32, 1), colorOf(red, .{ .kind = .invert, .amount = 1 }).g);
    const gray = colorOf(red, .{ .kind = .grayscale, .amount = 1 });
    try std.testing.expectApproxEqAbs(gray.r, gray.g, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2126), gray.b, 1e-3);
}

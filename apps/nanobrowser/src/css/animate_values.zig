//! The properties that really animate, as values read from a style, blended and
//! put back: opacity, transforms, colors, shadows, filters, corners, where a
//! background sits. Anything else in a `Style` jumps (`animate.zig`).
const std = @import("std");
const style = @import("style.zig");
const transform_mod = @import("transform.zig");
const diff = @import("style_diff.zig");

const fx = style.fx;
const Style = style.Style;
const Color = style.Color;
const Shadow = style.Shadow;
const Len = style.Len;
const Op = fx.Op;
const Allocator = std.mem.Allocator;

pub const Smooth = enum {
    opacity,
    transform,
    translate,
    rotate,
    scale,
    transform_origin,
    color,
    background_color,
    border_top_color,
    border_right_color,
    border_bottom_color,
    border_left_color,
    outline_color,
    text_decoration_color,
    box_shadow,
    text_shadow,
    filter,
    border_radius,
    background_position,
    visibility,
};

pub const Value = union(enum) {
    color: Color,
    floats: [16]f32,
    lens: [2]Len,
    ops: []const Op,
    shadows: []const Shadow,
    filters: []const fx.Filter,
    visibility: style.Visibility,
};

/// Whether a `transition-property` name covers `s`.
pub fn named(name: []const u8, s: Smooth) bool {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "all")) return true;
    const own = switch (s) {
        .opacity => "opacity",
        .transform => "transform",
        .translate => "translate",
        .rotate => "rotate",
        .scale => "scale",
        .transform_origin => "transform-origin",
        .color => "color",
        .background_color => "background-color",
        .border_top_color => "border-top-color",
        .border_right_color => "border-right-color",
        .border_bottom_color => "border-bottom-color",
        .border_left_color => "border-left-color",
        .outline_color => "outline-color",
        .text_decoration_color => "text-decoration-color",
        .box_shadow => "box-shadow",
        .text_shadow => "text-shadow",
        .filter => "filter",
        .border_radius => "border-radius",
        .background_position => "background-position",
        .visibility => "visibility",
    };
    if (eq(name, own)) return true;
    return switch (s) {
        .transform => eq(name, "-webkit-transform"),
        .filter => eq(name, "-webkit-filter"),
        .box_shadow => eq(name, "-webkit-box-shadow"),
        .background_color => eq(name, "background"),
        .border_top_color, .border_right_color, .border_bottom_color, .border_left_color => eq(name, "border-color") or eq(name, "border"),
        .outline_color => eq(name, "outline"),
        .text_decoration_color => eq(name, "text-decoration"),
        .border_radius => eq(name, "border-top-left-radius") or eq(name, "border-top-right-radius") or eq(name, "border-bottom-left-radius") or eq(name, "border-bottom-right-radius"),
        else => false,
    };
}

/// The name a transition of `s` is known by in its events.
pub fn eventName(s: Smooth) []const u8 {
    return switch (s) {
        .opacity => "opacity",
        .transform => "transform",
        .translate => "translate",
        .rotate => "rotate",
        .scale => "scale",
        .transform_origin => "transform-origin",
        .color => "color",
        .background_color => "background-color",
        .border_top_color => "border-top-color",
        .border_right_color => "border-right-color",
        .border_bottom_color => "border-bottom-color",
        .border_left_color => "border-left-color",
        .outline_color => "outline-color",
        .text_decoration_color => "text-decoration-color",
        .box_shadow => "box-shadow",
        .text_shadow => "text-shadow",
        .filter => "filter",
        .border_radius => "border-radius",
        .background_position => "background-position",
        .visibility => "visibility",
    };
}

fn radii(s: *const Style) [16]f32 {
    var v: [16]f32 = undefined;
    for (0..4) |i| {
        v[i] = s.radius[i];
        v[4 + i] = s.radius_pct[i];
        v[8 + i] = s.radius_y[i];
        v[12 + i] = s.radius_y_pct[i];
    }
    return v;
}

fn floats(vs: []const f32) [16]f32 {
    var v: [16]f32 = @splat(0);
    for (vs, 0..) |x, i| v[i] = x;
    return v;
}

pub fn get(s: *const Style, p: Smooth) Value {
    return switch (p) {
        .opacity => .{ .floats = floats(&.{s.opacity}) },
        .transform => .{ .ops = if (s.transform) |t| t.ops else &.{} },
        .translate => .{ .lens = .{ s.translate_x, s.translate_y } },
        .rotate => .{ .floats = floats(&.{s.rotate}) },
        .scale => .{ .floats = floats(&.{ s.scale_x, s.scale_y }) },
        .transform_origin => .{ .lens = .{ s.transform_origin_x, s.transform_origin_y } },
        .color => .{ .color = s.color },
        .background_color => .{ .color = s.background },
        .border_top_color => .{ .color = s.border_top.color },
        .border_right_color => .{ .color = s.border_right.color },
        .border_bottom_color => .{ .color = s.border_bottom.color },
        .border_left_color => .{ .color = s.border_left.color },
        .outline_color => .{ .color = s.outline.color },
        .text_decoration_color => .{ .color = s.text_decoration_color orelse s.color },
        .box_shadow => .{ .shadows = s.shadows },
        .text_shadow => .{ .shadows = s.text_shadows },
        .filter => .{ .filters = s.filters },
        .border_radius => .{ .floats = radii(s) },
        .background_position => .{ .floats = floats(&.{ s.background_x, s.background_x_px, s.background_y, s.background_y_px }) },
        .visibility => .{ .visibility = s.visibility },
    };
}

pub fn set(s: *Style, p: Smooth, v: Value) void {
    switch (p) {
        .opacity => s.opacity = std.math.clamp(v.floats[0], 0, 1),
        .transform => s.transform = if (v.ops.len == 0) null else .{ .ops = v.ops },
        .translate => {
            s.translate_x = v.lens[0];
            s.translate_y = v.lens[1];
        },
        .rotate => s.rotate = v.floats[0],
        .scale => {
            s.scale_x = v.floats[0];
            s.scale_y = v.floats[1];
        },
        .transform_origin => {
            s.transform_origin_x = v.lens[0];
            s.transform_origin_y = v.lens[1];
        },
        .color => s.color = v.color,
        .background_color => s.background = v.color,
        .border_top_color => s.border_top.color = v.color,
        .border_right_color => s.border_right.color = v.color,
        .border_bottom_color => s.border_bottom.color = v.color,
        .border_left_color => s.border_left.color = v.color,
        .outline_color => s.outline.color = v.color,
        .text_decoration_color => s.text_decoration_color = v.color,
        .box_shadow => {
            s.shadows = v.shadows;
            s.shadow = null;
            for (v.shadows) |sh| if (!sh.inset and sh.color.a > 0) {
                s.shadow = sh;
                break;
            };
        },
        .text_shadow => s.text_shadows = v.shadows,
        .filter => s.filters = v.filters,
        .border_radius => for (0..4) |i| {
            s.radius[i] = @max(v.floats[i], 0);
            s.radius_pct[i] = @max(v.floats[4 + i], 0);
            s.radius_y[i] = @max(v.floats[8 + i], 0);
            s.radius_y_pct[i] = @max(v.floats[12 + i], 0);
        },
        .background_position => {
            s.background_x = v.floats[0];
            s.background_x_px = v.floats[1];
            s.background_y = v.floats[2];
            s.background_y_px = v.floats[3];
        },
        .visibility => {
            s.visibility = v.visibility;
            s.inherited_visibility = v.visibility;
        },
    }
}

pub fn equal(a: Value, b: Value) bool {
    return diff.same(Value, a, b);
}

fn mix(a: f32, b: f32, k: f32) f32 {
    return a + (b - a) * k;
}

fn mixColor(a: Color, b: Color, k: f32) Color {
    // Premultiplied, so a color fading out doesn't go through black.
    const alpha = mix(a.a, b.a, k);
    if (alpha <= 0) return .{ .r = b.r, .g = b.g, .b = b.b, .a = 0 };
    const f = struct {
        fn c(x: f32, xa: f32, y: f32, ya: f32, t: f32, out_a: f32) f32 {
            return std.math.clamp(mix(x * xa, y * ya, t) / out_a, 0, 1);
        }
    }.c;
    return .{ .r = f(a.r, a.a, b.r, b.a, k, alpha), .g = f(a.g, a.a, b.g, b.a, k, alpha), .b = f(a.b, a.a, b.b, b.a, k, alpha), .a = alpha };
}

fn mixLen(a: Len, b: Len, k: f32) Len {
    return .{ .px = mix(a.px, b.px, k), .pct = mix(a.pct, b.pct, k) };
}

fn identityOf(o: Op) Op {
    return switch (o) {
        .translate => .{ .translate = .{ .x = Len.zero, .y = Len.zero } },
        .scale => .{ .scale = .{ 1, 1 } },
        .rotate => .{ .rotate = 0 },
        .skew => .{ .skew = .{ 0, 0 } },
        .matrix, .mix => .{ .matrix = .{} },
    };
}

fn mixOp(a: Op, b: Op, k: f32, arena: Allocator) ?Op {
    return switch (a) {
        .translate => |x| .{ .translate = .{ .x = mixLen(x.x, b.translate.x, k), .y = mixLen(x.y, b.translate.y, k) } },
        .scale => |x| .{ .scale = .{ mix(x[0], b.scale[0], k), mix(x[1], b.scale[1], k) } },
        .rotate => |x| .{ .rotate = mix(x, b.rotate, k) },
        .skew => |x| .{ .skew = .{ mix(x[0], b.skew[0], k), mix(x[1], b.skew[1], k) } },
        .matrix => |x| .{ .matrix = transform_mod.blend(x, b.matrix, k) },
        .mix => {
            const m = arena.create(fx.Mix) catch return null;
            const one = arena.alloc(Op, 1) catch return null;
            const two = arena.alloc(Op, 1) catch return null;
            one[0] = a;
            two[0] = b;
            m.* = .{ .a = one, .b = two, .k = k };
            return .{ .mix = m };
        },
    };
}

fn mixOps(a_in: []const Op, b_in: []const Op, k: f32, arena: Allocator) []const Op {
    var a = a_in;
    var b = b_in;
    // `none` against a list: that list's functions at no effect.
    if (a.len == 0 or b.len == 0) {
        const other = if (a.len == 0) b else a;
        const zeros = arena.alloc(Op, other.len) catch return b_in;
        for (other, zeros) |o, *z| z.* = identityOf(o);
        if (a.len == 0) a = zeros else b = zeros;
    }
    if (transform_mod.sameShape(a, b)) {
        const out = arena.alloc(Op, a.len) catch return b_in;
        for (a, b, out) |x, y, *o| o.* = mixOp(x, y, k, arena) orelse return b_in;
        return out;
    }
    const m = arena.create(fx.Mix) catch return b_in;
    const out = arena.alloc(Op, 1) catch return b_in;
    m.* = .{ .a = a, .b = b, .k = k };
    out[0] = .{ .mix = m };
    return out;
}

fn mixShadows(a: []const Shadow, b: []const Shadow, k: f32, arena: Allocator) []const Shadow {
    const n = @max(a.len, b.len);
    const out = arena.alloc(Shadow, n) catch return b;
    for (out, 0..) |*o, i| {
        const x = if (i < a.len) a[i] else blank(b[i]);
        const y = if (i < b.len) b[i] else blank(a[i]);
        if (x.inset != y.inset) {
            o.* = if (k < 0.5) x else y;
            continue;
        }
        o.* = .{ .x = mix(x.x, y.x, k), .y = mix(x.y, y.y, k), .blur = @max(mix(x.blur, y.blur, k), 0), .spread = mix(x.spread, y.spread, k), .color = mixColor(x.color, y.color, k), .inset = x.inset };
    }
    return out;
}

fn blank(s: Shadow) Shadow {
    return .{ .color = .{ .r = s.color.r, .g = s.color.g, .b = s.color.b, .a = 0 }, .inset = s.inset };
}

fn filterIdentity(f: fx.Filter) fx.Filter {
    return switch (f.kind) {
        .blur, .hue_rotate, .grayscale, .invert, .sepia => .{ .kind = f.kind, .amount = 0 },
        .drop_shadow => .{ .kind = f.kind, .shadow = blank(f.shadow) },
        else => .{ .kind = f.kind, .amount = 1 },
    };
}

fn mixFilters(a_in: []const fx.Filter, b_in: []const fx.Filter, k: f32, arena: Allocator) []const fx.Filter {
    const n = @max(a_in.len, b_in.len);
    const out = arena.alloc(fx.Filter, n) catch return b_in;
    for (out, 0..) |*o, i| {
        const x = if (i < a_in.len) a_in[i] else filterIdentity(b_in[i]);
        const y = if (i < b_in.len) b_in[i] else filterIdentity(a_in[i]);
        if (x.kind != y.kind) return if (k < 0.5) a_in else b_in;
        o.* = .{ .kind = x.kind, .amount = mix(x.amount, y.amount, k) };
        if (x.kind == .drop_shadow) {
            const pair = mixShadows(&.{x.shadow}, &.{y.shadow}, k, arena);
            if (pair.len == 1) o.shadow = pair[0];
        }
    }
    return out;
}

/// Part way from `a` to `b`; what has to be made is made in `arena`.
pub fn blend(a: Value, b: Value, k: f32, arena: Allocator) Value {
    return switch (a) {
        .color => |x| .{ .color = mixColor(x, b.color, k) },
        .floats => |x| blk: {
            var out: [16]f32 = undefined;
            for (x, b.floats, &out) |p, q, *o| o.* = mix(p, q, k);
            break :blk .{ .floats = out };
        },
        .lens => |x| .{ .lens = .{ mixLen(x[0], b.lens[0], k), mixLen(x[1], b.lens[1], k) } },
        .ops => |x| .{ .ops = mixOps(x, b.ops, k, arena) },
        .shadows => |x| .{ .shadows = mixShadows(x, b.shadows, k, arena) },
        .filters => |x| .{ .filters = mixFilters(x, b.filters, k, arena) },
        // Visible all the while it is on its way to or from visible.
        .visibility => |x| .{ .visibility = if (k <= 0) x else if (k >= 1) b.visibility else if (x == .visible or b.visibility == .visible) .visible else b.visibility },
    };
}

fn copyOps(a: Allocator, ops: []const Op) ![]const Op {
    const out = try a.dupe(Op, ops);
    for (out) |*o| if (o.* == .mix) {
        const m = try a.create(fx.Mix);
        m.* = .{ .a = try copyOps(a, o.mix.a), .b = try copyOps(a, o.mix.b), .k = o.mix.k };
        o.* = .{ .mix = m };
    };
    return out;
}

/// A value kept beyond the style it came from.
pub fn keep(a: Allocator, v: Value) Allocator.Error!Value {
    return switch (v) {
        .ops => |x| .{ .ops = try copyOps(a, x) },
        .shadows => |x| .{ .shadows = try a.dupe(Shadow, x) },
        .filters => |x| .{ .filters = try a.dupe(fx.Filter, x) },
        else => v,
    };
}

test "values blend, and `none` meets a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const op = [_]Op{.{ .translate = .{ .x = .{ .px = 100 }, .y = Len.zero } }};
    const mid = blend(.{ .ops = &.{} }, .{ .ops = &op }, 0.5, a);
    try std.testing.expectApproxEqAbs(@as(f32, 50), mid.ops[0].translate.x.px, 0.001);
    const c = blend(.{ .color = .{ .r = 1, .a = 0 } }, .{ .color = .{ .r = 1, .a = 1 } }, 0.5, a);
    try std.testing.expectApproxEqAbs(@as(f32, 1), c.color.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), c.color.a, 0.001);
    const vis = blend(.{ .visibility = .hidden }, .{ .visibility = .visible }, 0.1, a);
    try std.testing.expect(vis.visibility == .visible);
    try std.testing.expect(equal(.{ .floats = floats(&.{1}) }, .{ .floats = floats(&.{1}) }));
    try std.testing.expect(named("border-color", .border_left_color));
    try std.testing.expect(named("all", .opacity));
    try std.testing.expect(!named("width", .opacity));
}

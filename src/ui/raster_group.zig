//! The CPU renderer's groups: a group's instances drawn into a layer of
//! their own, then composited at the group's opacity, clip and scroll fade,
//! as `shader.metal`'s layers are. Layers are window-sized, one per nesting
//! depth, and kept between frames on the thread that draws (as the GPU
//! renderers keep their layer textures): a group no longer maps, clears and
//! unmaps one every frame.
const std = @import("std");
const raster = @import("raster.zig");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const scroll_fade = @import("scroll_fade.zig");

/// A group's instances drawn into a layer of their own, then composited over
/// `out` at its end's opacity, clip and scroll fade.
pub fn draw(
    out: gpu.Pixels,
    span: []const gpu.Instance,
    begin_inst: *const gpu.Instance,
    end_inst: *const gpu.Instance,
    mask: raster.Mask,
    pictures: raster.Pictures,
    scale: f32,
    region: [4]usize,
    depth: u16,
) void {
    std.debug.assert(region[0] <= region[2]);
    std.debug.assert(region[2] <= out.width);
    std.debug.assert(region[3] <= out.height);
    const masked = end_inst.border_color[2] > 0 or end_inst.border_color[3] > 0;
    if (!masked) drawGlassBehind(out, span, mask, pictures, scale, region);
    const all = raster.bounds(out, begin_inst, scale) orelse return;
    // Only the group's pixels inside the region are composited: without
    // glass, which reads beyond itself, only those are drawn and cleared.
    const b: [4]usize = .{
        @max(all[0], region[0]), @max(all[1], region[1]),
        @min(all[2], region[2]), @min(all[3], region[3]),
    };
    if (b[2] <= b[0] or b[3] <= b[1]) return;
    // A group faded out shows nothing: nothing of it is drawn.
    if (end_inst.color[3] <= 0) return;
    const glassy = hasGlass(span);
    const area = if (glassy) region else b;
    const len = out.width * out.height * 4;
    const kept = keptLayer(depth, len);
    const tmp_bytes = kept orelse (std.heap.page_allocator.alloc(u8, len) catch return);
    defer if (kept == null) std.heap.page_allocator.free(tmp_bytes);
    const tmp: gpu.Pixels = .{ .bytes = tmp_bytes, .width = out.width, .height = out.height };
    // Masked, `drawRegion` clears the area itself.
    if (glassy) @memset(tmp_bytes, 0) else if (!masked) clear(tmp, area);
    if (masked) {
        raster.drawRegion(tmp, span, mask, pictures, scale, types.Color.transparent, area);
    } else {
        drawLayer(tmp, span, mask, pictures, scale, area, depth);
    }
    composite(out, tmp, end_inst, scale, b);
}

/// The glass in an unmasked group's own instances (not in groups within
/// it), drawn over `out` first: it reads what's behind the group.
fn drawGlassBehind(
    out: gpu.Pixels,
    span: []const gpu.Instance,
    mask: raster.Mask,
    pictures: raster.Pictures,
    scale: f32,
    region: [4]usize,
) void {
    var at: usize = 0;
    while (at < span.len) : (at += 1) {
        if (span[at].kind == gpu.Kind.layer_begin) {
            at = gpu.groupEnd(span, at) orelse break;
            continue;
        }
        if (span[at].kind != gpu.Kind.glass) continue;
        raster.drawOne(out, &span[at], mask, pictures, scale, region);
    }
}

/// An unmasked group's instances, but its glass, drawn into its layer
/// `tmp`, the groups within it each into a layer one deeper.
fn drawLayer(
    tmp: gpu.Pixels,
    span: []const gpu.Instance,
    mask: raster.Mask,
    pictures: raster.Pictures,
    scale: f32,
    area: [4]usize,
    depth: u16,
) void {
    var at: usize = 0;
    while (at < span.len) {
        const gi = &span[at];
        if (gi.kind == gpu.Kind.layer_begin) {
            const end_at = gpu.groupEnd(span, at) orelse break;
            const inner = span[at + 1 .. end_at];
            draw(tmp, inner, gi, &span[end_at], mask, pictures, scale, area, depth +| 1);
            at = end_at + 1;
            continue;
        }
        const skip = gi.kind == gpu.Kind.glass or gi.kind == gpu.Kind.layer_end;
        if (!skip) raster.drawOne(tmp, gi, mask, pictures, scale, area);
        at += 1;
    }
}

/// The layer `tmp`'s pixels `b` blended over `out` at the group end's
/// opacity, clip and scroll fade.
fn composite(
    out: gpu.Pixels,
    tmp: gpu.Pixels,
    end_inst: *const gpu.Instance,
    scale: f32,
    b: [4]usize,
) void {
    std.debug.assert(tmp.width == out.width);
    std.debug.assert(tmp.height == out.height);
    const alpha = std.math.clamp(end_inst.color[3], 0, 1);
    const inv = 1 / scale;
    for (b[1]..b[3]) |y| {
        const wy = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
        const row = y * out.width * 4;
        for (b[0]..b[2]) |x| {
            const wx = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
            const s = tmp.bytes[row + x * 4 ..][0..4];
            if (s[3] == 0) continue;
            const local = raster.unmatrix(end_inst, wx, wy);
            const fade = scroll_fade.alpha(end_inst.border_color, local[1]);
            const k = alpha * fade * raster.clipCover(end_inst, wx, wy, inv) / 255.0;
            const r: f32 = @floatFromInt(s[2]);
            const g: f32 = @floatFromInt(s[1]);
            const bl: f32 = @floatFromInt(s[0]);
            const a: f32 = @floatFromInt(s[3]);
            raster.blend(out.bytes, row + x * 4, r * k, g * k, bl * k, a * k);
        }
    }
}

threadlocal var held: [max_depth][]u8 = @splat(&.{});
/// Groups nested deeper get a buffer of their own, freed after drawing.
const max_depth = 8;

/// The layer at `depth`, `len` bytes, its pixels left from before; null when
/// none is kept that deep or it can't be made.
fn keptLayer(depth: u16, len: usize) ?[]u8 {
    std.debug.assert(len % 4 == 0);
    if (depth >= max_depth) return null;
    const layer = &held[depth];
    if (layer.len != len) {
        if (layer.len > 0) std.heap.page_allocator.free(layer.*);
        layer.* = std.heap.page_allocator.alloc(u8, len) catch &.{};
    }
    return if (layer.len == len) layer.* else null;
}

/// Frees the group layers this thread keeps (made again when a group is next
/// drawn).
pub fn freeLayers() void {
    for (&held) |*layer| {
        if (layer.len > 0) std.heap.page_allocator.free(layer.*);
        layer.* = &.{};
    }
}

/// Whether glass, which reads beyond its own pixels, is in `span`.
fn hasGlass(span: []const gpu.Instance) bool {
    for (span) |*i| if (i.kind == gpu.Kind.glass) return true;
    return false;
}

/// Clears the pixels `area` (x0, y0, x1, y1) of `px` to transparent.
fn clear(px: gpu.Pixels, area: [4]usize) void {
    std.debug.assert(area[0] <= area[2]);
    std.debug.assert(area[2] <= px.width);
    std.debug.assert(area[3] <= px.height);
    for (area[1]..area[3]) |y| {
        const row = y * px.width;
        @memset(px.bytes[(row + area[0]) * 4 .. (row + area[2]) * 4], 0);
    }
}

test "a layer is kept, then made again at a new size" {
    defer freeLayers();
    const a = keptLayer(0, 64) orelse return error.NoLayer;
    const again = keptLayer(0, 64) orelse return error.NoLayer;
    try std.testing.expectEqual(a.ptr, again.ptr);
    const grown = keptLayer(0, 128) orelse return error.NoLayer;
    try std.testing.expectEqual(@as(usize, 128), grown.len);
    try std.testing.expectEqual(@as(?[]u8, null), keptLayer(max_depth, 64));
}

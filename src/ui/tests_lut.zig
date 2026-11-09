//! A texture's LUTs (`ui.lut`, `Texture.lut`, `Texture.source_lut`): a
//! .cube's grid as a 3D texture, sampled by Metal as the CPU's trilinear
//! reference (`color.applyLut`) samples it, within one 8-bit step.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const color = @import("color.zig");
const raster = @import("raster.zig");

const w = 64;
const h = 48;

/// A .cube of `size` a side mapping each grid point by `f`.
fn cubeText(gpa: std.mem.Allocator, size: usize, comptime f: fn ([3]f32) [3]f32) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "TITLE \"test\"\n# a comment\nLUT_3D_SIZE {d}\nDOMAIN_MIN 0 0 0\nDOMAIN_MAX 1 1 1\n", .{size});
    const k: f32 = @floatFromInt(size - 1);
    for (0..size) |b| for (0..size) |g| for (0..size) |r| {
        const v = f(.{ @as(f32, @floatFromInt(r)) / k, @as(f32, @floatFromInt(g)) / k, @as(f32, @floatFromInt(b)) / k });
        try out.print(gpa, "{d:.6} {d:.6} {d:.6}\n", .{ v[0], v[1], v[2] });
    };
    return out.toOwnedSlice(gpa);
}

/// A .cube's size and its grid as RGBA half floats (what `ui.lut` takes).
fn parseCube(gpa: std.mem.Allocator, src: []const u8) !struct { size: u16, data: []f16 } {
    var size: u16 = 0;
    var data: std.ArrayList(f16) = .empty;
    errdefer data.deinit(gpa);
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.startsWith(u8, line, "TITLE") or std.mem.startsWith(u8, line, "DOMAIN")) continue;
        if (std.mem.startsWith(u8, line, "LUT_3D_SIZE")) {
            size = try std.fmt.parseInt(u16, std.mem.trim(u8, line["LUT_3D_SIZE".len..], " \t"), 10);
            continue;
        }
        var it = std.mem.tokenizeAny(u8, line, " \t");
        for (0..3) |_| try data.append(gpa, @floatCast(try std.fmt.parseFloat(f32, it.next() orelse return error.Short)));
        try data.append(gpa, 1);
    }
    if (data.items.len != @as(usize, size) * size * size * 4) return error.Short;
    return .{ .size = size, .data = try data.toOwnedSlice(gpa) };
}

fn identity(v: [3]f32) [3]f32 {
    return v;
}

fn invert(v: [3]f32) [3]f32 {
    return .{ 1 - v[0], 1 - v[1], 1 - v[2] };
}

fn card() [w * h * 4]u8 {
    var px: [w * h * 4]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        px[i..][0..4].* = .{ @intCast(x * 4), @intCast(y * 5), @intCast((x * 3 + y * 2) % 256), 255 };
    };
    return px;
}

const Scene = struct {
    source: ui.Texture,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        ui.texture(c, .{ .width = .{ .px = w }, .height = .{ .px = h } }, s.source, .{ 0, 0, 1, 1 }, 1);
    }
};

/// Draws `source` with Metal and on the CPU at a pixel a texel, and checks
/// both against `color.applyLuts` of each texel, and against `expect`.
fn check(source: ui.Texture, px: []const u8, comptime expect: fn ([3]f32) [3]f32) !void {
    const gpa = testing.allocator;
    var s: Scene = .{ .source = source };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = w, .height = h, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    const cpu: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, shown.bytes.len), .width = shown.width, .height = shown.height };
    defer cpu.deinit(gpa);
    var pictures = t.text.images.pictures();
    pictures.textures = t.ctx.textures.items;
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, pictures, t.scale, t.theme.background);
    for (0..h) |y| for (0..w) |x| {
        const src = px[(y * w + x) * 4 ..][0..4];
        const rgb = [3]f32{ @as(f32, @floatFromInt(src[2])) / 255, @as(f32, @floatFromInt(src[1])) / 255, @as(f32, @floatFromInt(src[0])) / 255 };
        const ref = color.applyLuts(source, rgb);
        const ideal = expect(rgb);
        for ([_]gpu.Pixels{ shown, cpu }) |out| {
            const got = out.bytes[(y * out.width + x) * 4 ..][0..4];
            for (0..3) |k| {
                const g: f32 = @floatFromInt(got[2 - k]);
                try testing.expect(@abs(g - ref[k] * 255) <= 1.01);
                try testing.expect(@abs(g - ideal[k] * 255) <= 1.51);
            }
        }
    };
}

test "an identity and an inverting .cube match the CPU's trilinear sampling" {
    const gpa = testing.allocator;
    const px = card();
    const id_text = try cubeText(gpa, 17, identity);
    defer gpa.free(id_text);
    const inv_text = try cubeText(gpa, 33, invert);
    defer gpa.free(inv_text);
    const id = try parseCube(gpa, id_text);
    defer gpa.free(id.data);
    const inv = try parseCube(gpa, inv_text);
    defer gpa.free(inv.data);
    var c: ui.Context = undefined;
    const id_lut = ui.lut(&c, "identity.cube", id.size, id.data);
    const inv_lut = ui.lut(&c, "invert.cube", inv.size, inv.data);
    try testing.expect(id_lut.key != inv_lut.key and id_lut.valid() and inv_lut.valid());
    const base: ui.Texture = .{ .width = w, .height = h, .bgra = &px };
    var t = base;
    t.lut = id_lut;
    try check(t, &px, identity);
    t.lut = inv_lut;
    try check(t, &px, invert);
    // A source look then the output LUT: inverted twice is as shot.
    t.source_lut = inv_lut;
    try check(t, &px, identity);
}

test "a LUT's domain maps what it covers onto its grid" {
    var data: [2 * 2 * 2 * 4]f16 = undefined;
    for (0..2) |b| for (0..2) |g| for (0..2) |r| {
        const i = ((b * 2 + g) * 2 + r) * 4;
        data[i..][0..4].* = .{ @floatFromInt(r), @floatFromInt(g), @floatFromInt(b), 1 };
    };
    const l: gpu.Lut = .{ .key = 7, .size = 2, .data = &data, .domain_min = .{ 0.5, 0.5, 0.5 }, .domain_max = .{ 1, 1, 1 } };
    const out = color.applyLut(l, .{ 0.75, 0.25, 1 });
    try testing.expectApproxEqAbs(@as(f32, 0.5), out[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0), out[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), out[2], 0.001);
    try testing.expect(!(gpu.Lut{ .key = 0, .size = 70, .data = &data }).valid());
}

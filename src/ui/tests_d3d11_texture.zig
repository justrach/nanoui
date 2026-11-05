//! Direct3D 11's textures (`ui.texture`) against the CPU renderer: a
//! texture's uv, its opacity, a rounded clip around it and a turn must come
//! out as the same pixels, and a slot's GPU texture is kept while its size
//! holds. The idioms are `tests_d3d11.zig`'s: only `error.NoDevice` skips,
//! and a frame that drew nothing fails.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const raster = @import("raster.zig");
const base = @import("tests_d3d11.zig");

/// A test card: a gradient, a white square at its top left, and a
/// translucent stripe (premultiplied) along its bottom.
fn card(comptime cw: usize, comptime ch: usize) [cw * ch * 4]u8 {
    var px: [cw * ch * 4]u8 = undefined;
    for (0..ch) |y| for (0..cw) |x| {
        const i = (y * cw + x) * 4;
        const white = x >= 4 and x < 20 and y >= 4 and y < 20;
        const stripe = y >= ch - 6;
        px[i + 0] = if (white) 255 else if (stripe) 40 else @intCast(x * 4 % 256);
        px[i + 1] = if (white) 255 else if (stripe) 40 else @intCast(y * 5 % 256);
        px[i + 2] = if (white) 255 else if (stripe) 60 else 200;
        px[i + 3] = if (stripe) 128 else 255;
    };
    return px;
}

const Scene = struct {
    source: ui.Texture,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).row().sizeFull().p(10).gap(16);
        defer root.end();
        // Rounded, whole, opaque.
        ui.texture(c, .{ .width = .{ .px = 128 }, .height = .{ .px = 96 }, .radius = 12 }, s.source, .{ 0, 0, 1, 1 }, 1);
        // A part of it (a zoom), at half opacity, in a rounded clip.
        {
            const clip = ui.div(c).w(90).h(70).rounded(18).clip();
            defer clip.end();
            ui.texture(c, .{ .width = .{ .px = 120 }, .height = .{ .px = 90 } }, s.source, .{ 0.1, 0.1, 0.6, 0.6 }, 0.5);
        }
        // Turned about its middle.
        ui.texture(c, .{ .width = .{ .px = 80 }, .height = .{ .px = 60 }, .radius = 6, .rotation = 0.35 }, s.source, .{ 0, 0, 1, 1 }, 1);
    }
};

test "d3d11: a texture draws as the CPU renderer draws it (uv, opacity, clip radius, rotation)" {
    const gpa = testing.allocator;
    const px = card(64, 48);
    var s: Scene = .{ .source = .{ .width = 64, .height = 48, .bgra = &px } };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = 420, .height = 140 });
    defer t.deinit();
    t.settle(0.1);
    // The scene is what it says: three texture instances, one turned, one
    // clipped by rounded corners.
    var textures: usize = 0;
    var turned = false;
    var clipped = false;
    for (t.instances.items) |i| if (i.kind == gpu.Kind.texture) {
        textures += 1;
        if (i.xf[0] != 0) turned = true;
        if (i.clip_round != 0) clipped = true;
    };
    try testing.expectEqual(@as(usize, 3), textures);
    try testing.expect(turned and clipped);

    var maybe = try base.renderer();
    if (maybe == null) return error.SkipZigTest;
    var r = &maybe.?;
    defer r.deinit();
    r.textures = t.ctx.textures.items;
    const ours = try base.drawThenRead(r, &t, t.theme.background);
    defer ours.deinit(gpa);
    var pictures = t.text.images.pictures();
    pictures.textures = t.ctx.textures.items;
    const cpu = try gpa.alloc(u8, ours.bytes.len);
    defer gpa.free(cpu);
    raster.draw(.{ .bytes = cpu, .width = ours.width, .height = ours.height }, t.instances.items, t.text.atlas.mask(), pictures, t.scale, t.theme.background);
    var total: u64 = 0;
    var worst: u8 = 0;
    var off: usize = 0;
    for (ours.bytes, cpu) |a, b| {
        const d = if (a > b) a - b else b - a;
        total += d;
        worst = @max(worst, d);
        if (d > 8) off += 1;
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(cpu.len));
    std.debug.print("d3d11 vs cpu (textures): mean {d:.4}, worst {d}, {d} of {d} off ", .{ mean, worst, off, cpu.len });
    // Bilinear sampling rounds a little differently on the GPU; edges are
    // antialiased the same way. Anything structural (a missing texture, the
    // wrong slot, no turn) is thousands of pixels off.
    try testing.expect(mean <= 1.0);
    try testing.expect(off * 40 < cpu.len);
    // The texture is really there: the white square of the first one.
    const at = (30 * ours.width + 30) * 4;
    try testing.expect(ours.bytes[at] > 240 and ours.bytes[at + 1] > 240 and ours.bytes[at + 2] > 240);
}

test "d3d11: a texture slot is remade only when its size changes" {
    var maybe = try base.renderer();
    if (maybe == null) return error.SkipZigTest;
    var r = &maybe.?;
    defer r.deinit();
    const a = card(64, 48);
    const b = card(32, 16);
    const black: ui.Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    const quad = [_]gpu.Instance{.{ .rect = .{ 0, 0, 32, 24 }, .color = .{ 1, 1, 1, 1 }, .uv = .{ 0, 0, 1, 1 }, .kind = gpu.Kind.texture, .border_width = 0 }};
    const big = [_]gpu.Texture{.{ .width = 64, .height = 48, .bgra = &a }};
    const small = [_]gpu.Texture{.{ .width = 32, .height = 16, .bgra = &b }};
    r.textures = &big;
    r.draw(&quad, .{ .w = 32, .h = 24 }, 1, black, null);
    const first = r.slots.entries.items[0].texture;
    try testing.expect(first != null);
    r.draw(&quad, .{ .w = 32, .h = 24 }, 1, black, null);
    try testing.expectEqual(first, r.slots.entries.items[0].texture);
    r.textures = &small;
    r.draw(&quad, .{ .w = 32, .h = 24 }, 1, black, null);
    try testing.expectEqual(@as(u32, 32), r.slots.entries.items[0].w);
    try testing.expectEqual(@as(u32, 16), r.slots.entries.items[0].h);
}

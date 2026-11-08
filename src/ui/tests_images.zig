//! Tests for `ui.image` device-pixel sizing in the atlas and decode budgeting.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const images = @import("images.zig");

const ViewState = struct {
    bytes: []const u8,
    fn view(s: *ViewState, c: *ui.Context) void {
        _ = ui.image(c, .{ .key = "icon", .source = .{ .encoded = s.bytes }, .max_width = 15, .max_height = 15, .radius = 0, .scale = 0.5 });
    }
};

test "ui.image at 15 pt packs side 30 at scale 2 and side 15 at scale 1" {
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 64 * 64 * 4);
    defer gpa.free(raw);
    @memset(raw, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 64, .height = 64 });
    defer gpa.free(png);

    const k = images.Images.key("icon");
    {
        var s: ViewState = .{ .bytes = png };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&s, ViewState.view), .{ .width = 100, .height = 100, .scale = 2 });
        defer t.deinit();
        t.frame();
        try testing.expect(t.ctx.text.images.entries.get(.{ .key = k, .side = 30 }).?.entry != null);
    }
    {
        var s: ViewState = .{ .bytes = png };
        var t: ui.Tester = undefined;
        try t.init(gpa, ui.View.init(&s, ViewState.view), .{ .width = 100, .height = 100, .scale = 1 });
        defer t.deinit();
        t.frame();
        try testing.expect(t.ctx.text.images.entries.get(.{ .key = k, .side = 15 }).?.entry != null);
    }
}

const BudgetState = struct {
    bytes: []const u8,
    fn view(s: *BudgetState, c: *ui.Context) void {
        for (0..9) |i| {
            _ = ui.image(c, .{ .key = c.print("icon.{d}", .{i}), .source = .{ .encoded = s.bytes }, .max_width = 15, .max_height = 15, .radius = 0, .scale = 0.5 });
        }
    }
};

test "decode budget limits to 8 decodes per frame and requests next frame" {
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(raw);
    @memset(raw, 200);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 16, .height = 16 });
    defer gpa.free(png);

    var s: BudgetState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, BudgetState.view), .{ .width = 200, .height = 200, .scale = 2 });
    defer t.deinit();
    try testing.expectEqual(@as(usize, 8), t.ctx.text.images.entries.count());
    try testing.expect(t.ctx.text.images.wants_frame);
    t.frame();
    try testing.expectEqual(@as(usize, 9), t.ctx.text.images.entries.count());
    try testing.expect(!t.ctx.text.images.wants_frame);
}

test "sink uploads survive render after pre-sink pixels allocation" {
    if (@import("build_options").portable or @import("builtin").os.tag != .macos) return;
    const gpa = testing.allocator;
    const raw = try gpa.alloc(u8, 16 * 16 * 4);
    defer gpa.free(raw);
    @memset(raw, 220);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 16, .height = 16 });
    defer gpa.free(png);

    var s: BudgetState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    // Frame 1 runs with sink == null, allocating im.pixels and decoding 8 of 9 icons.
    try t.init(gpa, ui.View.init(&s, BudgetState.view), .{ .width = 200, .height = 200, .scale = 2, .dark = true });
    defer t.deinit();
    // Sync the first 8 icons into images_texture, then attach the direct GPU sink for icon.8.
    t.renderer.syncImages(&t.text.images);
    t.text.images.sink = .{ .ctx = &t.renderer, .upload = @TypeOf(t.renderer).uploadImage };
    t.frame();
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const k8 = images.Images.key("icon.8");
    const e6 = t.ctx.text.images.entries.get(.{ .key = k8, .side = 30 }).?.entry.?;
    var r6: ?ui.Rect = null;
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .image => |im| if (im.key == k8) {
            r6 = n.rect;
        },
        else => {},
    };
    try testing.expect(e6.uv[0] > 0);
    const rect = r6.?;
    const cx: usize = @intFromFloat(@round((rect.x + rect.w * 0.5) * 2));
    const cy: usize = @intFromFloat(@round((rect.y + rect.h * 0.5) * 2));
    const idx = (cy * px.width + cx) * 4;
    try testing.expect(px.bytes[idx] > 180 and px.bytes[idx + 1] > 180 and px.bytes[idx + 2] > 180);
}

const PartState = struct {
    bytes: []const u8,
    fn view(s: *PartState, c: *ui.Context) void {
        // Its left half, stretched over a box twice as wide as tall.
        _ = ui.image(c, .{ .key = "sides", .source = .{ .encoded = s.bytes }, .radius = 0, .box = .{ .w = 40, .h = 20 }, .part = .{ 0, 0, 0.5, 1 } });
        _ = ui.image(c, .{ .key = "sides", .source = .{ .encoded = s.bytes }, .radius = 0, .box = .{ .w = 40, .h = 20 }, .part = .{ 0.5, 0, 1, 1 } });
    }
};

test "ui.image shows the part asked for, in the box asked for" {
    const gpa = testing.allocator;
    // Red on its left half, blue on its right, 8x8 (BGRA).
    var raw: [8 * 8 * 4]u8 = undefined;
    for (0..8) |y| for (0..8) |x| {
        const px: [4]u8 = if (x < 4) .{ 0, 0, 255, 255 } else .{ 255, 0, 0, 255 };
        @memcpy(raw[(y * 8 + x) * 4 ..][0..4], &px);
    };
    const png = try ui.png.encode(gpa, .{ .bytes = &raw, .width = 8, .height = 8 });
    defer gpa.free(png);
    var s: PartState = .{ .bytes = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, PartState.view), .{ .width = 60, .height = 60, .scale = 1 });
    defer t.deinit();
    t.frame();
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    const at = struct {
        fn bgra(p: anytype, x: usize, y: usize) [4]u8 {
            return p.bytes[(y * p.width + x) * 4 ..][0..4].*;
        }
    }.bgra;
    // Both ends of the first box are red, both ends of the second blue.
    for ([_][2]usize{ .{ 3, 10 }, .{ 36, 10 } }) |p| {
        const v = at(px, p[0], p[1]);
        try testing.expect(v[2] > 200 and v[0] < 60);
    }
    for ([_][2]usize{ .{ 3, 30 }, .{ 36, 30 } }) |p| {
        const v = at(px, p[0], p[1]);
        try testing.expect(v[0] > 200 and v[2] < 60);
    }
    try testing.expectEqual(@as(f32, 8), ui.imageSize(&t.ctx, "sides", png).?.w);
    try testing.expect(ui.imageSize(&t.ctx, "not", "not a picture") == null);
}

const FormatState = struct {
    bytes: []const u8,
    fn view(s: *FormatState, c: *ui.Context) void {
        _ = ui.image(c, .{ .key = "picture", .source = .{ .encoded = s.bytes }, .radius = 0, .box = .{ .w = 32, .h = 32 } });
    }
};

/// Whichever decodes it (ImageIO, or nanoui's own with `-Dportable`), the
/// picture is the same size and comes out in the same place.
fn drawsAt(bytes: []const u8, width: f32, height: f32) ![4]u8 {
    const gpa = testing.allocator;
    var s: FormatState = .{ .bytes = bytes };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, FormatState.view), .{ .width = 32, .height = 32, .scale = 1 });
    defer t.deinit();
    t.frame();
    const size = ui.imageSize(&t.ctx, "picture", bytes).?;
    try testing.expectEqual(width, size.w);
    try testing.expectEqual(height, size.h);
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    return px.bytes[(16 * px.width + 16) * 4 ..][0..4].*;
}

test "a GIF and a JPEG draw on every platform" {
    // One red pixel: GIF89a, a palette of two, LZW's clear, 0, end.
    const gif = "GIF89a\x01\x00\x01\x00\x80\x00\x00\xff\x00\x00\x00\x00\x00" ++
        "\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
    const red = try drawsAt(gif, 1, 1);
    try testing.expect(red[2] > 240 and red[1] < 20 and red[0] < 20);
    const jpeg = &@import("jpeg_decode_test.zig").real_sips;
    const px = try drawsAt(jpeg, @floatFromInt(@import("jpeg_decode.zig").size(jpeg).?.width), @floatFromInt(@import("jpeg_decode.zig").size(jpeg).?.height));
    try testing.expectEqual(@as(u8, 255), px[3]);
}

const Big = struct {
    bytes: []const u8,
    w: f32,
    limits: ?images.Limits = null,
    fn view(s: *Big, c: *ui.Context) void {
        if (s.limits) |l| ui.imageLimits(c, l);
        _ = ui.image(c, .{ .key = "big", .source = .{ .encoded = s.bytes }, .box = .{ .w = s.w, .h = 20 }, .radius = 0 });
    }
};

/// Columns one pixel wide, black and white in turn: blurred, they would be gray.
fn stripes(gpa: std.mem.Allocator, w: usize, h: usize) ![]u8 {
    const raw = try gpa.alloc(u8, w * h * 4);
    defer gpa.free(raw);
    for (0..h) |y| for (0..w) |x| {
        const v: u8 = if (x % 2 == 0) 255 else 0;
        raw[(y * w + x) * 4 ..][0..4].* = .{ v, v, v, 255 };
    };
    return ui.png.encode(gpa, .{ .bytes = raw, .width = @intCast(w), .height = @intCast(h) });
}

test "with larger limits a picture a window wide on a dense screen keeps every pixel" {
    const gpa = testing.allocator;
    const png = try stripes(gpa, 2560, 40);
    defer gpa.free(png);
    var s: Big = .{ .bytes = png, .w = 1280, .limits = .{ .picture_side = 8192, .atlas_side = 8192, .decoded_bytes = 64 * 1024 * 1024 } };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, Big.view), .{ .width = 1280, .height = 40, .scale = 2 });
    defer t.deinit();
    t.frame();
    try testing.expectEqual(@as(u32, 4096), t.text.images.side);
    const px = try t.render(gpa);
    defer px.deinit(gpa);
    // Neighbouring pixels are the picture's own columns, not an average.
    const a = px.bytes[(10 * px.width + 1000) * 4];
    const b = px.bytes[(10 * px.width + 1001) * 4];
    try testing.expect((a > 230 and b < 25) or (a < 25 and b > 230));
}

test "without asking, a picture stays within the defaults and the atlas doesn't grow" {
    const gpa = testing.allocator;
    const png = try stripes(gpa, 2560, 40);
    defer gpa.free(png);
    var s: Big = .{ .bytes = png, .w = 1280 };
    var t: ui.Tester = undefined;
    try t.init(gpa, ui.View.init(&s, Big.view), .{ .width = 1280, .height = 40, .scale = 2 });
    defer t.deinit();
    t.frame();
    try testing.expectEqual(images.size, t.text.images.side);
    var it = t.text.images.entries.iterator();
    while (it.next()) |kv| try testing.expect(kv.key_ptr.side <= images.max_side);
}

test "a frame's pictures that don't fit double the atlas, and a smaller frame's leave" {
    const gpa = testing.allocator;
    var im: images.Images = .{ .gpa = gpa, .limits = .{ .picture_side = 2000, .atlas_side = 8192 } };
    defer im.deinit();
    const raw = try gpa.alloc(u8, 2000 * 1800 * 4);
    defer gpa.free(raw);
    @memset(raw, 90);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 2000, .height = 1800 });
    defer gpa.free(png);
    im.beginPaint();
    im.decodes_left = 8;
    const first = im.get(images.Images.key("a"), .{ .encoded = png }, 2000).?;
    try testing.expectEqual(images.size, im.side);
    try testing.expect(first.uv[2] > 0);
    const second = im.get(images.Images.key("b"), .{ .encoded = png }, 2000).?;
    try testing.expectEqual(@as(u32, 4096), im.side);
    try testing.expect(im.reset_during_frame);
    // Both in the larger atlas, apart.
    const again = im.get(images.Images.key("a"), .{ .encoded = png }, 2000).?;
    try testing.expect(again.uv[1] != second.uv[1] or again.uv[0] != second.uv[0]);
    try testing.expectEqual(@as(usize, 4096 * 4096 * 4), im.pixels.len);
}

test "a decoded picture over budget leaves the cache, not the atlas" {
    const gpa = testing.allocator;
    var im: images.Images = .{ .gpa = gpa, .limits = .{ .decoded_bytes = 100 } };
    defer im.deinit();
    const raw = try gpa.alloc(u8, 32 * 32 * 4);
    defer gpa.free(raw);
    @memset(raw, 90);
    const png = try ui.png.encode(gpa, .{ .bytes = raw, .width = 32, .height = 32 });
    defer gpa.free(png);
    im.beginPaint();
    const a = im.get(images.Images.key("a"), .{ .encoded = png }, 32).?;
    _ = im.get(images.Images.key("b"), .{ .encoded = png }, 32).?;
    try testing.expectEqual(@as(usize, 1), im.decoded.count());
    // Still drawn from the atlas, nothing decoded again.
    const gen = im.generation;
    const left = im.decodes_left;
    const a2 = im.get(images.Images.key("a"), .{ .encoded = png }, 32).?;
    try testing.expectEqual(a.uv, a2.uv);
    try testing.expectEqual(gen, im.generation);
    try testing.expectEqual(left, im.decodes_left);
}

test "an SVG larger than a picture may be is drawn at the limit, not past the atlas" {
    const gpa = testing.allocator;
    var im: images.Images = .{ .gpa = gpa };
    defer im.deinit();
    const doc = "<svg viewBox='0 0 10 10'><rect width='10' height='10' fill='#f00'/></svg>";
    im.beginPaint();
    const d = im.infoSvg(77, doc, .{ .width = 6000, .height = 3000, .current = .{ 0, 0, 0, 1 } }).?;
    try testing.expectEqual(@as(u32, images.max_side), d.w);
    try testing.expectEqual(@as(u32, images.max_side / 2), d.h);
    try testing.expect(im.get(77, .{ .encoded = doc }, 6000) != null);
}

test "types that decode here" {
    try testing.expect(ui.imageTypeDecodes("image/png"));
    try testing.expect(ui.imageTypeDecodes("IMAGE/JPEG; q=1"));
    try testing.expect(ui.imageTypeDecodes("image/svg+xml"));
    try testing.expect(!ui.imageTypeDecodes("image/jxl"));
    try testing.expect(!ui.imageTypeDecodes("text/html"));
}

/// The rectangle the last frame gave the picture `name`.
fn imageRect(t: *ui.Tester, name: []const u8) ?ui.Rect {
    const k = images.Images.key(name);
    for (t.ctx.nodes.items) |n| switch (n.content) {
        .image => |im| if (im.key == k) return n.rect,
        else => {},
    };
    return null;
}

const Tile = struct {
    bgra: []const u8,
    png: []const u8,
    fn view(s: *Tile, c: *ui.Context) void {
        ui.column(c, .{ .padding = .all(10), .gap = 2 });
        defer ui.end(c);
        _ = ui.image(c, .{ .key = "raw", .source = .{ .pixels = .{ .bgra = s.bgra, .width = 4, .height = 4 } }, .max_width = 4, .max_height = 4, .radius = 0, .scale = 1 });
        _ = ui.image(c, .{ .key = "png", .source = .{ .encoded = s.png }, .max_width = 4, .max_height = 4, .radius = 0, .scale = 1 });
    }
};

test "raw pixels draw like the same picture decoded from a PNG" {
    const gpa = testing.allocator;
    var px: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..4) |x| {
        px[(y * 4 + x) * 4 ..][0..4].* = if ((x + y) % 2 == 0) .{ 30, 90, 200, 255 } else .{ 220, 40, 10, 255 };
    };
    const png = try ui.png.encode(gpa, .{ .bytes = &px, .width = 4, .height = 4 });
    defer gpa.free(png);
    var s: Tile = .{ .bgra = &px, .png = png };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Tile.view), .{ .width = 60, .height = 60, .scale = 1 });
    defer t.deinit();
    t.settle(1);
    const a = imageRect(&t, "raw").?;
    const b = imageRect(&t, "png").?;
    try testing.expectEqual(a.w, b.w);
    try testing.expectEqual(a.h, b.h);
    const kw = images.Images.key("raw");
    const kp = images.Images.key("png");
    const ew = t.ctx.text.images.entries.get(.{ .key = kw, .side = 4 }).?.entry.?;
    const ep = t.ctx.text.images.entries.get(.{ .key = kp, .side = 4 }).?.entry.?;
    try testing.expect(ew.uv[0] != ep.uv[0]);
    const out = try t.render(gpa);
    defer out.deinit(gpa);
    const ax: usize = @intFromFloat(@round(a.x));
    const ay: usize = @intFromFloat(@round(a.y));
    const bx: usize = @intFromFloat(@round(b.x));
    const by: usize = @intFromFloat(@round(b.y));
    const w: usize = @intFromFloat(@round(a.w));
    const h: usize = @intFromFloat(@round(a.h));
    try testing.expect(w == 4 and h == 4);
    for (0..h) |y| for (0..w) |x| {
        const p = ((ay + y) * out.width + ax + x) * 4;
        const q = ((by + y) * out.width + bx + x) * 4;
        for (0..4) |ch| {
            const want = if ((x + y) % 2 == 0) [4]u8{ 30, 90, 200, 255 } else [4]u8{ 220, 40, 10, 255 };
            const d = if (out.bytes[p + ch] > want[ch]) out.bytes[p + ch] - want[ch] else want[ch] - out.bytes[p + ch];
            try testing.expect(d <= 1);
            const e = if (out.bytes[p + ch] > out.bytes[q + ch]) out.bytes[p + ch] - out.bytes[q + ch] else out.bytes[q + ch] - out.bytes[p + ch];
            try testing.expect(e <= 1);
        }
    };
}

const Same = struct {
    bgra: []const u8,
    fn view(s: *Same, c: *ui.Context) void {
        _ = ui.image(c, .{ .key = "same", .source = .{ .pixels = .{ .bgra = s.bgra, .width = 2, .height = 2 } }, .max_width = 2, .max_height = 2, .radius = 0, .scale = 1 });
    }
};

test "a key keeps the first pixels it was given" {
    const gpa = testing.allocator;
    var px = [_]u8{ 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255, 0, 0, 255, 255 };
    var s: Same = .{ .bgra = &px };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Same.view), .{ .width = 20, .height = 20, .scale = 1 });
    defer t.deinit();
    const r = imageRect(&t, "same").?;
    const first = try t.render(gpa);
    defer first.deinit(gpa);
    const p = (@as(usize, @intFromFloat(@round(r.y))) * first.width + @as(usize, @intFromFloat(@round(r.x)))) * 4;
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, first.bytes[p..][0..4]);
    @memset(&px, 0);
    px[3] = 255;
    t.frame();
    const second = try t.render(gpa);
    defer second.deinit(gpa);
    try testing.expectEqualSlices(u8, first.bytes[p..][0..4], second.bytes[p..][0..4]);
}

test "raw pixels validate their rows and preserve stride" {
    const gpa = testing.allocator;
    var im: images.Images = .{ .gpa = gpa };
    defer im.deinit();
    var buf = [_]u8{
        10, 20, 30, 255, 40,  50,  60,  255, 0, 0, 0, 0, 0, 0, 0, 0,
        70, 80, 90, 128, 100, 110, 120, 128, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    const source: images.Source = .{ .pixels = .{ .bgra = &buf, .width = 2, .height = 2, .stride = 16 } };
    const k = images.Images.key("raw-stride");
    try testing.expectEqual(images.Info{ .width = 2, .height = 2 }, im.info(k, source).?);
    _ = im.get(k, source, 2).?;
    try testing.expectEqualSlices(u8, buf[0..8], im.pixels[0..8]);
    try testing.expectEqualSlices(u8, buf[16..24], im.pixels[im.side * 4 ..][0..8]);
    try testing.expect(im.info(images.Images.key("short"), .{ .pixels = .{ .bgra = buf[0..8], .width = 2, .height = 2 } }) == null);
    try testing.expect(im.info(images.Images.key("stride"), .{ .pixels = .{ .bgra = &buf, .width = 2, .height = 2, .stride = 4 } }) == null);
}

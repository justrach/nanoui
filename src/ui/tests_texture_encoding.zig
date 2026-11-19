//! Textures an app has already colour managed (`Texture.encoding`):
//! `.display_sdr` is drawn as stored, whatever its pixel format, and
//! `.surface_linear` (linear light, SDR white 1.0) is clipped and sRGB
//! encoded on an SDR surface by the colour stage's source mode 4. Neither
//! takes a LUT or a tone map. `.auto`, the default, changes nothing: every
//! decision and uniform is the one a texture got before encodings existed.
//! Metal and the CPU renderer must each land within one 8-bit step of the
//! oracle, and of each other.
const std = @import("std");
const testing = std.testing;
const ui = @import("ui.zig");
const gpu = @import("gpu.zig");
const color = @import("color.zig");
const raster = @import("raster.zig");
const text = @import("text.zig");
const texture_cpu = @import("texture_cpu.zig");
const pixel_buffer = @import("pixel_buffer.zig");

const n = 32;

/// An inverting 2³ LUT: a texture that took it would come out negated.
const invert_data = blk: {
    var d: [2 * 2 * 2 * 4]f16 = undefined;
    for (0..2) |b| for (0..2) |g| for (0..2) |r| {
        const i = ((b * 2 + g) * 2 + r) * 4;
        d[i..][0..4].* = .{ @floatFromInt(1 - r), @floatFromInt(1 - g), @floatFromInt(1 - b), 1 };
    };
    break :blk d;
};
const invert: gpu.Lut = .{ .key = 0x1a7e, .size = 2, .data = &invert_data };

/// The linear test values: below black, through SDR, above white.
fn linearAt(x: usize, y: usize) [3]f32 {
    return .{ @as(f32, @floatFromInt(x)) / 12 - 0.4, @as(f32, @floatFromInt(y)) / 16, @as(f32, @floatFromInt((x * 3 + y) % n)) / 20 };
}

/// Display codes 0 to 1.
fn codeAt(x: usize, y: usize) [3]f32 {
    return .{ @as(f32, @floatFromInt(x)) / (n - 1), @as(f32, @floatFromInt(y)) / (n - 1), @as(f32, @floatFromInt((x * 7 + y * 3) % n)) / (n - 1) };
}

fn half(v: f32) f32 {
    return @floatCast(@as(f16, @floatCast(v)));
}

/// `n` × `n` RGBA half floats of `f`, opaque, 8 bytes a texel.
fn halfPixels(comptime f: fn (usize, usize) [3]f32) [n * n * 8]u8 {
    var px: [n * n * 8]u8 = undefined;
    for (0..n) |y| for (0..n) |x| {
        const v = f(x, y);
        for (0..4) |k| {
            const h: f16 = if (k < 3) @floatCast(v[k]) else 1;
            std.mem.writeInt(u16, px[(y * n + x) * 8 + k * 2 ..][0..2], @bitCast(h), .little);
        }
    };
    return px;
}

test "texture encodings: .auto is the default and decides everything as before" {
    const formats = [_]gpu.Format{ .bgra8, .ycbcr420_8, .ycbcr420_10, .ycbcr422_10, .ycbcr444_10, .rgba16f };
    for (formats) |f| for ([_]?gpu.Lut{ null, invert }) |l| for ([_]gpu.Transfer{ .rec709, .srgb, .linear, .pq }) |tr| {
        const t: gpu.Texture = .{ .width = 1, .height = 1, .format = f, .lut = l, .source_lut = l, .transfer = tr };
        try testing.expectEqual(gpu.Encoding.auto, t.encoding);
        const before = f != .bgra8 or l != null;
        try testing.expectEqual(before, t.needsPost());
        const st = color.stage(t, color.sourceMode(f), false);
        try testing.expectEqual(color.sourceMode(f), st.mode);
        try testing.expectEqual(before, st.run);
        const u = color.uniforms(t, st.mode);
        try testing.expectEqual(@intFromBool(l != null), u.lut_enabled);
        try testing.expectEqual(@intFromBool(l != null), u.source_lut_enabled);
        // A Y'CbCr frame's encoding is its range, matrix and transfer.
        for ([_]gpu.Encoding{ .display_sdr, .surface_linear }) |e| {
            if (f == .bgra8 or f == .rgba16f) continue;
            var te = t;
            te.encoding = e;
            try testing.expectEqual(gpu.Encoding.auto, te.effectiveEncoding());
            try testing.expectEqual(t.needsPost(), te.needsPost());
            try testing.expectEqualSlices(u8, std.mem.asBytes(&u), std.mem.asBytes(&color.uniforms(te, color.stage(te, color.sourceMode(f), false).mode)));
        }
    };
}

test "texture encodings: passed through, a texture takes no LUT and no tone map" {
    for ([_]gpu.Format{ .bgra8, .rgba16f }) |f| {
        var t: gpu.Texture = .{ .width = 1, .height = 1, .format = f, .lut = invert, .source_lut = invert, .encoding = .display_sdr };
        try testing.expect(!t.needsPost());
        try testing.expectEqual(color.Stage{ .mode = 0, .run = false }, color.stage(t, color.sourceMode(f), false));
        // Sampled from sRGB storage: encoded again by mode 4, the codes back.
        try testing.expectEqual(color.Stage{ .mode = 4, .run = true }, color.stage(t, 3, true));
        try testing.expectEqualSlices(f32, &.{ 0.2, 0.4, 0.6 }, &color.applyLuts(t, .{ 0.2, 0.4, 0.6 }));
        t.encoding = .surface_linear;
        try testing.expect(t.needsPost());
        try testing.expectEqual(color.Stage{ .mode = 4, .run = true }, color.stage(t, color.sourceMode(f), false));
        const u = color.uniforms(t, 4);
        try testing.expectEqual(@as(u32, 4), u.source_mode);
        try testing.expectEqual(@as(u32, 0), u.lut_enabled);
        try testing.expectEqual(@as(u32, 0), u.source_lut_enabled);
    }
    // Mode 4 clips at SDR white and black, and only encodes in between.
    const out = color.surfaceLinearToSdr(.{ 2.5, -0.25, 0.18 });
    try testing.expectEqual(color.linearToSrgb(1), out[0]);
    try testing.expectApproxEqAbs(@as(f32, 1), out[0], 1e-6);
    try testing.expectEqual(@as(f32, 0), out[1]);
    try testing.expectEqual(color.linearToSrgb(0.18), out[2]);
}

test "texture encodings: the CPU's half floats, packed 10-bit RGB, and BGRA" {
    const gpa = testing.allocator;
    const lin = halfPixels(linearAt);
    const codes = halfPixels(codeAt);
    const plane = struct {
        fn of(px: []const u8) texture_cpu.Plane {
            return .{ .bytes = px.ptr, .width = n, .height = n, .stride = n * 8 };
        }
    }.of;
    const base: gpu.Texture = .{ .width = n, .height = n, .format = .rgba16f, .lut = invert, .tone_map = true };
    var t = base;
    t.encoding = .display_sdr;
    var shown = texture_cpu.fromPlanes(gpa, t, plane(&codes), null).?;
    defer shown.deinit(gpa);
    t.encoding = .surface_linear;
    var encoded = texture_cpu.fromPlanes(gpa, t, plane(&lin), null).?;
    defer encoded.deinit(gpa);
    for (0..n) |y| for (0..n) |x| {
        const c = codeAt(x, y);
        const l = linearAt(x, y);
        const e = color.surfaceLinearToSdr(.{ half(l[0]), half(l[1]), half(l[2]) });
        for (0..3) |k| {
            try testing.expectEqual(color.unorm8(half(c[k])), shown.bgra.pixels[(y * n + x) * 4 + 2 - k]);
            try testing.expectEqual(color.unorm8(e[k]), encoded.bgra.pixels[(y * n + x) * 4 + 2 - k]);
        }
        try testing.expectEqual(@as(u8, 255), encoded.bgra.pixels[(y * n + x) * 4 + 3]);
    };
    // Packed 10-bit: red low, alpha in the top two bits (and Metal's BGR form).
    const word: u32 = 1023 | (512 << 10) | (0 << 20) | (3 << 30);
    var src: [4]u8 = undefined;
    std.mem.writeInt(u32, &src, word, .little);
    var out: [8]u8 = undefined;
    for ([_]bool{ false, true }) |bgr| {
        texture_cpu.rgb10a2ToHalf(&src, 1, 1, 4, bgr, &out);
        var got: [4]f32 = undefined;
        for (0..4) |k| got[k] = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, out[k * 2 ..][0..2], .little))));
        try testing.expectEqual(@as(f32, if (bgr) 0 else 1), got[0]);
        try testing.expectApproxEqAbs(@as(f32, 512.0 / 1023.0), got[1], 1e-3);
        try testing.expectEqual(@as(f32, if (bgr) 1 else 0), got[2]);
        try testing.expectEqual(@as(f32, 1), got[3]);
    }
    // BGRA bytes: drawn as stored with their LUT ignored, or encoded.
    var bgra: [4 * 4]u8 = undefined;
    for (0..4) |i| bgra[i * 4 ..][0..4].* = .{ @intCast(i * 60), 128, 20, 255 };
    var tb: gpu.Texture = .{ .width = 2, .height = 2, .bgra = &bgra, .lut = invert, .encoding = .display_sdr };
    var as_stored = texture_cpu.resolve(gpa, tb).?;
    defer as_stored.deinit(gpa);
    try testing.expectEqualSlices(u8, &bgra, as_stored.bgra.pixels);
    tb.encoding = .surface_linear;
    var lin8 = texture_cpu.resolve(gpa, tb).?;
    defer lin8.deinit(gpa);
    try testing.expectEqual(color.unorm8(color.linearToSrgb(128.0 / 255.0)), lin8.bgra.pixels[1]);
}

// ── Metal and the CPU renderer, through a frame ──

const Scene = struct {
    source: ui.Texture,
    fn view(s: *Scene, c: *ui.Context) void {
        const root = ui.div(c).column().sizeFull();
        defer root.end();
        ui.texture(c, .{ .width = .{ .px = n }, .height = .{ .px = n } }, s.source, .{ 0, 0, 1, 1 }, 1);
    }
};

/// Draws `source` at a pixel a texel with Metal and on the CPU and checks
/// both against `want(x, y)`, and each other, within one 8-bit step.
fn expectDrawn(source: ui.Texture, comptime want: fn (usize, usize) [3]f32) !void {
    const gpa = testing.allocator;
    var s: Scene = .{ .source = source };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = n, .height = n, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    const cpu: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, shown.bytes.len), .width = shown.width, .height = shown.height };
    defer cpu.deinit(gpa);
    var pictures = t.text.images.pictures();
    pictures.textures = t.ctx.textures.items;
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, pictures, t.scale, t.theme.background);
    var worst: [3]f32 = .{ 0, 0, 0 };
    for (0..n) |y| for (0..n) |x| {
        const w = want(x, y);
        const g = shown.bytes[(y * shown.width + x) * 4 ..][0..4];
        const c = cpu.bytes[(y * cpu.width + x) * 4 ..][0..4];
        for (0..3) |k| {
            worst[0] = @max(worst[0], @abs(@as(f32, @floatFromInt(g[2 - k])) - w[k] * 255));
            worst[1] = @max(worst[1], @abs(@as(f32, @floatFromInt(c[2 - k])) - w[k] * 255));
            worst[2] = @max(worst[2], @abs(@as(f32, @floatFromInt(g[2 - k])) - @as(f32, @floatFromInt(c[2 - k]))));
        }
        try testing.expectEqual(@as(u8, 255), g[3]);
        try testing.expectEqual(@as(u8, 255), c[3]);
    };
    if (worst[0] > 1 or worst[1] > 1 or worst[2] > 1) std.debug.print("worst: Metal {d:.3}, CPU {d:.3}, Metal vs CPU {d:.3} steps\n", .{ worst[0], worst[1], worst[2] });
    try testing.expect(worst[0] <= 1 and worst[1] <= 1 and worst[2] <= 1);
}

fn encodedAt(x: usize, y: usize) [3]f32 {
    const l = linearAt(x, y);
    return color.surfaceLinearToSdr(.{ half(l[0]), half(l[1]), half(l[2]) });
}

fn codeHalfAt(x: usize, y: usize) [3]f32 {
    const c = codeAt(x, y);
    return .{ half(c[0]), half(c[1]), half(c[2]) };
}

extern "c" fn CVPixelBufferCreate(allocator: ?*anyopaque, width: usize, height: usize, format: u32, attrs: ?*anyopaque, out: *?*anyopaque) i32;
extern "c" fn CVPixelBufferLockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferUnlockBaseAddress(pb: *anyopaque, flags: u64) i32;
extern "c" fn CVPixelBufferGetBaseAddress(pb: *anyopaque) ?[*]u8;
extern "c" fn CVPixelBufferGetBytesPerRow(pb: *anyopaque) usize;
extern "c" fn CFRelease(obj: *anyopaque) void;
extern "c" const kCVPixelBufferMetalCompatibilityKey: *anyopaque;
extern "c" const kCVPixelBufferIOSurfacePropertiesKey: *anyopaque;

/// A Metal-compatible 'RGhA' buffer of `px` (half floats, `n` × `n`).
fn halfBuffer(px: []const u8) !*anyopaque {
    const objc = @import("../objc.zig");
    const keys = [2]*anyopaque{ kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey };
    const values = [2]objc.Object{ objc.msg(objc.Object, objc.class("NSNumber"), "numberWithBool:", .{objc.YES}), objc.msg(objc.Object, objc.class("NSDictionary"), "dictionary", .{}) };
    const attrs = objc.msg(objc.Object, objc.class("NSDictionary"), "dictionaryWithObjects:forKeys:count:", .{ @as(*const anyopaque, &values), @as(*const anyopaque, &keys), @as(objc.NSUInteger, 2) });
    var pb: ?*anyopaque = null;
    if (CVPixelBufferCreate(null, n, n, std.mem.readInt(u32, "RGhA", .big), @ptrCast(attrs), &pb) != 0) return error.SkipZigTest;
    _ = CVPixelBufferLockBaseAddress(pb.?, 0);
    defer _ = CVPixelBufferUnlockBaseAddress(pb.?, 0);
    const base = CVPixelBufferGetBaseAddress(pb.?).?;
    const stride = CVPixelBufferGetBytesPerRow(pb.?);
    for (0..n) |y| @memcpy(base[y * stride ..][0 .. n * 8], px[y * n * 8 ..][0 .. n * 8]);
    return pb.?;
}

test "texture encodings: linear light for the surface is clipped and encoded, not tone mapped, on Metal as on the CPU" {
    if (text.portable) return error.SkipZigTest;
    const px = halfPixels(linearAt);
    const pb = try halfBuffer(&px);
    defer CFRelease(pb);
    var tex = pixel_buffer.texture(pb);
    try testing.expectEqual(gpu.Format.rgba16f, tex.format);
    tex.encoding = .surface_linear;
    tex.lut = invert;
    tex.source_lut = invert;
    inline for (.{ true, false }) |tone| {
        tex.tone_map = tone;
        try expectDrawn(tex, encodedAt);
    }
}

test "texture encodings: display codes in half floats are drawn as stored, their LUT ignored" {
    if (text.portable) return error.SkipZigTest;
    const px = halfPixels(codeAt);
    const pb = try halfBuffer(&px);
    defer CFRelease(pb);
    var tex = pixel_buffer.texture(pb);
    tex.encoding = .display_sdr;
    tex.lut = invert;
    try expectDrawn(tex, codeHalfAt);
}

/// An app's shared MTLTexture of pixel format `pf`, `n` × `n`, holding
/// `bytes` (`row` bytes a row).
fn appTexture(pf: usize, bytes: []const u8, row: usize) !*anyopaque {
    const objc = @import("../objc.zig");
    const device: objc.Object = @ptrCast(ui.metalDevice() orelse return error.SkipZigTest);
    const desc = objc.msg(objc.Object, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ @as(objc.NSUInteger, pf), @as(objc.NSUInteger, n), @as(objc.NSUInteger, n), objc.NO });
    objc.msg(void, desc, "setUsage:", .{@as(objc.NSUInteger, 1)});
    objc.msg(void, desc, "setStorageMode:", .{@as(objc.NSUInteger, 0)});
    const tex = objc.msg(?objc.Object, device, "newTextureWithDescriptor:", .{desc}) orelse return error.SkipZigTest;
    const Region = extern struct { x: usize, y: usize, z: usize, w: usize, h: usize, d: usize };
    objc.msg(void, tex, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ Region{ .x = 0, .y = 0, .z = 0, .w = n, .h = n, .d = 1 }, @as(objc.NSUInteger, 0), @as(*const anyopaque, bytes.ptr), @as(objc.NSUInteger, row) });
    return @ptrCast(tex);
}

fn code10At(x: usize, y: usize) [3]f32 {
    const c = codeAt(x, y);
    return .{ @round(c[0] * 1023) / 1023, @round(c[1] * 1023) / 1023, @round(c[2] * 1023) / 1023 };
}

test "texture encodings: an app's RGBA16F and RGB10A2 textures of display codes are sampled as they are" {
    if (text.portable) return error.SkipZigTest;
    const objc = @import("../objc.zig");
    const codes = halfPixels(codeAt);
    const f16_tex = try appTexture(115, &codes, n * 8);
    defer objc.release(@ptrCast(f16_tex));
    var packed_px: [n * n * 4]u8 = undefined;
    for (0..n) |y| for (0..n) |x| {
        const c = code10At(x, y);
        var word: u32 = 3 << 30;
        for (0..3) |k| word |= @as(u32, @intFromFloat(c[k] * 1023)) << @intCast(k * 10);
        std.mem.writeInt(u32, packed_px[(y * n + x) * 4 ..][0..4], word, .little);
    };
    const packed_tex = try appTexture(90, &packed_px, n * 4);
    defer objc.release(@ptrCast(packed_tex));
    try expectDrawn(.{ .width = n, .height = n, .mtl_texture = f16_tex, .encoding = .display_sdr, .lut = invert }, codeHalfAt);
    try expectDrawn(.{ .width = n, .height = n, .mtl_texture = packed_tex, .encoding = .display_sdr }, code10At);
    // Linear light in an app's RGBA16F texture: encoded by mode 4.
    const lin = halfPixels(linearAt);
    const lin_tex = try appTexture(115, &lin, n * 8);
    defer objc.release(@ptrCast(lin_tex));
    try expectDrawn(.{ .width = n, .height = n, .mtl_texture = lin_tex, .encoding = .surface_linear, .lut = invert }, encodedAt);
}

/// Draws `source` (`n` × `n`, in a window 8 pixels wider) with Metal and on
/// the CPU: every channel, alpha's effect included, within one 8-bit step
/// of the other. A texel transparent in column 0 must show the background
/// (the pixel right of the texture) on both.
fn expectSameOverBackground(source: ui.Texture) !void {
    const gpa = testing.allocator;
    var s: Scene = .{ .source = source };
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&s, Scene.view), .{ .width = n + 8, .height = n, .scale = 1 });
    defer t.deinit();
    t.settle(0.1);
    const shown = try t.render(gpa);
    defer shown.deinit(gpa);
    const cpu: gpu.Pixels = .{ .bytes = try gpa.alloc(u8, shown.bytes.len), .width = shown.width, .height = shown.height };
    defer cpu.deinit(gpa);
    var pictures = t.text.images.pictures();
    pictures.textures = t.ctx.textures.items;
    raster.draw(cpu, t.instances.items, .{ .pixels = &.{}, .size = 0 }, pictures, t.scale, t.theme.background);
    var worst: f32 = 0;
    for (0..n) |y| for (0..n) |x| for (0..4) |k| {
        const i = (y * shown.width + x) * 4 + k;
        worst = @max(worst, @abs(@as(f32, @floatFromInt(shown.bytes[i])) - @as(f32, @floatFromInt(cpu.bytes[i]))));
    };
    if (worst > 1) std.debug.print("worst: Metal vs CPU {d:.3} steps\n", .{worst});
    try testing.expect(worst <= 1);
    const bg = (n + 4) * 4;
    for (0..n) |y| for (0..3) |k| {
        const row = y * shown.width * 4;
        try testing.expectEqual(shown.bytes[row + bg + k], shown.bytes[row + k]);
        try testing.expectEqual(cpu.bytes[row + bg + k], cpu.bytes[row + k]);
    };
}

test "texture encodings: alpha is kept, through an sRGB pixel format and through mode 4, on Metal as on the CPU" {
    if (text.portable) return error.SkipZigTest;
    const objc = @import("../objc.zig");
    // Premultiplied display codes: column 0 transparent, then alpha rising.
    var bgra: [n * n * 4]u8 = undefined;
    for (0..n) |y| for (0..n) |x| {
        const a: u32 = @intCast(x * 255 / (n - 1));
        const c = codeAt(x, y);
        var px: [4]u8 = undefined;
        for (0..3) |k| px[2 - k] = @intCast(@as(u32, color.unorm8(c[k])) * a / 255);
        px[3] = @intCast(a);
        bgra[(y * n + x) * 4 ..][0..4].* = px;
    };
    const srgb_tex = try appTexture(81, &bgra, n * 4);
    defer objc.release(@ptrCast(srgb_tex));
    try expectSameOverBackground(.{ .width = n, .height = n, .mtl_texture = srgb_tex, .encoding = .display_sdr, .lut = invert });
    try expectSameOverBackground(.{ .width = n, .height = n, .mtl_texture = srgb_tex, .encoding = .surface_linear });
    // Linear light, premultiplied, in half floats: mode 4 keeps its alpha.
    var lin: [n * n * 8]u8 = undefined;
    for (0..n) |y| for (0..n) |x| {
        const a = @as(f32, @floatFromInt(x)) / (n - 1);
        const l = linearAt(x, y);
        const v = [4]f32{ l[0] * a, l[1] * a, l[2] * a, a };
        for (0..4) |k| std.mem.writeInt(u16, lin[(y * n + x) * 8 + k * 2 ..][0..2], @bitCast(@as(f16, @floatCast(v[k]))), .little);
    };
    const lin_tex = try appTexture(115, &lin, n * 8);
    defer objc.release(@ptrCast(lin_tex));
    try expectSameOverBackground(.{ .width = n, .height = n, .mtl_texture = lin_tex, .encoding = .surface_linear });
}

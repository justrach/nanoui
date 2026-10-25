//! Pictures the UI shows (`ui.image`): decoded once from the bytes the app
//! gives (ImageIO on macOS and iOS, nanoui's PNG decoder elsewhere), scaled to at
//! most `max_side` pixels, and packed into one BGRA atlas the renderers
//! sample (premultiplied). Made on the first picture; when full, emptied
//! and packed again, and the frame painted again.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const png_decode = @import("png_decode.zig");

const portable = build_options.portable or !(builtin.os.tag == .macos or builtin.os.tag == .ios);
const imageio = if (portable) void else @import("image.zig");

pub const size: u32 = 2048;
/// The longest side a picture keeps.
pub const max_side: u32 = 1024;
const pad: u32 = 1;

/// NANOUI_DEBUG_IMAGES set: say where each picture is packed.
fn debug() bool {
    return std.c.getenv("NANOUI_DEBUG_IMAGES") != null;
}

pub const Entry = struct {
    uv: [4]f32,
    /// The picture's own size in pixels (before scaling down).
    width: u32,
    height: u32,
};

/// A picture decoded and scaled down, kept so packing it again is a copy.
pub const Decoded = struct {
    /// Its own size in pixels.
    width: u32,
    height: u32,
    /// The scaled pixels, `w` × `h`.
    w: u32,
    h: u32,
    bgra: []u8,
};

/// Decoded pictures kept at most (the oldest go first).
const max_kept_bytes = 64 * 1024 * 1024;

/// Where packed pictures go instead of `pixels`: the GPU's texture, so no
/// copy of the atlas is kept in memory (a window on Metal).
pub const Sink = struct {
    ctx: *anyopaque,
    upload: *const fn (ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, bgra: []const u8) void,
};

pub const SvgSpec = struct {
    width: u32,
    height: u32,
    /// `currentColor`, straight RGBA.
    current: [4]f32,
};

pub const Images = struct {
    gpa: std.mem.Allocator,
    /// Every picture decoded, by key (null: it can't be).
    decoded: std.AutoArrayHashMapUnmanaged(u64, ?Decoded) = .empty,
    kept_bytes: usize = 0,
    /// Rows of `pixels` changed since the GPU's copy was made.
    dirty: ?[2]u32 = null,
    sink: ?Sink = null,
    /// BGRA, `size` × `size`; empty until a picture comes.
    pixels: []u8 = &.{},
    entries: std.AutoHashMapUnmanaged(u64, ?Entry) = .empty,
    /// Pictures drawn from SVG (`ui.svg`), by key: the size and color they
    /// are drawn at, so they are drawn again the same if they're let go.
    svgs: std.AutoHashMapUnmanaged(u64, SvgSpec) = .empty,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    /// Changes whenever the pixels do, for the GPU's copy.
    generation: u64 = 0,
    /// Bumped when it starts over: a picture may now be where another was.
    resets: u64 = 0,
    /// Emptied during a frame: its earlier pictures must be painted again.
    reset_during_frame: bool = false,

    pub fn deinit(im: *Images) void {
        if (im.pixels.len > 0) im.gpa.free(im.pixels);
        im.entries.deinit(im.gpa);
        im.svgs.deinit(im.gpa);
        for (im.decoded.values()) |d| if (d) |x| im.gpa.free(x.bgra);
        im.decoded.deinit(im.gpa);
    }

    /// The picture `k` decoded (from `bytes` the first time), or null.
    /// Sizing a picture needs only this: it is packed when drawn.
    pub fn info(im: *Images, k: u64, bytes: []const u8) ?Decoded {
        if (im.decoded.get(k)) |d| return d;
        const d = (if (im.svgs.get(k)) |spec| drawSvg(im.gpa, bytes, spec) else load(im.gpa, bytes)) catch |e| blk: {
            // Not drawn from now on: say why, once.
            std.log.warn("nanoui: picture {x} ({d} bytes) can't be decoded: {s}", .{ k, bytes.len, @errorName(e) });
            break :blk null;
        };
        if (d) |x| im.kept_bytes += x.bgra.len;
        im.decoded.put(im.gpa, k, d) catch {
            if (d) |x| im.gpa.free(x.bgra);
            return null;
        };
        // Over budget: the oldest go (not this one); they decode again if
        // they are drawn again.
        var i: usize = 0;
        while (im.kept_bytes > max_kept_bytes and i + 1 < im.decoded.count()) {
            if (im.decoded.values()[i]) |x| {
                im.kept_bytes -= x.bgra.len;
                im.gpa.free(x.bgra);
                const old = im.decoded.keys()[i];
                im.decoded.orderedRemoveAt(i);
                _ = im.entries.remove(old);
            } else i += 1;
        }
        return d;
    }

    /// The SVG document `bytes` drawn at `spec`'s size and color, as
    /// picture `k`: decoded once, then packed when drawn like any other.
    pub fn infoSvg(im: *Images, k: u64, bytes: []const u8, spec: SvgSpec) ?Decoded {
        im.svgs.put(im.gpa, k, spec) catch return null;
        return im.info(k, bytes);
    }

    /// The atlas as the CPU renderer reads it.
    pub fn pictures(im: *const Images) @import("raster.zig").Pictures {
        return .{ .pixels = im.pixels, .size = if (im.pixels.len > 0) size else 0 };
    }

    pub fn key(name: []const u8) u64 {
        return std.hash.Wyhash.hash(0x1a9e, name);
    }

    /// The picture `k` in the atlas, packing it (decoding `bytes` the
    /// first time) when it is not there; null if it can't be decoded.
    pub fn get(im: *Images, k: u64, bytes: []const u8) ?Entry {
        if (im.entries.get(k)) |e| return e;
        const d = im.info(k, bytes) orelse return null;
        const e = im.pack(d) catch |err| {
            std.log.warn("nanoui: picture {x} can't be packed: {s}", .{ k, @errorName(err) });
            return null;
        };
        im.entries.put(im.gpa, k, e) catch {};
        if (debug()) std.log.warn("nanoui: packed {x} {d}x{d} at uv {d:.4},{d:.4} (shelf {d},{d}; resets {d}; sink {})", .{ k, d.w, d.h, e.uv[0], e.uv[1], im.shelf_x, im.shelf_y, im.resets, im.sink != null });
        return e;
    }

    fn pack(im: *Images, d: Decoded) !Entry {
        if (im.pixels.len == 0 and im.sink == null) {
            im.pixels = try im.gpa.alloc(u8, size * size * 4);
            @memset(im.pixels, 0);
        }
        if (!im.fits(d.w, d.h)) {
            im.empty();
            im.reset_during_frame = true;
        }
        if (im.shelf_x + d.w + pad > size) {
            im.shelf_y += im.shelf_h + pad;
            im.shelf_x = 0;
            im.shelf_h = 0;
        }
        const x = im.shelf_x;
        const y = im.shelf_y;
        if (im.sink) |sk| sk.upload(sk.ctx, x, y, d.w, d.h, d.bgra);
        // The CPU's copy too, while there is one (pictures packed before the
        // sink came): its changed rows are copied to the GPU after, and
        // without this one they'd draw over it.
        if (im.pixels.len > 0) for (0..d.h) |row| {
            const src = d.bgra[row * d.w * 4 ..][0 .. d.w * 4];
            @memcpy(im.pixels[((y + row) * size + x) * 4 ..][0 .. d.w * 4], src);
        };
        im.shelf_x += d.w + pad;
        im.shelf_h = @max(im.shelf_h, d.h);
        im.generation +%= 1;
        im.dirty = if (im.dirty) |r| .{ @min(r[0], y), @max(r[1], y + d.h) } else .{ y, y + d.h };
        const s: f32 = @floatFromInt(size);
        return .{
            .uv = .{ @as(f32, @floatFromInt(x)) / s, @as(f32, @floatFromInt(y)) / s, @as(f32, @floatFromInt(x + d.w)) / s, @as(f32, @floatFromInt(y + d.h)) / s },
            .width = d.width,
            .height = d.height,
        };
    }

    fn fits(im: *const Images, w: u32, h: u32) bool {
        if (im.shelf_x + w + pad <= size) return im.shelf_y + @max(im.shelf_h, h) <= size;
        return im.shelf_y + im.shelf_h + pad + h <= size;
    }

    fn empty(im: *Images) void {
        if (debug()) std.log.warn("nanoui: image atlas full: starting over", .{});
        im.entries.clearRetainingCapacity();
        im.shelf_x = 0;
        im.shelf_y = 0;
        im.shelf_h = 0;
        im.resets +%= 1;
    }
};

fn drawSvg(gpa: std.mem.Allocator, bytes: []const u8, spec: SvgSpec) !Decoded {
    const px = try @import("svg.zig").render(gpa, bytes, .{ .width = spec.width, .height = spec.height, .current = spec.current });
    return .{ .width = spec.width, .height = spec.height, .w = spec.width, .h = spec.height, .bgra = px };
}

const Raw = struct { width: u32, height: u32, bgra: []u8 };

/// Decodes and scales a picture to keep.
fn load(gpa: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (!portable) {
        const f = try imageio.decodeFit(gpa, bytes, max_side);
        return .{ .width = f.width, .height = f.height, .w = f.w, .h = f.h, .bgra = f.bgra };
    }
    const d = try decode(gpa, bytes);
    const scaled = fit(gpa, d.bgra, d.width, d.height) catch |e| {
        gpa.free(d.bgra);
        return e;
    };
    if (scaled.bgra.ptr != d.bgra.ptr) gpa.free(d.bgra);
    return .{ .width = d.width, .height = d.height, .w = scaled.w, .h = scaled.h, .bgra = scaled.bgra };
}

fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Raw {
    if (!portable) {
        const d = try imageio.decode(gpa, bytes);
        return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
    }
    const d = try png_decode.decode(gpa, bytes);
    return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
}

const Scaled = struct { w: u32, h: u32, bgra: []u8 };

/// The picture within `max_side`, averaging the pixels each new one covers.
fn fit(gpa: std.mem.Allocator, bgra: []u8, w: u32, h: u32) !Scaled {
    const longest = @max(w, h);
    if (longest <= max_side) return .{ .w = w, .h = h, .bgra = bgra };
    const nw = @max(1, w * max_side / longest);
    const nh = @max(1, h * max_side / longest);
    const out = try gpa.alloc(u8, nw * nh * 4);
    for (0..nh) |y| {
        const sy0 = y * h / nh;
        const sy1 = @max(sy0 + 1, (y + 1) * h / nh);
        for (0..nw) |x| {
            const sx0 = x * w / nw;
            const sx1 = @max(sx0 + 1, (x + 1) * w / nw);
            var acc: [4]u32 = .{ 0, 0, 0, 0 };
            for (sy0..sy1) |sy| for (sx0..sx1) |sx| {
                const p = bgra[(sy * w + sx) * 4 ..][0..4];
                for (0..4) |k| acc[k] += p[k];
            };
            const n: u32 = @intCast((sy1 - sy0) * (sx1 - sx0));
            for (0..4) |k| out[(y * nw + x) * 4 + k] = @intCast(acc[k] / n);
        }
    }
    return .{ .w = nw, .h = nh, .bgra = out };
}

test "pictures pack, scale down and come back by key" {
    const gpa = std.testing.allocator;
    var im: Images = .{ .gpa = gpa };
    defer im.deinit();
    // A 2×1 PNG, red then half-transparent blue.
    var px = [_]u8{ 0, 0, 255, 255, 128, 0, 0, 128 };
    const bytes = try @import("png.zig").encode(gpa, .{ .bytes = &px, .width = 2, .height = 1 });
    defer gpa.free(bytes);
    const e = im.get(Images.key("a.png"), bytes).?;
    try std.testing.expectEqual(@as(u32, 2), e.width);
    try std.testing.expectEqualSlices(u8, &px, im.pixels[0..8]);
    const gen = im.generation;
    _ = im.get(Images.key("a.png"), bytes);
    try std.testing.expectEqual(gen, im.generation);
    try std.testing.expect(im.get(Images.key("bad"), "not an image") == null);
    // Too big: averaged down to the longest side.
    const big = try gpa.alloc(u8, 2048 * 2 * 4);
    defer gpa.free(big);
    @memset(big, 200);
    const s = try fit(gpa, big, 2048, 2);
    defer gpa.free(s.bgra);
    try std.testing.expectEqual(@as(u32, 1024), s.w);
    try std.testing.expectEqual(@as(u32, 1), s.h);
    try std.testing.expectEqual(@as(u8, 200), s.bgra[0]);
}

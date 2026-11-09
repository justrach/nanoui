//! Pictures the UI shows (`ui.image`): decoded once from encoded bytes, or
//! copied once from caller-held pixels, scaled to the pixels a box needs, at
//! most `Limits.picture_side`, and packed into one BGRA atlas the renderers
//! sample (premultiplied). Made on the first picture; when full, pictures no
//! longer drawn leave and the rest are packed again, the frame painted again.
//! An app that shows large pictures asks for more (`Limits`): the atlas then
//! doubles when what one frame shows doesn't fit, so only what's on screen costs
//! memory, on every renderer.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const png_decode = @import("png_decode.zig");
const jpeg_decode = @import("jpeg_decode.zig");
const gif_decode = @import("gif_decode.zig");

const portable = build_options.portable or !(builtin.os.tag == .macos or builtin.os.tag == .ios);
const imageio = if (portable) void else @import("image.zig");

/// The atlas's side when nothing asks for more.
pub const size: u32 = 2048;
/// The longest side a picture keeps when nothing asks for more.
pub const max_side: u32 = 1024;
const pad: u32 = 1;

pub const Entry = struct {
    uv: [4]f32,
    /// The picture's own size in pixels (before scaling down).
    width: u32,
    height: u32,
};

/// A picture decoded or copied and scaled down, kept so packing it again is a copy.
pub const Decoded = struct {
    /// Its own size in pixels.
    width: u32,
    height: u32,
    /// The scaled pixels, `w` × `h`.
    w: u32,
    h: u32,
    bgra: []u8,
};

/// Where a picture comes from: encoded bytes, or pixels the app already has.
pub const Source = union(enum) {
    /// An encoded picture, kept by the caller while it is shown.
    encoded: []const u8,
    /// Caller-held pixels, kept while the picture is shown.
    pixels: Pixels,

    /// BGRA8, premultiplied, top row first; 0 stride means `width * 4`.
    pub const Pixels = struct {
        bgra: []const u8,
        width: u32,
        height: u32,
        stride: usize = 0,
    };
};

/// Decoded pictures kept at most (the oldest go first).
const max_kept_bytes = 12 * 1024 * 1024;
/// Larger pictures are refused rather than copied (64 megapixels).
const max_pixels: u64 = 64 * 1024 * 1024;

/// What pictures may cost. The defaults suit an app's icons and thumbnails; a
/// browser shows heroes a window wide on a dense screen and sets its own.
pub const Limits = struct {
    /// The longest side a picture keeps, in pixels.
    picture_side: u32 = max_side,
    /// How far the atlas may double, when a frame's pictures don't fit.
    atlas_side: u32 = size,
    /// Decoded pixels kept, so packing a picture again is a copy, not a decode.
    decoded_bytes: usize = max_kept_bytes,
};

/// Where packed pictures go instead of `pixels`: the GPU's texture, so no
/// copy of the atlas is kept in memory (a window on Metal).
pub const Sink = struct {
    ctx: *anyopaque,
    upload: *const fn (ctx: *anyopaque, x: u32, y: u32, w: u32, h: u32, bgra: []const u8, atlas_side: u32) void,
};

pub const SizedKey = struct {
    key: u64,
    side: u32,
};

pub const Info = struct {
    width: u32,
    height: u32,
};

const KeptEntry = struct {
    entry: ?Entry,
    last_frame: u64,
};

pub const SvgSpec = struct {
    width: u32,
    height: u32,
    /// `currentColor`, straight RGBA.
    current: [4]f32,
};

pub const Images = struct {
    gpa: std.mem.Allocator,
    limits: Limits = .{},
    /// The largest texture the device takes (a renderer lowers it).
    device_side: u32 = 16384,
    /// The atlas's side now.
    side: u32 = size,
    /// Header dimensions per picture key (null: invalid image).
    headers: std.AutoHashMapUnmanaged(u64, ?Info) = .empty,
    /// Every picture decoded, by (key, target_side) (null: it can't be).
    decoded: std.AutoArrayHashMapUnmanaged(SizedKey, ?Decoded) = .empty,
    kept_bytes: usize = 0,
    /// Rows of `pixels` changed since the GPU's copy was made.
    dirty: ?[2]u32 = null,
    sink: ?Sink = null,
    /// BGRA, `side` × `side`; empty until a picture comes.
    pixels: []u8 = &.{},
    entries: std.AutoHashMapUnmanaged(SizedKey, KeptEntry) = .empty,
    frame: u64 = 0,
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
    decodes_left: u32 = 8,
    wants_frame: bool = false,

    pub fn deinit(im: *Images) void {
        if (im.pixels.len > 0) im.gpa.free(im.pixels);
        im.headers.deinit(im.gpa);
        im.entries.deinit(im.gpa);
        im.svgs.deinit(im.gpa);
        im.trimDecoded();
        im.decoded.deinit(im.gpa);
    }

    pub fn trimDecoded(im: *Images) void {
        for (im.decoded.values()) |d| if (d) |x| im.gpa.free(x.bgra);
        im.decoded.clearRetainingCapacity();
        im.kept_bytes = 0;
    }

    /// Called at the start of `paint`: compacts stale entries before any
    /// instance is emitted when the atlas is filling up.
    pub fn beginPaint(im: *Images) void {
        im.frame +%= 1;
        im.decodes_left = 8;
        im.wants_frame = false;
        if (im.shelf_y + im.shelf_h > im.side * 3 / 4 and im.hasStale()) im.repackLive();
    }

    /// The picture `k`'s native dimensions, from its source the first time.
    /// Sizing a picture needs only this: it is decoded and packed when drawn.
    pub fn info(im: *Images, k: u64, src: Source) ?Info {
        switch (src) {
            .pixels => |p| return if (pixelsOk(p)) .{ .width = p.width, .height = p.height } else null,
            .encoded => |bytes| {
                if (im.headers.get(k)) |h| return h;
                if (im.headers.count() >= 2048) im.headers.clearRetainingCapacity();
                const h = probeHeader(bytes);
                im.headers.put(im.gpa, k, h) catch {};
                return h;
            },
        }
    }

    fn getDecoded(im: *Images, sk: SizedKey, src: Source) ?Decoded {
        if (im.decoded.get(sk)) |d| return d;
        const d: ?Decoded = switch (src) {
            .encoded => |bytes| if (im.svgs.get(sk.key)) |spec| drawSvg(im.gpa, bytes, spec) catch null else load(im.gpa, bytes, sk.side) catch null,
            .pixels => |p| if (pixelsOk(p)) loadPixels(im.gpa, p, sk.side) catch null else null,
        };
        if (d) |x| im.kept_bytes += x.bgra.len;
        im.decoded.put(im.gpa, sk, d) catch {
            if (d) |x| im.gpa.free(x.bgra);
            return null;
        };
        // Over budget: the oldest go (not this one); they decode again if
        // they are drawn again.
        var i: usize = 0;
        while (im.kept_bytes > im.limits.decoded_bytes and i + 1 < im.decoded.count()) {
            if (im.decoded.values()[i]) |x| {
                // What's in the atlas stays there; only packing it again
                // would need it decoded again.
                im.kept_bytes -= x.bgra.len;
                im.gpa.free(x.bgra);
                im.decoded.orderedRemoveAt(i);
            } else i += 1;
        }
        return d;
    }

    /// The SVG document `bytes` drawn at `spec`'s size and color, as
    /// picture `k`: decoded once, then packed when drawn like any other.
    pub fn infoSvg(im: *Images, k: u64, bytes: []const u8, spec: SvgSpec) ?Decoded {
        // A document is drawn at the size asked, not one fitted to the side a
        // box wants: its key alone finds it.
        const longest = @max(spec.width, spec.height);
        var at = spec;
        if (longest > im.pictureLimit()) {
            at.width = @max(1, @as(u32, @intCast(@as(u64, spec.width) * im.pictureLimit() / longest)));
            at.height = @max(1, @as(u32, @intCast(@as(u64, spec.height) * im.pictureLimit() / longest)));
        }
        im.svgs.put(im.gpa, k, at) catch return null;
        return im.getDecoded(.{ .key = k, .side = 0 }, .{ .encoded = bytes });
    }

    /// The atlas as the CPU renderer reads it.
    pub fn pictures(im: *const Images) @import("raster.zig").Pictures {
        return .{ .pixels = im.pixels, .size = if (im.pixels.len > 0) im.side else 0 };
    }

    pub fn key(name: []const u8) u64 {
        return std.hash.Wyhash.hash(0x1a9e, name);
    }

    /// The picture `k` in the atlas at `target_px`, packing it from its source
    /// the first time. The first source at a size is kept: new content needs a
    /// new key.
    pub fn get(im: *Images, k: u64, src: Source, target_px: u32) ?Entry {
        const sk: SizedKey = .{ .key = k, .side = im.sideFor(k, target_px) };
        if (im.entries.getPtr(sk)) |ke| {
            ke.last_frame = im.frame;
            return ke.entry;
        }
        if (!im.decoded.contains(sk)) {
            if (im.decodes_left == 0) {
                im.wants_frame = true;
                return null;
            }
            im.decodes_left -= 1;
        }
        const d = im.getDecoded(sk, src) orelse {
            im.entries.put(im.gpa, sk, .{ .entry = null, .last_frame = im.frame }) catch {};
            return null;
        };
        if (!im.fits(d.w, d.h)) im.makeRoom(d.w, d.h);
        const e = im.pack(d) catch return null;
        im.entries.put(im.gpa, sk, .{ .entry = e, .last_frame = im.frame }) catch {};
        return e;
    }

    fn pictureLimit(im: *const Images) u32 {
        return @min(im.limits.picture_side, im.atlasLimit());
    }

    fn atlasLimit(im: *const Images) u32 {
        return @min(im.limits.atlas_side, im.device_side);
    }

    /// The side a picture is kept at for a box wanting `target_px`: large ones
    /// in steps, or resizing a window would decode one again each frame; its
    /// own size once that's near, since nothing is sharper.
    fn sideFor(im: *const Images, k: u64, target_px: u32) u32 {
        if (im.svgs.contains(k)) return 0;
        const limit = im.pictureLimit();
        const s = std.math.clamp(target_px, 1, limit);
        if (s <= 512) return s;
        const stepped = @min(limit, std.mem.alignForward(u32, s, 64));
        if (im.headers.get(k)) |h| if (h) |i| {
            const own = @max(i.width, i.height);
            if (stepped / 4 * 5 >= own) return @min(own, limit);
        };
        return stepped;
    }

    /// Whether the atlas holds a picture no longer being drawn.
    fn hasStale(im: *const Images) bool {
        var it = im.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.entry != null and kv.value_ptr.last_frame + 1 < im.frame) return true;
        }
        return false;
    }

    /// Room for a picture: pictures no longer drawn leave; if that's not
    /// enough the atlas doubles while it may. At its limit, `pack` starts over.
    fn makeRoom(im: *Images, w: u32, h: u32) void {
        if (@max(w, h) <= im.side and im.hasStale()) {
            im.repackLive();
            if (im.fits(w, h)) return;
        }
        const limit = im.atlasLimit();
        var next = im.side;
        while (next < limit and (next < @max(w, h) or next == im.side)) next *= 2;
        next = @min(next, limit);
        if (next > im.side) {
            if (im.pixels.len > 0) im.gpa.free(im.pixels);
            im.pixels = &.{};
            im.side = next;
            im.repackLive();
            if (!im.fits(w, h)) im.makeRoom(w, h);
            return;
        }
        if (@max(w, h) > im.side) return;
        im.repackLive();
    }

    /// Evicts entries not drawn in the current or previous frame and repacks
    /// live ones from their cached decoded pixels.
    fn repackLive(im: *Images) void {
        var live: std.ArrayList(SizedKey) = .empty;
        defer live.deinit(im.gpa);
        var same_frame = false;
        var it = im.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.entry == null) continue;
            if (kv.value_ptr.last_frame == im.frame) same_frame = true;
            if (kv.value_ptr.last_frame + 1 >= im.frame) live.append(im.gpa, kv.key_ptr.*) catch {};
        }
        im.empty();
        if (same_frame) im.reset_during_frame = true;
        for (live.items) |sk| {
            const d = (im.decoded.get(sk) orelse continue) orelse continue;
            if (!im.fits(d.w, d.h)) break;
            const e = im.pack(d) catch break;
            im.entries.put(im.gpa, sk, .{ .entry = e, .last_frame = im.frame }) catch break;
        }
    }
    fn pack(im: *Images, d: Decoded) !Entry {
        if (im.pixels.len == 0 and im.sink == null) {
            im.pixels = try im.gpa.alloc(u8, @as(usize, im.side) * im.side * 4);
            @memset(im.pixels, 0);
        }
        // Larger than the atlas may grow to: it can't be drawn.
        if (d.w > im.side or d.h > im.side) return error.TooLarge;
        if (!im.fits(d.w, d.h)) {
            im.empty();
            im.reset_during_frame = true;
        }
        if (im.shelf_x + d.w + pad > im.side) {
            im.shelf_y += im.shelf_h + pad;
            im.shelf_x = 0;
            im.shelf_h = 0;
        }
        const x = im.shelf_x;
        const y = im.shelf_y;
        if (im.sink) |sk| {
            sk.upload(sk.ctx, x, y, d.w, d.h, d.bgra, im.side);
        } else for (0..d.h) |row| {
            const src = d.bgra[row * d.w * 4 ..][0 .. d.w * 4];
            @memcpy(im.pixels[((y + row) * im.side + x) * 4 ..][0 .. d.w * 4], src);
        }
        im.shelf_x += d.w + pad;
        im.shelf_h = @max(im.shelf_h, d.h);
        im.generation +%= 1;
        im.dirty = if (im.dirty) |r| .{ @min(r[0], y), @max(r[1], y + d.h) } else .{ y, y + d.h };
        const s: f32 = @floatFromInt(im.side);
        return .{
            .uv = .{ @as(f32, @floatFromInt(x)) / s, @as(f32, @floatFromInt(y)) / s, @as(f32, @floatFromInt(x + d.w)) / s, @as(f32, @floatFromInt(y + d.h)) / s },
            .width = d.width,
            .height = d.height,
        };
    }

    fn fits(im: *const Images, w: u32, h: u32) bool {
        if (w > im.side) return false;
        if (im.shelf_x + w + pad <= im.side) return im.shelf_y + @max(im.shelf_h, h) <= im.side;
        return im.shelf_y + im.shelf_h + pad + h <= im.side;
    }

    fn empty(im: *Images) void {
        im.entries.clearRetainingCapacity();
        im.shelf_x = 0;
        im.shelf_y = 0;
        im.shelf_h = 0;
        im.resets +%= 1;
    }
};

/// Whether pictures of a MIME type can be decoded here (`<source type>`).
pub fn decodes(mime_in: []const u8) bool {
    var mime = mime_in;
    if (std.mem.indexOfScalar(u8, mime, ';')) |semi| mime = mime[0..semi];
    mime = std.mem.trim(u8, mime, " \t\r\n");
    const eq = std.ascii.eqlIgnoreCase;
    for ([_][]const u8{ "image/png", "image/jpeg", "image/jpg", "image/gif", "image/svg+xml" }) |t| if (eq(mime, t)) return true;
    if (portable) return false;
    for ([_][]const u8{ "image/webp", "image/heic", "image/heif", "image/avif", "image/tiff", "image/bmp", "image/x-icon", "image/vnd.microsoft.icon" }) |t| if (eq(mime, t)) return true;
    return false;
}

fn probeHeader(bytes: []const u8) ?Info {
    if (!portable) {
        const d = imageio.dimensions(bytes) orelse return null;
        return .{ .width = d.width, .height = d.height };
    }
    if (bytes.len >= 24 and std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n") and std.mem.eql(u8, bytes[12..16], "IHDR")) {
        const w = std.mem.readInt(u32, bytes[16..20], .big);
        const h = std.mem.readInt(u32, bytes[20..24], .big);
        return sane(w, h);
    }
    if (jpeg_decode.matches(bytes)) {
        const d = jpeg_decode.size(bytes) orelse return null;
        return sane(d.width, d.height);
    }
    if (gif_decode.matches(bytes)) {
        const d = gif_decode.size(bytes) orelse return null;
        return sane(d.width, d.height);
    }
    return null;
}

/// A size worth decoding: what the decoders themselves refuse is refused here.
fn sane(w: u32, h: u32) ?Info {
    if (w > 0 and h > 0 and @as(u64, w) * h <= 64 * 1024 * 1024) return .{ .width = w, .height = h };
    return null;
}

fn drawSvg(gpa: std.mem.Allocator, bytes: []const u8, spec: SvgSpec) !Decoded {
    const px = try @import("svg.zig").render(gpa, bytes, .{ .width = spec.width, .height = spec.height, .current = spec.current });
    return .{ .width = spec.width, .height = spec.height, .w = spec.width, .h = spec.height, .bgra = px };
}

const Raw = struct { width: u32, height: u32, bgra: []u8 };

/// Decodes and scales a picture to keep.
fn load(gpa: std.mem.Allocator, bytes: []const u8, side: u32) !Decoded {
    if (!portable) {
        const f = try imageio.decodeFit(gpa, bytes, side);
        return .{ .width = f.width, .height = f.height, .w = f.w, .h = f.h, .bgra = f.bgra };
    }
    const d = try decode(gpa, bytes);
    const scaled = fit(gpa, d.bgra, d.width, d.height, side) catch |e| {
        gpa.free(d.bgra);
        return e;
    };
    if (scaled.bgra.ptr != d.bgra.ptr) gpa.free(d.bgra);
    return .{ .width = d.width, .height = d.height, .w = scaled.w, .h = scaled.h, .bgra = scaled.bgra };
}

/// Whether `p` holds whole rows within the picture and allocation limits.
fn pixelsOk(p: Source.Pixels) bool {
    const w: u64 = p.width;
    const h: u64 = p.height;
    if (w == 0 or h == 0 or w * h > max_pixels) return false;
    const stride: u64 = if (p.stride == 0) w * 4 else @intCast(p.stride);
    if (stride < w * 4 or stride > max_pixels * 4) return false;
    return @as(u64, p.bgra.len) >= (h - 1) * stride + w * 4;
}

/// Copies rows apart from their stride, then scales to the requested side.
fn loadPixels(gpa: std.mem.Allocator, p: Source.Pixels, side: u32) !Decoded {
    const w: usize = p.width;
    const h: usize = p.height;
    const stride: usize = if (p.stride == 0) w * 4 else p.stride;
    const tight = w * 4;
    const pixels = try gpa.alloc(u8, tight * h);
    errdefer gpa.free(pixels);
    if (stride == tight) {
        @memcpy(pixels, p.bgra[0 .. tight * h]);
    } else for (0..h) |y| {
        @memcpy(pixels[y * tight ..][0..tight], p.bgra[y * stride ..][0..tight]);
    }
    const scaled = try fit(gpa, pixels, p.width, p.height, side);
    if (scaled.bgra.ptr != pixels.ptr) gpa.free(pixels);
    return .{ .width = p.width, .height = p.height, .w = scaled.w, .h = scaled.h, .bgra = scaled.bgra };
}

fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Raw {
    if (!portable) {
        const d = try imageio.decode(gpa, bytes);
        return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
    }
    if (jpeg_decode.matches(bytes)) {
        const d = try jpeg_decode.decode(gpa, bytes);
        return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
    }
    if (gif_decode.matches(bytes)) {
        const d = try gif_decode.decode(gpa, bytes);
        return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
    }
    const d = try png_decode.decode(gpa, bytes);
    return .{ .width = d.width, .height = d.height, .bgra = d.bgra };
}

const Scaled = struct { w: u32, h: u32, bgra: []u8 };

/// The picture within `max_side`, averaging the pixels each new one covers.
fn fit(gpa: std.mem.Allocator, bgra: []u8, w: u32, h: u32, limit: u32) !Scaled {
    const longest = @max(w, h);
    if (longest <= limit) return .{ .w = w, .h = h, .bgra = bgra };
    const nw = @max(1, w * limit / longest);
    const nh = @max(1, h * limit / longest);
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
    const e = im.get(Images.key("a.png"), .{ .encoded = bytes }, max_side).?;
    try std.testing.expectEqual(@as(u32, 2), e.width);
    try std.testing.expectEqualSlices(u8, &px, im.pixels[0..8]);
    const gen = im.generation;
    _ = im.get(Images.key("a.png"), .{ .encoded = bytes }, max_side);
    try std.testing.expectEqual(gen, im.generation);
    try std.testing.expect(im.get(Images.key("bad"), .{ .encoded = "not an image" }, max_side) == null);
    // Too big: averaged down to the longest side.
    const big = try gpa.alloc(u8, 2048 * 2 * 4);
    defer gpa.free(big);
    @memset(big, 200);
    const s = try fit(gpa, big, 2048, 2, max_side);
    defer gpa.free(s.bgra);
    try std.testing.expectEqual(@as(u32, 1024), s.w);
    try std.testing.expectEqual(@as(u32, 1), s.h);
    try std.testing.expectEqual(@as(u8, 200), s.bgra[0]);
}

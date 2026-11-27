//! Characters no font has, drawn by the host instead: on the web, the
//! browser's own fonts. Shaping asks the host for a grapheme cluster's
//! advance; painting asks it for pixels, kept here and drawn through the
//! picture atlas. Emoji keep their colours; other text is a coverage mask
//! tinted with the text colour.
const std = @import("std");
const Images = @import("images.zig").Images;
const isPictographic = @import("text_selection_data.zig").isPictographic;

/// A rasterized cluster, in device pixels: its box, and how far its
/// baseline sits below the top and where the pen sits from the left.
pub const Raster = struct { width: u32, height: u32, ascent: f32, left: f32 };

pub const Hooks = struct {
    ctx: ?*anyopaque = null,
    /// The advance of `text`, one grapheme cluster, at `size` points; 0 when
    /// the host cannot draw it.
    measure: *const fn (ctx: ?*anyopaque, text: []const u8, size: f32) f32,
    /// The box `text` takes at `px` pixels, null when it can't be drawn.
    box: *const fn (ctx: ?*anyopaque, text: []const u8, px: f32) ?Raster,
    /// Draws `text` at `px` pixels into `rgba`, `box`'s width × height, its
    /// baseline `box.ascent` from the top: unpremultiplied RGBA. False when
    /// it could not.
    draw: *const fn (ctx: ?*anyopaque, text: []const u8, px: f32, box: Raster, rgba: []u8) bool,
};

/// Where a fallback cluster lands, in points from the pen and the baseline.
/// `color`: drawn as is (emoji); otherwise tinted with the text colour.
pub const Placed = struct { uv: [4]f32, w: f32, h: f32, ascent: f32, left: f32, color: bool };

const max_entries = 1024;
const max_bitmap_bytes = 8 * 1024 * 1024;

const Pixels = struct { bgra: []u8, r: Raster, color: bool };

pub const Cache = struct {
    pixels: std.AutoHashMapUnmanaged(u64, ?Pixels) = .empty,
    order: [max_entries]u64 = undefined,
    first: usize = 0,
    bitmap_bytes: usize = 0,

    pub fn deinit(c: *Cache, gpa: std.mem.Allocator) void {
        var it = c.pixels.valueIterator();
        while (it.next()) |m| if (m.*) |found| gpa.free(found.bgra);
        c.pixels.deinit(gpa);
        c.* = .{};
    }

    fn get(c: *Cache, gpa: std.mem.Allocator, hooks: Hooks, text: []const u8, px: f32) ?Pixels {
        const k = key(text, px);
        if (c.pixels.get(k)) |m| return m;
        const m = rasterize(gpa, hooks, text, px);
        const bytes = if (m) |found| found.bgra.len else 0;
        while (c.pixels.count() == max_entries or c.bitmap_bytes + bytes > max_bitmap_bytes) {
            const old = c.pixels.fetchRemove(c.order[c.first]).?.value;
            c.first = (c.first + 1) % max_entries;
            if (old) |found| {
                c.bitmap_bytes -= found.bgra.len;
                gpa.free(found.bgra);
            }
        }
        const tail = (c.first + c.pixels.count()) % max_entries;
        c.pixels.put(gpa, k, m) catch {
            if (m) |found| gpa.free(found.bgra);
            return null;
        };
        c.order[tail] = k;
        c.bitmap_bytes += bytes;
        return m;
    }

    /// `text` at `size` points on a `scale` screen, packed into the
    /// picture atlas.
    pub fn place(c: *Cache, gpa: std.mem.Allocator, images: *Images, hooks: Hooks, text: []const u8, size: f32, scale: f32) ?Placed {
        const px = size * scale;
        const m = c.get(gpa, hooks, text, px) orelse return null;
        const side = @max(m.r.width, m.r.height);
        const entry = images.get(key(text, px), .{ .pixels = .{ .bgra = m.bgra, .width = m.r.width, .height = m.r.height } }, side) orelse return null;
        return .{
            .uv = entry.uv,
            .w = @as(f32, @floatFromInt(m.r.width)) / scale,
            .h = @as(f32, @floatFromInt(m.r.height)) / scale,
            .ascent = m.r.ascent / scale,
            .left = m.r.left / scale,
            .color = m.color,
        };
    }
};

fn key(text: []const u8, px: f32) u64 {
    var h = std.hash.Wyhash.init(0x9f1b_a11b);
    h.update(text);
    h.update(std.mem.asBytes(&@as(u32, @bitCast(px))));
    return h.final();
}

/// Whether a cluster is drawn in its own colours: an emoji, a flag.
pub fn colored(text: []const u8) bool {
    var it = (std.unicode.Utf8View.init(text) catch return false).iterator();
    while (it.nextCodepoint()) |cp| if (isPictographic(cp) or cp == 0x20e3 or (cp >= 0x1f1e6 and cp <= 0x1f1ff)) return true;
    return false;
}

/// Premultiplied BGRA: emoji as drawn, other text white so a tint colours it.
fn rasterize(gpa: std.mem.Allocator, hooks: Hooks, text: []const u8, px: f32) ?Pixels {
    const r = hooks.box(hooks.ctx, text, px) orelse return null;
    if (r.width == 0 or r.height == 0 or r.width > 512 or r.height > 512) return null;
    const bytes = gpa.alloc(u8, @as(usize, r.width) * r.height * 4) catch return null;
    @memset(bytes, 0);
    if (!hooks.draw(hooks.ctx, text, px, r, bytes)) {
        gpa.free(bytes);
        return null;
    }
    const color = colored(text);
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) {
        const a = bytes[i + 3];
        if (!color) {
            @memset(bytes[i..][0..4], a);
            continue;
        }
        const red = bytes[i];
        bytes[i] = premultiply(bytes[i + 2], a);
        bytes[i + 1] = premultiply(bytes[i + 1], a);
        bytes[i + 2] = premultiply(red, a);
    }
    return .{ .bgra = bytes, .r = r, .color = color };
}

fn premultiply(v: u8, a: u8) u8 {
    return @intCast((@as(u16, v) * a + 127) / 255);
}

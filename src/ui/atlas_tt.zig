//! The glyph atlas where nanoui shapes text itself: each glyph rasterized
//! once per font and quarter pixel of horizontal position, at the
//! display's scale, by nanoui's TrueType rasterizer into one byte-per-texel
//! image in memory, which the CPU renderer samples (and GPU renderers
//! upload when `generation` changes). Shelf packed; it grows when full,
//! then resets. Icons come from `icons.zig`.
const std = @import("std");
const font = @import("tt/font.zig");
const tt_raster = @import("tt/raster.zig");
const icons = @import("icons.zig");

const initial_size: u32 = 512;
const max_size: u32 = 4096;
const pad: u32 = 1;
pub const subpixel_bins = 4;

/// A glyph in the atlas, placed relative to its pen position on the
/// baseline, in points.
pub const Sprite = struct {
    uv: [4]f32,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

/// A font at a size, as glyphs are drawn: `skew` slants an upright face
/// for italics it lacks.
pub const RunFont = struct {
    font: *const font.Font,
    size: f32,
    skew: f32 = 0,
    /// Strokes thickened by this fraction of the size, for a weight the
    /// face lacks (a variable font's one instance): drawn again offset.
    embolden: f32 = 0,
};

const Key = struct { font: u16, glyph: u16, bin: u8 };
const SymbolKey = struct { name: u64, size_bits: u32, weight: u8 };

pub const Atlas = struct {
    gpa: std.mem.Allocator,
    size: u32 = initial_size,
    scale: f32 = 2,
    pixels: []u8,
    sprites: std.AutoHashMapUnmanaged(Key, ?Sprite) = .empty,
    symbols: std.AutoHashMapUnmanaged(SymbolKey, ?Sprite) = .empty,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    reset_during_frame: bool = false,
    /// Bumped whenever texels change, for renderers that upload them.
    generation: u64 = 0,
    /// Bumped when it starts over: a glyph may now be where another was.
    resets: u64 = 0,
    scratch: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Atlas {
        const px = gpa.alloc(u8, @as(usize, initial_size) * initial_size) catch return .{ .gpa = gpa, .pixels = &.{}, .size = 0 };
        @memset(px, 0);
        return .{ .gpa = gpa, .pixels = px };
    }

    pub fn deinit(a: *Atlas) void {
        a.sprites.deinit(a.gpa);
        a.symbols.deinit(a.gpa);
        a.scratch.deinit(a.gpa);
        a.gpa.free(a.pixels);
    }

    /// The texels, as the CPU renderer samples them.
    pub fn mask(a: *const Atlas) @import("raster.zig").Mask {
        return .{ .pixels = a.pixels, .size = a.size };
    }

    /// For the test against Metal: texels are already in memory.
    pub fn read(a: *Atlas, gpa: std.mem.Allocator) ![]u8 {
        return gpa.dupe(u8, a.pixels);
    }

    pub fn setScale(a: *Atlas, scale: f32) void {
        if (scale == a.scale) return;
        a.scale = scale;
        a.reset();
    }

    pub fn reset(a: *Atlas) void {
        a.sprites.clearRetainingCapacity();
        a.symbols.clearRetainingCapacity();
        a.shelf_x = 0;
        a.shelf_y = 0;
        a.shelf_h = 0;
        @memset(a.pixels, 0);
        a.generation += 1;
        a.resets += 1;
    }

    fn makeRoom(a: *Atlas) void {
        if (a.size < max_size) {
            const bigger = a.gpa.alloc(u8, @as(usize, a.size) * a.size * 4) catch {
                a.reset();
                a.reset_during_frame = true;
                return;
            };
            a.gpa.free(a.pixels);
            a.pixels = bigger;
            a.size *= 2;
        }
        a.reset();
        a.reset_during_frame = true;
    }

    fn allocate(a: *Atlas, w: u32, h: u32) ?[2]u32 {
        if (a.shelf_x + w > a.size) {
            a.shelf_y += a.shelf_h;
            a.shelf_x = 0;
            a.shelf_h = 0;
        }
        if (a.shelf_y + h > a.size) return null;
        const at: [2]u32 = .{ a.shelf_x, a.shelf_y };
        a.shelf_x += w;
        a.shelf_h = @max(a.shelf_h, h);
        return at;
    }

    /// Room for a `w` × `h` bitmap, made if needed.
    fn place(a: *Atlas, w: u32, h: u32) ?[2]u32 {
        if (w > max_size or h > max_size) return null;
        return a.allocate(w, h) orelse blk: {
            a.makeRoom();
            break :blk a.allocate(w, h);
        };
    }

    fn uv(a: *const Atlas, at: [2]u32, w: u32, h: u32) [4]f32 {
        const s: f32 = @floatFromInt(a.size);
        return .{
            @as(f32, @floatFromInt(at[0])) / s,
            @as(f32, @floatFromInt(at[1])) / s,
            @as(f32, @floatFromInt(at[0] + w)) / s,
            @as(f32, @floatFromInt(at[1] + h)) / s,
        };
    }

    /// Copies a coverage bitmap into the atlas at `at`.
    fn blit(a: *Atlas, at: [2]u32, w: u32, h: u32, src: []const u8) void {
        for (0..h) |y| {
            const dst = (at[1] + y) * a.size + at[0];
            @memcpy(a.pixels[dst..][0..w], src[y * w ..][0..w]);
        }
        a.generation += 1;
    }

    /// The sprite of glyph `g` of run font `font_id`, drawn `bin` quarters
    /// of a pixel right of a pixel boundary; null for blank glyphs.
    pub fn glyph(a: *Atlas, font_id: u16, rf: RunFont, g: u16, bin: u8) ?Sprite {
        const key: Key = .{ .font = font_id, .glyph = g, .bin = bin };
        if (a.sprites.get(key)) |sp| return sp;
        const sp = a.rasterize(rf, g, bin);
        a.sprites.put(a.gpa, key, sp) catch {};
        return sp;
    }

    fn rasterize(a: *Atlas, rf: RunFont, g: u16, bin: u8) ?Sprite {
        const f = rf.font;
        const b = f.bounds(g) orelse return null;
        const ps = rf.size * a.scale / f.units_per_em;
        const sub = @as(f32, @floatFromInt(bin)) / subpixel_bins;
        // The slant moves x by skew × y; bounds widen by its reach.
        const sk0 = @min(rf.skew * b[1], rf.skew * b[3]) * ps;
        const sk1 = @max(rf.skew * b[1], rf.skew * b[3]) * ps;
        const x0 = @floor(b[0] * ps + sub + sk0);
        const bold = rf.embolden * rf.size * a.scale;
        const x1 = @ceil(b[2] * ps + sub + sk1 + bold);
        const top = @ceil(b[3] * ps);
        const bottom = @floor(b[1] * ps);
        if (x1 <= x0 or top <= bottom) return null;
        const w: u32 = @as(u32, @intFromFloat(x1 - x0)) + 2 * pad;
        const h: u32 = @as(u32, @intFromFloat(top - bottom)) + 2 * pad;
        const at = a.place(w, h) orelse return null;
        var r = tt_raster.Raster.init(a.gpa, w, h) catch return null;
        defer r.deinit(a.gpa);
        const p: f32 = @floatFromInt(pad);
        // Emboldened: the outline again at steps of at most a pixel.
        const steps: usize = if (bold > 0) @as(usize, @intFromFloat(@ceil(bold))) else 0;
        for (0..steps + 1) |k| {
            const dx = if (steps == 0) 0 else bold * @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
            f.outline(g, .{ ps, 0, rf.skew * ps, -ps, sub - x0 + p + dx, top + p }, r.sink());
        }
        a.scratch.resize(a.gpa, w * h) catch return null;
        r.coverage(a.scratch.items);
        a.blit(at, w, h, a.scratch.items);
        return .{
            .uv = a.uv(at, w, h),
            .x = (x0 - p) / a.scale,
            .y = -(top + p) / a.scale,
            .w = @as(f32, @floatFromInt(w)) / a.scale,
            .h = @as(f32, @floatFromInt(h)) / a.scale,
        };
    }

    /// The icon `name` (SF Symbols' names) at `point_size` and `weight` (0
    /// regular … 3 bold), as a mask: `x`, `y` are 0 and `w`, `h` its size.
    pub fn symbol(a: *Atlas, name: []const u8, point_size: f32, weight: u8) ?Sprite {
        const key: SymbolKey = .{ .name = std.hash.Wyhash.hash(0, name), .size_bits = @bitCast(point_size), .weight = weight };
        if (a.symbols.get(key)) |sp| return sp;
        const sp = a.rasterizeSymbol(name, point_size, weight);
        a.symbols.put(a.gpa, key, sp) catch {};
        return sp;
    }

    fn rasterizeSymbol(a: *Atlas, name: []const u8, point_size: f32, weight: u8) ?Sprite {
        const icon = icons.find(name) orelse return null;
        // Icons are drawn on a 24-unit grid, a little larger than the
        // text they sit beside, as SF Symbols are.
        const side_pt = point_size * 1.2;
        const side: u32 = @intFromFloat(@ceil(side_pt * a.scale));
        const w = side + 2 * pad;
        const h = side + 2 * pad;
        const at = a.place(w, h) orelse return null;
        var r = tt_raster.Raster.init(a.gpa, w, h) catch return null;
        defer r.deinit(a.gpa);
        const k = @as(f32, @floatFromInt(side)) / 24;
        icons.draw(icon, &r, k, @floatFromInt(pad), 1.6 + 0.35 * @as(f32, @floatFromInt(weight)));
        a.scratch.resize(a.gpa, w * h) catch return null;
        r.coverage(a.scratch.items);
        a.blit(at, w, h, a.scratch.items);
        const pp = @as(f32, pad) / a.scale;
        return .{
            .uv = a.uv(at, w, h),
            .x = -pp,
            .y = -pp,
            .w = @as(f32, @floatFromInt(w)) / a.scale,
            .h = @as(f32, @floatFromInt(h)) / a.scale,
        };
    }
};

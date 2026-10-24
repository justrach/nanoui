//! Text where nanoui shapes it itself (Linux, Windows, Android, and macOS built
//! with `-Dportable=true`): the installed TrueType fonts (`tt/fontdb.zig`),
//! characters to glyphs with kerning and fallback fonts for characters a
//! font lacks, greedy wrapping at spaces, carets, and the glyph atlas.
//! The same interface as `text_mac.zig`; layouts are cached the same way.
const std = @import("std");
const types = @import("types.zig");
const fontdb = @import("tt/fontdb.zig");
const tt = @import("tt/font.zig");
const atlas_mod = @import("atlas_tt.zig");
const utf8 = @import("utf8.zig");
pub const rich = @import("rich_tt.zig");

pub const Atlas = atlas_mod.Atlas;
pub const Sprite = atlas_mod.Sprite;
pub const subpixel_bins = atlas_mod.subpixel_bins;

pub const Font = struct {
    ascent: f32,
    descent: f32,
    leading: f32,
    /// The run font of its face at its size.
    id: u16,
    weight: u16,

    pub fn lineHeight(f: Font) f32 {
        return @ceil(f.ascent + f.descent + f.leading);
    }
};

/// A shaped glyph, as `text_mac.zig` has it.
pub const Glyph = struct { font: u16, glyph: u16, x: f32, y: f32, index: u32 = 0 };
pub const Layout = struct { width: f32, glyphs: []const Glyph };
pub const Line = struct { start: usize, end: usize, width: f32 };

const FontKey = struct { size_bits: u32, weight: types.Weight, mono: bool, italic: bool };

fn fontKey(style: types.TextStyle) FontKey {
    return .{ .size_bits = @bitCast(style.size), .weight = style.weight, .mono = style.mono, .italic = style.italic };
}

fn weightOf(w: types.Weight) u16 {
    return switch (w) {
        .regular => 400,
        .medium => 500,
        .semibold => 600,
        .bold => 700,
    };
}

pub const TextSystem = struct {
    gpa: std.mem.Allocator,
    db: fontdb.Db,
    atlas: Atlas,
    /// The pictures shown (`ui.image`).
    images: @import("images.zig").Images,
    scale: f32 = 2,
    fonts: std.AutoHashMapUnmanaged(FontKey, Font) = .empty,
    /// Faces at sizes, as glyphs refer to them.
    run_fonts: std.ArrayList(atlas_mod.RunFont) = .empty,
    run_faces: std.ArrayList(u32) = .empty,
    layouts: std.AutoHashMapUnmanaged(u64, Layout) = .empty,
    previous: std.AutoHashMapUnmanaged(u64, Layout) = .empty,
    wraps: @import("wrap_cache.zig").WrapCache(Line) = .{},
    family: ?[]const u8 = null,
    mono_family: ?[]const u8 = null,
    /// Every size times this (`Context.setZoom`).
    zoom: f32 = 1,

    pub fn init(gpa: std.mem.Allocator) TextSystem {
        return .{ .gpa = gpa, .db = .init(gpa, std.Io.Threaded.global_single_threaded.io()), .atlas = .init(gpa), .images = .{ .gpa = gpa } };
    }

    pub fn deinit(self: *TextSystem) void {
        self.images.deinit();
        self.fonts.deinit(self.gpa);
        self.run_fonts.deinit(self.gpa);
        self.run_faces.deinit(self.gpa);
        freeLayouts(self.gpa, &self.layouts);
        freeLayouts(self.gpa, &self.previous);
        self.layouts.deinit(self.gpa);
        self.previous.deinit(self.gpa);
        self.wraps.deinit(self.gpa);
        self.atlas.deinit();
        self.db.deinit();
    }

    pub fn setScale(self: *TextSystem, scale: f32) void {
        self.scale = scale;
        self.atlas.setScale(scale);
    }

    pub fn setFamilies(self: *TextSystem, family: ?[]const u8, mono_family: ?[]const u8) void {
        const same = struct {
            fn f(a: ?[]const u8, b: ?[]const u8) bool {
                if (a == null or b == null) return a == null and b == null;
                return std.mem.eql(u8, a.?, b.?);
            }
        }.f;
        if (same(self.family, family) and same(self.mono_family, mono_family)) return;
        self.family = family;
        self.mono_family = mono_family;
        self.dropCaches();
    }

    fn dropCaches(self: *TextSystem) void {
        self.fonts.clearRetainingCapacity();
        freeLayouts(self.gpa, &self.layouts);
        freeLayouts(self.gpa, &self.previous);
        self.wraps.clear(self.gpa);
    }

    /// Scales every text by `z`: a change drops every cached font, shaping and wrap.
    pub fn setZoom(self: *TextSystem, z: f32) void {
        if (z == self.zoom) return;
        self.zoom = z;
        self.dropCaches();
    }

    pub fn lineHeight(self: *TextSystem, style: types.TextStyle) f32 {
        if (style.line_height > 0) return style.line_height * self.zoom;
        const lh = self.font(style).lineHeight();
        return if (style.leading == 1) lh else @ceil(lh * style.leading);
    }

    pub fn beginFrame(self: *TextSystem) void {
        self.atlas.reset_during_frame = false;
        freeLayouts(self.gpa, &self.previous);
        std.mem.swap(std.AutoHashMapUnmanaged(u64, Layout), &self.layouts, &self.previous);
        self.wraps.beginFrame(self.gpa);
    }

    fn freeLayouts(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u64, Layout)) void {
        var it = map.valueIterator();
        while (it.next()) |l| gpa.free(l.glyphs);
        map.clearRetainingCapacity();
    }

    /// The run font of `face` at `size`, slanted when italics were asked
    /// of an upright face.
    fn runFont(self: *TextSystem, face: u32, size: f32, slant: bool, weight: u16) u16 {
        const f = self.db.load(face) orelse return 0xffff;
        const skew: f32 = if (slant and !f.style.italic) 0.2 else 0;
        // Semibold and bold of a face that is neither: thickened.
        const embolden: f32 = if (weight >= 600 and f.style.weight < 550) (if (weight >= 700) 0.045 else 0.03) else 0;
        for (self.run_fonts.items, self.run_faces.items, 0..) |rf, rface, i| {
            if (rface == face and rf.size == size and rf.skew == skew and rf.embolden == embolden) return @intCast(i);
        }
        self.run_fonts.append(self.gpa, .{ .font = f, .size = size, .skew = skew, .embolden = embolden }) catch return 0xffff;
        self.run_faces.append(self.gpa, face) catch {
            self.run_fonts.items.len -= 1;
            return 0xffff;
        };
        return @intCast(self.run_fonts.items.len - 1);
    }

    pub fn font(self: *TextSystem, style: types.TextStyle) Font {
        const fk = fontKey(style);
        if (self.fonts.get(fk)) |f| return f;
        const weight = weightOf(style.weight);
        const size = style.size * self.zoom;
        const face = self.db.match(if (style.mono) self.mono_family else self.family, weight, style.italic, style.mono);
        var f: Font = .{ .ascent = size * 0.8, .descent = size * 0.2, .leading = 0, .id = 0xffff, .weight = weight };
        if (face) |fc| if (self.db.load(fc)) |tf| {
            const k = size / tf.units_per_em;
            f = .{ .ascent = tf.ascent * k, .descent = tf.descent * k, .leading = tf.line_gap * k, .id = self.runFont(fc, size, style.italic, weight), .weight = weight };
        };
        self.fonts.put(self.gpa, fk, f) catch {};
        return f;
    }

    pub fn key(s: []const u8, style: types.TextStyle, extra: u64) u64 {
        var h = std.hash.Wyhash.init(extra);
        h.update(s);
        h.update(std.mem.asBytes(&style.size));
        h.update(std.mem.asBytes(&style.mono_scale));
        h.update(&.{ @intFromEnum(style.weight), @intFromBool(style.mono), @intFromBool(style.italic) });
        return h.final();
    }

    pub fn layout(self: *TextSystem, s: []const u8, style: types.TextStyle) Layout {
        if (s.len == 0) return .{ .width = 0, .glyphs = &.{} };
        const k = key(s, style, 1);
        if (self.cached(k)) |l| return l;
        var glyphs: std.ArrayList(Glyph) = .empty;
        const w = self.shapeInto(&glyphs, s, style, 0, 0) catch {
            glyphs.deinit(self.gpa);
            return .{ .width = 0, .glyphs = &.{} };
        };
        return self.keep(k, .{ .width = w, .glyphs = glyphs.toOwnedSlice(self.gpa) catch return .{ .width = w, .glyphs = &.{} } });
    }

    pub fn cached(self: *TextSystem, k: u64) ?Layout {
        if (self.layouts.get(k)) |l| return l;
        if (self.previous.fetchRemove(k)) |kv| {
            self.layouts.put(self.gpa, k, kv.value) catch {};
            return kv.value;
        }
        return null;
    }

    pub fn keep(self: *TextSystem, k: u64, l: Layout) Layout {
        self.layouts.put(self.gpa, k, l) catch {
            self.gpa.free(l.glyphs);
            return .{ .width = l.width, .glyphs = &.{} };
        };
        return l;
    }

    /// Shapes `s` in `style` from pen position `x0`, appending its glyphs
    /// (byte offsets plus `offset`); returns the pen position after it.
    pub fn shapeInto(self: *TextSystem, out: *std.ArrayList(Glyph), s: []const u8, style: types.TextStyle, x0: f32, offset: usize) !f32 {
        const f = self.font(style);
        const size = style.size * self.zoom;
        var x = x0;
        if (f.id == 0xffff) return x + @as(f32, @floatFromInt(s.len)) * size * 0.5;
        const primary = self.run_fonts.items[f.id];
        var prev: ?struct { id: u16, g: u16 } = null;
        var i: usize = 0;
        while (i < s.len) {
            // A character cut off at the end (a span ending inside it) is
            // the replacement character, not a decode of too few bytes.
            const want = utf8.seqLen(s[i]);
            const n = @min(want, s.len - i);
            const cp: u21 = if (n == want) std.unicode.utf8Decode(s[i .. i + n]) catch 0xfffd else 0xfffd;
            var id = f.id;
            var rf = primary;
            var g = rf.font.glyphIndex(if (cp == '\t') ' ' else cp);
            if (g == 0 and cp >= 0x20) {
                if (self.db.fallback(cp, f.weight)) |face| {
                    const fid = self.runFont(face, size, style.italic, f.weight);
                    if (fid != 0xffff) {
                        id = fid;
                        rf = self.run_fonts.items[fid];
                        g = rf.font.glyphIndex(cp);
                    }
                }
            }
            const k = size / rf.font.units_per_em;
            if (prev) |p| if (p.id == id) {
                x += rf.font.kerning(p.g, g) * k;
            };
            if (cp >= 0x20 or cp == '\t') try out.append(self.gpa, .{ .font = id, .glyph = g, .x = x, .y = 0, .index = @intCast(offset + i) });
            x += (rf.font.advance(g) * k + rf.embolden * size) * @as(f32, if (cp == '\t') 4 else 1);
            prev = .{ .id = id, .g = g };
            i += n;
        }
        return x;
    }

    pub fn glyph(self: *TextSystem, g: Glyph, bin: u8) ?Sprite {
        if (g.font >= self.run_fonts.items.len) return null;
        return self.atlas.glyph(g.font, self.run_fonts.items[g.font], g.glyph, bin);
    }

    pub fn width(self: *TextSystem, s: []const u8, style: types.TextStyle) f32 {
        return self.layout(s, style).width;
    }

    pub fn wrap(self: *TextSystem, s: []const u8, style: types.TextStyle, max_width: f32) []const Line {
        return self.wrapAttributed(s, style, &.{}, max_width);
    }

    /// `s` broken at spaces (or, for a word wider than the line, between
    /// characters) and at newlines into lines no wider than `max_width`.
    pub fn wrapAttributed(self: *TextSystem, s: []const u8, style: types.TextStyle, spans: []const types.Span, max_width: f32) []const Line {
        const styled = rich.styled(spans);
        const k = key(s, style, (@as(u64, @intFromFloat(@max(0, @min(max_width, 1e6)))) + 2) ^ (if (styled) rich.spansHash(spans, 0, s.len) else 0));
        if (self.wraps.get(self.gpa, k)) |lines| return lines;
        const lay = if (styled) rich.layout(self, s, style, spans, 0) else self.layout(s, style);
        var lines: std.ArrayList(Line) = .empty;
        defer lines.deinit(self.gpa);
        breakLines(self.gpa, &lines, s, lay, @max(1, max_width)) catch {};
        if (lines.items.len == 0) lines.append(self.gpa, .{ .start = 0, .end = 0, .width = 0 }) catch {};
        return self.wraps.put(self.gpa, k, lines.toOwnedSlice(self.gpa) catch return &.{});
    }

    pub fn caretX(self: *TextSystem, s: []const u8, style: types.TextStyle, index: usize) f32 {
        if (s.len == 0 or index == 0) return 0;
        return xAt(self.layout(s, style), index);
    }

    pub fn indexAt(self: *TextSystem, s: []const u8, style: types.TextStyle, x: f32) usize {
        if (s.len == 0) return 0;
        const lay = self.layout(s, style);
        var best: usize = s.len;
        var best_d = @abs(lay.width - x);
        for (lay.glyphs) |g| {
            const d = @abs(g.x - x);
            if (d < best_d) {
                best_d = d;
                best = g.index;
            }
        }
        return best;
    }
};

/// The pen position at byte `at` of a layout.
fn xAt(lay: Layout, at: usize) f32 {
    for (lay.glyphs) |g| if (g.index >= at) return g.x;
    return lay.width;
}

/// Greedy line breaking over a shaped paragraph.
fn breakLines(gpa: std.mem.Allocator, lines: *std.ArrayList(Line), s: []const u8, lay: Layout, max: f32) !void {
    var start: usize = 0;
    while (start < s.len) {
        const x0 = xAt(lay, start);
        var end = start;
        var last_break: ?usize = null;
        var i = start;
        while (i < s.len) {
            if (s[i] == '\n') {
                end = i;
                break;
            }
            const n = utf8.seqLen(s[i]);
            const next = @min(s.len, i + n);
            // A character that ends past the line, unless it is a space.
            if (s[i] != ' ' and xAt(lay, next) - x0 > max and i > start) {
                end = last_break orelse i;
                break;
            }
            if (s[i] == ' ' or s[i] == '-' or s[i] == '/') last_break = next;
            i = next;
            end = i;
        }
        const trimmed = std.mem.trimEnd(u8, s[start..end], " \t\r");
        try lines.append(gpa, .{ .start = start, .end = start + trimmed.len, .width = xAt(lay, start + trimmed.len) - x0 });
        var next_start = end;
        if (next_start < s.len and s[next_start] == '\n') next_start += 1;
        while (next_start < s.len and s[next_start] == ' ') next_start += 1;
        if (next_start == start) next_start += 1;
        start = next_start;
        if (start == s.len and end < s.len and s[end] == '\n') try lines.append(gpa, .{ .start = s.len, .end = s.len, .width = 0 });
    }
}

test "a character cut off at a string's end is shaped, not decoded short" {
    var ts = TextSystem.init(std.testing.allocator);
    defer ts.deinit();
    // "a→" with the arrow's last byte gone, as a span can end.
    const w = ts.width("a\xe2\x86", .{ .size = 13 });
    try std.testing.expect(w > 0);
}

//! Text where nanoui shapes it itself (Linux, Windows, Android, and macOS built
//! with `-Dportable=true`): the installed TrueType fonts (`tt/fontdb.zig`),
//! characters to glyphs with kerning and fallback fonts for characters a
//! font lacks, greedy wrapping at spaces, carets, and the glyph atlas.
//! The same interface as `text_mac.zig`; layouts are cached the same way.
const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const fontdb = @import("tt/fontdb.zig");
const tt = @import("tt/font.zig");
const atlas_mod = @import("atlas_tt.zig");
const utf8 = @import("utf8.zig");
const stacks = @import("text_stack_tt.zig");
const registry = @import("font_registry.zig");
pub const rich = @import("rich_tt.zig");

pub const Atlas = atlas_mod.Atlas;
pub const Sprite = atlas_mod.Sprite;
pub const subpixel_bins = atlas_mod.subpixel_bins;

const desktop = switch (builtin.os.tag) {
    .macos => @import("../desktop.zig"),
    .ios => @import("../ios/desktop.zig"),
    .windows => @import("../windows/desktop.zig"),
    .linux => if (builtin.abi.isAndroid()) @import("../android/desktop.zig") else @import("../linux/desktop.zig"),
    else => unreachable,
};

pub const Font = struct {
    ascent: f32,
    descent: f32,
    leading: f32,
    /// The run font of its face at its size.
    id: u16,
    weight: u16,
    /// The height of its lowercase and capitals, and the advance of `0`.
    x_height: f32 = 0,
    cap_height: f32 = 0,
    zero_width: f32 = 0,

    pub fn lineHeight(f: Font) f32 {
        return @ceil(f.ascent + f.descent + f.leading);
    }
};

/// A shaped glyph, as `text_mac.zig` has it.
pub const Glyph = struct { font: u16, glyph: u16, x: f32, y: f32, index: u32 = 0 };
pub const Layout = struct { width: f32, glyphs: []const Glyph };
pub const Line = struct { start: usize, end: usize, width: f32 };

const FontKey = struct { size_bits: u32, weight: types.Weight, mono: bool, italic: bool, system: bool, family: u64, css_weight: u16, stretch: u16 };

fn fontKey(style: types.TextStyle) FontKey {
    return .{
        .size_bits = @bitCast(style.size),
        .weight = style.weight,
        .mono = style.mono,
        .italic = style.italic,
        .system = style.system_font,
        .family = if (style.family) |f| std.hash.Wyhash.hash(0x66, f) else 0,
        .css_weight = style.css_weight,
        .stretch = style.stretch,
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
    /// The fonts of each style that names families (`TextStyle.family`).
    stacks: std.AutoHashMapUnmanaged(FontKey, ?*stacks.Stack) = .empty,
    /// `font_registry.generation` when the caches were last good.
    fonts_seen: u64 = 0,
    layouts: std.AutoHashMapUnmanaged(u64, Layout) = .empty,
    previous: std.AutoHashMapUnmanaged(u64, Layout) = .empty,
    wraps: @import("wrap_cache.zig").WrapCache(Line) = .{},
    family: ?[]const u8 = null,
    mono_family: ?[]const u8 = null,
    /// Every size times this (`Context.setZoom`).
    zoom: f32 = 1,
    /// The portable typesetter currently uses its own line breaks for both.
    wrap_rule: types.WrapRule = .typesetter,
    /// What is centered in a line given its own height.
    baseline_rule: types.BaselineRule = .font_line,
    /// How glyph origins land on device pixels.
    glyph_snap: types.GlyphSnap = .nearest,

    pub fn init(gpa: std.mem.Allocator) TextSystem {
        return .{ .gpa = gpa, .db = .init(gpa, std.Io.Threaded.global_single_threaded.io()), .atlas = .init(gpa), .images = .{ .gpa = gpa } };
    }

    /// Called only by live window surfaces. Testers and headless snapshots use
    /// plain `init`, so they never create or write a persistent font index.
    pub fn enablePersistence(self: *TextSystem, app_name: []const u8) void {
        if (builtin.is_test) return;
        const dir = desktop.path(self.gpa, .cache, app_name) catch return;
        defer self.gpa.free(dir);
        self.db.enableCache(dir);
    }

    pub fn deinit(self: *TextSystem) void {
        self.images.deinit();
        self.fonts.deinit(self.gpa);
        self.run_fonts.deinit(self.gpa);
        self.run_faces.deinit(self.gpa);
        self.dropStacks();
        self.stacks.deinit(self.gpa);
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
        self.run_fonts.clearRetainingCapacity();
        self.run_faces.clearRetainingCapacity();
        self.dropStacks();
        freeLayouts(self.gpa, &self.layouts);
        freeLayouts(self.gpa, &self.previous);
        self.wraps.clear(self.gpa);
        self.atlas.reset();
    }

    fn dropStacks(self: *TextSystem) void {
        var it = self.stacks.valueIterator();
        while (it.next()) |st| if (st.*) |x| x.destroy(self.gpa);
        self.stacks.clearRetainingCapacity();
    }

    /// Fonts came or went (`ui.registerFontFace`): what was shaped goes.
    pub fn syncFonts(self: *TextSystem) void {
        if (self.fonts_seen == registry.generation) return;
        self.fonts_seen = registry.generation;
        self.dropCaches();
        self.db.dropBrought();
    }

    /// Whether every font brought so far is in what this measures with.
    pub fn fontsCurrent(self: *const TextSystem) bool {
        return self.fonts_seen == registry.generation;
    }

    /// Whether a name of a family list would find a font: brought, or installed.
    pub fn hasFamily(self: *TextSystem, name: []const u8) bool {
        if (registry.hasFamily(name)) return true;
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(name, "system-ui") or eq(name, "ui-monospace") or eq(name, "ui-rounded")) return true;
        return self.db.family(name, 400, false) != null;
    }

    /// Whether an installed font goes by this name: families are all this has.
    pub fn hasLocalFont(self: *TextSystem, name: []const u8) bool {
        return self.db.family(name, 400, false) != null;
    }

    /// Whether a family has a font and that font this character.
    pub fn familyHasChar(self: *TextSystem, name: []const u8, cp: u21) bool {
        const st = self.stackOf(.{ .size = 16, .family = name }) orelse return false;
        return st.pick(self.run_fonts.items, cp) != null;
    }

    /// The family name of the font a line in `style` takes its metrics from, in `buf`.
    pub fn familyName(self: *TextSystem, style: types.TextStyle, buf: []u8) []const u8 {
        const f = self.font(style);
        if (f.id >= self.run_fonts.items.len) return "";
        const name = self.run_fonts.items[f.id].font.style.name();
        const n = @min(name.len, buf.len);
        @memcpy(buf[0..n], name[0..n]);
        return buf[0..n];
    }

    /// The fonts of a style that names families; null when it names none that exist.
    pub fn stackOf(self: *TextSystem, style: types.TextStyle) ?*stacks.Stack {
        const list = style.family orelse return null;
        const fk = fontKey(style);
        if (self.stacks.get(fk)) |st| return st;
        const st = stacks.build(self, list, style);
        self.stacks.put(self.gpa, fk, st) catch {};
        return st;
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
        self.syncFonts();
        if (self.layouts.count() >= 4096) {
            freeLayouts(self.gpa, &self.previous);
            std.mem.swap(std.AutoHashMapUnmanaged(u64, Layout), &self.layouts, &self.previous);
        }
        self.wraps.beginFrame(self.gpa);
    }

    fn freeLayouts(gpa: std.mem.Allocator, map: *std.AutoHashMapUnmanaged(u64, Layout)) void {
        var it = map.valueIterator();
        while (it.next()) |l| gpa.free(l.glyphs);
        map.clearRetainingCapacity();
    }

    /// The run font of `face` at `size`, slanted when italics were asked
    /// of an upright face.
    pub fn runFont(self: *TextSystem, face: u32, size: f32, slant: bool, weight: u16) u16 {
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
        const weight = style.weightValue();
        const size = style.size * self.zoom;
        var f: Font = .{ .ascent = size * 0.8, .descent = size * 0.2, .leading = 0, .id = 0xffff, .weight = weight };
        var tf: ?*const tt.Font = null;
        if (self.stackOf(style)) |st| {
            f.id = st.entries[st.primary].id;
            tf = self.run_fonts.items[f.id].font;
        } else {
            const face = self.db.match(if (style.mono) self.mono_family else if (style.system_font) null else self.family, weight, style.italic, style.mono);
            if (face) |fc| if (self.db.load(fc)) |loaded| {
                f.id = self.runFont(fc, size, style.italic, weight);
                tf = loaded;
            };
        }
        if (tf) |t| {
            const k = size / t.units_per_em;
            f.ascent = t.ascent * k;
            f.descent = t.descent * k;
            f.leading = t.line_gap * k;
            f.x_height = t.xHeight() * k;
            f.cap_height = t.capHeight() * k;
            f.zero_width = t.advance(t.glyphIndex('0')) * k;
        }
        self.fonts.put(self.gpa, fk, f) catch {};
        return f;
    }

    pub fn key(s: []const u8, style: types.TextStyle, extra: u64) u64 {
        var h = std.hash.Wyhash.init(extra);
        h.update(s);
        h.update(std.mem.asBytes(&style.size));
        h.update(std.mem.asBytes(&style.mono_scale));
        h.update(&.{ @backingInt(style.weight), @intFromBool(style.mono), @intFromBool(style.italic), @intFromBool(style.system_font), @intFromBool(style.tabular) });
        h.update(std.mem.asBytes(&style.tracking));
        if (style.family) |f| h.update(f);
        h.update(std.mem.asBytes(&style.css_weight));
        h.update(std.mem.asBytes(&style.stretch));
        return h.final();
    }

    pub fn layout(self: *TextSystem, s: []const u8, style: types.TextStyle) Layout {
        if (s.len == 0) return .{ .width = 0, .glyphs = &.{} };
        const k = key(s, style, 1);
        if (self.cached(k)) |l| return l;
        var glyphs: std.ArrayList(Glyph) = .empty;
        var w = self.shapeInto(&glyphs, s, style, 0, 0) catch {
            glyphs.deinit(self.gpa);
            return .{ .width = 0, .glyphs = &.{} };
        };
        if (style.tracking != 0) w += utf8.track(glyphs.items, s, style.tracking);
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
        const stack = self.stackOf(style);
        var prev: ?struct { id: u16, g: u16, digit: bool } = null;
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
            if (stack) |st| if (st.pick(self.run_fonts.items, if (cp == '\t') ' ' else cp)) |p| {
                id = p.id;
                rf = self.run_fonts.items[id];
                g = p.glyph;
            };
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
            // Tabular digits: each in a cell as wide as the widest, unkerned.
            const digit = style.tabular and cp >= '0' and cp <= '9';
            if (prev) |p| if (p.id == id and !digit and !p.digit) {
                x += rf.font.kerning(p.g, g) * k;
            };
            const adv = rf.font.advance(g) * k;
            var cell = adv;
            if (digit) for ("0123456789") |d| {
                cell = @max(cell, rf.font.advance(rf.font.glyphIndex(d)) * k);
            };
            if (cp >= 0x20 or cp == '\t') try out.append(self.gpa, .{ .font = id, .glyph = g, .x = x + (cell - adv) / 2, .y = 0, .index = @intCast(offset + i) });
            x += (cell + rf.embolden * size) * @as(f32, if (cp == '\t') 4 else 1);
            prev = .{ .id = id, .g = g, .digit = digit };
            i += n;
        }
        return x;
    }

    /// Strokes aren't thickened here: `dilation` is for macOS's look.
    pub fn glyph(self: *TextSystem, g: Glyph, bin: u8, dilation: u8) ?Sprite {
        _ = dilation;
        if (g.font >= self.run_fonts.items.len) return null;
        return self.atlas.glyph(g.font, self.run_fonts.items[g.font], g.glyph, bin);
    }

    pub fn positions(self: *TextSystem, g: Glyph) u8 {
        if (g.font >= self.run_fonts.items.len) return 4;
        return self.atlas.positions(g.font, self.run_fonts.items[g.font]);
    }

    pub fn dilationFor(r: f32, g: f32, b: f32) u8 {
        _ = .{ r, g, b };
        return 0;
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

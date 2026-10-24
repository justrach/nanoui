//! Text on macOS: fonts, shaping and measuring with CoreText, and the glyph atlas.
//!
//! A run of text is shaped once into a layout (glyphs, their positions,
//! the fonts CoreText fell back to) that measuring and painting share;
//! layouts live while they are used, two frames at most unused. Glyphs are
//! rasterized once into the atlas, so text that changes every frame (a
//! counter, a clock) costs a shaping and no rasterizing.
const std = @import("std");
const objc = @import("../objc.zig");
const cf = @import("cf.zig");
const types = @import("types.zig");
const atlas_mod = @import("atlas.zig");
const shaper = @import("shaper.zig");
const fonts = @import("fonts.zig");
pub const rich = @import("rich.zig");

pub const Atlas = atlas_mod.Atlas;
pub const Sprite = atlas_mod.Sprite;
pub const subpixel_bins = atlas_mod.subpixel_bins;

extern "c" fn CTFontGetAscent(font: cf.CTFontRef) f64;
extern "c" fn CTFontGetDescent(font: cf.CTFontRef) f64;
extern "c" fn CTFontGetLeading(font: cf.CTFontRef) f64;
extern "c" fn CTLineGetGlyphRuns(line: cf.CTLineRef) *anyopaque;
extern "c" fn CFArrayGetCount(arr: *anyopaque) cf.CFIndex;
extern "c" fn CFArrayGetValueAtIndex(arr: *anyopaque, i: cf.CFIndex) *anyopaque;
extern "c" fn CTRunGetGlyphCount(run: *anyopaque) cf.CFIndex;
extern "c" fn CTRunGetGlyphs(run: *anyopaque, range: cf.CFRange, out: [*]u16) void;
extern "c" fn CTRunGetPositions(run: *anyopaque, range: cf.CFRange, out: [*]objc.CGPoint) void;
extern "c" fn CTRunGetAttributes(run: *anyopaque) *anyopaque;
extern "c" fn CTRunGetStringIndices(run: *anyopaque, range: cf.CFRange, out: [*]cf.CFIndex) void;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *const anyopaque) ?*anyopaque;
extern "c" fn CFHash(ref: *anyopaque) usize;
extern "c" fn CFEqual(a: *anyopaque, b: *anyopaque) bool;

pub const Font = struct {
    ref: cf.CTFontRef,
    ascent: f32,
    descent: f32,
    leading: f32,

    pub fn lineHeight(f: Font) f32 {
        return @ceil(f.ascent + f.descent + f.leading);
    }
};

/// A shaped glyph: `font` indexes the text system's fonts; `x` and `y`
/// are its pen position from the run's origin on the baseline (y up).
/// `index` is the byte offset in the run of the text the glyph draws.
pub const Glyph = struct { font: u16, glyph: u16, x: f32, y: f32, index: u32 = 0 };

pub const Layout = struct { width: f32, glyphs: []const Glyph };

/// A line of wrapped text: a byte range and its width.
pub const Line = struct { start: usize, end: usize, width: f32 };

const FontKey = struct { size_bits: u32, weight: types.Weight, mono: bool, italic: bool };

fn fontKey(style: types.TextStyle) FontKey {
    return .{ .size_bits = @bitCast(style.size), .weight = style.weight, .mono = style.mono, .italic = style.italic };
}

pub const TextSystem = struct {
    gpa: std.mem.Allocator,
    atlas: Atlas,
    /// The pictures shown (`ui.image`).
    images: @import("images.zig").Images,
    scale: f32 = 2,
    fonts: std.AutoHashMapUnmanaged(FontKey, Font) = .empty,
    /// Every font a run used, retained; glyphs refer to them by index.
    run_fonts: std.ArrayList(cf.CTFontRef) = .empty,
    /// The fast path's cached shaping of printable ASCII, per font.
    tables: std.AutoHashMapUnmanaged(FontKey, *shaper.Table) = .empty,
    layouts: std.AutoHashMapUnmanaged(u64, Layout) = .empty,
    previous: std.AutoHashMapUnmanaged(u64, Layout) = .empty,
    wraps: @import("wrap_cache.zig").WrapCache(Line) = .{},
    scratch_glyphs: std.ArrayList(u16) = .empty,
    scratch_points: std.ArrayList(objc.CGPoint) = .empty,
    /// The theme's font families (null: the system's).
    family: ?[]const u8 = null,
    mono_family: ?[]const u8 = null,
    /// Every size times this (`Context.setZoom`).
    zoom: f32 = 1,

    pub fn init(gpa: std.mem.Allocator, device: objc.Object) TextSystem {
        return .{ .gpa = gpa, .atlas = .init(gpa, device), .images = .{ .gpa = gpa } };
    }

    pub fn deinit(self: *TextSystem) void {
        self.images.deinit();
        var fit = self.fonts.valueIterator();
        while (fit.next()) |f| cf.CFRelease(f.ref);
        self.fonts.deinit(self.gpa);
        var tit = self.tables.valueIterator();
        while (tit.next()) |t| {
            t.*.deinit(self.gpa);
            self.gpa.destroy(t.*);
        }
        self.tables.deinit(self.gpa);
        for (self.run_fonts.items) |f| cf.CFRelease(f);
        self.run_fonts.deinit(self.gpa);
        freeLayouts(self.gpa, &self.layouts);
        freeLayouts(self.gpa, &self.previous);
        self.layouts.deinit(self.gpa);
        self.previous.deinit(self.gpa);
        self.wraps.deinit(self.gpa);
        self.scratch_glyphs.deinit(self.gpa);
        self.scratch_points.deinit(self.gpa);
        self.atlas.deinit();
    }

    pub fn texture(self: *TextSystem) objc.Object {
        return self.atlas.texture;
    }

    pub fn setScale(self: *TextSystem, scale: f32) void {
        self.scale = scale;
        self.atlas.setScale(scale);
    }

    /// Uses the theme's font families; a change drops every cached font,
    /// shaping and wrap.
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

    /// Drops every cached font, shaping and wrap.
    fn dropCaches(self: *TextSystem) void {
        var fit = self.fonts.valueIterator();
        while (fit.next()) |f| cf.CFRelease(f.ref);
        self.fonts.clearRetainingCapacity();
        var tit = self.tables.valueIterator();
        while (tit.next()) |t| {
            t.*.deinit(self.gpa);
            self.gpa.destroy(t.*);
        }
        self.tables.clearRetainingCapacity();
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

    /// A line's height in `style`, its leading applied.
    pub fn lineHeight(self: *TextSystem, style: types.TextStyle) f32 {
        if (style.line_height > 0) return style.line_height * self.zoom;
        const lh = self.font(style).lineHeight();
        return if (style.leading == 1) lh else @ceil(lh * style.leading);
    }

    /// Called at the start of every frame: layouts unused for two frames go.
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

    pub fn font(self: *TextSystem, style: types.TextStyle) Font {
        const fk = fontKey(style);
        if (self.fonts.get(fk)) |f| return f;
        const ref = fonts.create(if (style.mono) self.mono_family else self.family, style.size * self.zoom, style.weight, style.italic, style.mono);
        const f: Font = .{
            .ref = ref,
            .ascent = @floatCast(CTFontGetAscent(ref)),
            .descent = @floatCast(CTFontGetDescent(ref)),
            .leading = @floatCast(CTFontGetLeading(ref)),
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

    fn line(self: *TextSystem, s: []const u8, style: types.TextStyle) cf.CTLineRef {
        const attr = cf.attributed(s, self.font(style).ref);
        defer cf.CFRelease(attr);
        return cf.CTLineCreateWithAttributedString(attr).?;
    }

    /// The index of `f` among the run fonts, adding it if new.
    pub fn fontId(self: *TextSystem, f: cf.CTFontRef) u16 {
        const h = CFHash(f);
        for (self.run_fonts.items, 0..) |known, i| {
            if (known == f or (CFHash(known) == h and CFEqual(known, f))) return @intCast(i);
        }
        self.run_fonts.append(self.gpa, @ptrCast(cf.CFRetain(f))) catch return 0;
        return @intCast(self.run_fonts.items.len - 1);
    }

    /// `s` shaped on one line.
    pub fn layout(self: *TextSystem, s: []const u8, style: types.TextStyle) Layout {
        if (s.len == 0) return .{ .width = 0, .glyphs = &.{} };
        const k = key(s, style, 1);
        return self.cached(k) orelse self.keep(k, self.shape(s, style) catch return .{ .width = 0, .glyphs = &.{} });
    }

    /// A layout made in this frame or the last.
    pub fn cached(self: *TextSystem, k: u64) ?Layout {
        if (self.layouts.get(k)) |l| return l;
        if (self.previous.fetchRemove(k)) |kv| {
            self.layouts.put(self.gpa, k, kv.value) catch {};
            return kv.value;
        }
        return null;
    }

    /// Keeps a new layout for this frame and the next.
    pub fn keep(self: *TextSystem, k: u64, l: Layout) Layout {
        self.layouts.put(self.gpa, k, l) catch {
            self.gpa.free(l.glyphs);
            return .{ .width = l.width, .glyphs = &.{} };
        };
        return l;
    }

    fn shape(self: *TextSystem, s: []const u8, style: types.TextStyle) !Layout {
        if (s.len <= 256) if (try self.shapeFast(s, style)) |l| return l;
        const ln = self.line(s, style);
        defer cf.CFRelease(ln);
        return self.glyphsOf(ln, s);
    }

    /// The glyphs of a shaped line of `s`, with byte offsets.
    pub fn glyphsOf(self: *TextSystem, ln: cf.CTLineRef, s: []const u8) !Layout {
        const w: f32 = @floatCast(cf.CTLineGetTypographicBounds(ln, null, null, null));
        var glyphs: std.ArrayList(Glyph) = .empty;
        errdefer glyphs.deinit(self.gpa);
        // UTF-16 offsets (CoreText's) to byte offsets (ours).
        var bytes_of: std.ArrayList(u32) = .empty;
        defer bytes_of.deinit(self.gpa);
        {
            var i: usize = 0;
            while (i < s.len) {
                const n = cf.seqLen(s[i]);
                try bytes_of.append(self.gpa, @intCast(i));
                if (n == 4) try bytes_of.append(self.gpa, @intCast(i));
                i += n;
            }
        }
        var indices: std.ArrayList(cf.CFIndex) = .empty;
        defer indices.deinit(self.gpa);
        const runs = CTLineGetGlyphRuns(ln);
        const n_runs = CFArrayGetCount(runs);
        var r: cf.CFIndex = 0;
        while (r < n_runs) : (r += 1) {
            const run = CFArrayGetValueAtIndex(runs, r);
            const count: usize = @intCast(CTRunGetGlyphCount(run));
            if (count == 0) continue;
            const run_font = CFDictionaryGetValue(CTRunGetAttributes(run), cf.kCTFontAttributeName) orelse continue;
            const fid = self.fontId(@ptrCast(run_font));
            try self.scratch_glyphs.resize(self.gpa, count);
            try self.scratch_points.resize(self.gpa, count);
            const all: cf.CFRange = .{ .location = 0, .length = 0 };
            CTRunGetGlyphs(run, all, self.scratch_glyphs.items.ptr);
            CTRunGetPositions(run, all, self.scratch_points.items.ptr);
            try indices.resize(self.gpa, count);
            CTRunGetStringIndices(run, all, indices.items.ptr);
            for (self.scratch_glyphs.items, self.scratch_points.items, indices.items) |g, p, u| {
                const u16i: usize = @intCast(@max(0, u));
                const at = if (u16i < bytes_of.items.len) bytes_of.items[u16i] else @as(u32, @intCast(s.len));
                try glyphs.append(self.gpa, .{ .font = fid, .glyph = g, .x = @floatCast(p.x), .y = @floatCast(p.y), .index = at });
            }
        }
        return .{ .width = w, .glyphs = try glyphs.toOwnedSlice(self.gpa) };
    }

    /// Printable ASCII through the cached tables, null if it needs CoreText.
    fn shapeFast(self: *TextSystem, s: []const u8, style: types.TextStyle) !?Layout {
        const fk = fontKey(style);
        const gop = try self.tables.getOrPut(self.gpa, fk);
        if (!gop.found_existing) {
            const t = self.gpa.create(shaper.Table) catch |err| {
                _ = self.tables.remove(fk);
                return err;
            };
            t.* = .{ .font = self.font(style).ref };
            gop.value_ptr.* = t;
        }
        const t = gop.value_ptr.*;
        var gs: [256]u16 = undefined;
        var xs: [256]f32 = undefined;
        const w = t.layout(self.gpa, s, gs[0..s.len], xs[0..s.len]) orelse return null;
        const fid = self.fontId(@ptrCast(t.run_font orelse return null));
        const glyphs = try self.gpa.alloc(Glyph, s.len);
        for (glyphs, gs[0..s.len], xs[0..s.len], 0..) |*g, id, x, i| g.* = .{ .font = fid, .glyph = id, .x = x, .y = 0, .index = @intCast(i) };
        return .{ .width = w, .glyphs = glyphs };
    }

    /// The atlas sprite of a shaped glyph at `bin` quarters of a pixel.
    pub fn glyph(self: *TextSystem, g: Glyph, bin: u8) ?Sprite {
        if (g.font >= self.run_fonts.items.len) return null;
        return self.atlas.glyph(g.font, self.run_fonts.items[g.font], g.glyph, bin);
    }

    /// The width of `s` on one line.
    pub fn width(self: *TextSystem, s: []const u8, style: types.TextStyle) f32 {
        return self.layout(s, style).width;
    }

    /// `s` broken into lines no wider than `max_width`.
    pub fn wrap(self: *TextSystem, s: []const u8, style: types.TextStyle, max_width: f32) []const Line {
        return self.wrapAttributed(s, style, &.{}, max_width);
    }

    /// `s` with its spans broken into lines no wider than `max_width`.
    pub fn wrapAttributed(self: *TextSystem, s: []const u8, style: types.TextStyle, spans: []const types.Span, max_width: f32) []const Line {
        const styled = rich.styled(spans);
        const k = key(s, style, (@as(u64, @intFromFloat(@max(0, @min(max_width, 1e6)))) + 2) ^ (if (styled) rich.spansHash(spans, 0, s.len) else 0));
        if (self.wraps.get(self.gpa, k)) |lines| return lines;
        if (self.oneLine(s, style, spans, max_width)) |line_| {
            const one = self.gpa.alloc(Line, 1) catch return &.{};
            one[0] = line_;
            return self.wraps.put(self.gpa, k, one);
        }
        return self.wraps.put(self.gpa, k, self.breakLines(s, style, spans, max_width) catch return &.{});
    }

    /// `s` as one line, when it has no line breaks and fits: what CoreText
    /// would answer, without a typesetter (a resize asks for every line of
    /// a window at each new width). Null when it must break.
    pub fn oneLine(self: *TextSystem, s: []const u8, style: types.TextStyle, spans: []const types.Span, max_width: f32) ?Line {
        if (std.mem.indexOfAny(u8, s, "\n\r\x0b\x0c") != null) return null;
        // NEL, and the line and paragraph separators.
        if (std.mem.indexOf(u8, s, "\u{85}") != null or std.mem.indexOf(u8, s, "\u{2028}") != null or std.mem.indexOf(u8, s, "\u{2029}") != null) return null;
        const styled = rich.styled(spans);
        const full = if (styled) rich.layout(self, s, style, spans, 0).width else self.width(s, style);
        if (full > @max(1, max_width)) return null;
        const trimmed = std.mem.trimEnd(u8, s, " \t");
        const w = if (styled) rich.layout(self, trimmed, style, spans, 0).width else self.width(trimmed, style);
        return .{ .start = 0, .end = trimmed.len, .width = w };
    }

    /// `s` broken where CoreText's typesetter suggests.
    pub fn breakLines(self: *TextSystem, s: []const u8, style: types.TextStyle, spans: []const types.Span, max_width: f32) ![]Line {
        const styled = rich.styled(spans);
        var lines: std.ArrayList(Line) = .empty;
        defer lines.deinit(self.gpa);
        const attr = if (styled) rich.attributed(self, s, style, spans, 0) else cf.attributed(s, self.font(style).ref);
        defer cf.CFRelease(attr);
        const ts = cf.CTTypesetterCreateWithAttributedString(attr).?;
        defer cf.CFRelease(ts);
        const total = cf.utf16Offset(s, s.len);
        var start16: cf.CFIndex = 0;
        while (start16 < total) {
            var n = cf.CTTypesetterSuggestLineBreak(ts, start16, @max(1, max_width));
            if (n <= 0) n = 1;
            const a = cf.byteOffset(s, start16);
            const b = cf.byteOffset(s, start16 + n);
            const trimmed = std.mem.trimEnd(u8, s[a..b], " \n\r\t");
            const w = if (styled) rich.layout(self, s[a .. a + trimmed.len], style, spans, a).width else self.width(trimmed, style);
            lines.append(self.gpa, .{ .start = a, .end = a + trimmed.len, .width = w }) catch break;
            start16 += n;
        }
        if (lines.items.len == 0) lines.append(self.gpa, .{ .start = 0, .end = 0, .width = 0 }) catch {};
        return lines.toOwnedSlice(self.gpa);
    }

    /// The x offset of the caret before byte `index` of `s`.
    pub fn caretX(self: *TextSystem, s: []const u8, style: types.TextStyle, index: usize) f32 {
        if (s.len == 0 or index == 0) return 0;
        const l = self.line(s, style);
        defer cf.CFRelease(l);
        return @floatCast(cf.CTLineGetOffsetForStringIndex(l, cf.utf16Offset(s, index), null));
    }

    /// The byte index of the caret position nearest to `x`.
    pub fn indexAt(self: *TextSystem, s: []const u8, style: types.TextStyle, x: f32) usize {
        if (s.len == 0) return 0;
        const l = self.line(s, style);
        defer cf.CFRelease(l);
        const i = cf.CTLineGetStringIndexForPosition(l, .{ .x = x, .y = 0 });
        return if (i < 0) s.len else cf.byteOffset(s, i);
    }
};

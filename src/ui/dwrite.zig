//! DirectWrite glyph coverage at the layout's exact em size and subpixel
//! position. Load the SAME font bytes/collection face as nanoui: a glyph
//! index is meaningful only in the face that produced it. Work happens on
//! atlas misses, never per frame. Windows 10 1703+; older DirectWrite
//! versions fall back to the portable text path.
const std = @import("std");
const font = @import("tt/font.zig");
const blending = @import("text_blend.zig");
pub const enabled = @import("builtin").os.tag == .windows and !@import("build_options").portable;

const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const factory5_iid: Guid = .{ .a = 0x958db99a, .b = 0xbe2a, .c = 0x4f09, .d = .{ 0xaf, 0x7d, 0x65, 0x18, 0x98, 0x03, 0xd1, 0xd3 } };
const face3_iid: Guid = .{ .a = 0xd37d7598, .b = 0x09be, .c = 0x4222, .d = .{ 0xa2, 0x36, 0x20, 0x81, 0x34, 0x1c, 0xc1, 0xf2 } };
const params1_iid: Guid = .{ .a = 0x94413cf4, .b = 0xa6fc, .c = 0x4248, .d = .{ 0x8b, 0x50, 0x66, 0x74, 0x34, 0x8f, 0xca, 0xd3 } };
const Com = extern struct {
    vtable: [*]const *const anyopaque,

    fn method(self: *Com, comptime index: usize, comptime F: type) F {
        return @ptrCast(@alignCast(self.vtable[index]));
    }

    fn release(self: *Com) void {
        if (enabled) _ = self.method(2, *const fn (*Com) callconv(.winapi) u32)(self);
    }
};
extern "dwrite" fn DWriteCreateFactory(u32, *const Guid, *?*Com) callconv(.winapi) i32;
extern "user32" fn SystemParametersInfoW(u32, u32, *anyopaque, u32) callconv(.winapi) i32;
const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
const GlyphRun = extern struct {
    face: *Com,
    em_size: f32,
    count: u32 = 1,
    indices: *const u16,
    advances: ?*const f32 = null,
    offsets: ?*const anyopaque = null,
    sideways: i32 = 0,
    bidi_level: u32 = 0,
};
const Key = struct { face: usize, simulations: u32 };
pub const Bitmap = struct { bytes: []const u8, rgb: []const u8, w: u32, h: u32, stride: u32, x: f32, y: f32 };

pub const Cache = struct {
    unavailable: bool = false,
    factory: ?*Com = null,
    loader: ?*Com = null,
    params: ?*Com = null,
    blending: blending.Params = .{},
    cleartype: bool = false,
    aliased: bool = false,
    bgr: bool = false,
    clear_level: f32 = 1,
    fonts: std.AutoHashMapUnmanaged(Key, *Com) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    rgb: std.ArrayList(u8) = .empty,
    scratch: std.ArrayList(u8) = .empty,
    /// Audits reject a silent fallback to the unhinted portable rasterizer.
    failures: usize = 0,

    pub fn deinit(self: *Cache, gpa: std.mem.Allocator) void {
        if (enabled) {
            var it = self.fonts.valueIterator();
            while (it.next()) |cached_face| cached_face.*.release();
            if (self.params) |params| params.release();
            if (self.loader) |loader| {
                if (self.factory) |factory| _ = factory.method(14, *const fn (*Com, *Com) callconv(.winapi) i32)(factory, loader);
                loader.release();
            }
            if (self.factory) |factory| factory.release();
        }
        self.fonts.deinit(gpa);
        self.bytes.deinit(gpa);
        self.rgb.deinit(gpa);
        self.scratch.deinit(gpa);
    }

    fn initialize(self: *Cache) !void {
        if (self.factory != null) return;
        if (self.unavailable) return error.DirectWriteUnavailable;
        errdefer self.unavailable = true;
        var factory: ?*Com = null;
        // An isolated factory gives the loader/cache the atlas's lifetime.
        if (DWriteCreateFactory(1, &factory5_iid, &factory) < 0) return error.DirectWriteFactory;
        const f = factory orelse return error.DirectWriteFactory;
        errdefer f.release();
        var loader: ?*Com = null;
        if (f.method(44, *const fn (*Com, *?*Com) callconv(.winapi) i32)(f, &loader) < 0) return error.DirectWriteLoader;
        const l = loader orelse return error.DirectWriteLoader;
        errdefer l.release();
        if (f.method(13, *const fn (*Com, *Com) callconv(.winapi) i32)(f, l) < 0) return error.DirectWriteLoader;
        errdefer _ = f.method(14, *const fn (*Com, *Com) callconv(.winapi) i32)(f, l);
        var params: ?*Com = null;
        if (f.method(10, *const fn (*Com, *?*Com) callconv(.winapi) i32)(f, &params) < 0) return error.DirectWriteParams;
        self.params = params orelse return error.DirectWriteParams;
        const p = self.params.?;
        const gamma = p.method(3, *const fn (*Com) callconv(.winapi) f32)(p);
        const contrast = p.method(4, *const fn (*Com) callconv(.winapi) f32)(p);
        self.blending = .{ .gamma = blending.gammaRatios(gamma), .contrast = contrast, .grayscale_contrast = contrast };
        var p1: ?*Com = null;
        if (p.method(0, *const fn (*Com, *const Guid, *?*Com) callconv(.winapi) i32)(p, &params1_iid, &p1) >= 0) {
            if (p1) |gray| {
                self.blending.grayscale_contrast = gray.method(8, *const fn (*Com) callconv(.winapi) f32)(gray);
                gray.release();
            }
        }
        self.clear_level = std.math.clamp(p.method(5, *const fn (*Com) callconv(.winapi) f32)(p), 0, 1);
        const geometry = p.method(6, *const fn (*Com) callconv(.winapi) u32)(p);
        self.bgr = geometry == 2;
        var smooth: i32 = 1;
        var kind: u32 = 0;
        _ = SystemParametersInfoW(0x004a, 0, &smooth, 0);
        _ = SystemParametersInfoW(0x200a, 0, &kind, 0);
        self.aliased = smooth == 0 or p.method(7, *const fn (*Com) callconv(.winapi) u32)(p) == 1;
        self.cleartype = !self.aliased and kind == 2 and geometry != 0;
        if (self.aliased) self.blending = .{};
        self.factory = f;
        self.loader = l;
    }

    fn face(self: *Cache, gpa: std.mem.Allocator, rf: anytype) !*Com {
        const key: Key = .{
            .face = @intFromPtr(rf.font),
            .simulations = @as(u32, if (rf.embolden > 0) 1 else 0) | @as(u32, if (rf.skew != 0) 2 else 0),
        };
        if (self.fonts.get(key)) |f| return f;
        try self.initialize();
        const factory = self.factory.?;
        const loader = self.loader.?;
        var file: ?*Com = null;
        // A null owner makes DirectWrite own a copy of the bytes, independent
        // of the font database's lifetime. No GDI family-name substitution.
        if (loader.method(4, *const fn (*Com, *Com, [*]const u8, u32, ?*Com, *?*Com) callconv(.winapi) i32)(loader, factory, rf.font.data.ptr, @intCast(rf.font.data.len), null, &file) < 0) return error.DirectWriteFontFile;
        const ff = file orelse return error.DirectWriteFontFile;
        defer ff.release();
        var supported: i32 = 0;
        var file_type: u32 = 0;
        var face_type: u32 = 0;
        var count: u32 = 0;
        if (ff.method(5, *const fn (*Com, *i32, *u32, *u32, *u32) callconv(.winapi) i32)(ff, &supported, &file_type, &face_type, &count) < 0 or supported == 0) return error.DirectWriteFontFile;
        const index: u32 = for (0..font.faces(rf.font.data)) |i| {
            const tables = font.Tables.read(rf.font.data, i) catch continue;
            if (tables.head == rf.font.t.head) break @intCast(i);
        } else return error.DirectWriteFontFace;
        if (index >= count) return error.DirectWriteFontFace;
        var result: ?*Com = null;
        if (factory.method(9, *const fn (*Com, u32, u32, *const *Com, u32, u32, *?*Com) callconv(.winapi) i32)(factory, face_type, 1, &ff, index, key.simulations, &result) < 0) return error.DirectWriteFontFace;
        const base = result orelse return error.DirectWriteFontFace;
        defer base.release();
        const f = try face3(base);
        errdefer f.release();
        try self.fonts.put(gpa, key, f);
        return f;
    }

    fn face3(base: *Com) !*Com {
        var result: ?*Com = null;
        if (base.method(0, *const fn (*Com, *const Guid, *?*Com) callconv(.winapi) i32)(base, &face3_iid, &result) < 0) return error.DirectWriteFontFace;
        return result orelse return error.DirectWriteFontFace;
    }

    pub fn mode(self: *Cache, f: *Com, size: f32, scale: f32) struct { rendering: u32, grid: u32 } {
        if (self.aliased) return .{ .rendering = 1, .grid = 0 };
        var rendering: u32 = 5;
        var grid: u32 = 0;
        const hr = f.method(44, *const fn (*Com, f32, f32, f32, ?*const anyopaque, i32, u32, u32, ?*Com, *u32, *u32) callconv(.winapi) i32)(f, size, 96 * scale, 96 * scale, null, 0, 0, 0, self.params, &rendering, &grid);
        if (hr < 0 or rendering == 0 or rendering == 6) rendering = 5;
        return .{ .rendering = rendering, .grid = grid };
    }

    pub fn positions(self: *Cache, gpa: std.mem.Allocator, rf: anytype, scale: f32) !u8 {
        const m = self.mode(try self.face(gpa, rf), rf.size, scale);
        if (m.rendering <= 3) return 1;
        if (self.cleartype) return 6;
        return switch (m.rendering) {
            4 => 8,
            7 => 2,
            else => 4,
        };
    }

    fn analyze(self: *Cache, run: *const GlyphRun, phase: f32, rendering: u32, grid: u32, clear: bool) !struct { analysis: *Com, bounds: Rect } {
        const factory = self.factory.?;
        var analysis: ?*Com = null;
        // Factory3 accepts the high-DPI downsampled rendering mode too.
        if (factory.method(31, *const fn (*Com, *const GlyphRun, ?*const anyopaque, u32, u32, u32, u32, f32, f32, *?*Com) callconv(.winapi) i32)(factory, run, null, rendering, 0, grid, if (clear) 0 else 1, phase, 0, &analysis) < 0) return error.DirectWriteAnalysis;
        const a = analysis orelse return error.DirectWriteAnalysis;
        errdefer a.release();
        var bounds: Rect = undefined;
        if (a.method(3, *const fn (*Com, u32, *Rect) callconv(.winapi) i32)(a, @intFromBool(clear), &bounds) < 0) return error.DirectWriteBounds;
        return .{ .analysis = a, .bounds = bounds };
    }

    pub fn rasterize(self: *Cache, gpa: std.mem.Allocator, rf: anytype, glyph: u16, scale: f32, phase: f32) !?Bitmap {
        if (!enabled) return null;
        const run: GlyphRun = .{ .face = try self.face(gpa, rf), .em_size = rf.size * scale, .indices = &glyph };
        const m = self.mode(run.face, rf.size, scale);
        const gray = try self.analyze(&run, phase, m.rendering, m.grid, false);
        defer gray.analysis.release();
        const clear = if (self.cleartype) try self.analyze(&run, phase, m.rendering, m.grid, true) else null;
        defer if (clear) |c| c.analysis.release();
        const gb = gray.bounds;
        const cb = if (clear) |c| c.bounds else gb;
        const bounds: Rect = .{ .left = @min(gb.left, cb.left), .top = @min(gb.top, cb.top), .right = @max(gb.right, cb.right), .bottom = @max(gb.bottom, cb.bottom) };
        if (bounds.right <= bounds.left or bounds.bottom <= bounds.top) return null;
        const w: u32 = @intCast(bounds.right - bounds.left);
        const h: u32 = @intCast(bounds.bottom - bounds.top);
        const len = try std.math.mul(u32, w, h);
        try self.bytes.resize(gpa, len);
        if (gray.analysis.method(4, *const fn (*Com, u32, *const Rect, [*]u8, u32) callconv(.winapi) i32)(gray.analysis, 0, &bounds, self.bytes.items.ptr, len) < 0) return error.DirectWriteTexture;
        try self.rgb.resize(gpa, len * 4);
        @memset(self.rgb.items, 0);
        if (clear) |c| {
            try self.scratch.resize(gpa, len * 3);
            if (c.analysis.method(4, *const fn (*Com, u32, *const Rect, [*]u8, u32) callconv(.winapi) i32)(c.analysis, 1, &bounds, self.scratch.items.ptr, len * 3) < 0) return error.DirectWriteTexture;
            for (0..len) |i| {
                const v = self.scratch.items[i * 3 ..][0..3];
                const mean = (@as(f32, @floatFromInt(v[0])) + @as(f32, @floatFromInt(v[1])) + @as(f32, @floatFromInt(v[2]))) / 3;
                for (0..3) |ch| {
                    const value: f32 = @floatFromInt(v[if (self.bgr) 2 - ch else ch]);
                    self.rgb.items[i * 4 + ch] = @intFromFloat(@round(mean + (value - mean) * self.clear_level));
                }
                self.rgb.items[i * 4 + 3] = 255;
            }
        } else {
            for (0..len) |i| self.rgb.items[i * 4 + 3] = 128;
        }
        return .{ .bytes = self.bytes.items, .rgb = self.rgb.items, .w = w, .h = h, .stride = w, .x = @floatFromInt(bounds.left), .y = @floatFromInt(-bounds.top) };
    }
};

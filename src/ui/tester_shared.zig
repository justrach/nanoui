//! A renderer and text system lent to one `ui.Tester` after another
//! (`TesterOptions.shared`, or every Tester of a test binary built with
//! `-Dtester-shares-caches`).
const std = @import("std");
const text = @import("text.zig");
const portable = text.portable;
const metal = if (portable) struct {
    pub const Renderer = void;
} else @import("metal.zig");

/// What a Tester draws and shapes with, lent to one Tester after another:
/// the GPU device and its pipelines, the fonts found and loaded, the glyph
/// atlas and the shaping and layout caches stay warm, so a test's first
/// frame costs what a window's later frames do. Every Tester still has its
/// own context, view and clock; what one leaves behind that the next could
/// see (pictures, zoom, line rules) is reset when it is lent again.
pub const Shared = struct {
    gpa: std.mem.Allocator,
    renderer: metal.Renderer,
    text: text.TextSystem,
    /// The text system's families, kept here: a theme's strings may be gone
    /// once the Tester that named them is.
    family: [256]u8 = undefined,
    mono_family: [256]u8 = undefined,
    /// A Tester has it now.
    lent: bool = false,

    /// Initializes in place (the text system may point into the renderer).
    /// `gpa` outlives every Tester lent it: not `std.testing.allocator`,
    /// which checks for leaks after each test.
    pub fn init(s: *Shared, gpa: std.mem.Allocator) !void {
        var renderer: metal.Renderer = if (portable) {} else try metal.Renderer.init();
        errdefer if (!portable) renderer.deinit();
        s.* = .{
            .gpa = gpa,
            .renderer = renderer,
            .text = if (portable) .init(gpa) else .init(gpa, renderer.device),
        };
    }

    pub fn deinit(s: *Shared) void {
        s.text.deinit();
        if (!portable) s.renderer.deinit();
    }

    /// The process's own, made on first use and never freed (tests only);
    /// null while another Tester has it (a test with two windows open).
    pub fn process() !?*Shared {
        const S = struct {
            var shared: ?*Shared = null;
        };
        if (S.shared) |sh| return if (sh.lent) null else sh;
        const gpa = std.heap.smp_allocator;
        const sh = try gpa.create(Shared);
        errdefer gpa.destroy(sh);
        try sh.init(gpa);
        S.shared = sh;
        return sh;
    }

    pub fn lend(s: *Shared) !void {
        if (s.lent) return error.SharedInUse;
        s.lent = true;
        text.restoreDefaults(&s.text);
        if (!portable) restoreRenderer(&s.renderer);
    }

    /// What a test may have set on the renderer, as `Renderer.init` left it.
    fn restoreRenderer(r: *metal.Renderer) void {
        r.images_generation = std.math.maxInt(u64);
        r.setColour(.sdr_srgb) catch {};
        r.setInTransaction(false);
        r.setLiveResize(false);
        r.textures = &.{};
        r.gradients = &.{};
        r.before_encode = null;
        r.backdrop = null;
        r.sdr_white_scale = 1;
        r.plane_mode = false;
        r.framebuffer_only = true;
        r.time = 0;
        r.present_at = 0;
    }

    pub fn giveBack(s: *Shared) void {
        s.lent = false;
        // The context these pointed into is gone.
        if (!portable) {
            s.renderer.textures = &.{};
            s.renderer.gradients = &.{};
        }
        // Pictures are known by keys their views chose: the next view's
        // could mean another picture.
        s.text.images.deinit();
        s.text.images = .{ .gpa = s.gpa };
        keep(&s.text.family, &s.family);
        keep(&s.text.mono_family, &s.mono_family);
    }

    /// Points `name` at a copy in `buf`, the same text, so caches made for
    /// it still hold; forgets it (and them) if it doesn't fit.
    fn keep(name: *?[]const u8, buf: []u8) void {
        const n = name.* orelse return;
        if (n.ptr == buf.ptr) return;
        if (n.len > buf.len) {
            name.* = null;
            return;
        }
        @memcpy(buf[0..n.len], n);
        name.* = buf[0..n.len];
    }
};

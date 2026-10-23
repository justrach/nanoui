//! What the renderers draw, whichever draws it: instanced quads that are
//! rounded rectangles with borders, glyphs and icons from the atlas,
//! shadows, pictures from the image atlas, or panes of glass, each clipped. Metal draws them on macOS (`metal.zig`, with
//! `shader.metal`); `raster.zig` draws the same pixels on the CPU.
const types = @import("types.zig");
const std = @import("std");

/// One quad, as the shader reads it.
pub const Instance = extern struct {
    rect: [4]f32,
    color: [4]f32,
    border_color: [4]f32 = .{ 0, 0, 0, 0 },
    uv: [4]f32 = .{ 0, 0, 0, 0 },
    clip: [4]f32 = .{ -1e6, -1e6, 1e6, 1e6 },
    radius: f32 = 0,
    border_width: f32 = 0,
    kind: f32 = 0,
    /// The clip's rounded corners (`clipRound`): 0 for a plain rectangle.
    clip_round: f32 = 0,
    xf: [4]f32 = .{ 0, 0, 0, 0 },
    pulse: [4]f32 = .{ 0, 0, 1, 0 },
    vel: [4]f32 = .{ 0, 0, 0, 0 },
};
comptime {
    std.debug.assert(@sizeOf(Instance) == 144);
}

/// The clip rectangle's corners rounded by `radius`: those in `corners`
/// (1 top left, 2 top right, 4 bottom right, 8 bottom left), packed in one
/// float as the shader reads it.
pub fn clipRound(radius: f32, corners: u4) f32 {
    if (corners == 0 or radius <= 0) return 0;
    return @as(f32, @floatFromInt(corners)) * 4096 + @min(radius, 4095);
}

/// `clipRound` unpacked: the radius and the corners.
pub fn clipCorners(v: f32) struct { radius: f32, corners: u4 } {
    if (v <= 0) return .{ .radius = 0, .corners = 0 };
    const m = @floor(v / 4096);
    return .{ .radius = v - m * 4096, .corners = @intFromFloat(m) };
}

pub const Kind = struct {
    pub const quad: f32 = 0;
    pub const text: f32 = 1;
    pub const shadow: f32 = 2;
    /// A picture from the image atlas (`images.zig`), its corners rounded.
    pub const image: f32 = 3;
    /// A pane of Liquid Glass over what was drawn before it (`glass.zig`):
    /// `color` its tint, `uv` its bezel, refraction, opacity and rim width,
    /// `border_color` its tone (low, high, curve, saturation), and
    /// `border_width` the blur of what shows through, all in points.
    pub const glass: f32 = 4;
    /// A shadow drawn outside its box only (`Shadow.knockout`): what is
    /// under the box shows through it. `uv`'s x, y: where the box is from
    /// the shadow's rect, in points.
    pub const shadow_out: f32 = 5;
    /// A line (`ui.Canvas`): from `uv`'s first point to its second, in
    /// points, `border_width` wide, its ends round; dashed when
    /// `border_color` holds a dash's length, the gap's and where the line
    /// starts in them. `rect` bounds it.
    pub const segment: f32 = 6;
    /// A filled triangle (`ui.Canvas`): its corners `uv`'s two points and
    /// `border_color`'s first; `border_color`'s third says which edges are
    /// smoothed (1 the first to the second, 2 the second to the third, 4
    /// the third to the first), the others shared with triangles beside it,
    /// cut sharp so the two meet without a seam. `rect` bounds it.
    pub const triangle: f32 = 7;
    /// A texture the app gave this frame (`ui.texture`, a video frame):
    /// `uv` the part of it shown, `border_width` its slot in the frame's
    /// textures, its corners rounded as a picture's.
    pub const texture: f32 = 8;
    pub const layer_begin: f32 = 9;
    pub const layer_end: f32 = 10;
    pub const layer_composite: f32 = 11;
};

/// Pixels the app gives a frame to show (`ui.texture`), changing as often
/// as it likes: a video's frames. On macOS a CVPixelBuffer (BGRA, Metal
/// compatible) is wrapped as a texture without a copy; else, or for the
/// CPU renderer, `bgra` (premultiplied, `stride` bytes a row, 0 for
/// `width * 4`) is drawn.
pub const Texture = struct {
    width: u32,
    height: u32,
    bgra: []const u8 = &.{},
    stride: usize = 0,
    /// A CVPixelBufferRef, kept alive by the app until the frame is drawn.
    pixel_buffer: ?*anyopaque = null,
};

pub fn color4(c: types.Color) [4]f32 {
    return .{ c.r, c.g, c.b, c.a };
}

pub fn clip4(r: types.Rect) [4]f32 {
    return .{ r.x, r.y, r.x + r.w, r.y + r.h };
}

/// A rendered frame: BGRA, premultiplied, `width * 4` bytes per row.
pub const Pixels = struct {
    bytes: []u8,
    width: usize,
    height: usize,

    pub fn deinit(p: Pixels, gpa: std.mem.Allocator) void {
        gpa.free(p.bytes);
    }
};

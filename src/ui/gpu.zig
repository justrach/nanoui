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
    /// Motion blur's vector (x, y), and the face it is on (`Style.face`:
    /// 0 both, 1 front, 2 back) with the x a back face mirrors about.
    vel: [4]f32 = .{ 0, 0, 0, 0 },
    /// A turn about the vertical axis (`Style.turn`): the angle (radians),
    /// the eye's distance (points, 0 flat), and the pivot's x, y.
    turn: [4]f32 = .{ 0, 0, 0, 0 },
    /// A plane transform of where everything else puts it (`Style.transform`):
    /// x' = m0 x + m2 y + mt0, y' = m1 x + m3 y + mt1. Its clip is where it
    /// lands; shapes are worked out before it, so a rounded corner stays one.
    m: [4]f32 = .{ 1, 0, 0, 1 },
    mt: [4]f32 = .{ 0, 0, 0, 0 },
};
comptime {
    std.debug.assert(@sizeOf(Instance) == 192);
}

/// Whether `i` carries a transform other than none.
pub fn hasMatrix(i: *const Instance) bool {
    return i.m[0] != 1 or i.m[1] != 0 or i.m[2] != 0 or i.m[3] != 1 or i.mt[0] != 0 or i.mt[1] != 0;
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
    /// A rounded box cut out of the frame (`ui.hole`), drawn as a quad's
    /// fill: what's under the frame (a map) shows there.
    pub const hole: f32 = 12;
};

/// Pixels the app gives a frame to show (`ui.texture`), changing as often
/// as it likes: a video's frames. On macOS a CVPixelBuffer (Metal
/// compatible) is wrapped as a texture without a copy, a plane at a time;
/// an app's own MTLTexture (`mtl_texture`) is drawn as it is; else, or for
/// the CPU renderer, `bgra` (premultiplied, `stride` bytes a row, 0 for
/// `width * 4`) is drawn. A frame that isn't BGRA, or that has a LUT, is
/// first made display sRGB at its own size by the colour stage
/// (`texture_post.metal`, mirrored on the CPU by `color.zig`).
pub const Texture = struct {
    width: u32,
    height: u32,
    bgra: []const u8 = &.{},
    stride: usize = 0,
    /// A CVPixelBufferRef, kept alive by the app until the frame is drawn.
    /// `pixel_buffer.texture` fills in its format, range, matrix and
    /// transfer from the buffer itself.
    pixel_buffer: ?*anyopaque = null,
    /// An app's MTLTexture (made on `ui.metalDevice()`, filled in its own
    /// passes: `Surface.before_encode`), kept alive by the app until the
    /// frame is drawn. A float or sRGB one holds linear light and is
    /// encoded for the display; any other is shown as its values are.
    mtl_texture: ?*anyopaque = null,
    format: Format = .bgra8,
    range: Range = .video,
    matrix: Matrix = .bt709,
    transfer: Transfer = .rec709,
    /// HDR (PQ, HLG) and linear half-float frames: highlights compressed
    /// into SDR (`hdr_to_sdr`), else clipped at 100 nits.
    tone_map: bool = true,
    /// A look applied first (a camera's log to Rec. 709), then the output
    /// LUT (`ui.lut`), both on display-encoded colour.
    source_lut: ?Lut = null,
    lut: ?Lut = null,

    /// Whether the colour stage must run before the frame is drawn.
    pub fn needsPost(t: Texture) bool {
        return t.format != .bgra8 or t.lut != null or t.source_lut != null;
    }
};

/// What a texture's pixels are: BGRA (display sRGB, premultiplied), two-
/// plane Y'CbCr (luma, then interleaved chroma: NV12, P010 and the 10-bit
/// 4:2:2 and 4:4:4 the ProRes decoders make), or linear half floats.
pub const Format = enum { bgra8, ycbcr420_8, ycbcr420_10, ycbcr422_10, ycbcr444_10, rgba16f };
/// Video (16-235) or full (0-255) code values, as the post shader's `rangeMode`.
pub const Range = enum(u32) { video = 0, full = 1 };
/// The Y'CbCr matrix, as the post shader's `matrixMode`.
pub const Matrix = enum(u32) { bt709 = 0, bt601 = 1, bt2020 = 2 };
/// How the frame's values encode light, as the post shader's `transferMode`.
pub const Transfer = enum(u32) { rec709 = 0, srgb = 1, linear = 2, pq = 3, hlg = 4 };

/// A 3D LUT (`ui.lut`): `size`³ RGBA half floats, red fastest (a .cube's
/// order), over `domain_min` to `domain_max`. Its data is kept by the app;
/// the GPU's copy is made once per key.
pub const Lut = struct {
    key: u64,
    size: u16,
    data: []const f16,
    domain_min: [3]f32 = .{ 0, 0, 0 },
    domain_max: [3]f32 = .{ 1, 1, 1 },

    pub const max_size = 65;

    pub fn valid(l: Lut) bool {
        const n: usize = l.size;
        return l.size >= 2 and l.size <= max_size and l.data.len >= n * n * n * 4;
    }
};

/// Called with the frame's MTLCommandBuffer before nanoui encodes into it
/// (`Surface.before_encode`): an app's own compute or render passes, whose
/// textures the frame then shows (`Texture.mtl_texture`).
pub const BeforeEncode = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, cmd_buffer: *anyopaque) void,
};

/// The last instance that is a plain, opaque quad covering all of `size`
/// (a window's background): everything before it is hidden, so it can be
/// the frame's clear color instead of shaded pixels. Null if there is
/// none, or if a group, pane of glass, hole or texture comes before it
/// (their passes must still run in order).
pub fn lastCover(instances: []const Instance, size: types.Size) ?usize {
    var found: ?usize = null;
    for (instances, 0..) |inst, k| {
        const kind = inst.kind;
        if (kind == Kind.glass or kind == Kind.layer_begin or kind == Kind.layer_end or kind == Kind.hole or kind == Kind.texture) return found;
        if (kind != Kind.quad or inst.color[3] < 1) continue;
        if (inst.radius != 0 or (inst.border_width > 0 and inst.border_color[3] > 0) or inst.uv[1] != 0 or hasMatrix(&inst)) continue;
        if (inst.clip_round != 0 or inst.xf[0] != 0 or inst.xf[1] != 0 or inst.pulse[0] > 0) continue;
        if (inst.vel[0] != 0 or inst.vel[1] != 0 or inst.vel[2] != 0 or inst.turn[0] != 0) continue;
        const r = inst.rect;
        if (r[0] > 0 or r[1] > 0 or r[0] + r[2] < size.w or r[1] + r[3] < size.h) continue;
        const c = inst.clip;
        if (c[0] > 0 or c[1] > 0 or c[2] < size.w or c[3] < size.h) continue;
        found = k;
    }
    return found;
}

test "lastCover: a full opaque quad hides what came before it" {
    const full: Instance = .{ .rect = .{ 0, 0, 100, 50 }, .color = .{ 0.1, 0.2, 0.3, 1 } };
    const small: Instance = .{ .rect = .{ 10, 10, 5, 5 }, .color = .{ 1, 1, 1, 1 } };
    const sz: types.Size = .{ .w = 100, .h = 50 };
    try std.testing.expectEqual(@as(?usize, 2), lastCover(&.{ small, full, full, small }, sz));
    var clear = full;
    clear.color[3] = 0.5;
    try std.testing.expectEqual(@as(?usize, 0), lastCover(&.{ full, clear, small }, sz));
    var round = full;
    round.radius = 4;
    try std.testing.expectEqual(@as(?usize, null), lastCover(&.{ round, small }, sz));
    var glass = small;
    glass.kind = Kind.glass;
    try std.testing.expectEqual(@as(?usize, null), lastCover(&.{ glass, full }, sz));
    var clipped = full;
    clipped.clip = .{ 0, 0, 50, 50 };
    try std.testing.expectEqual(@as(?usize, null), lastCover(&.{clipped}, sz));
}

/// A quad's gradient (`Style.gradient`) in its free `uv`: y marks it, z and
/// w hold the bottom color's 8-bit r·256+g and b·256+a (exact in a float).
pub fn gradientUv(dashed: bool, bottom: ?types.Color) [4]f32 {
    const d: f32 = if (dashed) 1 else 0;
    const c = bottom orelse return .{ d, 0, 0, 0 };
    const q = struct {
        fn b(v: f32) f32 {
            return @round(std.math.clamp(v, 0, 1) * 255);
        }
    };
    return .{ d, 1, q.b(c.r) * 256 + q.b(c.g), q.b(c.b) * 256 + q.b(c.a) };
}

/// A quad's gradient of many stops (`Style.gradient_stops`): uv's y 2, z
/// where its data starts in the frame's gradients, w how many stops.
/// The data (`gradientData`) is a header (the anchor's y from the quad's
/// top and its height, in points, and the count), then each stop's `at`
/// and its color (straight alpha).
pub fn gradientStopsUv(dashed: bool, at: usize, count: usize) [4]f32 {
    return .{ if (dashed) 1 else 0, 2, @floatFromInt(at), @floatFromInt(count) };
}

/// Appends a gradient's data to `out` (`gradientStopsUv`).
pub fn gradientData(gpa: std.mem.Allocator, out: *std.ArrayList([4]f32), stops: []const types.GradientStop, anchor_y: f32, anchor_h: f32, opacity: f32) !usize {
    const at = out.items.len;
    try out.append(gpa, .{ anchor_y, anchor_h, @floatFromInt(stops.len), 0 });
    for (stops) |st| {
        try out.append(gpa, .{ st.at, 0, 0, 0 });
        try out.append(gpa, color4(st.color.alpha(opacity)));
    }
    return at;
}

/// The color of a gradient of many stops `y` points below its quad's top,
/// straight alpha: what `shader.metal`'s `gradient_stops` computes.
pub fn gradientAt(data: []const [4]f32, uv: [4]f32, y: f32) [4]f32 {
    const at: usize = @intFromFloat(uv[2]);
    if (at >= data.len) return .{ 0, 0, 0, 0 };
    const h = data[at];
    const n: usize = @min(@as(usize, @intFromFloat(h[2])), (data.len - at - 1) / 2);
    if (n == 0) return .{ 0, 0, 0, 0 };
    const t = (y - h[0]) / @max(h[1], 1e-4);
    if (t <= data[at + 1][0]) return data[at + 2];
    for (1..n) |k| {
        const p0 = data[at + 1 + 2 * (k - 1)][0];
        const p1 = data[at + 1 + 2 * k][0];
        if (t <= p1) {
            const c0 = data[at + 2 + 2 * (k - 1)];
            const c1 = data[at + 2 + 2 * k];
            const f = (t - p0) / @max(p1 - p0, 1e-6);
            return .{ c0[0] + (c1[0] - c0[0]) * f, c0[1] + (c1[1] - c0[1]) * f, c0[2] + (c1[2] - c0[2]) * f, c0[3] + (c1[3] - c0[3]) * f };
        }
    }
    return data[at + 2 * n];
}

/// `gradientUv`'s bottom color, unpacked (straight alpha).
pub fn gradientBottom(uv: [4]f32) [4]f32 {
    const r = @floor(uv[2] / 256);
    const b = @floor(uv[3] / 256);
    return .{ r / 255, (uv[2] - r * 256) / 255, b / 255, (uv[3] - b * 256) / 255 };
}

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

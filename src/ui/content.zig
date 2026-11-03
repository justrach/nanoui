//! What a box draws inside it: text, an icon, a picture, a texture, a
//! canvas, or a hole that a native view shows through.
const types = @import("types.zig");
const text = @import("text.zig");

pub const Content = union(enum) {
    none,
    text: Text,
    icon: Icon,
    image: Image,
    texture: Texture,
    /// A see-through cut in the frame, its corners rounded by this
    /// radius: a native view under the UI (a map) shows through it.
    hole: f32,
    /// What a canvas draws (`ui.canvas`), at points within its box.
    canvas: *const @import("draw.zig").Canvas,

    /// One of this frame's textures (`Context.textures`), the part `uv`
    /// (0 to 1) of it shown.
    pub const Texture = struct {
        slot: u32,
        uv: [4]f32 = .{ 0, 0, 1, 1 },
        opacity: f32 = 1,
    };

    /// A picture: its key in the image atlas, and its bytes for the first
    /// time it is drawn.
    pub const Image = struct {
        key: u64,
        bytes: []const u8,
        opacity: f32 = 1,
        /// Its shape (alpha) filled with this color: a monochrome mark.
        tint: ?types.Color = null,
        /// Drawn on whole pixels: a picture made at the screen's own
        /// size (an icon from SVG), so nothing blurs it.
        snap: bool = false,
    };

    pub const Icon = struct {
        /// An SF Symbol's name.
        name: []const u8,
        size: f32,
        weight: types.Weight,
        color: types.Color,
    };

    pub const Text = struct {
        str: []const u8,
        style: types.TextStyle,
        color: types.Color,
        lines: []const text.Line = &.{},
        /// Colored byte ranges, sorted; the rest is drawn in `color`.
        spans: []const types.Span = &.{},
        cut_lay: ?text.Layout = null,
    };
};

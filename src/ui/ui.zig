//! Native UI: views are Zig functions of the app's state, drawn by nanoui
//! on the GPU. No HTML, no JavaScript, no webview.
//!
//! Strings given to widgets are kept until the frame is drawn, after the
//! view returns: pass the app's own memory or the frame's (`c.print`,
//! `c.alloc()`), never a buffer on the stack.
//!
//!     fn view(s: *Counter, c: *ui.Context) void {
//!         ui.column(c, .{ .width = .fill, .height = .fill, .align_items = .center, .justify = .center, .gap = 12 });
//!         defer ui.end(c);
//!         ui.textf(c, .{ .size = 40, .weight = .bold }, "{d}", .{s.n});
//!         if (ui.button(c, "Increment", .{ .variant = .primary }).clicked) s.n += 1;
//!     }
const std = @import("std");
const types = @import("types.zig");
const widgets = @import("widgets.zig");
const textfield = @import("textfield.zig");
const ctx_mod = @import("context.zig");

pub const Context = ctx_mod.Context;
pub const Interaction = ctx_mod.Interaction;
pub const FrameStats = ctx_mod.FrameStats;
pub const Shortcut = ctx_mod.Shortcut;
/// A text field's editing keys: the system's, Emacs's or Vim's.
pub const Keymap = @import("keymap.zig").Keymap;
/// The system's editing commands (Option-Delete, Command-Left…), as `TextOp`s.
pub const Command = @import("input.zig").Command;
pub const TextOp = @import("input.zig").TextOp;
pub const Cursor = ctx_mod.Cursor;
pub const Theme = @import("theme.zig").Theme;
/// Key combinations as the platform writes them: `ui.keys.label("⌘P")`.
pub const keys = @import("keys.zig");
/// A monotonic clock in seconds.
pub const clock = @import("clock.zig");
/// PNG files from pixels (and back, `png_decode`).
pub const png = @import("png.zig");

pub const Point = types.Point;
pub const Size = types.Size;
pub const Rect = types.Rect;
pub const Color = types.Color;
pub const Edges = types.Edges;
pub const Length = types.Length;
pub const Style = types.Style;
pub const TextStyle = types.TextStyle;
pub const Truncate = types.Truncate;
pub const SpanBox = types.SpanBox;
pub const BaselineRule = types.BaselineRule;
pub const Shadow = types.Shadow;
pub const Glass = types.Glass;
pub const Weight = types.Weight;

pub const key = widgets.key;
pub const column = widgets.column;
pub const row = widgets.row;
pub const end = widgets.end;
pub const pressable = widgets.pressable;
pub const card = widgets.card;
pub const scroll = widgets.scroll;
pub const spacer = widgets.spacer;
pub const divider = widgets.divider;
pub const image = widgets.image;
pub const texture = widgets.texture;
/// A box to draw lines, triangles, polygons and circles in (draw.zig).
pub const canvas = @import("draw.zig").canvas;
pub const Canvas = @import("draw.zig").Canvas;
pub const Stroke = @import("draw.zig").Stroke;
pub const triangulate = @import("draw.zig").triangulate;
pub const Texture = @import("gpu.zig").Texture;
pub const ImageOptions = widgets.ImageOptions;
pub const svg = widgets.svg;
/// A font the app brings, found by family name (`Theme.font`, …).
pub const registerFont = @import("font_registry.zig").register;
pub const SvgOptions = widgets.SvgOptions;
pub const text = widgets.text;
pub const textf = widgets.textf;
pub const richText = widgets.richText;
pub const Span = types.Span;
pub const heading = widgets.heading;
pub const icon = widgets.icon;
pub const IconOptions = widgets.IconOptions;
pub const label = widgets.label;
pub const button = widgets.button;
pub const ButtonOptions = widgets.ButtonOptions;
pub const checkbox = widgets.checkbox;
pub const toggle = widgets.toggle;
pub const slider = widgets.slider;
pub const SliderOptions = widgets.SliderOptions;
pub const progress = widgets.progress;
pub const segmented = widgets.segmented;
pub const badge = widgets.badge;
pub const kbd = widgets.kbd;
pub const textField = textfield.textField;
pub const TextFieldOptions = textfield.Options;
pub const TextBuffer = textfield.TextBuffer;
pub const TextFieldResult = textfield.Result;
/// Declarative, interruptible animation (springs, tweens, presence).
pub const motion = @import("motion/motion.zig");
pub const div = @import("div.zig").div;
pub const Div = @import("div.zig").Div;
pub const list = @import("list.zig").list;
pub const ListOptions = @import("list.zig").Options;
pub const ListRows = @import("list.zig").Rows;
/// Tooltips as GPUI's (`Div.tooltip`): after the pointer rests, by it.
pub const tooltip = @import("tooltip.zig").tooltip;
pub const tooltipWith = @import("tooltip.zig").tooltipWith;
pub const TooltipOptions = @import("tooltip.zig").Options;
/// Whether the pointer is over a box that doesn't take it (`tooltip.zig`).
pub const pointerOver = @import("tooltip.zig").pointerOver;
pub const Tester = @import("tester.zig").Tester;
pub const TesterOptions = @import("tester.zig").Options;

/// What a window of native UI shows: `build` runs on every frame.
pub const View = struct {
    ptr: *anyopaque,
    build: *const fn (ptr: *anyopaque, c: *Context) void,

    /// `View.init(&state, State.view)` where `fn view(s: *State, c: *ui.Context) void`.
    pub fn init(ptr: anytype, comptime build_fn: fn (@TypeOf(ptr), *Context) void) View {
        const P = @TypeOf(ptr);
        return .{
            .ptr = @ptrCast(ptr),
            .build = struct {
                fn call(p: *anyopaque, c: *Context) void {
                    build_fn(@as(P, @ptrCast(@alignCast(p))), c);
                }
            }.call,
        };
    }
};

test {
    _ = types;
    _ = @import("layout.zig");
    _ = textfield;
    _ = @import("tests.zig");
    _ = @import("tests_keymap.zig");
    _ = @import("tests_multiline.zig");
    _ = @import("tests_caret.zig");
    _ = @import("tests_textfield_weight.zig");
    _ = @import("tests_texture.zig");
    _ = @import("tests_canvas.zig");
    _ = @import("triangulate.zig");
    _ = @import("tests_motion.zig");
    _ = @import("tests_layer.zig");
    _ = @import("tests_safe_area.zig");
    _ = @import("motion/motion.zig");
    _ = @import("keymap.zig");
    _ = @import("undo.zig");
    _ = @import("tests_cursor.zig");
    _ = @import("tests_image_sink.zig");
    // CoreText's fast path, on macOS.
    if (!@import("text.zig").portable) {
        _ = @import("shaper.zig");
        _ = @import("tests_wrap.zig");
    }
    _ = @import("raster.zig");
    _ = @import("tests_raster.zig");
    _ = @import("glass.zig");
    _ = @import("tests_glass.zig");
    _ = @import("tests_overlay_bar.zig");
    _ = @import("tests_border.zig");
    if (@import("builtin").os.tag == .linux) _ = @import("tests_opengl.zig");
    _ = @import("tt/raster.zig");
    _ = @import("tt/tests.zig");
    _ = @import("png.zig");
    _ = @import("png_decode.zig");
    _ = @import("images.zig");
    _ = @import("pacing.zig");
    _ = @import("svg.zig");
    _ = @import("tests_svg.zig");
    _ = @import("tests_emoji.zig");
    _ = @import("tests_truncate.zig");
    _ = @import("tooltip.zig");
    _ = @import("tests_tooltip.zig");
    _ = @import("icons.zig");
    _ = keys;
}

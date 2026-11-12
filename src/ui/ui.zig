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
/// Springs and timed curves (`spring`, `springFrom`, `tween`).
const motion_legacy = @import("motion.zig");
pub const Spring = motion_legacy.Spring;
pub const Curve = motion_legacy.Curve;
pub const spring = motion_legacy.spring;
pub const springFrom = motion_legacy.springFrom;
pub const tween = motion_legacy.tween;
pub const jump = motion_legacy.jump;
pub const Interaction = ctx_mod.Interaction;
pub const FrameStats = ctx_mod.FrameStats;
pub const frame_log = @import("frame_log.zig");
pub const FrameLog = frame_log.FrameLog;
pub const Surface = if (@import("builtin").os.tag == .macos) @import("surface.zig").Surface else void;
pub const KeysReleased = if (@import("builtin").os.tag == .macos) @import("surface.zig").KeysReleased else void;
pub const Shortcut = ctx_mod.Shortcut;
/// A text field's editing keys: the system's, Emacs's or Vim's.
pub const Keymap = @import("keymap.zig").Keymap;
/// The system's editing commands (Option-Delete, Command-Left…), as `TextOp`s.
pub const Command = @import("input.zig").Command;
pub const TextOp = @import("input.zig").TextOp;
pub const Cursor = ctx_mod.Cursor;
pub const Theme = @import("theme.zig").Theme;
pub const A11yRole = ctx_mod.A11yRole;
pub const A11yItem = ctx_mod.A11yItem;
/// Accessibility: labels, headings, announcements, Dynamic Type (`access.zig`).
pub const access = @import("access.zig");
/// Key combinations as the platform writes them: `ui.keys.label("⌘P")`.
pub const keys = @import("keys.zig");
/// A monotonic clock in seconds.
pub const clock = @import("clock.zig");
/// PNG files from pixels (and back, `png_decode`).
pub const png = @import("png.zig");

pub const Point = types.Point;
pub const Face = types.Face;
pub const Fade = types.Fade;
pub const Size = types.Size;
pub const Affine = types.Affine;
pub const Rect = types.Rect;
pub const Color = types.Color;
pub const Edges = types.Edges;
pub const Length = types.Length;
pub const Style = types.Style;
pub const Pulse = types.Pulse;
pub const TextStyle = types.TextStyle;
pub const WrapRule = types.WrapRule;
pub const BaselineRule = types.BaselineRule;
pub const GlyphSnap = types.GlyphSnap;
pub const SpanBox = types.SpanBox;
pub const Truncate = types.Truncate;
pub const Shadow = types.Shadow;
pub const Glass = types.Glass;
pub const Weight = types.Weight;
/// Foldables: posture, hinge, fold band and occlusions (`Context.device`).
pub const device = @import("device.zig");
pub const Device = device.Device;
pub const Posture = device.Posture;
/// Two panes that keep clear of a fold (`panes.zig`).
pub const panes = @import("panes.zig").panes;
pub const Panes = @import("panes.zig").Panes;
pub const PanesOptions = @import("panes.zig").Options;
/// Dockable panels: a tree of splits and tabbed groups (`dock.zig`), drawn
/// with draggable dividers and tabs (`dock_view.zig`).
pub const dock = struct {
    const model = @import("dock.zig");
    const lay = @import("dock_layout.zig");
    const v = @import("dock_view.zig");
    pub const Tree = model.Tree;
    pub const Node = model.Node;
    pub const PanelId = model.PanelId;
    pub const PanelInfo = model.PanelInfo;
    pub const Metrics = model.Metrics;
    pub const DropZone = model.DropZone;
    pub const DropTarget = model.DropTarget;
    pub const Layout = lay.Layout;
    pub const GroupItem = lay.GroupItem;
    pub const DividerItem = lay.DividerItem;
    pub const zoneRect = lay.zoneRect;
    pub const Style = v.Style;
    pub const State = v.State;
    pub const TabState = v.TabState;
    pub const view = v.view;
    pub const ExternalDrag = v.ExternalDrag;
    pub const externalTarget = v.externalTarget;
    pub const dropExternal = v.dropExternal;
};
/// Whether macOS offers inline predictions (14+) in text fields. They come
/// as marked text: off, each typed letter is committed as it's typed, as
/// a search field wants. On by default; no effect elsewhere.
pub fn setInlinePredictions(on: bool) void {
    if (comptime @import("builtin").os.tag != .macos) return;
    @import("textinput.zig").inline_predictions = on;
    // The runtime library (`rt.zig`) keeps its own copy, and its text input
    // reads that one.
    if (comptime @import("../rt.zig").enabled) {
        const Ext = struct {
            extern fn nanoui_rt_set_inline_predictions(on: u8) callconv(.c) void;
        };
        Ext.nanoui_rt_set_inline_predictions(@intFromBool(on));
    }
}
/// Holds the menu bar's key equivalents back while a view captures key
/// combinations (a shortcut editor): ⌘ chords reach the view instead.
pub const suspendMenuKeyEquivalents = keys.suspendMenuKeyEquivalents;
/// Whether light text on dark is thickened as macOS's font smoothing does
/// (the default follows the user's `AppleFontSmoothing`). Off draws every
/// glyph at its outline's own weight, as a renderer of its own would. Set it
/// before the first frame: glyphs already in the atlas keep their weight.
pub fn setFontSmoothing(on: bool) void {
    if (comptime @import("text.zig").portable) return;
    @import("atlas.zig").smoothing_allowed = on;
    // The runtime library (`rt.zig`) keeps its own copy. Frames it draws read
    // that one, so without this a frame the app's copy drew and one the
    // library drew give the same glyphs different weights.
    if (comptime @import("../rt.zig").enabled) {
        const Ext = struct {
            extern fn nanoui_rt_set_font_smoothing(on: u8) callconv(.c) void;
        };
        Ext.nanoui_rt_set_font_smoothing(@intFromBool(on));
    }
}

pub const key = widgets.key;
pub const keyInt = widgets.keyInt;
pub const column = widgets.column;
pub const row = widgets.row;
pub const end = widgets.end;
pub const pressable = widgets.pressable;
pub const card = widgets.card;
pub const scroll = widgets.scroll;
pub const spacer = widgets.spacer;
pub const divider = widgets.divider;
pub const image = widgets.image;
pub const imageSize = widgets.imageSize;
pub const imageLimits = widgets.imageLimits;
pub const imageTypeDecodes = widgets.imageTypeDecodes;
pub const ImageLimits = @import("images.zig").Limits;
pub const texture = widgets.texture;
pub const textureAffine = widgets.textureAffine;
pub const hole = widgets.hole;
/// A box to draw lines, triangles, polygons and circles in (draw.zig).
pub const canvas = @import("draw.zig").canvas;
pub const Canvas = @import("draw.zig").Canvas;
pub const Stroke = @import("draw.zig").Stroke;
pub const triangulate = @import("draw.zig").triangulate;
pub const Texture = @import("gpu.zig").Texture;
/// A texture's pixels, their range, matrix and transfer (`Texture`).
pub const TextureFormat = @import("gpu.zig").Format;
pub const VideoRange = @import("gpu.zig").Range;
pub const VideoMatrix = @import("gpu.zig").Matrix;
pub const VideoTransfer = @import("gpu.zig").Transfer;
/// A 3D LUT for a texture's colour stage (`ui.lut`).
pub const Lut = @import("gpu.zig").Lut;
pub const lut = @import("ui_gpu.zig").lut;
/// A texture showing a CVPixelBuffer, its format, range, matrix and
/// transfer read from the buffer (Apple platforms).
pub const pixelBufferTexture = @import("pixel_buffer.zig").texture;
/// The app's own GPU passes before each frame's (`Surface.before_encode`).
pub const BeforeEncode = @import("gpu.zig").BeforeEncode;
pub const metalDevice = @import("ui_gpu.zig").metalDevice;
pub const d3d11Device = @import("ui_gpu.zig").d3d11Device;
pub const d3d11DeviceGeneration = @import("ui_gpu.zig").d3d11DeviceGeneration;
/// Cursors from the app's pixels (`Cursor.custom`).
pub const makeCursor = @import("ui_gpu.zig").makeCursor;
pub const setCursor = @import("ui_gpu.zig").setCursor;
pub const freeCursor = @import("ui_gpu.zig").freeCursor;
/// One color of a gradient of many stops (`Style.gradient_stops`).
pub const GradientStop = types.GradientStop;
pub const ImageOptions = widgets.ImageOptions;
/// Where a picture comes from: encoded bytes, or premultiplied BGRA pixels.
pub const ImageSource = @import("images.zig").Source;
pub const svg = widgets.svg;
/// A font the app brings, found by family name (`Theme.font`, …).
pub const registerFont = @import("font_registry.zig").register;
/// A face from a TrueType, OpenType, WOFF or WOFF2 file's bytes (or an installed
/// font), under a family `TextStyle.family` finds it by.
pub const registerFontFace = @import("font_registry.zig").registerFace;
pub const FontFaceOptions = @import("font_registry.zig").FaceOptions;
/// Gives a face registered as `pending` its file, or the installed font it is.
pub const fillFontFace = @import("font_registry.zig").fillFace;
/// Takes away the families `registerFontFace` added whose names start so.
pub const unregisterFontFamilies = @import("font_registry.zig").unregisterFamilies;
pub const unscopedFontGeneration = @import("font_registry.zig").unscopedGeneration;
/// How far a face's description is from a style, as CSS's font matching ranks them.
pub const fontFaceScore = @import("font_registry.zig").score;
/// Text shaped by nanoui's own TrueType reader, not the system's.
pub const portable = @import("text.zig").portable;
/// A tiny font made on the spot, for tests that need one that isn't installed.
pub const test_font = @import("tt/testfont.zig");
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
pub const TextFieldCaret = textfield.Caret;
/// A bounded, inertial ruler with clipped rolling numerals.
pub const RulerPicker = @import("ruler.zig").RulerPicker;
pub const RulerOptions = @import("ruler.zig").Options;
/// Declarative, interruptible animation (springs, tweens, presence).
pub const motion = @import("motion/motion.zig");
pub const div = @import("div.zig").div;
pub const Div = @import("div.zig").Div;
/// Delayed, window-contained hints for a control.
pub const TooltipOptions = @import("tooltip.zig").Options;
pub const tooltip = @import("tooltip.zig").tooltip;
pub const tooltipWith = @import("tooltip.zig").tooltipWith;
pub const list = @import("list.zig").list;
pub const ListOptions = @import("list.zig").Options;
pub const ListRows = @import("list.zig").Rows;
pub const Tester = @import("tester.zig").Tester;
pub const TesterOptions = @import("tester.zig").Options;
pub const textArea = @import("textarea.zig").textArea;
pub const AreaOptions = @import("textarea.zig").AreaOptions;
/// Focuses the field built next (`c.focusNext`), selecting all its text if asked.
pub const focusNext = @import("context_hooks.zig").focusNext;
/// A drag inside the window carrying the app's value from box to box,
/// across panels (`drag_payload.zig`): `dragSource` on the box it starts
/// from, `dragOver`/`dropTarget` on where it may land.
pub const dragSource = @import("drag_payload.zig").dragSource;
pub const dragOver = @import("drag_payload.zig").dragOver;
pub const dropTarget = @import("drag_payload.zig").dropTarget;
pub const dragging = @import("drag_payload.zig").dragging;
pub const cancelDrag = @import("drag_payload.zig").cancel;
pub const DragSource = @import("drag_payload.zig").Source;
pub const DragActive = @import("drag_payload.zig").Active;
/// A scroll box's offset read back and set (`scroll_x.zig`).
pub const scrollBox = @import("scroll_x.zig").scrollBox;
pub const scrollOffset = @import("scroll_x.zig").scrollOffset;
pub const setScrollOffset = @import("scroll_x.zig").setScrollOffset;
pub const scrollMax = @import("scroll_x.zig").scrollMax;
pub const scrollAtEnd = @import("scroll_x.zig").atEnd;
pub const scrollToEnd = @import("scroll_x.zig").scrollToEnd;
/// Rich text from a little Markdown (`markdown.zig`): bold, italic,
/// code, headings and bullets as spans.
pub const markdown = @import("markdown.zig");
/// What a drop from another app brought (`Context.dropAt`).
pub const Drop = @import("input.zig").Drop;
pub const MouseButton = @import("input.zig").Button;
pub const ScrollPhase = @import("input.zig").ScrollPhase;
/// Offscreen pixels a CPU window reuses (`canvas.zig`).
pub const PixelCanvas = @import("canvas.zig").Canvas;
/// CPU raster (Linux/Windows). `raster.shapes.shadow_samples` is 8 to match Metal.
pub const raster = @import("raster.zig");

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
    _ = @import("tests_ruler.zig");
    // The one press in flight: a second button ignored, a stale press replaced.
    _ = @import("pointer_press.zig");
    _ = @import("tests_caret_activity.zig");
    _ = @import("tests_motion.zig");
    _ = @import("motion/tests_catalog.zig");
    _ = @import("motion/tests_reduced_motion.zig");
    _ = @import("tests_context_parity.zig");
    _ = @import("tests_tooltip_parity.zig");
    _ = @import("tests_text_parity.zig");
    _ = @import("tests_paint_parity.zig");
    _ = @import("tests_textfield_parity.zig");
    _ = @import("tests_live_theme.zig");
    _ = @import("tests_field_layout.zig");
    _ = frame_log;
    _ = @import("present_slots.zig");
    _ = @import("tests_effects.zig");
    _ = @import("tests_scroll_x.zig");
    _ = @import("tests_a11y_adjust.zig");
    _ = @import("tests_access.zig");
    _ = @import("tests_text_select.zig");
    _ = @import("tests_shadow_x.zig");
    _ = @import("tests_text_style.zig");
    _ = @import("tests_text_extras.zig");
    _ = @import("tests_turn.zig");
    _ = @import("tests_transform.zig");
    _ = @import("tests_settle.zig");
    _ = types;
    _ = device;
    _ = @import("panes.zig");
    _ = @import("dock.zig");
    _ = @import("dock_layout.zig");
    _ = @import("dock_resize.zig");
    _ = @import("tests_dock_external.zig");
    _ = @import("drag_payload.zig");
    _ = @import("tests_drag_payload.zig");
    _ = @import("tests_dock.zig");
    _ = @import("tests_dock_hooks.zig");
    _ = @import("tests_scroll_api.zig");
    _ = @import("markdown.zig");
    _ = @import("tests_tester_verbs.zig");
    _ = @import("tester_script.zig");
    _ = @import("tests_gradient.zig");
    _ = @import("layout.zig");
    _ = textfield;
    _ = @import("textfield_tests.zig");
    _ = @import("tests_frame_part.zig");
    _ = @import("tests.zig");
    _ = @import("tests_keymap.zig");
    _ = @import("tests_multiline.zig");
    _ = @import("tests_handles.zig");
    _ = @import("tests_texture.zig");
    _ = @import("tests_texture_affine.zig");
    _ = @import("tests_texture_color.zig");
    _ = @import("tests_lut.zig");
    _ = @import("tests_gpu_hook.zig");
    _ = @import("color.zig");
    _ = @import("ui_gpu.zig");
    _ = @import("tests_hole.zig");
    _ = @import("tests_canvas.zig");
    _ = @import("triangulate.zig");
    _ = @import("tests_motion_more.zig");
    _ = @import("tests_roll.zig");
    _ = @import("tests_layer.zig");
    _ = @import("tests_wheel.zig");
    _ = @import("tests_safe_area.zig");
    _ = @import("motion/motion.zig");
    _ = @import("keymap.zig");
    _ = @import("undo.zig");
    _ = @import("tests_cursor.zig");
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
    _ = @import("tests_scrollbar.zig");
    if (@import("builtin").os.tag == .linux) _ = @import("tests_opengl.zig");
    _ = @import("tt/raster.zig");
    _ = @import("tt/tests.zig");
    _ = @import("tt/tests_decode.zig");
    _ = @import("tt/brotli.zig");
    _ = @import("font_registry.zig");
    _ = @import("tests_text_family.zig");
    _ = @import("png.zig");
    _ = @import("png_decode.zig");
    _ = @import("jpeg_decode.zig");
    _ = @import("gif_decode.zig");
    _ = @import("images.zig");
    _ = @import("tests_images.zig");
    _ = @import("pacing.zig");
    _ = @import("svg.zig");
    _ = @import("tests_svg.zig");
    _ = @import("tests_truncate.zig");
    if (@import("dwrite.zig").enabled) _ = @import("tests_dwrite.zig");
    if (@import("builtin").os.tag == .windows) _ = @import("tests_d3d11.zig");
    if (@import("builtin").os.tag == .windows) _ = @import("tests_d3d11_texture.zig");
    // An app's D3D11 textures: the shared device, the colour stage, the slots.
    if (@import("builtin").os.tag == .windows) _ = @import("tests_d3d11_video.zig");
    if (@import("builtin").os.tag == .windows) _ = @import("d3d11_device.zig");
    if (@import("builtin").os.tag == .windows) _ = @import("d3d11_video.zig");
    if (@import("builtin").os.tag == .windows) _ = @import("d3d11_texture.zig");
    _ = @import("icons.zig");
    _ = @import("frame_pace.zig");
    _ = keys;
    _ = @import("tests_textedit.zig");
    _ = @import("tests_field.zig");
    _ = @import("tests_input.zig");
    _ = @import("tests_key_up.zig");
    _ = @import("tests_backtab.zig");
    _ = @import("retain.zig");
    if (@import("builtin").os.tag == .macos) {
        _ = @import("tests_menu.zig");
        _ = @import("tests_a11y.zig");
    }
}

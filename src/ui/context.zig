//! The context a view builds its UI with, every frame: the tree of boxes,
//! their ids, the input, what the pointer is over, and animated values.
//!
//! Views are immediate mode: a function of the app's state, run again on
//! every event. Interactions are answered from the previous frame's layout,
//! and a frame whose interactions changed state is built again before it is
//! drawn, so the screen never lags the state.
const std = @import("std");
const types = @import("types.zig");
const Theme = @import("theme.zig").Theme;
const text = @import("text.zig");

pub const none = std.math.maxInt(u32);

pub const Content = @import("content.zig").Content;

pub const Node = struct {
    id: u64,
    parent: u32 = none,
    first_child: u32 = none,
    last_child: u32 = none,
    next: u32 = none,
    child_count: u32 = 0,
    style: types.Style,
    content: Content = .none,
    interactive: bool = false,
    /// Holds wrapping text: may shrink below its measured width in a row.
    flexible: bool = false,
    /// Built using the preceding size; a size change needs another frame.
    layout_dependent: bool = false,
    measured: types.Size = .{},
    rect: types.Rect = .{},
};

const input = @import("input.zig");
pub const Key = input.Key;
pub const Shortcut = input.Shortcut;
pub const TextOp = input.TextOp;
pub const Command = input.Command;
pub const FocusedText = input.FocusedText;
pub const Clipboard = input.Clipboard;
pub const EditState = input.EditState;
pub const Input = input.Input;

/// Asks for a frame from any thread (`Context.requestFrameFromAnyThread`).
pub const Waker = struct { ctx: *anyopaque, wake: *const fn (ctx: *anyopaque) void };
pub const FocusRing = struct { color: types.Color, width: f32 = 2 };

pub const Interaction = struct {
    id: u64,
    rect: ?types.Rect,
    /// The pointer is over it, or over a box inside it (its button, its
    /// link), as CSS's :hover: a row that shows its buttons on hover keeps
    /// them while the pointer goes to them.
    hovered: bool,
    /// Held down: pressed on this box and not yet released.
    pressed: bool,
    clicked: bool,
    /// The second click of a double click (it is a click too): opens what
    /// a click selects, as a row's inspector.
    double_clicked: bool = false,
    /// Pressed over it with the right button or Control+left: a context menu.
    right_pressed: bool = false,
    right_clicked: bool = false,
    middle_clicked: bool = false,
    /// A secondary press (right, or Control-click on the Mac) on it or on a
    /// box inside it: its context menu is wanted. Like an event bubbling
    /// up, every box under the pointer sees it; ask on the one whose menu
    /// it is.
    secondary_clicked: bool = false,
    focused: bool,
    /// VoiceOver incremented (+1) or decremented (−1) it in this event
    /// (`Context.adjustable`): a splitter, a slider.
    a11y_step: i8 = 0,
};
pub const Hit = struct { id: u64, index: u32, rect: types.Rect, scroll: bool, scroll_x: bool = false, wheel: bool = false };
pub const Cursor = enum { arrow, hand, text, resize_left_right, resize_up_down, open_hand, closed_hand, not_allowed, crosshair, custom };
pub const A11yRole = @import("access.zig").Role;
pub const A11yItem = @import("access.zig").Item;

/// What the last frame cost, for profiling and the hill-climb benchmarks.
pub const FrameStats = struct {
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
    /// Builds of the view: more than one when interactions changed state.
    passes: u32 = 0,
    nodes: usize = 0,
    instances: usize = 0,
    /// The scene was the last frame's, shifted: nothing was built or painted.
    retained: bool = false,
};
const Anim = struct { value: f32, frame: u64 };
/// A widget's own state (`Context.state`): a few bytes, kept while it's drawn.
const Memory = struct { bytes: [48]u8 align(16), frame: u64 };

pub const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    text: *text.TextSystem,
    theme: Theme = .light,
    theme_chosen: ?Theme = null, // the view's own choice; null: the system's
    size: types.Size = .{},
    scale: f32 = 2,
    /// Opt in to device-pixel edges after layout (half ties toward zero).
    pixel_snap: bool = false,
    /// With pixel snapping, round text measurements up to device pixels too.
    pixel_snap_text: bool = true,
    /// What draws the frames: Metal, OpenGL, or nanoui's own CPU renderer.
    renderer: []const u8 = if (@import("text.zig").portable) "CPU" else "Metal",
    /// Wait for the display's refresh when presenting (Windows' Direct3D 11).
    vsync: bool = true,
    /// `dt` is capped and reset after an idle frame, for animations;
    /// `frame_time` is the real gap, which a frame rate is read from.
    dt: f32 = 1.0 / 60.0,
    frame_time: f32 = 1.0 / 60.0,
    /// Seconds since the first frame: the clock of animations a view drives itself.
    time: f64 = 0,
    frame: u64 = 0,
    input: Input = .{},
    retain: @import("retain.zig").State = .{},

    nodes: std.ArrayList(Node) = .empty,
    stack: std.ArrayList(u32) = .empty,

    transparent_root: bool = false,
    stage_rects: [4]types.Rect = @splat(.{}),
    stage_nodes: [4]u32 = @splat(none),
    stage_count: usize = 0,
    a11y_items: std.ArrayList(A11yItem) = .empty,
    // Kept across frames.
    rects: std.AutoHashMapUnmanaged(u64, types.Rect) = .empty,
    prev_rects: std.AutoHashMapUnmanaged(u64, types.Rect) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    next_hits: std.ArrayList(Hit) = .empty,
    anims: std.AutoHashMapUnmanaged(u64, Anim) = .empty,
    /// What widgets remember between frames (`state`).
    memory: std.AutoHashMapUnmanaged(u64, Memory) = .empty,
    /// What `ui.motion` remembers of each animated box.
    motion_store: @import("motion/store.zig").Store = .{},
    /// The system asks for reduced motion: `ui.motion` moves at once.
    reduced_motion: bool = false,
    /// Dynamic Type, contrast, announcements (`access.zig`).
    access: @import("access.zig").Access = .{},
    /// Boxes of a higher layer met while painting, drawn after the page;
    /// and the one being drawn so.
    layers: std.ArrayList(u32) = .empty,
    layer_root: u32 = std.math.maxInt(u32),
    scroll: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Rubber-band overscroll offset by box id (`scroll.zig`).
    overscroll: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    scrollbars: std.AutoHashMapUnmanaged(u64, @import("scroll.zig").ScrollbarGeom) = .empty,
    scrollbar_drag: ?@import("scroll.zig").ScrollbarDrag = null,
    scroll_holding: bool = false,
    /// The textures this frame shows (`ui.texture`), by slot.
    textures: std.ArrayList(@import("gpu.zig").Texture) = .empty,
    /// The frame's gradients of many stops (`gpu.gradientData`).
    gradients: std.ArrayList([4]f32) = .empty,
    edits: std.AutoHashMapUnmanaged(u64, EditState) = .empty,
    /// The largest scroll offset of each scrolling box in the last layout
    /// (follow_end and scroll-linked motion both read it).
    scroll_max: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Whether each of those follows its end, and the offset layout last left it at.
    scroll_follow: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    scroll_seen: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// An overlay bar's box: its offset as last painted, and when it last
    /// moved (`Scrollbar.overlay`).
    overlay_bars: std.AutoHashMapUnmanaged(u64, struct { offset: f32, moved_at: f64 }) = .empty,
    /// How far such a box may follow this frame (`capScroll`), and the
    /// boxes whose offset the reader or the app moved in the last layout.
    scroll_cap: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    scroll_moved: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Text selected in `selectable` boxes, and this frame's Copy.
    selection: @import("selection.zig").Selection = .{},
    copy_requested: bool = false,
    /// The soonest a view asked for another frame (`frameIn`), seconds.
    frame_in: ?f32 = null,
    /// Delayed help requested during build, drawn over the completed view.
    tooltip: @import("tooltip.zig").Frame = .{},
    copy_done: bool = false,
    /// Set when the view took the offered shortcut: it goes no further.
    shortcut_taken: bool = false,
    /// Set by the focused text field each frame, along with caret blink and selection state.
    focused_text: ?FocusedText = null,
    focused_multiline: bool = false,
    focused_password: bool = false,
    text_menu: bool = false,
    caret_moved_at: f64 = 0,
    window_focused: bool = true,
    /// A person is dragging the window to a new size (macOS): a frame should be quick,
    /// and a view can leave what's dear until the drag lets up.
    live_resizing: bool = false,
    select_granularity: @import("textedit.zig").Granularity = .char,
    select_origin: [2]usize = .{ 0, 0 },
    undo_op: @import("textedit.zig").UndoOp = .none,
    paste_op: bool = false,
    building: bool = false,
    right_press: bool = false,
    drag_request: ?@import("context_hooks.zig").DragRequest = null,
    /// A drag inside the window carrying the app's value (`ui.dragSource`).
    payload_drag: @import("drag_payload.zig").State = .{},
    close_request: bool = false,
    focusable_ids: std.ArrayList(u64) = .empty,
    last_focusable_ids: std.ArrayList(u64) = .empty,
    clipboard: Clipboard = .{},
    /// Who draws this context's frames, woken from other threads
    /// (`requestFrameFromAnyThread`): the window's surface, or a Tester.
    waker: ?Waker = null,
    /// The focused box was a text field in the last frame (Tab is its).
    focus_is_text: bool = false,
    /// Drawn round a focused box that isn't a text field (`interact`'s
    /// `focusable`): a border of this color and width (null: none).
    focus_ring: ?FocusRing = null,
    /// The key of the next box, for ids that survive reordering.
    next_key: ?[]const u8 = null,
    next_key_int: ?u64 = null,
    /// The topmost interactive box under the pointer, and its interactive ancestors.
    hot: u64 = 0,
    /// Hide hover after keyboard input until the next pointer move or press.
    keyboard_hides_hover: bool = false,
    keyboard_modality: bool = false,
    hot_path: std.ArrayList(u64) = .empty,
    active: u64 = 0,
    focus: u64 = 0,
    /// `focusNext` asked the field it focuses to select all.
    focus_select_all: bool = false,
    /// The hot box's index in the last tree (`none` when nothing is hot).
    hot_index: u32 = none,
    /// This frame's help (tooltips) by box id, and the boxes taking drops.
    helps: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    drop_targets: std.ArrayList(u64) = .empty,
    /// How far down from the top of a window with a hidden title bar
    /// its empty space moves the window, as a title bar does: a view with
    /// a toolbar there makes it the toolbar's height.
    title_bar_height: f32 = 28,
    /// The window's edges the system draws over, in points: on iOS the
    /// status bar, the home indicator, the screen's corners and the
    /// keyboard. Zero on the desktop, and in an iOS window that isn't
    /// `full_bleed` (laid out inside it already). `ui.div(c).safeArea()`
    /// pads by it.
    safe_area: types.Edges = .{},
    device: @import("device.zig").Device = .{},
    /// Set by a view that follows the pointer inside one box (a graph's
    /// column under it, a crosshair): every move draws a frame while it is
    /// set, not only moves onto another box. Cleared each frame.
    wants_moves: bool = false,
    /// Set by a view that takes the wheel where nothing scrolls (a
    /// terminal's full-screen program): it then comes as `input.scroll`.
    wants_wheel: bool = false,
    /// Set by widgets whose interaction changed the app's state.
    changed: bool = false,
    /// Set while an animated value has not reached its target.
    animating: bool = false,
    stats: FrameStats = .{},
    /// Set when the pointer is over something clickable.
    cursor_hand: bool = false,
    /// Whether what `interact` makes clickable shows the pointing hand. An
    /// app whose controls keep the arrow, as AppKit's do, sets it false
    /// once; a view still asks for the hand with `cursor = .hand`.
    hand_cursor: bool = true,
    cursor_text: bool = false,
    /// A cursor a view asks for, over what widgets set (dividers).
    cursor: ?Cursor = null,
    /// With `cursor = .custom`: the platform cursor to show (an NSCursor on
    /// macOS, an HCURSOR on Windows), owned by the app. Changing it while
    /// `.custom` stays set re-applies it. Ignored on Linux (the arrow).
    custom_cursor: ?*anyopaque = null,
    /// Springs and tweens (`motion.zig`), kept across frames.
    motion: @import("motion.zig").State = .{},
    /// The system's Reduce Motion: springs and tweens are their target.
    reduce_motion: bool = false,
    /// Horizontal offsets of `scroll_x` boxes, by id.
    scroll_x: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    truncates: std.AutoHashMapUnmanaged(u64, text.Cut) = .empty,
    text_warmed: bool = false,
    time_driven: enum { none, slow, fast } = .none,
    painting_group: bool = false,

    pub fn init(gpa: std.mem.Allocator, ts: *text.TextSystem) Context {
        return .{ .gpa = gpa, .arena = .init(gpa), .text = ts };
    }

    pub fn deinit(c: *Context) void {
        c.arena.deinit();
        c.textures.deinit(c.gpa);
        c.gradients.deinit(c.gpa);
        c.nodes.deinit(c.gpa);
        c.stack.deinit(c.gpa);
        c.a11y_items.deinit(c.gpa);
        c.rects.deinit(c.gpa);
        c.prev_rects.deinit(c.gpa);
        c.hits.deinit(c.gpa);
        c.next_hits.deinit(c.gpa);
        c.hot_path.deinit(c.gpa);
        c.anims.deinit(c.gpa);
        c.motion_store.deinit(c.gpa);
        c.memory.deinit(c.gpa);
        c.layers.deinit(c.gpa);
        c.scroll.deinit(c.gpa);
        c.overscroll.deinit(c.gpa);
        c.scrollbars.deinit(c.gpa);
        c.focusable_ids.deinit(c.gpa);
        c.last_focusable_ids.deinit(c.gpa);
        c.edits.deinit(c.gpa);
        c.scroll_max.deinit(c.gpa);
        c.scroll_follow.deinit(c.gpa);
        c.scroll_seen.deinit(c.gpa);
        c.overlay_bars.deinit(c.gpa);
        c.scroll_cap.deinit(c.gpa);
        c.scroll_moved.deinit(c.gpa);
        c.selection.deinit(c.gpa);
        c.motion.deinit(c.gpa);
        c.scroll_x.deinit(c.gpa);
        c.helps.deinit(c.gpa);
        c.drop_targets.deinit(c.gpa);
        c.truncates.deinit(c.gpa);
        c.retain.deinit(c.gpa);
    }

    /// Memory that lives until the end of the frame, for formatted text.
    /// Scales every text by `z` (1 is as written): an app's zoom, ⌘= ⌘-.
    pub fn setZoom(c: *Context, z: f32) void {
        c.access.zoom = z;
        @import("access.zig").applyZoom(c);
    }

    pub fn alloc(c: *Context) std.mem.Allocator {
        if (@import("../rt.zig").enabled) {
            const Ext = struct { extern fn nanoui_rt_ctx_alloc(c: *Context, out: *std.mem.Allocator) callconv(.c) void; };
            var out: std.mem.Allocator = undefined;
            Ext.nanoui_rt_ctx_alloc(c, &out);
            return out;
        }
        return c.arena.allocator();
    }

    pub fn print(c: *Context, comptime fmt: []const u8, args: anytype) []const u8 {
        if (@import("../rt.zig").enabled and comptime std.mem.eql(u8, fmt, "{d}") and args.len == 1 and @typeInfo(@TypeOf(args[0])) == .int) {
            const Ext = struct { extern fn nanoui_rt_ctx_print_i64(c: *Context, val: i64, out_ptr: *[*]const u8, out_len: *usize) callconv(.c) void; };
            var ptr: [*]const u8 = undefined;
            var len: usize = undefined;
            Ext.nanoui_rt_ctx_print_i64(c, @intCast(args[0]), &ptr, &len);
            return ptr[0..len];
        }
        return std.fmt.allocPrint(c.alloc(), fmt, args) catch "…";
    }
    /// Starts building a frame: the root fills the window.
    pub fn begin(c: *Context) void {
        c.noteModality();
        c.tooltip = .{};
        if (c.frame == 0 and c.nodes.capacity == 0) hooks.warmMaps(c);
        // Tab moves the focus on, unless a text field has it (it takes Tab).
        if (c.input.key == .tab and (c.focus == 0 or !c.focus_is_text) and c.last_focusable_ids.items.len > 0) {
            hooks.focusCycle(c, c.input.shift);
            c.input.key = null;
        }
        scroll_mod.updateScrollbarDrag(c);
        _ = c.arena.reset(.retain_capacity);
        c.textures.clearRetainingCapacity();
        c.gradients.clearRetainingCapacity();
        c.nodes.clearRetainingCapacity();
        c.stack.clearRetainingCapacity();
        c.next_hits.clearRetainingCapacity();
        c.a11y_items.clearRetainingCapacity();
        c.focusable_ids.clearRetainingCapacity();
        c.stage_count = 0;
        c.cursor_hand = false;
        c.cursor_text = false;
        c.cursor = null;
        c.focused_text = null;
        c.focused_multiline = false;
        c.focused_password = false;
        c.wants_wheel = false;
        c.wants_moves = false;
        c.retain.virtual_list = false;
        c.scroll_cap.clearRetainingCapacity();
        c.helps.clearRetainingCapacity();
        c.drop_targets.clearRetainingCapacity();
        c.building = true;
        c.nodes.append(c.gpa, .{
            .id = 0x9e3779b97f4a7c15,
            .style = .{ .width = .{ .px = c.size.w }, .height = .{ .px = c.size.h }, .background = if (c.transparent_root) null else c.theme.background },
        }) catch @panic("OOM");
        c.stack.append(c.gpa, 0) catch @panic("OOM");
    }

    /// A frame whose interactions changed state is built again, the input's
    /// edges spent. `close_request` is not an edge: a one-shot ask survives.
    pub fn rebuild(c: *Context) void {
        c.input.clearEdges();
        c.undo_op = .none;
        c.paste_op = false;
        c.changed = false;
        c.begin();
    }
    pub fn finish(c: *Context) void {
        c.building = false;
        if (c.focus != 0 and std.mem.indexOfScalar(u64, c.focusable_ids.items, c.focus) == null) c.focus = 0;
        c.focus_is_text = c.focus != 0 and c.focused_text != null;
        std.mem.swap(std.ArrayList(u64), &c.last_focusable_ids, &c.focusable_ids);
        if (c.right_press) {
            c.input.down = false;
            c.right_press = false;
        }
        c.input.clearEdges();
        c.undo_op = .none;
        c.paste_op = false;
        c.changed = false;
        if (!c.input.down) c.active = 0;
        c.focus_select_all = false;
        c.frame += 1;
        // Forget animations of widgets gone for a while.
        if (c.frame % 120 == 0) hooks.forgetStale(c);
        c.motion.prune(c.frame);
        if (@hasField(@TypeOf(c.text.images), "wants_frame") and c.text.images.wants_frame) c.animationFrame();
    }

    fn childId(c: *Context, key: ?[]const u8) u64 {
        const parent = &c.nodes.items[c.stack.items[c.stack.items.len - 1]];
        var h = std.hash.Wyhash.init(parent.id);
        const k = key orelse c.next_key;
        c.next_key = null;
        if (k) |v| {
            h.update(v);
        } else if (c.next_key_int) |n| {
            h.update("#");
            h.update(std.mem.asBytes(&n));
        } else h.update(std.mem.asBytes(&parent.child_count));
        c.next_key_int = null;
        return h.final();
    }

    fn add(c: *Context, new_node: Node) u32 {
        const parent_index = c.stack.items[c.stack.items.len - 1];
        const index: u32 = @intCast(c.nodes.items.len);
        var n = new_node;
        n.parent = parent_index;
        c.nodes.append(c.gpa, n) catch @panic("OOM");
        const parent = &c.nodes.items[parent_index];
        if (parent.last_child == none) parent.first_child = index else c.nodes.items[parent.last_child].next = index;
        parent.last_child = index;
        parent.child_count += 1;
        return index;
    }

    /// Opens a box; its children follow until `end`.
    pub fn open(c: *Context, style: types.Style, key: ?[]const u8) u32 {
        if (@import("../rt.zig").enabled) {
            const Ext = struct { extern fn nanoui_rt_ctx_open(c: *Context, s: *const types.Style, kp: ?[*]const u8, kl: usize) callconv(.c) u32; };
            return Ext.nanoui_rt_ctx_open(c, &style, if (key) |k| k.ptr else null, if (key) |k| k.len else 0);
        }
        return c.openImpl(style, key);
    }

    pub fn openImpl(c: *Context, style: types.Style, key: ?[]const u8) u32 {
        const index = c.add(.{ .id = c.childId(key), .style = style });
        c.stack.append(c.gpa, index) catch @panic("OOM");
        return index;
    }

    pub fn end(c: *Context) void {
        if (@import("../rt.zig").enabled) {
            const Ext = struct { extern fn nanoui_rt_ctx_end(c: *Context) callconv(.c) void; };
            return Ext.nanoui_rt_ctx_end(c);
        }
        c.endImpl();
    }

    pub fn endImpl(c: *Context) void {
        std.debug.assert(c.stack.items.len > 1);
        _ = c.stack.pop();
    }

    /// Adds a box without children.
    pub fn leaf(c: *Context, style: types.Style, content: Content, key: ?[]const u8) u32 {
        if (@import("../rt.zig").enabled) {
            const Ext = struct { extern fn nanoui_rt_ctx_leaf(c: *Context, s: *const types.Style, ct: *const Content, kp: ?[*]const u8, kl: usize) callconv(.c) u32; };
            return Ext.nanoui_rt_ctx_leaf(c, &style, &content, if (key) |k| k.ptr else null, if (key) |k| k.len else 0);
        }
        return c.leafImpl(style, content, key);
    }

    pub fn leafImpl(c: *Context, style: types.Style, content: Content, key: ?[]const u8) u32 {
        return c.add(.{ .id = c.childId(key), .style = style, .content = content });
    }

    pub fn node(c: *Context, index: u32) *Node {
        return &c.nodes.items[index];
    }

    /// The id the next child of the open box will get.
    pub fn peekId(c: *Context, key: ?[]const u8) u64 {
        const saved = c.next_key;
        const saved_int = c.next_key_int;
        defer {
            c.next_key = saved;
            c.next_key_int = saved_int;
        }
        return c.childId(key);
    }

    pub const interact = hooks.interact;
    pub const requestClose = hooks.requestClose;

    const hooks = @import("context_hooks.zig");
    const scroll_mod = @import("scroll.zig");
    pub const focusNext = hooks.focusNext;
    pub const focusCycle = hooks.focusCycle;
    pub const startDrag = hooks.startDrag;
    pub const help = hooks.help;
    pub const hotHelp = hooks.hotHelp;
    pub const acceptDrop = hooks.acceptDrop;
    pub const acceptsDropAt = hooks.acceptsDropAt;
    pub const dropAt = hooks.dropAt;
    pub const startsWindowDrag = hooks.startsWindowDrag;
    pub const framePartAt = hooks.framePartAt;
    pub const addA11y = hooks.addA11y;
    pub const adjustable = hooks.adjustable;
    pub const a11yStep = hooks.a11yStep;
    pub const a11yPress = hooks.a11yPress;
    pub const shortcut = hooks.shortcut;
    pub const state = hooks.state;
    pub const animate = hooks.animate;

    /// Asks for another frame as soon as the display can show it: for
    /// views that animate from `time` every frame.
    pub fn animationFrame(c: *Context) void {
        c.animating = true;
    }

    /// This frame only slid a clip (a sidebar seam). The next display-link
    /// tick may translate the last scene by `dx` instead of rebuilding.
    pub fn clipShift(c: *Context, slot: f32, dx: f32) void {
        c.retain.clip_shift = true;
        c.retain.clip_slot = slot;
        c.retain.clip_dx = dx;
        c.animating = true;
    }

    /// From any thread (a decoder's, a worker's): a frame is wanted, drawn
    /// at the display's next refresh. Lock-free; many asks before it runs
    /// are one frame. Not after the window has closed.
    pub fn requestFrameFromAnyThread(c: *const Context) void {
        if (c.waker) |w| w.wake(w.ctx);
    }

    /// Whether the pointer is over text that selects (as last painted):
    /// for the cursor when it moves without a frame being drawn.
    pub fn pointerOverText(c: *Context) bool {
        for (c.selection.lines.items) |r| if (r.contains(c.input.mouse)) return true;
        return c.selection.dragging;
    }

    pub const capScroll = scroll_mod.capScroll;
    pub const scrollMoved = scroll_mod.scrollMoved;
    /// Asks for another frame within `seconds`: for what changes now and
    /// then (a spinner's step, a clock's second), without drawing every
    /// refresh in between.
    pub fn frameIn(c: *Context, seconds: f32) void {
        c.frame_in = if (c.frame_in) |f| @min(f, seconds) else seconds;
    }

    pub const addHit = hooks.addHit;
    const hit_mod = @import("context_hits.zig");
    pub const commitHits = hit_mod.commitHits;
    pub const updateHot = hit_mod.updateHot;
    pub const noteModality = hit_mod.noteModality;
    pub const applyScroll = scroll_mod.applyScroll;
    pub const wheelAt = scroll_mod.wheelAt;
    pub const hasOverscroll = scroll_mod.hasOverscroll;

    pub fn pointerUp(c: *Context) void {
        c.input.down = false;
        c.input.released = true;
    }

    /// The secondary button went down (`Input.secondary`): no press, and
    /// the focus stays where it was.
    pub fn secondaryDown(c: *Context) void {
        c.updateHot();
        c.input.secondary = true;
    }

    pub fn pointerDown(c: *Context) void {
        c.updateHot();
        c.input.down = true;
        c.input.pressed = true;
        c.right_press = c.input.button == .right or (@import("keys.zig").mac and c.input.button == .left and c.input.ctrl);
        if (scroll_mod.tryPressScrollbar(c)) return;
        if (c.hot == 0) c.focus = 0;
    }

    pub const addStageHole = hooks.addStageHole;
    pub const addStageHoleNode = hooks.addStageHoleNode;
    pub const hitAt = hooks.hitAt;
    pub const inStageHoleAt = hooks.inStageHoleAt;
    pub const setScroll = @import("scroll_x.zig").setScroll;
};

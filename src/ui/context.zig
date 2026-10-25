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

pub const Content = union(enum) {
    none,
    text: Text,
    icon: Icon,
    image: Image,
    texture: Texture,
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
    };
};

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
    /// A secondary press (right, or Control-click on the Mac) on it or on a
    /// box inside it: its context menu is wanted. Like an event bubbling
    /// up, every box under the pointer sees it; ask on the one whose menu
    /// it is.
    secondary_clicked: bool = false,
    focused: bool,
};

const Hit = struct { id: u64, index: u32, rect: types.Rect, scroll: bool };

pub const Cursor = enum { arrow, hand, text, resize_left_right, resize_up_down };

/// What the last frame cost, for profiling and the hill-climb benchmarks.
pub const FrameStats = struct {
    build_ms: f64 = 0,
    layout_ms: f64 = 0,
    paint_ms: f64 = 0,
    /// Builds of the view: more than one when interactions changed state.
    passes: u32 = 0,
    nodes: usize = 0,
    instances: usize = 0,
};
const Anim = struct { value: f32, frame: u64 };
/// A widget's own state (`Context.state`): a few bytes, kept while it's drawn.
const Memory = struct { bytes: [48]u8 align(16), frame: u64 };

pub const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    text: *text.TextSystem,
    theme: Theme = .light,
    size: types.Size = .{},
    scale: f32 = 2,
    /// What draws the frames: Metal, OpenGL (Linux, where there is a GPU),
    /// or nanoui's own CPU renderer.
    renderer: []const u8 = if (@import("text.zig").portable) "CPU" else "Metal",
    /// Seconds since the previous frame, for animations.
    dt: f32 = 1.0 / 60.0,
    /// Seconds since the first frame: the clock of animations a view drives itself.
    time: f64 = 0,
    frame: u64 = 0,
    input: Input = .{},

    nodes: std.ArrayList(Node) = .empty,
    stack: std.ArrayList(u32) = .empty,

    // Kept across frames.
    rects: std.AutoHashMapUnmanaged(u64, types.Rect) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    next_hits: std.ArrayList(Hit) = .empty,
    anims: std.AutoHashMapUnmanaged(u64, Anim) = .empty,
    /// What widgets remember between frames (`state`).
    memory: std.AutoHashMapUnmanaged(u64, Memory) = .empty,
    /// What `ui.motion` remembers of each animated box.
    motion: @import("motion/store.zig").Store = .{},
    /// The system asks for reduced motion: `ui.motion` moves at once.
    reduced_motion: bool = false,
    /// Boxes of a higher layer met while painting, drawn after the page;
    /// and the one being drawn so.
    layers: std.ArrayList(u32) = .empty,
    layer_root: u32 = std.math.maxInt(u32),
    scroll: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// The textures this frame shows (`ui.texture`), by slot.
    textures: std.ArrayList(@import("gpu.zig").Texture) = .empty,
    edits: std.AutoHashMapUnmanaged(u64, EditState) = .empty,
    /// The largest scroll offset of each scrolling box in the last layout,
    /// for boxes that follow their end.
    scroll_max: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// Whether each of those follows its end, and the offset layout last
    /// left it at (a different one was moved by the reader or the app).
    scroll_follow: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    scroll_seen: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    /// An overlay bar's box: its offset as last painted, and when it last
    /// moved (`Scrollbar.overlay`).
    overlay_bars: std.AutoHashMapUnmanaged(u64, struct { offset: f32, moved_at: f64 }) = .empty,
    /// How far such a box may follow this frame (`capScroll`), and the
    /// boxes whose offset the reader or the app moved in the last layout.
    scroll_cap: std.AutoHashMapUnmanaged(u64, f32) = .empty,
    scroll_moved: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Text selected in `selectable` boxes, and this frame's Copy: asked
    /// for, and done by a text field of its own selection.
    selection: @import("selection.zig").Selection = .{},
    copy_requested: bool = false,
    /// The soonest a view asked for another frame (`frameIn`), seconds.
    frame_in: ?f32 = null,
    copy_done: bool = false,
    /// Set when the view took the offered shortcut: it goes no further.
    shortcut_taken: bool = false,
    /// Set by the focused text field each frame.
    focused_text: ?FocusedText = null,
    clipboard: Clipboard = .{},
    /// The key of the next box, for ids that survive reordering.
    next_key: ?[]const u8 = null,
    next_key_int: ?u64 = null,
    /// The topmost interactive box under the pointer: it takes presses.
    hot: u64 = 0,
    /// The hot box and the boxes it is in, innermost first: all hovered.
    hot_path: std.ArrayList(u64) = .empty,
    active: u64 = 0,
    focus: u64 = 0,

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
    /// While a live snapshot is drawn (live_snapshot.zig): what its request
    /// asked for, for the view to show it in that frame alone (it isn't put
    /// on screen); empty otherwise.
    snapshot_request: []const u8 = "",
    stats: FrameStats = .{},
    /// Set when the pointer is over something clickable.
    cursor_hand: bool = false,
    cursor_text: bool = false,
    /// A cursor a view asks for, over what widgets set (dividers).
    cursor: ?Cursor = null,

    pub fn init(gpa: std.mem.Allocator, ts: *text.TextSystem) Context {
        return .{ .gpa = gpa, .arena = .init(gpa), .text = ts };
    }

    pub fn deinit(c: *Context) void {
        c.arena.deinit();
        c.textures.deinit(c.gpa);
        c.nodes.deinit(c.gpa);
        c.stack.deinit(c.gpa);
        c.rects.deinit(c.gpa);
        c.hits.deinit(c.gpa);
        c.next_hits.deinit(c.gpa);
        c.hot_path.deinit(c.gpa);
        c.anims.deinit(c.gpa);
        c.motion.deinit(c.gpa);
        c.memory.deinit(c.gpa);
        c.layers.deinit(c.gpa);
        c.scroll.deinit(c.gpa);
        c.edits.deinit(c.gpa);
        c.scroll_max.deinit(c.gpa);
        c.scroll_follow.deinit(c.gpa);
        c.scroll_seen.deinit(c.gpa);
        c.overlay_bars.deinit(c.gpa);
        c.scroll_cap.deinit(c.gpa);
        c.scroll_moved.deinit(c.gpa);
        c.selection.deinit(c.gpa);
    }

    /// Memory that lives until the end of the frame, for formatted text.
    /// Scales every text by `z` (1 is as written): an app's zoom, ⌘= ⌘-.
    pub fn setZoom(c: *Context, z: f32) void {
        c.text.setZoom(std.math.clamp(z, 0.5, 3));
    }

    pub fn alloc(c: *Context) std.mem.Allocator {
        return c.arena.allocator();
    }

    pub fn print(c: *Context, comptime fmt: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(c.alloc(), fmt, args) catch "…";
    }

    /// Starts building a frame: the root fills the window.
    pub fn begin(c: *Context) void {
        _ = c.arena.reset(.retain_capacity);
        c.textures.clearRetainingCapacity();
        c.nodes.clearRetainingCapacity();
        c.stack.clearRetainingCapacity();
        c.next_hits.clearRetainingCapacity();
        c.cursor_hand = false;
        c.cursor_text = false;
        c.cursor = null;
        c.focused_text = null;
        c.wants_wheel = false;
        c.wants_moves = false;
        c.scroll_cap.clearRetainingCapacity();
        c.nodes.append(c.gpa, .{
            .id = 0x9e3779b97f4a7c15,
            .style = .{ .width = .{ .px = c.size.w }, .height = .{ .px = c.size.h }, .background = c.theme.background },
        }) catch @panic("OOM");
        c.stack.append(c.gpa, 0) catch @panic("OOM");
    }

    /// A frame whose interactions changed state is built again: the edges
    /// of the input (the press, the key) are consumed by the first build.
    pub fn rebuild(c: *Context) void {
        c.input.clearEdges();
        c.changed = false;
        c.begin();
    }

    pub fn finish(c: *Context) void {
        c.input.clearEdges();
        c.changed = false;
        if (!c.input.down) c.active = 0;
        c.frame += 1;
        // Forget animations of widgets gone for a while.
        if (c.frame % 120 == 0) {
            var stale: [64]u64 = undefined;
            var n: usize = 0;
            var it = c.anims.iterator();
            while (it.next()) |e| {
                if (n == stale.len) break;
                if (c.frame - e.value_ptr.frame > 120) {
                    stale[n] = e.key_ptr.*;
                    n += 1;
                }
            }
            for (stale[0..n]) |k| _ = c.anims.remove(k);
            c.motion.forget(c.frame, 120);
            n = 0;
            var mit = c.memory.iterator();
            while (mit.next()) |e| {
                if (n == stale.len) break;
                if (c.frame - e.value_ptr.frame > 120) {
                    stale[n] = e.key_ptr.*;
                    n += 1;
                }
            }
            for (stale[0..n]) |k| _ = c.memory.remove(k);
        }
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
        const index = c.add(.{ .id = c.childId(key), .style = style });
        c.stack.append(c.gpa, index) catch @panic("OOM");
        return index;
    }

    pub fn end(c: *Context) void {
        std.debug.assert(c.stack.items.len > 1);
        _ = c.stack.pop();
    }

    /// Adds a box without children.
    pub fn leaf(c: *Context, style: types.Style, content: Content, key: ?[]const u8) u32 {
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

    /// How the pointer relates to the box `index`, from the last layout.
    pub fn interact(c: *Context, index: u32, opts: struct { focusable: bool = false }) Interaction {
        const n = c.node(index);
        n.interactive = true;
        const id = n.id;
        const rect = c.rects.get(id);
        // Presses go to the topmost box alone; hover to the boxes it is in too.
        const top = c.hot == id;
        const hovered = top or std.mem.indexOfScalar(u64, c.hot_path.items, id) != null;
        if (top and c.input.pressed) {
            c.active = id;
            c.focus = if (opts.focusable) id else 0;
        }
        // A drag that selected text is not a click.
        const clicked = c.input.released and c.active == id and top and !c.selection.moved;
        if (top) c.cursor_hand = true;
        return .{
            .id = id,
            .rect = rect,
            .hovered = hovered,
            .pressed = c.active == id and c.input.down,
            .clicked = clicked,
            .double_clicked = clicked and c.input.click_count >= 2,
            .secondary_clicked = hovered and c.input.secondary,
            .focused = c.focus == id,
        };
    }

    /// Whether this event is the key combination `want`, which the view then
    /// takes: `if (c.shortcut(.{ .key = 'k', .cmd = true })) clear();`
    pub fn shortcut(c: *Context, want_in: Shortcut) bool {
        // Command shortcuts are Control ones where there is no Command key.
        const want = want_in.native();
        const s = (c.input.shortcut orelse return false).native();
        if (s.key != want.key or s.cmd != want.cmd or s.ctrl != want.ctrl or s.alt != want.alt or s.shift != want.shift) return false;
        c.shortcut_taken = true;
        c.changed = true;
        c.input.shortcut = null;
        return true;
    }

    /// Asks for another frame as soon as the display can show it: for
    /// views that animate from `time` every frame.
    pub fn animationFrame(c: *Context) void {
        c.animating = true;
    }

    /// Whether the pointer is over text that selects (as last painted):
    /// for the cursor when it moves without a frame being drawn.
    pub fn pointerOverText(c: *Context) bool {
        for (c.selection.lines.items) |r| if (r.contains(c.input.mouse)) return true;
        return c.selection.dragging;
    }

    /// Lets the box `id`, which follows its end, follow no further than
    /// `offset` this frame: what was just started stays at the top while
    /// what it prints grows below, to be read from its start.
    pub fn capScroll(c: *Context, id: u64, offset: f32) void {
        c.scroll_cap.put(c.gpa, id, @max(0, offset)) catch {};
    }

    /// Whether box `id`'s offset was moved (by the wheel, a drag, the app)
    /// in the last layout, rather than by following its end.
    pub fn scrollMoved(c: *Context, id: u64) bool {
        return c.scroll_moved.contains(id);
    }

    /// Asks for another frame within `seconds`: for what changes now and
    /// then (a spinner's step, a clock's second), without drawing every
    /// refresh in between.
    pub fn frameIn(c: *Context, seconds: f32) void {
        c.frame_in = if (c.frame_in) |f| @min(f, seconds) else seconds;
    }

    /// A widget's state of type `T` (a small struct with defaults), kept
    /// under `key` in the box now open while it's drawn every so often;
    /// forgotten a couple of seconds after it isn't.
    pub fn state(c: *Context, comptime T: type, key: []const u8) *T {
        comptime std.debug.assert(@sizeOf(T) <= 48 and @alignOf(T) <= 16);
        var h = std.hash.Wyhash.init(c.peekId(null));
        h.update("state:");
        h.update(key);
        const gop = c.memory.getOrPut(c.gpa, h.final()) catch {
            const S = struct {
                var spare: T = .{};
            };
            S.spare = .{};
            return &S.spare;
        };
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .bytes = undefined, .frame = c.frame };
            @as(*T, @ptrCast(&gop.value_ptr.bytes)).* = .{};
        }
        gop.value_ptr.frame = c.frame;
        return @ptrCast(&gop.value_ptr.bytes);
    }

    /// Moves `id`'s animated value toward `target`; returns the current value.
    pub fn animate(c: *Context, id: u64, salt: u32, target: f32, speed: f32) f32 {
        var h = std.hash.Wyhash.init(id);
        h.update(std.mem.asBytes(&salt));
        const key = h.final();
        const gop = c.anims.getOrPut(c.gpa, key) catch return target;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .value = target, .frame = c.frame };
            return target;
        }
        const a = gop.value_ptr;
        a.frame = c.frame;
        const k = 1 - @exp(-speed * @min(c.dt, 0.1));
        a.value += (target - a.value) * k;
        if (@abs(target - a.value) < 0.002) a.value = target else c.animating = true;
        return a.value;
    }

    // Called by the surface between frames.

    /// Records an interactive box's visible rectangle, in paint order.
    pub fn addHit(c: *Context, id: u64, index: u32, rect: types.Rect, scroll: bool) void {
        c.next_hits.append(c.gpa, .{ .id = id, .index = index, .rect = rect, .scroll = scroll }) catch {};
    }

    /// Swaps in the boxes of the frame just painted.
    pub fn commitHits(c: *Context) void {
        std.mem.swap(std.ArrayList(Hit), &c.hits, &c.next_hits);
        c.updateHot();
    }

    /// The topmost interactive box under the pointer becomes hot.
    pub fn updateHot(c: *Context) void {
        c.hot = 0;
        c.hot_path.clearRetainingCapacity();
        var i = c.hits.items.len;
        while (i > 0) {
            i -= 1;
            const h = c.hits.items[i];
            if (!h.scroll and h.rect.contains(c.input.mouse)) {
                c.hot = h.id;
                c.hotPath(h);
                return;
            }
        }
    }

    /// The hot box's interactive ancestors, from the tree it was painted
    /// in (between frames, still the last one).
    fn hotPath(c: *Context, h: Hit) void {
        if (h.index >= c.nodes.items.len or c.nodes.items[h.index].id != h.id) return;
        var at = h.index;
        while (at != none) {
            const n = c.nodes.items[at];
            if (n.interactive) c.hot_path.append(c.gpa, n.id) catch return;
            at = n.parent;
        }
    }

    /// Scrolls the innermost scrolling box under the pointer.
    pub fn applyScroll(c: *Context, dy: f32) bool {
        var i = c.hits.items.len;
        while (i > 0) {
            i -= 1;
            const h = c.hits.items[i];
            if (h.scroll and h.rect.contains(c.input.mouse)) {
                const gop = c.scroll.getOrPut(c.gpa, h.id) catch return false;
                if (!gop.found_existing) gop.value_ptr.* = 0;
                gop.value_ptr.* = @max(0, gop.value_ptr.* - dy);
                return true;
            }
        }
        return false;
    }

    pub fn pointerUp(c: *Context) void {
        c.input.down = false;
        c.input.released = true;
    }

    /// The secondary button went down (`Input.secondary`): no press, and
    /// the focus stays where it was.
    pub fn secondaryDown(c: *Context) void {
        c.input.secondary = true;
    }

    pub fn pointerDown(c: *Context) void {
        c.input.down = true;
        c.input.pressed = true;
        // A press outside every focusable box drops the focus.
        if (c.hot == 0) c.focus = 0;
    }
};

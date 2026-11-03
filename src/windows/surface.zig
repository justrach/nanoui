//! Native UI on Windows: the window's client area shows frames the CPU
//! renderer draws (only what changed, in bands across threads: ui.Canvas),
//! presented through a Direct3D 11 flip swap chain
//! (d3d.zig; GDI copies them where there's no Direct3D), fed the mouse,
//! the wheel, keys and typed characters from the window procedure. Frames
//! run on input and while something animates (a 60 Hz timer); idle,
//! nothing runs.
const std = @import("std");
const w = @import("win32.zig");
const ui = @import("../ui/ui.zig");
const types = @import("../ui/types.zig");
const gpu = @import("../ui/gpu.zig");
const canvas = @import("../ui/canvas.zig");
const text = @import("../ui/text.zig");
const frame_mod = @import("../ui/frame.zig");
const ctx_mod = @import("../ui/context.zig");
const clock = @import("../ui/clock.zig");
const Theme = @import("../ui/theme.zig").Theme;
const Context = ctx_mod.Context;
const Window = @import("window.zig").Window;
const d3d = @import("d3d.zig");
const d3d11 = @import("../ui/d3d11.zig");
const gpu_side = @import("surface_gpu.zig");
const ime = @import("ime.zig");

/// Posted for a frame requested from outside the view.
pub const WM_FRAME = w.WM_APP + 1;
const tick_timer = 1;
/// A frame asked for later (`frameIn`).
const later_timer: usize = 2;

pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: *Window,
    text: text.TextSystem,
    ctx: Context,
    view: ui.View,
    instances: std.ArrayList(gpu.Instance) = .empty,
    pixels: canvas.Canvas = .{},
    size: types.Size = .{},
    scale: f32 = 1,
    last_frame_time: f64 = 0,
    /// A frame is being built: a second one asked for meanwhile is queued, not
    /// run. Windows dispatches messages from inside calls the view makes
    /// (`ShellExecuteW` pumps its own), so a timer can reach `frame` while the
    /// view is still building the Context, and the Context is not re-entrant.
    in_frame: bool = false,
    /// A frame was asked for while one was building: run one more after it.
    frame_again: bool = false,
    start_time: f64,
    ticking: bool = false,
    frame_posted: bool = false,
    tracking: bool = false,
    theme_override: ?Theme = null,
    /// The system's appearance as last read: a window that names no theme of
    /// its own follows it, and `WM_SETTINGCHANGE` says when it changed.
    system_theme_dark: bool = false,
    /// The theme the view asked for with `c.theme`, which outranks the system's
    /// appearance until the view resets it to null.
    theme_chosen: ?Theme = null,
    cursor: ctx_mod.Cursor = .arrow,
    /// A UTF-16 high surrogate waiting for its other half.
    high: u16 = 0,
    /// The IME's state for this window: a composition running, the guard that
    /// keeps a placement from echoing into a freeze, and the caret last told
    /// about. `ime.zig` says why each one exists.
    ime: ime.State = .{},
    chars: [8]u8 = undefined,
    /// Where `NANOUI_DUMP` writes the frames it compares.
    path_buf: [64]u8 = undefined,
    /// Frames go to the screen through this, once made; GDI if it can't be.
    presenter: ?d3d.Presenter = null,
    no_d3d: bool = false,
    /// The frame drawn by the GPU, on the swap chain's own device. Absent
    /// until the first frame, and after the device is lost.
    gpu: ?d3d11.Renderer = null,
    /// Set when there is no Direct3D 11 renderer to draw with, so that the
    /// canvas is not kept trying.
    no_gpu: bool = false,
    /// A size arrived that no frame has been built for yet.
    size_dirty: bool = false,
    /// A drag is moving the window's edge (`WM_ENTERSIZEMOVE` .. `WM_EXITSIZEMOVE`).
    dragging: bool = false,
    /// `NANOUI_DUMP`: F12 writes the canvas beside the same frame drawn whole.
    dump_enabled: bool = false,
    dumps: usize = 0,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        self.* = .{ .gpa = gpa, .window = window, .text = .init(gpa), .ctx = undefined, .view = view, .theme_override = theme_override, .start_time = clock.now() };
        self.ctx = .init(gpa, &self.text);
        // Diagnostics, off unless asked for: which presenter draws the frame,
        // how many threads draw it, and F12 dumping the canvas.
        self.no_d3d = envFlag("NANOUI_NO_D3D");
        self.dump_enabled = envFlag("NANOUI_DUMP");
        if (envFlag("NANOUI_ONE_THREAD")) @import("../ui/raster.zig").threads = 1;
        // Frames come from Direct3D 11 here (`paintGpu`), so the view names it
        // from the first frame; if no device can be made, `paintGpu` says CPU
        // and the next frame reads that instead.
        if (!self.no_d3d) self.ctx.renderer = "Direct3D 11";
        // The system's appearance now, and again if it changes while the app
        // runs (a window without a theme of its own follows it).
        self.system_theme_dark = @import("desktop.zig").isDark();
        return self;
    }

    pub fn destroy(self: *Surface) void {
        gpu_side.release(self);
        // The IME's scratch buffers: three ArrayLists that outlive a frame.
        self.ime.deinit(self.gpa);
        self.instances.deinit(self.gpa);
        self.pixels.deinit(self.gpa);
        self.ctx.deinit();
        self.text.deinit();
        self.gpa.destroy(self);
    }

    fn hwnd(self: *Surface) ?w.HWND {
        return self.window.hwnd;
    }

    /// The theme the frame is drawn with: a window's own when it named one,
    /// else the one the view chose (`c.theme`), else the system's appearance.
    fn theme(self: *Surface) Theme {
        if (self.theme_override) |t| return t;
        if (self.theme_chosen) |t| return t;
        return if (self.system_theme_dark) Theme.dark_theme else Theme.light;
    }

    /// Builds the view for the current state and asks for it to be drawn: the
    /// one entry point for everything that changes what the window shows.
    pub fn frame(self: *Surface) void {
        if (self.in_frame) {
            // Building the view called something that pumped messages (the
            // shell, a dialog), and a timer or input arrived: the frame it asks
            // for runs once the one being built is done.
            self.frame_again = true;
            return;
        }
        self.in_frame = true;
        defer self.in_frame = false;
        // A view that asks for a frame every time it builds one would spin
        // here; a handful is what a queued timer or a click needs.
        var passes: u8 = 0;
        while (passes < 4) : (passes += 1) {
            self.frame_again = false;
            self.buildFrame();
            gpu_side.invalidate(self);
            if (!self.frame_again) break;
        }
        self.frame_again = false;
        // The size a WM_SIZE between frames brought is built here: a WM_PAINT
        // still to come has nothing left to build.
        self.size_dirty = false;
    }

    /// Builds one frame: layout, paint, and the timers animations and later
    /// frames need, without asking for a paint. `frame` adds that; `paint` is
    /// already drawing.
    pub fn buildFrame(self: *Surface) void {
        if (self.size.w <= 0 or self.size.h <= 0) return;
        const c = &self.ctx;
        const now = clock.now();
        const raw_dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 1.0)) else 1.0 / 60.0;
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        // The theme the view picked last frame, and the one it picks now: a
        // view that picks a theme has the frame rebuilt with it in this same
        // frame, so a change shows at once and the first frame is right too.
        var drawn_theme = self.theme();
        var r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, drawn_theme, dt, now - self.start_time);
        if (!sameChoice(self.theme_chosen, c.theme_chosen)) {
            self.theme_chosen = c.theme_chosen;
            drawn_theme = self.theme();
            r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, drawn_theme, dt, now - self.start_time);
        }
        // The real gap, for a view that reports its frame rate: `dt` above is
        // clamped so an animation cannot jump. The rate is what it is.
        c.frame_time = raw_dt;
        // The caret may have moved: the IME's windows follow it.
        if (c.focused_text != null) if (self.hwnd()) |h| ime.followIfMoved(h, c, self.scale, &self.ime);
        if (c.close_request) {
            c.close_request = false;
            self.window.close();
        }
        self.updateCursor();
        const more = c.animating or r.hot_changed;
        if (more and !self.ticking) if (self.hwnd()) |h| {
            _ = w.SetTimer(h, tick_timer, 16, null);
            self.ticking = true;
        };
        // Something changes now and then: one frame, that much later.
        if (!more) if (c.frame_in) |s| if (self.hwnd()) |h| {
            _ = w.SetTimer(h, later_timer, @intFromFloat(@max(1, s * 1000)), null);
        };
    }

    /// Whether two theme choices pick the same theme (both null: the system's).
    fn sameChoice(a: ?Theme, b: ?Theme) bool {
        const an = a orelse return b == null;
        const bn = b orelse return false;
        return std.meta.eql(an, bn);
    }

    pub fn requestFrame(self: *Surface) void {
        if (self.frame_posted) return;
        const h = self.hwnd() orelse return;
        self.frame_posted = true;
        _ = w.PostMessageW(h, WM_FRAME, 0, 0);
    }

    fn updateCursor(self: *Surface) void {
        self.cursor = self.ctx.cursor orelse if (self.ctx.cursor_text) .text else if (self.ctx.cursor_hand) .hand else .arrow;
    }

    fn setCursor(self: *Surface) void {
        // IDC_ARROW, IDC_HAND, IDC_IBEAM, IDC_SIZEWE, IDC_SIZENS, IDC_SIZEALL, IDC_NO.
        const id: usize = switch (self.cursor) {
            .arrow => 32512,
            .hand => 32649,
            .text => 32513,
            .resize_left_right => 32644,
            .resize_up_down => 32645,
            .open_hand, .closed_hand => 32646,
            .not_allowed => 32648,
            .crosshair => 32515,
        };
        _ = w.SetCursor(w.LoadCursorW(null, id));
    }

    fn updateSize(self: *Surface, h: w.HWND) void {
        var r: w.RECT = .{};
        _ = w.GetClientRect(h, &r);
        const dpi = w.GetDpiForWindow(h);
        const scale: f32 = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
        // A drag-resize sends WM_SIZE per pixel of movement, and the DPI does
        // not change with the size: only a scale that changed is worth telling
        // the text system about (it would empty the glyph atlas to re-raster
        // every glyph at the new scale).
        if (scale != self.scale) {
            self.scale = scale;
            self.text.setScale(scale);
        }
        self.size = .{ .w = @as(f32, @floatFromInt(r.right - r.left)) / self.scale, .h = @as(f32, @floatFromInt(r.bottom - r.top)) / self.scale };
    }

    fn setMouse(self: *Surface, lp: w.LPARAM) void {
        const x: i16 = @truncate(lp);
        const y: i16 = @truncate(lp >> 16);
        self.ctx.input.mouse = .{ .x = @as(f32, @floatFromInt(x)) / self.scale, .y = @as(f32, @floatFromInt(y)) / self.scale };
        self.ctx.input.shift = w.GetKeyState(0x10) < 0;
        self.ctx.input.cmd = false;
        self.ctx.input.ctrl = w.GetKeyState(0x11) < 0;
    }

    /// The window procedure's part for native UI; null for messages it
    /// leaves to the default.
    pub fn handle(self: *Surface, h: w.HWND, msg: u32, wp: w.WPARAM, lp: w.LPARAM) ?w.LRESULT {
        switch (msg) {
            w.WM_PAINT => gpu_side.paint(self, h),
            w.WM_ERASEBKGND => return 1,
            w.WM_SETTINGCHANGE => {
                // The system's appearance may have changed under
                // Personalization > Colors: a window that follows it is redrawn.
                if (self.theme_override == null) {
                    const dark = @import("desktop.zig").isDark();
                    if (dark != self.system_theme_dark) {
                        self.system_theme_dark = dark;
                        self.frame();
                    }
                }
            },
            w.WM_DPICHANGED => {
                // The window has moved or been scaled onto a monitor with
                // another DPI: the system suggests a rect that keeps its
                // physical size, and WM_SIZE from that reads the new scale.
                const r: *const w.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
                _ = w.SetWindowPos(h, null, r.left, r.top, r.right - r.left, r.bottom - r.top, 0x0004 | 0x0010); // no z-order, no activate
                return 0;
            },
            w.WM_SIZE => {
                // A resize is many messages a second, and laying the view out
                // for each is wasted: the size is read now, the frame built once
                // when the queue is empty. Except before the first frame: a
                // hidden window never receives WM_PAINT, so deferring it leaves
                // every rect zero and clicks landing nowhere.
                self.updateSize(h);
                if (self.last_frame_time == 0) {
                    self.buildFrame();
                    self.requestFrame();
                } else {
                    self.size_dirty = true;
                    if (self.hwnd()) |hh| _ = w.InvalidateRect(hh, null, 0);
                }
            },
            // A drag resize begins and ends: between them frames present at
            // once instead of one per vblank, so the sizes the drag passes
            // through are not each a refresh behind the pointer.
            w.WM_ENTERSIZEMOVE, w.WM_EXITSIZEMOVE => {
                // The surface keeps it as well as the presenter: the drag may
                // begin before the first frame made one.
                const begin = msg == w.WM_ENTERSIZEMOVE;
                self.dragging = begin;
                if (self.presenter) |*p| {
                    p.resizing = begin;
                    // The size the drag ended on, in one ResizeBuffers.
                    if (!begin) p.endResize();
                }
                if (!begin) self.requestFrame();
            },
            w.WM_TIMER => if (wp == later_timer) {
                _ = w.KillTimer(h, later_timer);
                self.frame();
            } else if (wp == tick_timer) {
                self.frame();
                if (!self.ctx.animating) {
                    _ = w.KillTimer(h, tick_timer);
                    self.ticking = false;
                }
            },
            WM_FRAME => {
                self.frame_posted = false;
                self.frame();
            },
            w.WM_SETCURSOR => {
                // Over the client area only: the frame keeps its own.
                if (lp & 0xffff != 1) return null;
                self.setCursor();
                return 1;
            },
            w.WM_MOUSEMOVE => {
                if (!self.tracking) {
                    var t: w.TRACKMOUSEEVENT = .{ .dwFlags = 2, .hwndTrack = h };
                    _ = w.TrackMouseEvent(&t);
                    self.tracking = true;
                }
                self.setMouse(lp);
                const before = self.ctx.hot;
                self.ctx.updateHot();
                if (self.ctx.input.down or self.ctx.hot != before or self.ctx.wants_moves) {
                    self.frame();
                } else if (self.ctx.pointerOverText() != self.ctx.cursor_text) {
                    // Onto or off text that selects: the cursor only.
                    self.ctx.cursor_text = !self.ctx.cursor_text;
                    self.updateCursor();
                }
            },
            w.WM_MOUSELEAVE => {
                self.tracking = false;
                self.ctx.input.mouse = .{ .x = -1e6, .y = -1e6 };
                if (self.ctx.hot != 0) {
                    self.ctx.updateHot();
                    self.frame();
                }
            },
            w.WM_LBUTTONDOWN, w.WM_LBUTTONDBLCLK => {
                self.setMouse(lp);
                self.ctx.input.click_count = if (msg == w.WM_LBUTTONDBLCLK) 2 else 1;
                self.ctx.updateHot();
                // A borderless window's drag handle (`window_drag`): the press
                // belongs to the system's move loop, the way macOS hands the
                // event to `performWindowDragWithEvent`. A double click zooms.
                if (self.ctx.startsWindowDrag()) {
                    if (msg == w.WM_LBUTTONDBLCLK) {
                        self.window.zoom();
                    } else {
                        _ = w.ReleaseCapture();
                        _ = w.SendMessageW(h, w.WM_NCLBUTTONDOWN, w.HTCAPTION, 0);
                    }
                    return 0;
                }
                _ = w.SetCapture(h);
                self.ctx.pointerDown();
                self.frame();
            },
            w.WM_LBUTTONUP => {
                _ = w.ReleaseCapture();
                self.setMouse(lp);
                self.ctx.updateHot();
                self.ctx.pointerUp();
                self.frame();
            },
            w.WM_MOUSEWHEEL => {
                var p: w.POINT = .{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
                _ = w.ScreenToClient(h, &p);
                self.ctx.input.mouse = .{ .x = @as(f32, @floatFromInt(p.x)) / self.scale, .y = @as(f32, @floatFromInt(p.y)) / self.scale };
                const notches: f32 = @as(f32, @floatFromInt(@as(i16, @truncate(@as(isize, @bitCast(wp)) >> 16)))) / 120;
                const delta = notches * 48;
                if (self.ctx.applyScroll(delta)) {
                    self.frame();
                    self.ctx.updateHot();
                } else if (self.ctx.wants_wheel) {
                    self.ctx.input.scroll = .{ .y = delta };
                    self.frame();
                }
            },
            // The sideways wheel (tilt, trackpads): the same as the vertical
            // one, along x. Windows' delta is positive to the right.
            w.WM_MOUSEHWHEEL => {
                var p: w.POINT = .{ .x = @as(i16, @truncate(lp)), .y = @as(i16, @truncate(lp >> 16)) };
                _ = w.ScreenToClient(h, &p);
                self.ctx.input.mouse = .{ .x = @as(f32, @floatFromInt(p.x)) / self.scale, .y = @as(f32, @floatFromInt(p.y)) / self.scale };
                const notches: f32 = @as(f32, @floatFromInt(@as(i16, @truncate(@as(isize, @bitCast(wp)) >> 16)))) / 120;
                self.ctx.input.scroll = .{ .x = notches * 48 };
                self.frame();
            },
            w.WM_KEYDOWN, w.WM_SYSKEYDOWN => {
                // F12, with NANOUI_DUMP set: what the canvas holds, and what
                // drawing the same frame whole makes of it.
                if (wp == 0x7B and self.dump_enabled) {
                    gpu_side.verify(self);
                    return 0;
                }
                // Composing: the keys belong to the input method — its caret,
                // its candidates, Return to commit. Handling them here as well
                // makes Return commit and insert a newline at the same time.
                // A *system* key is another matter: Alt+F4 and its friends must
                // keep working, so they go to the default handling.
                if (self.ime.composing) return if (msg == w.WM_SYSKEYDOWN) null else 0;
                if (self.keyDown(@intCast(wp))) {
                    // An arrow key or a delete moved the caret: the IME's windows
                    // follow it, outside `frame` where its callbacks re-enter.
                    if (self.ctx.focused_text != null) ime.follow(h, &self.ctx, self.scale, &self.ime);
                    return 0;
                }
                return null;
            },
            w.WM_CHAR, w.WM_IME_CHAR => ime.char(self, @truncate(wp)),
            // The input method and its windows: `ime.zig` has the lot.
            else => if (ime.handle(self, h, msg, wp, lp)) |r| return r else return null,
        }
        return 0;
    }

    /// Keys that are not text, and key combinations; true if taken.
    fn keyDown(self: *Surface, vk: u32) bool {
        const in = &self.ctx.input;
        const ctrl = w.GetKeyState(0x11) < 0;
        const alt = w.GetKeyState(0x12) < 0;
        in.shift = w.GetKeyState(0x10) < 0;
        in.cmd = false;
        in.ctrl = ctrl;
        in.alt = alt;
        const key: ?ctx_mod.Key = switch (vk) {
            0x08 => .backspace,
            0x2E => .delete,
            0x25 => .left,
            0x26 => .up,
            0x27 => .right,
            0x28 => .down,
            0x24 => .home,
            0x23 => .end,
            0x0D => .enter,
            0x09 => .tab,
            0x1B => .escape,
            0x21 => .page_up,
            0x22 => .page_down,
            0x70...0x7B => @fromBackingInt(@intCast(@backingInt(ctx_mod.Key.f1) + (vk - 0x70))),
            else => null,
        };
        const S = ui.Shortcut;
        const special: ?u21 = if (key) |k| switch (k) {
            .up => S.up,
            .down => S.down,
            .left => S.left,
            .right => S.right,
            .tab => S.tab,
            .escape => S.escape,
            .enter => S.enter,
            else => null,
        } else null;
        // Letters and digits by their virtual key; other characters come as WM_CHAR.
        const letter: u21 = if ((vk >= 'A' and vk <= 'Z') or (vk >= '0' and vk <= '9')) std.ascii.toLower(@intCast(vk)) else switch (vk) {
            0xBC => ',',
            0xBE => '.',
            0xBF => '/',
            0xDB => '[',
            0xDD => ']',
            0xDC => '\\',
            0xBD => '-',
            0xBB => '=',
            0x20 => ' ',
            else => 0,
        };
        const base: u21 = special orelse letter;
        const offer = base != 0 and (ctrl or alt or base == S.up or base == S.down or base == S.tab or base == S.escape);
        if (offer) {
            const sc: S = .{ .key = base, .ctrl = ctrl, .alt = alt, .shift = in.shift };
            if (self.window.app.accelerator(sc)) return true;
            if (ctrl and self.ctx.focused_text != null and self.editShortcut(base)) return true;
            self.ctx.shortcut_taken = false;
            in.shortcut = sc;
            // Restored, not cleared: building the view can pump messages (the
            // shell does), and an IME character that arrives inside the pump
            // sets its own ops — which must not be thrown away with ours.
            const prev_ops = self.ctx.input.ops;
            self.frame();
            self.ctx.input.ops = prev_ops;
            in.shortcut = null;
            if (self.ctx.shortcut_taken) return true;
        }
        if (key) |k| {
            in.key = k;
            self.frame();
            return true;
        }
        return false;
    }

    /// Ctrl+C, X, V and A in a text field: copy, cut, paste, select all.
    fn editShortcut(self: *Surface, key: u21) bool {
        var ops: [1]ctx_mod.TextOp = undefined;
        var pasted: ?[]u8 = null;
        defer if (pasted) |p| self.gpa.free(p);
        ops[0] = switch (key) {
            'c' => .{ .command = .copy },
            'x' => .{ .command = .cut },
            'a' => .{ .command = .select_all },
            'v' => blk: {
                pasted = @import("desktop.zig").clipboard.readText(self.gpa) catch null;
                // No text: the view may take Ctrl+V for something else (an image).
                const t = pasted orelse return false;
                for (t) |*ch| if (ch.* == '\n' or ch.* == '\r') {
                    ch.* = ' ';
                };
                break :blk .{ .insert = t };
            },
            else => return false,
        };
        // Restored, not cleared, for the same reason as in `keyDown`: a message
        // pumped during the frame may set ops of its own.
        const prev_ops = self.ctx.input.ops;
        self.ctx.input.ops = &ops;
        self.frame();
        self.ctx.input.ops = prev_ops;
        return true;
    }
};

/// Whether the environment variable `name` is set to something but "0":
/// `NANOUI_NO_D3D` (draw with GDI), `NANOUI_ONE_THREAD` (one raster thread),
/// `NANOUI_DUMP` (F12 dumps the canvas). All off unless set.
fn envFlag(name: []const u8) bool {
    if (name.len == 0 or name.len > 120) return false;
    var key: [128]u16 = undefined;
    for (name, 0..) |ch, i| key[i] = ch;
    key[name.len] = 0;
    var value: [64]u16 = undefined;
    const n = w.GetEnvironmentVariableW(@ptrCast(&key), &value, value.len);
    return n > 0 and n < value.len and value[0] != '0';
}

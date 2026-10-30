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
    start_time: f64,
    ticking: bool = false,
    frame_posted: bool = false,
    tracking: bool = false,
    theme_override: ?Theme = null,
    cursor: ctx_mod.Cursor = .arrow,
    /// A UTF-16 high surrogate waiting for its other half.
    high: u16 = 0,
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
        return self;
    }

    pub fn destroy(self: *Surface) void {
        gpu_side.release(self);
        self.instances.deinit(self.gpa);
        self.pixels.deinit(self.gpa);
        self.ctx.deinit();
        self.text.deinit();
        self.gpa.destroy(self);
    }

    fn hwnd(self: *Surface) ?w.HWND {
        return self.window.hwnd;
    }

    fn theme(self: *Surface) Theme {
        return self.theme_override orelse Theme.light;
    }

    /// Builds the view for the current state and asks for it to be drawn: the
    /// one entry point for everything that changes what the window shows.
    pub fn frame(self: *Surface) void {
        self.buildFrame();
        self.invalidate();
    }

    /// Asks Windows to paint the client area again. Called once per frame that
    /// is built: a WM_SIZE that already invalidated must not add another, or
    /// every size a drag passes through is drawn twice.
    fn invalidate(self: *Surface) void {
        const h = self.hwnd() orelse return;
        // A GPU frame draws the whole client area, so there is no damage to work
        // out (and no CPU pixels to keep for it). The CPU path still finds what
        // changed.
        if (self.gpu != null) {
            _ = w.InvalidateRect(h, null, 0);
        } else if (self.pixels.damage(self.shown())) |d| {
            const rect: w.RECT = .{ .left = @intCast(d[0]), .top = @intCast(d[1]), .right = @intCast(d[2]), .bottom = @intCast(d[3]) };
            _ = w.InvalidateRect(h, &rect, 0);
        }
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
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        // The real gap, for a view that reports its frame rate: `dt` above is
        // clamped so an animation cannot jump, but the rate is what it is.
        c.frame_time = raw_dt;
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

    pub fn requestFrame(self: *Surface) void {
        if (self.frame_posted) return;
        const h = self.hwnd() orelse return;
        self.frame_posted = true;
        _ = w.PostMessageW(h, WM_FRAME, 0, 0);
    }

    pub fn shown(self: *Surface) canvas.Frame {
        return .{ .instances = self.instances.items, .text = &self.text, .clear = self.ctx.theme.background, .size = self.size, .scale = self.scale, .textures = self.ctx.textures.items };
    }

    fn paint(self: *Surface, h: w.HWND) void {
        var ps: w.PAINTSTRUCT = undefined;
        const dc = w.BeginPaint(h, &ps) orelse return;
        defer _ = w.EndPaint(h, &ps);
        // A size arrived since the last frame: build it now, once, however many
        // WM_SIZE messages asked for it. No invalidation: this paint is the
        // drawing, and asking for another would draw every size twice.
        if (self.size_dirty) {
            self.size_dirty = false;
            self.buildFrame();
        }
        // The GPU first: it draws the whole frame, and no CPU rasterising
        // happens at all. Without one, the canvas draws what changed.
        if (gpu_side.paintGpu(self, h)) return;
        self.pixels.draw(self.gpa, self.shown());
        const px = &self.pixels;
        if (px.bytes.len == 0) return;
        if (gpu_side.present(self, h)) return;
        // A negative height: rows from the top, as the renderer writes them.
        // GDI copies only what was invalidated.
        const info: w.BITMAPINFOHEADER = .{ .biWidth = @intCast(px.width), .biHeight = -@as(i32, @intCast(px.height)) };
        _ = w.SetDIBitsToDevice(dc, 0, 0, @intCast(px.width), @intCast(px.height), 0, 0, 0, @intCast(px.height), px.bytes.ptr, &info, 0);
    }

    /// Presents the frame through the swap chain (made the first time);
    /// false to draw with GDI instead. A lost device is made again next frame.
    /// The frame drawn by Direct3D 11 straight into the swap chain's back
    /// buffer, from the instances `frame.zig` made. False when there is no
    /// renderer: the canvas then draws the frame instead.
    /// `NANOUI_DUMP`, on F12: draws the frame whole beside what the canvas
    /// holds and says whether they differ — the canvas is what the screen is
    /// given, the whole redraw is what it should have been. Only ever run
    /// when asked: it redraws the frame, so it costs a frame's worth of time.
    fn verify(self: *Surface) void {
        const gpa = self.gpa;
        const px = &self.pixels;
        if (px.bytes.len == 0) return;
        const whole_bytes = gpa.alloc(u8, px.bytes.len) catch return;
        defer gpa.free(whole_bytes);
        const whole: gpu.Pixels = .{ .bytes = whole_bytes, .width = px.width, .height = px.height };
        var pictures = self.text.images.pictures();
        pictures.textures = self.ctx.textures.items;
        @import("../ui/raster.zig").draw(whole, self.instances.items, self.text.atlas.mask(), pictures, self.scale, self.ctx.theme.background);
        var differ: usize = 0;
        for (whole_bytes, px.bytes) |a, b| {
            if (a != b) differ += 1;
        }
        if (differ == 0 and self.dumps > 0) return;
        const n = self.dumps;
        self.dumps += 1;        const io = std.Io.Threaded.global_single_threaded.io();
        const shot: gpu.Pixels = .{ .bytes = px.bytes, .width = px.width, .height = px.height };
        var name: [128]u8 = undefined;
        @import("../ui/png.zig").writePng(gpa, io, std.fmt.bufPrint(&name, "nanoui-canvas-{d}.png", .{n}) catch return, shot) catch |e| {
            std.debug.print("nanoui: canvas dump failed: {t}\n", .{e});
        };
        @import("../ui/png.zig").writePng(gpa, io, std.fmt.bufPrint(&name, "nanoui-whole-{d}.png", .{n}) catch return, whole) catch |e| {
            std.debug.print("nanoui: whole dump failed: {t}\n", .{e});
        };
        std.debug.print("nanoui: dumped {d}x{d} frame {d}: canvas vs whole redraw differ in {d} of {d} bytes\n", .{ px.width, px.height, n, differ, px.bytes.len });
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
            w.WM_PAINT => self.paint(h),
            w.WM_ERASEBKGND => return 1,
            w.WM_SIZE, w.WM_DPICHANGED => {
                // A resize is many messages a second, and laying the view out
                // for each of them is wasted work: the size is read now, and the
                // frame is built once, when the message queue is empty.
                self.updateSize(h);
                self.size_dirty = true;
                if (self.hwnd()) |hh| _ = w.InvalidateRect(hh, null, 0);
            },
            // A drag resize begins and ends: between them frames present at
            // once instead of one per vblank, so the sizes the drag passes
            // through are not each a refresh behind the pointer.
            0x0231, 0x0232 => { // WM_ENTERSIZEMOVE, WM_EXITSIZEMOVE
                // The surface keeps it as well as the presenter: the drag may
                // begin before the first frame made one.
                const begin = msg == 0x0231;
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
                _ = w.SetCapture(h);
                self.setMouse(lp);
                self.ctx.input.click_count = if (msg == w.WM_LBUTTONDBLCLK) 2 else 1;
                self.ctx.updateHot();
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
            w.WM_KEYDOWN, w.WM_SYSKEYDOWN => {
                // F12, with NANOUI_DUMP set: what the canvas holds, and what
                // drawing the same frame whole makes of it.
                if (wp == 0x7B and self.dump_enabled) {
                    self.verify();
                    return 0;
                }
                if (self.keyDown(@intCast(wp))) return 0 else return null;
            },
            w.WM_CHAR => self.char(@truncate(wp)),
            else => return null,
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
            0x70...0x7B => @enumFromInt(@intFromEnum(ctx_mod.Key.f1) + (vk - 0x70)),
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
            self.frame();
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

    fn char(self: *Surface, unit: u16) void {
        if (unit >= 0xD800 and unit <= 0xDBFF) {
            self.high = unit;
            return;
        }
        var cp: u21 = unit;
        if (unit >= 0xDC00 and unit <= 0xDFFF) {
            if (self.high == 0) return;
            cp = 0x10000 + ((@as(u21, self.high) - 0xD800) << 10) + (unit - 0xDC00);
            self.high = 0;
        }
        // Controls (Ctrl+letters, Enter, Tab, Backspace) came as keys.
        if (cp < 0x20 or cp == 0x7f) return;
        const n = std.unicode.utf8Encode(cp, &self.chars) catch return;
        self.ctx.input.chars = self.chars[0..n];
        self.frame();
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
        self.ctx.input.ops = &ops;
        self.frame();
        self.ctx.input.ops = &.{};
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
    return n > 0 and n <= value.len and value[0] != '0';
}

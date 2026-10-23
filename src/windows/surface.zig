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
    /// Frames go to the screen through this, once made; GDI if it can't be.
    presenter: ?d3d.Presenter = null,
    no_d3d: bool = false,

    pub fn create(window: *Window, view: ui.View, theme_override: ?Theme) !*Surface {
        const gpa = window.app.gpa;
        const self = try gpa.create(Surface);
        self.* = .{ .gpa = gpa, .window = window, .text = .init(gpa), .ctx = undefined, .view = view, .theme_override = theme_override, .start_time = clock.now() };
        self.ctx = .init(gpa, &self.text);
        return self;
    }

    pub fn destroy(self: *Surface) void {
        if (self.presenter) |*p| p.deinit();
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

    pub fn frame(self: *Surface) void {
        if (self.size.w <= 0 or self.size.h <= 0) return;
        const c = &self.ctx;
        const now = clock.now();
        const dt: f32 = if (self.last_frame_time > 0) @floatCast(@min(now - self.last_frame_time, 0.1)) else 1.0 / 60.0;
        self.last_frame_time = now;
        const r = frame_mod.run(c, self.view, &self.text, &self.instances, self.size, self.scale, self.theme(), dt, now - self.start_time);
        // The client area is in pixels, as the damage is.
        if (self.pixels.damage(self.shown())) |d| if (self.hwnd()) |h| {
            const rect: w.RECT = .{ .left = @intCast(d[0]), .top = @intCast(d[1]), .right = @intCast(d[2]), .bottom = @intCast(d[3]) };
            _ = w.InvalidateRect(h, &rect, 0);
        };
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
        if (!c.animating) self.last_frame_time = 0;
    }

    pub fn requestFrame(self: *Surface) void {
        if (self.frame_posted) return;
        const h = self.hwnd() orelse return;
        self.frame_posted = true;
        _ = w.PostMessageW(h, WM_FRAME, 0, 0);
    }

    fn shown(self: *Surface) canvas.Frame {
        return .{ .instances = self.instances.items, .text = &self.text, .clear = self.ctx.theme.background, .size = self.size, .scale = self.scale, .textures = self.ctx.textures.items };
    }

    fn paint(self: *Surface, h: w.HWND) void {
        var ps: w.PAINTSTRUCT = undefined;
        const dc = w.BeginPaint(h, &ps) orelse return;
        defer _ = w.EndPaint(h, &ps);
        self.pixels.draw(self.gpa, self.shown());
        const px = &self.pixels;
        if (px.bytes.len == 0) return;
        if (self.present(h)) return;
        // A negative height: rows from the top, as the renderer writes them.
        // GDI copies only what was invalidated.
        const info: w.BITMAPINFOHEADER = .{ .biWidth = @intCast(px.width), .biHeight = -@as(i32, @intCast(px.height)) };
        _ = w.SetDIBitsToDevice(dc, 0, 0, @intCast(px.width), @intCast(px.height), 0, 0, 0, @intCast(px.height), px.bytes.ptr, &info, 0);
    }

    /// Presents the frame through the swap chain (made the first time);
    /// false to draw with GDI instead. A lost device is made again next frame.
    fn present(self: *Surface, h: w.HWND) bool {
        if (self.no_d3d) return false;
        const pw: u32 = @intCast(self.pixels.width);
        const ph: u32 = @intCast(self.pixels.height);
        if (self.presenter == null) {
            self.presenter = d3d.Presenter.init(h, pw, ph) catch {
                self.no_d3d = true;
                return false;
            };
        }
        const p = &self.presenter.?;
        const bg = self.ctx.theme.background;
        p.setBackground(bg.r, bg.g, bg.b);
        p.upload(self.pixels.bytes, pw, ph) catch {
            p.deinit();
            self.presenter = null;
            return false;
        };
        if (!p.present()) {
            // The device was lost: a new one gets the whole frame.
            p.deinit();
            self.presenter = null;
            _ = w.InvalidateRect(h, null, 0);
        }
        return true;
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
        self.scale = if (dpi > 0) @as(f32, @floatFromInt(dpi)) / 96 else 1;
        self.size = .{ .w = @as(f32, @floatFromInt(r.right - r.left)) / self.scale, .h = @as(f32, @floatFromInt(r.bottom - r.top)) / self.scale };
        self.text.setScale(self.scale);
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
                self.updateSize(h);
                self.frame();
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
            w.WM_KEYDOWN, w.WM_SYSKEYDOWN => if (self.keyDown(@intCast(wp))) return 0 else return null,
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

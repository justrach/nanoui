//! The Direct3D 11 side of a Windows surface: drawing the frame on the GPU,
//! presenting the CPU renderer's pixels through the same swap chain, and the
//! dump that compares the two — plus the paint that chooses between them and
//! GDI. `surface.zig` keeps the events and the frame.
const std = @import("std");
const w = @import("win32.zig");
const d3d = @import("d3d.zig");
const canvas = @import("../ui/canvas.zig");
const d3d11 = @import("../ui/d3d11.zig");
const gpu = @import("../ui/gpu.zig");
const raster = @import("../ui/raster.zig");
const types = @import("../ui/types.zig");
const surface = @import("surface.zig");
const Surface = surface.Surface;

/// Whether this frame may go through D3D at all: the window is opaque and no
/// device failure is known. A layered window's alpha (`opacity` below 1) is
/// lost on a flip-model swap chain, so below 1 everything D3D — draw *and*
/// present — stands down for GDI.
pub fn wantsGpu(self: *Surface) bool {
    return self.window.opacity >= 1 and !self.no_d3d and !self.no_gpu;
}

/// The frame drawn by Direct3D 11 straight into the swap chain's back buffer,
/// from the instances `frame.zig` made. False when there is no renderer: the
/// canvas then draws the frame instead.
pub fn paintGpu(self: *Surface, h: w.HWND) bool {
    if (self.no_d3d or self.no_gpu) return false;
    const pw: u32 = @intFromFloat(@max(1, @round(self.size.w * self.scale)));
    const ph: u32 = @intFromFloat(@max(1, @round(self.size.h * self.scale)));
    if (self.presenter == null) {
        self.presenter = d3d.Presenter.init(h, pw, ph) catch {
            self.no_d3d = true;
            nameCpu(self);
            return false;
        };
    }
    const p = &self.presenter.?;
    // The drag state is set before the size is given to the swap chain: a drag
    // that just began defers its first size too, instead of resizing once and
    // then holding still for the rest of the drag.
    p.resizing = self.dragging;
    p.resize(pw, ph) catch return false;
    if (self.gpu == null) {
        self.gpu = d3d11.Renderer.initOn(@ptrCast(d3d.Presenter.deviceOf(p)), @ptrCast(d3d.Presenter.contextOf(p))) catch {
            self.no_gpu = true;
            nameCpu(self);
            return false;
        };
    }
    const g = &self.gpu.?;
    const bg = self.ctx.theme.background;
    p.setBackground(bg.r, bg.g, bg.b);
    g.sync(self.text.atlas.mask(), self.text.atlas.generation, self.text.images.pictures(), self.text.images.generation);
    // The back buffer is a COM reference: released before the swap chain may
    // be resized, or ResizeBuffers fails with DXGI_ERROR_INVALID_CALL
    // (0x887A0001) because a reference is still held.
    const back = p.backBuffer() catch return false;
    defer back.release();
    // A drag keeps the swap chain at the size it had: the frame is drawn to fit
    // it (the view is laid out for the window, and the part past the buffer is
    // not drawn), so the strip the window grew into shows the clear colour until
    // the drag ends and one ResizeBuffers catches up.
    const draw_w: f32 = @as(f32, @floatFromInt(p.width)) / self.scale;
    const draw_h: f32 = @as(f32, @floatFromInt(p.height)) / self.scale;
    const draw_size: types.Size = .{ .w = @min(self.size.w, draw_w), .h = @min(self.size.h, draw_h) };
    g.draw(self.instances.items, draw_size, self.scale, bg, @ptrCast(back));
    // The view asks for the present mode; it can change between frames.
    p.vsync = self.ctx.vsync;
    if (self.dump_enabled and self.dumps == 0) {
        // NANOUI_DUMP: the first frame as the GPU drew it, beside the same
        // frame drawn by the CPU, to see that they agree.
        self.dumps += 1;
        dumpGpuFrame(self, g);
    }
    const ok = p.present();
    if (!ok) {
        // The device was lost: both go, and a new pair gets the frame.
        release(self);
        _ = w.InvalidateRect(h, null, 0);
    }
    return true;
}

/// Writes the GPU's frame and the CPU's of the same instances, for
/// `NANOUI_DUMP`, and says how far apart they are.
fn dumpGpuFrame(self: *Surface, g: *d3d11.Renderer) void {
    const gpa = self.gpa;
    const shot = g.read(gpa) catch return;
    defer shot.deinit(gpa);
    var whole: canvas.Canvas = .{};
    defer whole.deinit(gpa);
    whole.draw(gpa, shown(self));
    const io = self.window.app.io;
    std.log.info("nanoui: GPU frame {d}x{d}", .{ shot.width, shot.height });
    @import("../ui/png.zig").writePng(gpa, io, std.fmt.bufPrint(&self.path_buf, "nanoui-gpu-{d}.png", .{self.dumps}) catch return, shot) catch |e| {
        std.log.warn("nanoui: could not write the GPU frame: {t}", .{e});
        return;
    };
    @import("../ui/png.zig").writePng(gpa, io, std.fmt.bufPrint(&self.path_buf, "nanoui-cpu-{d}.png", .{self.dumps}) catch return, .{ .bytes = whole.bytes, .width = whole.width, .height = whole.height }) catch {};
}

pub fn release(self: *Surface) void {
    if (self.gpu) |*g| g.deinit();
    self.gpu = null;
    if (self.presenter) |*p| p.deinit();
    self.presenter = null;
}

/// The frame the screen is given is drawn on the CPU: the view names that
/// from the next frame on.
fn nameCpu(self: *Surface) void {
    if (std.mem.eql(u8, self.ctx.renderer, "CPU")) return;
    self.ctx.renderer = "CPU";
    self.ctx.changed = true;
    self.requestFrame();
}

/// The CPU renderer's pixels, presented through the same swap chain: the path
/// taken when there is no Direct3D 11 renderer to draw a frame.
pub fn present(self: *Surface, h: w.HWND) bool {
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

/// What the last frame drew, for the damage the CPU path reports to GDI.
pub fn shown(self: *Surface) canvas.Frame {
    return .{ .instances = self.instances.items, .text = &self.text, .clear = self.ctx.theme.background, .size = self.size, .scale = self.scale, .textures = self.ctx.textures.items };
}

/// Asks Windows to paint the client area again. Called once per frame that
/// is built: a WM_SIZE that already invalidated must not add another, or
/// every size a drag passes through is drawn twice.
pub fn invalidate(self: *Surface) void {
    const h = self.window.hwnd orelse return;
    // A GPU frame draws the whole client area, so there is no damage to work
    // out (and no CPU pixels to keep for it). The CPU path still finds what
    // changed.
    if (self.gpu != null) {
        _ = w.InvalidateRect(h, null, 0);
    } else if (self.pixels.damage(shown(self))) |d| {
        const rect: w.RECT = .{ .left = @intCast(d[0]), .top = @intCast(d[1]), .right = @intCast(d[2]), .bottom = @intCast(d[3]) };
        _ = w.InvalidateRect(h, &rect, 0);
    }
}

/// One WM_PAINT: the GPU when it can and the window is opaque, else the
/// canvas and a GDI copy. `WM_PAINT` arrives only when something invalidated,
/// and `BeginPaint` clears the region: painting is the frame's output.
pub fn paint(self: *Surface, h: w.HWND) void {
    var ps: w.PAINTSTRUCT = undefined;
    const dc = w.BeginPaint(h, &ps) orelse return;
    defer _ = w.EndPaint(h, &ps);
    // A size arrived since the last frame: build it now, once, however many
    // WM_SIZE messages asked for it. No invalidation: this paint is the
    // drawing, and asking for another would draw every size twice. A paint
    // that arrives while a frame is building (from a message the view pumped)
    // waits for it rather than building over it.
    if (self.size_dirty and !self.in_frame) {
        self.size_dirty = false;
        self.in_frame = true;
        defer self.in_frame = false;
        self.buildFrame();
    }
    // The GPU draws the whole frame, and no CPU rasterising happens at all —
    // but not while translucent: `SetLayeredWindowAttributes` has no effect on
    // a DXGI flip-model swap chain, so a GPU frame would not fade. Below 1 the
    // canvas draws the frame and GDI copies the pixels into the layered
    // window, which does show the alpha; at 1 the GPU is picked back up.
    if (wantsGpu(self) and paintGpu(self, h)) return;
    self.pixels.draw(self.gpa, shown(self));
    const px = &self.pixels;
    if (px.bytes.len == 0) return;
    // The swap chain can show the canvas's pixels too — but never on a
    // layered window, for the same reason `paintGpu` stands down above.
    if (wantsGpu(self) and present(self, h)) return;
    // A negative height: rows from the top, as the renderer writes them.
    // GDI copies only what was invalidated.
    const info: w.BITMAPINFOHEADER = .{ .biWidth = @intCast(px.width), .biHeight = -@as(i32, @intCast(px.height)) };
    _ = w.SetDIBitsToDevice(dc, 0, 0, @intCast(px.width), @intCast(px.height), 0, 0, 0, @intCast(px.height), px.bytes.ptr, &info, 0);
}

/// `NANOUI_DUMP`, on F12: draws the frame whole beside what the canvas
/// holds and says whether they differ. Only when asked: it costs a frame.
pub fn verify(self: *Surface) void {
    const gpa = self.gpa;
    const px = &self.pixels;
    if (px.bytes.len == 0) return;
    const whole_bytes = gpa.alloc(u8, px.bytes.len) catch return;
    defer gpa.free(whole_bytes);
    const whole: gpu.Pixels = .{ .bytes = whole_bytes, .width = px.width, .height = px.height };
    var pictures = self.text.images.pictures();
    pictures.textures = self.ctx.textures.items;
    raster.draw(whole, self.instances.items, self.text.atlas.mask(), pictures, self.scale, self.ctx.theme.background);
    var differ: usize = 0;
    for (whole_bytes, px.bytes) |a, b| {
        if (a != b) differ += 1;
    }
    if (differ == 0 and self.dumps > 0) return;
    const n = self.dumps;
    self.dumps += 1;
    const io = std.Io.Threaded.global_single_threaded.io();
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

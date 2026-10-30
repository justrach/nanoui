//! The Direct3D 11 side of a Windows surface: drawing the frame on the GPU,
//! presenting the CPU renderer's pixels through the same swap chain, and the
//! dump that compares the two. `surface.zig` keeps the events and the frame.
const std = @import("std");
const w = @import("win32.zig");
const d3d = @import("d3d.zig");
const canvas = @import("../ui/canvas.zig");
const d3d11 = @import("../ui/d3d11.zig");
const types = @import("../ui/types.zig");
const surface = @import("surface.zig");
const Surface = surface.Surface;

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
    whole.draw(gpa, self.shown());
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

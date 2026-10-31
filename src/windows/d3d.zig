//! Frames on screen through Direct3D 11 and a DXGI flip-sequential swap
//! chain (issue #5), as Vercel's Native SDK presents its canvas: the CPU
//! renderer's pixels go into the swap chain's back buffer and are
//! presented by the compositor, with no GDI copy. Flip presentation keeps
//! resizing smooth: the buffers grow with the window (`ResizeBuffers`),
//! content stays anchored at the top left (no stretching), and the edge a
//! resize uncovers shows the background color until the next frame.
//!
//! A hardware device, else WARP (Windows' software one: virtual machines,
//! CI). A lost device (a driver update, a GPU reset) is dropped and made
//! again for the next frame; where none can be made the surface keeps
//! drawing with GDI. COM is called through each interface's vtable, by
//! slot, in the order the SDK's headers declare them.
const std = @import("std");
const w = @import("win32.zig");

const HRESULT = i32;
const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };

const iid_dxgi_device: Guid = .{ .a = 0x54ec77fa, .b = 0x1377, .c = 0x44e6, .d = .{ 0x8c, 0x32, 0x88, 0xfd, 0x5f, 0x44, 0xc8, 0x4c } };
const iid_dxgi_factory2: Guid = .{ .a = 0x50c83a1c, .b = 0xe072, .c = 0x4c48, .d = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
const iid_texture2d: Guid = .{ .a = 0x6f15aaf2, .b = 0xd208, .c = 0x4e89, .d = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c } };

const format_bgra8: u32 = 87; // DXGI_FORMAT_B8G8R8A8_UNORM, as the renderer writes
const device_removed: u32 = 0x887A0005;
const device_reset: u32 = 0x887A0007;

extern "d3d11" fn D3D11CreateDevice(adapter: ?*anyopaque, driver: u32, software: ?*anyopaque, flags: u32, levels: ?[*]const u32, n_levels: u32, sdk: u32, device: *?*Com, level: ?*u32, context: *?*Com) callconv(.winapi) HRESULT;

/// A COM object: its first field points at its vtable.
pub const Com = extern struct {
    vtable: [*]const *const anyopaque,

    fn slot(c: *Com, comptime T: type, i: usize) T {
        return @ptrCast(@alignCast(c.vtable[i]));
    }

    pub fn release(c: *Com) void {
        _ = c.slot(*const fn (*Com) callconv(.winapi) u32, 2)(c);
    }

    fn query(c: *Com, iid: *const Guid) !*Com {
        var out: ?*Com = null;
        try check(c.slot(*const fn (*Com, *const Guid, *?*Com) callconv(.winapi) HRESULT, 0)(c, iid, &out));
        return out orelse error.NoInterface;
    }
};

fn check(hr: HRESULT) !void {
    if (hr < 0) {
        std.log.err("nanoui: Direct3D failed: 0x{x:0>8}", .{@as(u32, @bitCast(hr))});
        return error.Direct3D;
    }
}

const SwapChainDesc1 = extern struct {
    width: u32,
    height: u32,
    format: u32 = format_bgra8,
    stereo: w.BOOL = 0,
    sample_count: u32 = 1,
    sample_quality: u32 = 0,
    usage: u32 = 0x20, // DXGI_USAGE_RENDER_TARGET_OUTPUT
    /// Two, the flip model's minimum. A deeper queue would let a drag resize
    /// pile frames the compositor has yet to show, and `Present` then blocks on
    /// a full queue: with two, each present waits for the one before it, which
    /// is what keeps a resize in step with the pointer.
    buffers: u32 = 2,
    /// Nothing is stretched: a frame is its own size, anchored at the top
    /// left, and a resize uncovers the background colour rather than a
    /// blurred or bent copy of the last frame.
    scaling: u32 = 1, // DXGI_SCALING_NONE
    effect: u32 = 3, // DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL
    alpha: u32 = 3, // DXGI_ALPHA_MODE_IGNORE
    flags: u32 = 0,
};

pub const Texture2DDesc = extern struct {
    width: u32,
    height: u32,
    mips: u32 = 1,
    array: u32 = 1,
    format: u32 = format_bgra8,
    sample_count: u32 = 1,
    sample_quality: u32 = 0,
    usage: u32 = 0,
    bind: u32 = 0,
    cpu: u32 = 0,
    misc: u32 = 0,
};

pub const Mapped = extern struct { data: [*]u8, row_pitch: u32, depth_pitch: u32 };

const Rgba = extern struct { r: f32, g: f32, b: f32, a: f32 };

/// A window's swap chain and the device it presents with.
pub const Presenter = struct {
    device: *Com,
    context: *Com,
    swap: *Com,
    width: u32,
    height: u32,
    /// Wait for the vertical blank when presenting. Off lets the renderer run
    /// as fast as it can; the flip model still never shows a half frame.
    vsync: bool = true,
    /// A resize is under way: present at once instead of waiting for the
    /// refresh, so a drag-resize is not one vblank plus one ResizeBuffers per
    /// size it passes through, which is what makes it stutter.
    resizing: bool = false,
    /// The size a drag ended on, applied once it does.
    want_w: u32 = 0,
    want_h: u32 = 0,
    /// The pixels go through this to reach the back buffer: a DYNAMIC
    /// texture the frame is mapped into and written, copy-by-discard, so
    /// the driver hands out fresh memory instead of waiting for the GPU to
    /// finish with what it last read. Straight from the app's own pixels
    /// (`UpdateSubresource`) is not safe: the runtime may still be reading
    /// them when the next frame draws over them, which tears the frame
    /// wherever the renderer got there first — and the faster the renderer,
    /// the more of it tears.
    upload_tex: ?*Com = null,

    /// A device (hardware, else WARP) and a flip-sequential swap chain for
    /// `hwnd`, `width` × `height` pixels.
    pub fn init(hwnd: w.HWND, width: u32, height: u32) !Presenter {
        var device: ?*Com = null;
        var context: ?*Com = null;
        const bgra: u32 = 0x20; // D3D11_CREATE_DEVICE_BGRA_SUPPORT
        // D3D_DRIVER_TYPE_HARDWARE, then D3D_DRIVER_TYPE_WARP.
        if (D3D11CreateDevice(null, 1, null, bgra, null, 0, 7, &device, null, &context) < 0)
            try check(D3D11CreateDevice(null, 5, null, bgra, null, 0, 7, &device, null, &context));
        const dev = device orelse return error.Direct3D;
        const ctx = context orelse return error.Direct3D;
        errdefer {
            ctx.release();
            dev.release();
        }
        // The factory that made the device's adapter makes the swap chain.
        const dxgi = try dev.query(&iid_dxgi_device);
        defer dxgi.release();
        var adapter: ?*Com = null;
        try check(dxgi.slot(*const fn (*Com, *?*Com) callconv(.winapi) HRESULT, 7)(dxgi, &adapter)); // GetAdapter
        defer adapter.?.release();
        var factory: ?*Com = null;
        try check(adapter.?.slot(*const fn (*Com, *const Guid, *?*Com) callconv(.winapi) HRESULT, 6)(adapter.?, &iid_dxgi_factory2, &factory)); // GetParent
        defer factory.?.release();
        const desc: SwapChainDesc1 = .{ .width = @max(width, 1), .height = @max(height, 1) };
        var swap: ?*Com = null;
        try check(factory.?.slot(*const fn (*Com, *Com, w.HWND, *const SwapChainDesc1, ?*anyopaque, ?*anyopaque, *?*Com) callconv(.winapi) HRESULT, 15)(factory.?, dev, hwnd, &desc, null, null, &swap)); // CreateSwapChainForHwnd
        // Alt+Enter is nanoui's to give meaning to, not DXGI's.
        _ = factory.?.slot(*const fn (*Com, w.HWND, u32) callconv(.winapi) HRESULT, 8)(factory.?, hwnd, 2); // MakeWindowAssociation, NO_ALT_ENTER
        return .{ .device = dev, .context = ctx, .swap = swap orelse return error.Direct3D, .width = desc.width, .height = desc.height };
    }

    pub fn deinit(p: *Presenter) void {
        if (p.upload_tex) |t| t.release();
        p.upload_tex = null;
        p.swap.release();
        p.context.release();
        p.device.release();
    }

    /// What a resize uncovers shows this until the next frame.
    pub fn setBackground(p: *Presenter, r: f32, g: f32, b: f32) void {
        const color: Rgba = .{ .r = r, .g = g, .b = b, .a = 1 };
        _ = p.swap.slot(*const fn (*Com, *const Rgba) callconv(.winapi) HRESULT, 25)(p.swap, &color); // SetBackgroundColor
    }

    /// Sizes the swap chain for a `width` × `height` frame. A no-op when it is
    /// already that size, and deferred while a drag is under way (`endResize`
    /// then applies the size it stopped at) — the deferral the GPU's drawing
    /// wants; the CPU's `upload` resizes directly, the pixels it carries
    /// being the size the window already is.
    pub fn resize(p: *Presenter, width: u32, height: u32) !void {
        if (width == p.width and height == p.height) return;
        // A drag asks for a new size every few pixels. `ResizeBuffers` waits for
        // the GPU to finish with the buffers it is replacing, and doing that per
        // size is what makes a drag hitch: the swap chain keeps its size until
        // the drag ends, and `DXGI_SCALING_NONE` anchors the frame at the top
        // left, so the strip the window gained shows the background colour (the
        // frame is never stretched, and never bent).
        if (p.resizing) {
            p.want_w = width;
            p.want_h = height;
            return;
        }
        try p.resizeNow(width, height);
    }

    /// The drag is over: the swap chain takes the size the drag ended on, in one
    /// `ResizeBuffers` rather than one per size the drag passed through.
    pub fn endResize(p: *Presenter) void {
        p.resizing = false;
        if (p.want_w == 0 or p.want_h == 0) return;
        const nw = p.want_w;
        const nh = p.want_h;
        p.want_w = 0;
        p.want_h = 0;
        if (nw != p.width or nh != p.height) p.resizeNow(nw, nh) catch {};
    }

    /// The swap chain at `width` × `height`: what `resize` calls once no drag
    /// is in the way.
    fn resizeNow(p: *Presenter, width: u32, height: u32) !void {
        try check(p.swap.slot(*const fn (*Com, u32, u32, u32, u32, u32) callconv(.winapi) HRESULT, 13)(p.swap, 0, width, height, 0, 0));
        p.width = width;
        p.height = height;
        // A drag's deferred size has been applied by hand, or never was one:
        // nothing left for `endResize` to do.
        p.want_w = 0;
        p.want_h = 0;
        // The CPU path's upload texture goes with the old size; the GPU path
        // never made one, and freeing nothing here keeps a resize to the one
        // call that must happen.
        if (p.upload_tex) |t| t.release();
        p.upload_tex = null;
    }

    /// Puts `pixels` (BGRA, `width` × `height`, rows from the top) in the back
    /// buffer, sized for them first if the window was.
    pub fn upload(p: *Presenter, pixels: []const u8, width: u32, height: u32) !void {
        // Not `resize`: the drag's deferral belongs to the GPU's drawing (which
        // draws into a buffer that may lag a size). The pixels in hand here are
        // the size the window is now, and mapping the old texture with them
        // would write past it — so this path sizes the swap chain at once.
        if (width != p.width or height != p.height) try p.resizeNow(width, height);
        // Through a DYNAMIC texture, not straight from `pixels`: the renderer
        // draws the next frame over those bytes, and may do it before the GPU
        // has read them — the frame then tears where it got there first.
        // WRITE_DISCARD hands out memory the GPU is not reading, so nothing
        // waits; a staging texture would stall the frame instead.
        const target = p.upload_tex orelse blk: {
            // D3D11_USAGE_DYNAMIC, D3D11_CPU_ACCESS_WRITE, and a bind flag:
            // a dynamic texture must name one (0 is staging's), and the
            // shader-resource bind is the one a copy source may carry.
            const desc: Texture2DDesc = .{ .width = width, .height = height, .usage = 2, .bind = 0x8, .cpu = 0x10000 };
            var tex: ?*Com = null;
            try check(p.device.slot(*const fn (*Com, *const Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, 5)(p.device, &desc, null, &tex));
            p.upload_tex = tex orelse return error.Direct3D;
            break :blk p.upload_tex.?;
        };
        var mapped: Mapped = undefined;
        // Map, D3D11_MAP_WRITE_DISCARD: memory the GPU is not reading.
        try check(p.context.slot(*const fn (*Com, *Com, u32, u32, u32, *Mapped) callconv(.winapi) HRESULT, 14)(p.context, target, 0, 4, 0, &mapped));
        const row: usize = @as(usize, width) * 4;
        const pitch: usize = mapped.row_pitch;
        var y: usize = 0;
        while (y < height) : (y += 1) @memcpy(mapped.data[y * pitch ..][0..row], pixels[y * row ..][0..row]);
        p.context.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, 15)(p.context, target, 0); // Unmap
        const buffer = try p.backBuffer();
        defer buffer.release();
        p.context.slot(*const fn (*Com, *Com, *Com) callconv(.winapi) void, 47)(p.context, buffer, target); // CopyResource
    }

    /// Shows the back buffer, waiting for the next vertical blank when
    /// `vsync` is set. False when the device was lost: the caller drops this
    /// presenter and makes another.
    pub fn present(p: *Presenter) bool {
        // SyncInterval 1 waits for the refresh, 0 presents at once. A drag
        // resize presents at once: the sizes it passes through are shown as
        // they come, not one vblank each.
        const sync: u32 = if (p.vsync and !p.resizing) 1 else 0;
        const hr = p.swap.slot(*const fn (*Com, u32, u32) callconv(.winapi) HRESULT, 8)(p.swap, sync, 0); // Present
        const code: u32 = @bitCast(hr);
        return !(code == device_removed or code == device_reset);
    }

    /// The device and context the swap chain was made on, so that a
    /// renderer can share them: D3D will not copy a texture from one device
    /// to another, so the frame has to be drawn on the swap chain's own.
    pub fn deviceOf(p: *Presenter) *Com {
        return p.device;
    }

    pub fn contextOf(p: *Presenter) *Com {
        return p.context;
    }

    pub fn backBuffer(p: *Presenter) !*Com {
        var tex: ?*Com = null;
        try check(p.swap.slot(*const fn (*Com, u32, *const Guid, *?*Com) callconv(.winapi) HRESULT, 9)(p.swap, 0, &iid_texture2d, &tex)); // GetBuffer
        return tex orelse error.Direct3D;
    }

    /// The back buffer's pixels, read back (for tests): `out` gets
    /// width × height BGRA.
    pub fn readBack(p: *Presenter, out: []u8) !void {
        var staging: ?*Com = null;
        // CreateTexture2D: D3D11_USAGE_STAGING, D3D11_CPU_ACCESS_READ.
        const desc: Texture2DDesc = .{ .width = p.width, .height = p.height, .usage = 3, .cpu = 0x20000 };
        try check(p.device.slot(*const fn (*Com, *const Texture2DDesc, ?*const anyopaque, *?*Com) callconv(.winapi) HRESULT, 5)(p.device, &desc, null, &staging));
        defer staging.?.release();
        const buffer = try p.backBuffer();
        defer buffer.release();
        p.context.slot(*const fn (*Com, *Com, *Com) callconv(.winapi) void, 47)(p.context, staging.?, buffer); // CopyResource
        var mapped: Mapped = undefined;
        try check(p.context.slot(*const fn (*Com, *Com, u32, u32, u32, *Mapped) callconv(.winapi) HRESULT, 14)(p.context, staging.?, 0, 1, 0, &mapped)); // Map, READ
        defer p.context.slot(*const fn (*Com, *Com, u32) callconv(.winapi) void, 15)(p.context, staging.?, 0); // Unmap
        const row = p.width * 4;
        for (0..p.height) |y| @memcpy(out[y * row ..][0..row], mapped.data[y * mapped.row_pitch ..][0..row]);
    }
};

test "pixels reach the flip swap chain's back buffer, before and after a resize" {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const hwnd = w.CreateWindowExW(0, class, class, 0, 0, 0, 64, 64, null, null, null, null) orelse return error.SkipZigTest;
    defer _ = w.DestroyWindow(hwnd);
    var p = Presenter.init(hwnd, 4, 3) catch |e| {
        std.debug.print("no Direct3D 11 here: {t}\n", .{e});
        return error.SkipZigTest;
    };
    defer p.deinit();
    p.setBackground(1, 1, 1);
    var pixels: [4 * 3 * 4]u8 = undefined;
    for (0..12) |i| pixels[i * 4 ..][0..4].* = .{ @intCast(i), 0x40, 0x80, 0xff };
    try p.upload(&pixels, 4, 3);
    var back: [4 * 3 * 4]u8 = undefined;
    try p.readBack(&back);
    try std.testing.expectEqualSlices(u8, &pixels, &back);
    try std.testing.expect(p.present());
    // Bigger: the buffers follow.
    var big: [8 * 6 * 4]u8 = undefined;
    @memset(&big, 0x7f);
    try p.upload(&big, 8, 6);
    var back2: [8 * 6 * 4]u8 = undefined;
    try p.readBack(&back2);
    try std.testing.expectEqualSlices(u8, &big, &back2);
    try std.testing.expect(p.present());
}

test "an upload during a drag sizes the swap chain instead of writing past the old texture" {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const hwnd = w.CreateWindowExW(0, class, class, 0, 0, 0, 64, 64, null, null, null, null) orelse return error.SkipZigTest;
    defer _ = w.DestroyWindow(hwnd);
    var p = Presenter.init(hwnd, 4, 3) catch |e| {
        std.debug.print("no Direct3D 11 here: {t}\n", .{e});
        return error.SkipZigTest;
    };
    defer p.deinit();
    var small: [4 * 3 * 4]u8 = undefined;
    @memset(&small, 0x11);
    try p.upload(&small, 4, 3);
    // A drag begins, and the window grows: the pixels in hand are the new
    // size, and `upload` must size the swap chain for them, not map the old
    // texture and run past it.
    p.resizing = true;
    var big: [8 * 6 * 4]u8 = undefined;
    for (0..big.len / 4) |i| big[i * 4 ..][0..4].* = .{ @intCast(i & 0xff), 0x40, 0x80, 0xff };
    try p.upload(&big, 8, 6);
    var back: [8 * 6 * 4]u8 = undefined;
    try p.readBack(&back);
    try std.testing.expectEqualSlices(u8, &big, &back);
    // The drag ends with nothing deferred over the size already taken.
    p.resizing = false;
    p.endResize();
    try std.testing.expectEqual(@as(u32, 8), p.width);
    try std.testing.expectEqual(@as(u32, 6), p.height);
    // A real frame's size, odd on purpose (a row no alignment rounds up):
    // the dynamic upload texture has to take it and read back the same.
    const fw: u32 = 901;
    const fh: u32 = 641;
    const frame_px = try std.testing.allocator.alloc(u8, fw * fh * 4);
    defer std.testing.allocator.free(frame_px);
    for (0..frame_px.len / 4) |i| frame_px[i * 4 ..][0..4].* = .{ @intCast(i % 256), 0x40, 0x80, 0xff };
    try p.upload(frame_px, fw, fh);
    const back3 = try std.testing.allocator.alloc(u8, fw * fh * 4);
    defer std.testing.allocator.free(back3);
    try p.readBack(back3);
    try std.testing.expectEqualSlices(u8, frame_px, back3);
}

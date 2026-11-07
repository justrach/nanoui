//! A `<canvas>`'s WebGL context: its own CGL context, drawing into an FBO the size of the
//! canvas, read back to BGRA only when paint asks and something drew since it last did.
//! A context is only ever current on the main thread.
const std = @import("std");
const nanoui = @import("nanoui");
const api = @import("api.zig");
const state = @import("state.zig");
const formats = @import("formats.zig");
const dom = @import("../dom.zig");
const canvas_source = @import("../paint/canvas_source.zig");
const Page = @import("../page.zig").Page;
const ui = nanoui.ui;

pub const Options = struct {
    webgl2: bool,
    alpha: bool = true,
    depth: bool = true,
    stencil: bool = false,
    premultiplied: bool = true,
    preserve: bool = false,
};

/// How big a drawing buffer may get, whatever the canvas says.
const max_side = 8192;

pub const Shader = struct { kind: u32, failure: ?[]const u8 = null };

pub const Context = struct {
    gpa: std.mem.Allocator,
    page: *Page,
    node: *dom.Node,
    options: Options,
    cgl: ?*anyopaque = null,
    fbo: u32 = 0,
    color: u32 = 0,
    depth_stencil: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// The page's bindings; 0 means the drawing buffer.
    draw_fb: u32 = 0,
    read_fb: u32 = 0,
    renderbuffer: u32 = 0,
    state: state.State,
    shaders: std.AutoHashMapUnmanaged(u32, Shader) = .empty,
    textures: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// An error of ours, reported before the driver's.
    pending_error: u32 = 0,
    pack_alignment: u32 = 4,
    unpack_alignment: u32 = 4,
    unpack_flip: bool = false,
    unpack_premultiply: bool = false,
    unpack_colorspace: i32 = 0x9244,
    warned_image: bool = false,
    /// Drew since paint last read.
    dirty: bool = false,
    /// Paint has shown this drawing, which must now read as cleared.
    clear_pending: bool = false,
    bgra: []u8 = &.{},
    row: []u8 = &.{},

    pub fn fail(c: *Context, code: u32) void {
        if (c.pending_error == 0) c.pending_error = code;
    }

    pub fn core(c: *const Context) bool {
        return c.options.webgl2;
    }

    /// This context is what `gl` talks to, from here until another's.
    pub fn use(c: *Context) void {
        if (api.gl.CGLGetCurrentContext() != c.cgl) _ = api.gl.CGLSetCurrentContext(c.cgl);
    }

    /// What the canvas's attributes ask for right now.
    fn wanted(c: *const Context) [2]u32 {
        return .{ side(c.node.attr("width"), 300), side(c.node.attr("height"), 150) };
    }

    fn side(text: ?[]const u8, default: u32) u32 {
        const t = std.mem.trim(u8, text orelse return default, " \t\r\n");
        const n = std.fmt.parseInt(u32, t, 10) catch return default;
        return std.math.clamp(n, 1, max_side);
    }

    /// Follows the canvas's size. Changing it clears the drawing buffer, as the spec has it.
    pub fn sync(c: *Context) void {
        const want = c.wanted();
        if (want[0] != c.width or want[1] != c.height) c.resize(want[0], want[1]);
    }

    fn resize(c: *Context, w: u32, h: u32) void {
        const g = &api.gl;
        const bytes = @as(usize, w) * h * 4;
        const px = c.gpa.realloc(c.bgra, bytes) catch {
            c.fail(state.OUT_OF_MEMORY);
            return;
        };
        c.bgra = px;
        const row = c.gpa.realloc(c.row, @as(usize, w) * 4) catch {
            c.fail(state.OUT_OF_MEMORY);
            return;
        };
        c.row = row;
        c.width = w;
        c.height = h;
        const iw: i32 = @intCast(w);
        const ih: i32 = @intCast(h);
        g.glBindRenderbuffer(api.RENDERBUFFER, c.color);
        g.glRenderbufferStorage(api.RENDERBUFFER, if (c.options.alpha) 0x8058 else 0x8051, iw, ih); // RGBA8, RGB8
        if (c.depth_stencil != 0) {
            g.glBindRenderbuffer(api.RENDERBUFFER, c.depth_stencil);
            g.glRenderbufferStorage(api.RENDERBUFFER, if (c.options.stencil) 0x88F0 else 0x81A6, iw, ih); // DEPTH24_STENCIL8, DEPTH_COMPONENT24
        }
        g.glBindRenderbuffer(api.RENDERBUFFER, c.renderbuffer);
        c.clearBuffer();
        c.dirty = true;
        c.clear_pending = false;
        c.page.redraw();
    }

    /// Clears the drawing buffer whatever the page has set, and leaves that as it found it.
    fn clearBuffer(c: *Context) void {
        const g = &api.gl;
        var scissor: u8 = 0;
        var colors: [4]u8 = undefined;
        var depth_mask: [1]u8 = undefined;
        var stencil_front: [1]i32 = undefined;
        var stencil_back: [1]i32 = undefined;
        var clear_color: [4]f32 = undefined;
        var clear_depth: [1]f32 = undefined;
        var clear_stencil: [1]i32 = undefined;
        scissor = g.glIsEnabled(api.SCISSOR_TEST);
        g.glGetBooleanv(0x0C23, &colors); // COLOR_WRITEMASK
        g.glGetBooleanv(0x0B72, &depth_mask); // DEPTH_WRITEMASK
        g.glGetIntegerv(0x0B98, &stencil_front); // STENCIL_WRITEMASK
        g.glGetIntegerv(0x8CA5, &stencil_back); // STENCIL_BACK_WRITEMASK
        g.glGetFloatv(0x0C22, &clear_color); // COLOR_CLEAR_VALUE
        g.glGetFloatv(0x0B73, &clear_depth); // DEPTH_CLEAR_VALUE
        g.glGetIntegerv(0x0B91, &clear_stencil); // STENCIL_CLEAR_VALUE
        g.glDisable(api.SCISSOR_TEST);
        g.glColorMask(1, 1, 1, 1);
        g.glDepthMask(1);
        g.glStencilMask(0xffffffff);
        g.glClearColor(0, 0, 0, 0);
        g.glClearDepth(1);
        g.glClearStencil(0);
        g.glBindFramebuffer(api.FRAMEBUFFER, c.fbo);
        g.glClear(api.COLOR_BUFFER_BIT | api.DEPTH_BUFFER_BIT | api.STENCIL_BUFFER_BIT);
        c.bindFramebuffers();
        if (scissor != 0) g.glEnable(api.SCISSOR_TEST);
        g.glColorMask(colors[0], colors[1], colors[2], colors[3]);
        g.glDepthMask(depth_mask[0]);
        g.glStencilMaskSeparate(0x0404, @bitCast(stencil_front[0])); // FRONT
        g.glStencilMaskSeparate(0x0405, @bitCast(stencil_back[0])); // BACK
        g.glClearColor(clear_color[0], clear_color[1], clear_color[2], clear_color[3]);
        g.glClearDepth(clear_depth[0]);
        g.glClearStencil(clear_stencil[0]);
    }

    /// Puts the page's framebuffers back, its "none" being the drawing buffer.
    pub fn bindFramebuffers(c: *Context) void {
        const g = &api.gl;
        if (c.draw_fb == c.read_fb) {
            g.glBindFramebuffer(api.FRAMEBUFFER, if (c.draw_fb != 0) c.draw_fb else c.fbo);
        } else {
            g.glBindFramebuffer(api.DRAW_FRAMEBUFFER, if (c.draw_fb != 0) c.draw_fb else c.fbo);
            g.glBindFramebuffer(api.READ_FRAMEBUFFER, if (c.read_fb != 0) c.read_fb else c.fbo);
        }
    }

    /// Before anything that draws or reads: the buffer is the right size, and what paint
    /// has already shown is gone unless the page asked to keep it.
    pub fn prepare(c: *Context) void {
        c.sync();
        if (c.clear_pending) {
            c.clear_pending = false;
            c.clearBuffer();
        }
    }

    /// Setting a canvas dimension clears even when its numeric value is unchanged.
    pub fn reset(c: *Context) void {
        c.sync();
        c.clearBuffer();
        c.clear_pending = false;
        c.dirty = true;
        c.page.redraw();
    }

    /// Something has just drawn. Into the drawing buffer, paint will want to know.
    pub fn drew(c: *Context) void {
        if (c.draw_fb != 0 or c.dirty) return;
        c.dirty = true;
        c.page.redraw();
    }

    /// The drawing buffer, as paint wants it, into `to`.
    fn readBack(c: *Context, to: []u8) void {
        // A refused resize/readback must never expose allocator contents to paint/export.
        @memset(to, 0);
        const g = &api.gl;
        var old_row: [1]i32 = undefined;
        g.glGetIntegerv(api.PACK_ALIGNMENT, &old_row);
        g.glPixelStorei(api.PACK_ALIGNMENT, 1);
        g.glBindFramebuffer(api.READ_FRAMEBUFFER, c.fbo);
        g.glReadPixels(0, 0, @intCast(c.width), @intCast(c.height), api.BGRA, api.UNSIGNED_INT_8_8_8_8_REV, to.ptr);
        g.glPixelStorei(api.PACK_ALIGNMENT, old_row[0]);
        c.bindFramebuffers();
        const row = @as(usize, c.width) * 4;
        formats.flipRows(to, row, c.height, row, c.row);
        if (c.options.alpha and !c.options.premultiplied) formats.premultiply(to);
    }

    fn pixels(ctx: *anyopaque) ?ui.Texture {
        const c: *Context = @ptrCast(@alignCast(ctx));
        c.use();
        c.sync();
        if (c.bgra.len == 0) return null;
        if (c.dirty) {
            c.dirty = false;
            c.readBack(c.bgra);
            if (!c.options.preserve) c.clear_pending = true;
        }
        return .{ .width = c.width, .height = c.height, .bgra = c.bgra };
    }

    /// The buffer as it is now, premultiplied BGRA with the top row first, in `a`'s
    /// memory, for `toDataURL`: not what paint is showing, which may be an older drawing.
    pub fn snapshot(c: *Context, a: std.mem.Allocator) ?nanoui.ui.png.Pixels {
        c.use();
        c.prepare();
        if (c.bgra.len == 0) return null;
        const to = a.alloc(u8, c.bgra.len) catch return null;
        c.readBack(to);
        return .{ .bytes = to, .width = c.width, .height = c.height };
    }

    pub fn destroy(c: *Context) void {
        c.page.canvases.remove(c.node);
        c.use();
        const g = &api.gl;
        g.glDeleteFramebuffers(1, &c.fbo);
        g.glDeleteRenderbuffers(1, &c.color);
        if (c.depth_stencil != 0) g.glDeleteRenderbuffers(1, &c.depth_stencil);
        _ = g.CGLSetCurrentContext(null);
        _ = g.CGLDestroyContext(c.cgl);
        c.state.deinit();
        c.shaders.deinit(c.gpa);
        c.textures.deinit(c.gpa);
        c.gpa.free(c.bgra);
        c.gpa.free(c.row);
        c.gpa.destroy(c);
    }
};

/// The drawing buffer's attachments, and what WebGL takes for granted that GL doesn't.
fn setUp(c: *Context) void {
    const g = &api.gl;
    g.glGenFramebuffers(1, &c.fbo);
    g.glGenRenderbuffers(1, &c.color);
    g.glBindFramebuffer(api.FRAMEBUFFER, c.fbo);
    if (c.options.depth or c.options.stencil) {
        g.glGenRenderbuffers(1, &c.depth_stencil);
        g.glBindRenderbuffer(api.RENDERBUFFER, c.depth_stencil);
    }
    // glGen reserves names; binding creates the objects before they can attach.
    g.glBindRenderbuffer(api.RENDERBUFFER, c.color);
    g.glFramebufferRenderbuffer(api.FRAMEBUFFER, api.COLOR_ATTACHMENT0, api.RENDERBUFFER, c.color);
    if (c.options.depth) g.glFramebufferRenderbuffer(api.FRAMEBUFFER, api.DEPTH_ATTACHMENT, api.RENDERBUFFER, c.depth_stencil);
    if (c.options.stencil) g.glFramebufferRenderbuffer(api.FRAMEBUFFER, api.STENCIL_ATTACHMENT, api.RENDERBUFFER, c.depth_stencil);
    c.sync();
    // Newly allocated CPU memory is not a frame: read the cleared FBO on first paint.
    c.dirty = true;
    g.glViewport(0, 0, @intCast(c.width), @intCast(c.height));
    g.glScissor(0, 0, @intCast(c.width), @intCast(c.height));
    g.glEnable(0x8642); // PROGRAM_POINT_SIZE: gl_PointSize always counts here.
    if (c.core()) {
        // The core profile draws nothing without a vertex array bound.
        var vao: u32 = 0;
        g.glGenVertexArrays(1, &vao);
        g.glBindVertexArray(vao);
        g.glEnable(0x8F9D); // PRIMITIVE_RESTART
    } else {
        g.glEnable(0x8861); // POINT_SPRITE: gl_PointCoord always works here.
    }
    g.glPixelStorei(api.PACK_ALIGNMENT, 4);
    g.glPixelStorei(api.UNPACK_ALIGNMENT, 4);
}

/// A context for `node`, null where there's no OpenGL or the system refuses one.
pub fn create(gpa: std.mem.Allocator, page: *Page, node: *dom.Node, options: Options) ?*Context {
    if (!api.available or !api.load()) return null;
    const g = &api.gl;
    const profile: c_int = if (options.webgl2) 0x4100 else 0x1000;
    const attrs = [_]c_int{ 99, profile, 73, 0 };
    var format: ?*anyopaque = null;
    var count: c_int = 0;
    if (g.CGLChoosePixelFormat(&attrs, &format, &count) != 0 or format == null) return null;
    defer _ = g.CGLDestroyPixelFormat(format);
    var cgl: ?*anyopaque = null;
    if (g.CGLCreateContext(format, null, &cgl) != 0 or cgl == null) return null;
    const c = gpa.create(Context) catch {
        _ = g.CGLDestroyContext(cgl);
        return null;
    };
    c.* = .{ .gpa = gpa, .page = page, .node = node, .options = options, .cgl = cgl, .state = .{ .gpa = gpa } };
    c.use();
    setUp(c);
    if (c.width == 0 or c.height == 0 or g.glCheckFramebufferStatus(api.FRAMEBUFFER) != 0x8CD5) {
        c.destroy();
        return null;
    }
    // Driver setup errors must never masquerade as successful context creation.
    if (g.glGetError() != 0) {
        c.destroy();
        return null;
    }
    page.canvases.set(gpa, node, .{ .ctx = c, .pixels = Context.pixels }) catch {
        c.destroy();
        return null;
    };
    return c;
}

/// Every context of a page's world. Browsers cap these too; past the cap a page's next
/// canvas gets null, which libraries handle.
pub const List = struct {
    pub const max = 16;
    items: std.ArrayList(*Context) = .empty,

    pub fn add(l: *List, gpa: std.mem.Allocator, c: *Context) bool {
        l.items.append(gpa, c) catch return false;
        return true;
    }

    pub fn full(l: *const List) bool {
        return l.items.items.len >= max;
    }

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        for (l.items.items) |c| c.destroy();
        l.items.deinit(gpa);
    }
};

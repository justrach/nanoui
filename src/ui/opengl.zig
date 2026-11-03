//! The OpenGL renderer (3.3 core, or OpenGL ES 3 on Android), as
//! metal.zig draws: instanced quads in one draw, split by panes of glass,
//! each of which reads what was drawn before it. The frame is drawn into a
//! texture of the renderer's own (so that glass can read it), then copied
//! to the target framebuffer. A context must be current; `gl.load` (or
//! `gl.loadEs`) must have succeeded. OpenGL ES has no BGRA textures:
//! pictures go up as they are and the shaders read them swapped.
const std = @import("std");
const types = @import("types.zig");
const gpu = @import("gpu.zig");
const glass = @import("glass.zig");
const raster = @import("raster.zig");
const gl = @import("gl.zig");

const source = @embedFile("shader.glsl");
const stride = @sizeOf(gpu.Instance);

/// A texture and the framebuffer that draws into it.
const Target = struct {
    texture: u32 = 0,
    fbo: u32 = 0,
    w: usize = 0,
    h: usize = 0,

    /// At least `w` × `h` (exactly, when `exact`), made or remade.
    fn reserve(t: *Target, w: usize, h: usize, exact: bool, format: u32) void {
        const fits = if (exact) w == t.w and h == t.h else w <= t.w and h <= t.h;
        if (t.fbo != 0 and fits) return;
        t.deinit();
        t.w = if (exact) w else @max(w, t.w);
        t.h = if (exact) h else @max(h, t.h);
        const g = &gl.api;
        t.texture = newTexture(gl.RGBA8, @intCast(t.w), @intCast(t.h), format, null, gl.NEAREST);
        g.glGenFramebuffers(1, &t.fbo);
        g.glBindFramebuffer(gl.FRAMEBUFFER, t.fbo);
        g.glFramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, t.texture, 0);
    }

    fn deinit(t: *Target) void {
        if (t.fbo != 0) gl.api.glDeleteFramebuffers(1, &t.fbo);
        if (t.texture != 0) gl.api.glDeleteTextures(1, &t.texture);
        t.fbo = 0;
        t.texture = 0;
    }
};

pub const Renderer = struct {
    /// OpenGL ES 3, not OpenGL 3.3.
    es: bool = false,
    quad: u32,
    pane: u32,
    down: u32,
    blur: u32,
    vao: u32 = 0,
    /// For passes, which read no instances.
    empty_vao: u32 = 0,
    vbo: u32 = 0,
    atlas: u32 = 0,
    atlas_size: u32 = 0,
    atlas_generation: u64 = std.math.maxInt(u64),
    images: u32 = 0,
    images_generation: u64 = std.math.maxInt(u64),
    frame: Target = .{},
    /// A pane's backdrop ends in `a`; `b` holds the blur between passes.
    a: Target = .{},
    b: Target = .{},

    /// For OpenGL 3.3.
    pub fn init() !Renderer {
        return start(false);
    }

    /// For OpenGL ES 3.
    pub fn initEs() !Renderer {
        return start(true);
    }

    fn start(es: bool) !Renderer {
        const g = &gl.api;
        var r: Renderer = .{ .es = es, .quad = 0, .pane = 0, .down = 0, .blur = 0 };
        errdefer r.deinit();
        r.quad = try program(es, "QUAD_VS", "QUAD_FS");
        r.pane = try program(es, "QUAD_VS", "GLASS_FS");
        r.down = try program(es, "PASS_VS", "DOWN_FS");
        r.blur = try program(es, "PASS_VS", "BLUR_FS");
        g.glGenVertexArrays(1, &r.vao);
        g.glGenVertexArrays(1, &r.empty_vao);
        g.glGenBuffers(1, &r.vbo);
        g.glBindVertexArray(r.vao);
        g.glBindBuffer(gl.ARRAY_BUFFER, r.vbo);
        for (0..10) |k| {
            g.glEnableVertexAttribArray(@intCast(k));
            g.glVertexAttribDivisor(@intCast(k), 1);
        }
        // Until a picture comes, one transparent texel stands in.
        r.images = newTexture(gl.RGBA8, 1, 1, r.bgra(), &[4]u8{ 0, 0, 0, 0 }, gl.LINEAR);
        return r;
    }

    /// The format BGRA pixels go up as: OpenGL ES takes them for RGBA.
    fn bgra(r: *const Renderer) u32 {
        return if (r.es) gl.RGBA else gl.BGRA;
    }

    pub fn deinit(r: *Renderer) void {
        const g = &gl.api;
        for ([_]u32{ r.quad, r.pane, r.down, r.blur }) |p| if (p != 0) g.glDeleteProgram(p);
        if (r.vao != 0) g.glDeleteVertexArrays(1, &r.vao);
        if (r.empty_vao != 0) g.glDeleteVertexArrays(1, &r.empty_vao);
        if (r.vbo != 0) g.glDeleteBuffers(1, &r.vbo);
        for ([_]u32{ r.atlas, r.images }) |t| if (t != 0) g.glDeleteTextures(1, &t);
        r.frame.deinit();
        r.a.deinit();
        r.b.deinit();
    }

    /// Brings the GPU's copies of the glyph and picture atlases up to date.
    pub fn sync(r: *Renderer, mask: raster.Mask, mask_generation: u64, pictures: raster.Pictures, pictures_generation: u64) void {
        const g = &gl.api;
        g.glPixelStorei(gl.UNPACK_ALIGNMENT, 1);
        if (mask.size > 0 and (mask_generation != r.atlas_generation or mask.size != r.atlas_size)) {
            const s: i32 = @intCast(mask.size);
            if (mask.size != r.atlas_size) {
                if (r.atlas != 0) g.glDeleteTextures(1, &r.atlas);
                r.atlas = newTexture(gl.R8, s, s, gl.RED, mask.pixels.ptr, gl.LINEAR);
                r.atlas_size = mask.size;
            } else {
                g.glBindTexture(gl.TEXTURE_2D, r.atlas);
                g.glTexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, s, s, gl.RED, gl.UNSIGNED_BYTE, mask.pixels.ptr);
            }
            r.atlas_generation = mask_generation;
        }
        if (pictures.size > 0 and pictures_generation != r.images_generation) {
            const s: i32 = @intCast(pictures.size);
            g.glDeleteTextures(1, &r.images);
            r.images = newTexture(gl.RGBA8, s, s, r.bgra(), pictures.pixels.ptr, gl.LINEAR);
            r.images_generation = pictures_generation;
        }
    }

    /// Draws `instances` over `clear`, `size` points at `scale`, into the
    /// renderer's frame, then copies it to framebuffer `target`.
    pub fn draw(r: *Renderer, instances: []const gpu.Instance, size: types.Size, scale: f32, clear: types.Color, target: u32, time: f64) void {
        const g = &gl.api;
        const w: usize = @intFromFloat(@max(1, @round(size.w * scale)));
        const h: usize = @intFromFloat(@max(1, @round(size.h * scale)));
        r.frame.reserve(w, h, true, r.bgra());
        for ([_]u32{ gl.DITHER, gl.SCISSOR_TEST, gl.DEPTH_TEST }) |cap| g.glDisable(cap);
        // OpenGL ES has no switch for it: its framebuffers aren't sRGB.
        if (!r.es) g.glDisable(gl.FRAMEBUFFER_SRGB);
        g.glBindFramebuffer(gl.FRAMEBUFFER, r.frame.fbo);
        g.glViewport(0, 0, @intCast(w), @intCast(h));
        g.glClearColor(clear.r, clear.g, clear.b, 1);
        g.glClear(gl.COLOR_BUFFER_BIT);
        if (instances.len > 0) {
            g.glBindBuffer(gl.ARRAY_BUFFER, r.vbo);
            g.glBufferData(gl.ARRAY_BUFFER, @intCast(instances.len * stride), instances.ptr, gl.STREAM_DRAW);
        }
        var first: usize = 0;
        while (first < instances.len) {
            // What comes before the next pane, in one draw.
            var end = first;
            while (end < instances.len and instances[end].kind != gpu.Kind.glass) end += 1;
            r.drawRange(r.quad, size, scale, first, end - first, time);
            if (end == instances.len) break;
            r.drawPane(instances, end, size, scale, time);
            first = end + 1;
        }
        g.glBindFramebuffer(gl.READ_FRAMEBUFFER, r.frame.fbo);
        g.glBindFramebuffer(gl.DRAW_FRAMEBUFFER, target);
        g.glBlitFramebuffer(0, 0, @intCast(w), @intCast(h), 0, 0, @intCast(w), @intCast(h), gl.COLOR_BUFFER_BIT, gl.NEAREST);
    }

    /// The last frame's pixels: BGRA, premultiplied, top row first.
    pub fn read(r: *Renderer, gpa: std.mem.Allocator) !gpu.Pixels {
        const g = &gl.api;
        const w = r.frame.w;
        const h = r.frame.h;
        const bytes = try gpa.alloc(u8, w * h * 4);
        errdefer gpa.free(bytes);
        const row = try gpa.alloc(u8, w * 4);
        defer gpa.free(row);
        g.glBindFramebuffer(gl.READ_FRAMEBUFFER, r.frame.fbo);
        g.glPixelStorei(gl.PACK_ALIGNMENT, 1);
        // OpenGL ES reads RGBA only: swapped back after.
        g.glReadPixels(0, 0, @intCast(w), @intCast(h), if (r.es) gl.RGBA else gl.BGRA, gl.UNSIGNED_BYTE, bytes.ptr);
        if (r.es) {
            var i: usize = 0;
            while (i < bytes.len) : (i += 4) std.mem.swap(u8, &bytes[i], &bytes[i + 2]);
        }
        // GL's rows go up from the bottom.
        for (0..h / 2) |y| {
            const top = bytes[y * w * 4 ..][0 .. w * 4];
            const bottom = bytes[(h - 1 - y) * w * 4 ..][0 .. w * 4];
            @memcpy(row, top);
            @memcpy(top, bottom);
            @memcpy(bottom, row);
        }
        return .{ .bytes = bytes, .width = w, .height = h };
    }

    /// Draws instances [first, first + count) with `prog`.
    fn drawRange(r: *Renderer, prog: u32, size: types.Size, scale: f32, first: usize, count: usize, time: f64) void {
        if (count == 0) return;
        const g = &gl.api;
        g.glUseProgram(prog);
        g.glUniform2f(g.glGetUniformLocation(prog, "viewport"), size.w, size.h);
        g.glUniform1f(g.glGetUniformLocation(prog, "scale"), scale);
        g.glUniform1f(g.glGetUniformLocation(prog, "time"), @floatCast(time));
        g.glBindVertexArray(r.vao);
        g.glBindBuffer(gl.ARRAY_BUFFER, r.vbo);
        // The instances from `first` on: rect, colors, uv, clip, then the
        // four floats after them.
        for (0..10) |k| g.glVertexAttribPointer(@intCast(k), 4, gl.FLOAT, 0, stride, first * stride + k * 16);
        g.glEnable(gl.BLEND);
        // Premultiplied alpha: one, one minus source alpha.
        g.glBlendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        bindTexture(prog, "atlas", 0, r.atlas);
        bindTexture(prog, "images", 1, r.images);
        g.glDrawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, @intCast(count));
    }

    /// Pane `at`: its backdrop from what was drawn, then the pane.
    fn drawPane(r: *Renderer, instances: []const gpu.Instance, at: usize, size: types.Size, scale: f32, time: f64) void {
        const g = &gl.api;
        const b = glass.backdropOf(instances[at].rect, instances[at].border_width, scale, r.frame.w, r.frame.h) orelse return;
        const w: usize = @intCast(b.w);
        const h: usize = @intCast(b.h);
        r.a.reserve(w, h, false, r.bgra());
        r.b.reserve(w, h, false, r.bgra());
        g.glDisable(gl.BLEND);
        g.glBindVertexArray(r.empty_vao);
        g.glUseProgram(r.down);
        g.glUniform4i(g.glGetUniformLocation(r.down, "area"), b.area[0], b.area[1], b.area[2], b.area[3]);
        g.glUniform1i(g.glGetUniformLocation(r.down, "down"), b.down);
        g.glUniform1i(g.glGetUniformLocation(r.down, "frame_height"), @intCast(r.frame.h));
        pass(r.down, r.frame.texture, &r.a, b, w, h);
        if (b.sigma > 0) {
            g.glUseProgram(r.blur);
            g.glUniform1i(g.glGetUniformLocation(r.blur, "radius"), b.radius);
            g.glUniform1f(g.glGetUniformLocation(r.blur, "sigma"), b.sigma);
            g.glUniform2i(g.glGetUniformLocation(r.blur, "dir"), 1, 0);
            pass(r.blur, r.a.texture, &r.b, b, w, h);
            g.glUniform2i(g.glGetUniformLocation(r.blur, "dir"), 0, 1);
            pass(r.blur, r.b.texture, &r.a, b, w, h);
        }
        g.glBindFramebuffer(gl.FRAMEBUFFER, r.frame.fbo);
        g.glViewport(0, 0, @intCast(r.frame.w), @intCast(r.frame.h));
        g.glUseProgram(r.pane);
        g.glUniform2f(g.glGetUniformLocation(r.pane, "origin"), @floatFromInt(b.area[0]), @floatFromInt(b.area[1]));
        g.glUniform2f(g.glGetUniformLocation(r.pane, "size"), @floatFromInt(b.w), @floatFromInt(b.h));
        g.glUniform1f(g.glGetUniformLocation(r.pane, "down"), @floatFromInt(b.down));
        bindTexture(r.pane, "backdrop", 2, r.a.texture);
        r.drawRange(r.pane, size, scale, at, 1, time);
    }

    /// One pass of a pane's backdrop: `prog` reading `src` into `dst`'s
    /// first `w` × `h` texels.
    fn pass(prog: u32, src: u32, dst: *Target, b: glass.Backdrop, w: usize, h: usize) void {
        const g = &gl.api;
        g.glBindFramebuffer(gl.FRAMEBUFFER, dst.fbo);
        g.glViewport(0, 0, @intCast(w), @intCast(h));
        g.glUniform2i(g.glGetUniformLocation(prog, "size"), b.w, b.h);
        // The frame (averaging) or the last pass (blurring).
        bindTexture(prog, "frame", 0, src);
        bindTexture(prog, "src", 0, src);
        g.glDrawArrays(gl.TRIANGLES, 0, 3);
    }
};

fn bindTexture(prog: u32, name: [*:0]const u8, unit: u32, texture: u32) void {
    const g = &gl.api;
    const at = g.glGetUniformLocation(prog, name);
    if (at < 0) return;
    g.glActiveTexture(gl.TEXTURE0 + unit);
    g.glBindTexture(gl.TEXTURE_2D, texture);
    g.glUniform1i(at, @intCast(unit));
}

fn newTexture(internal: i32, w: i32, h: i32, format: u32, data: ?*const anyopaque, filter: i32) u32 {
    const g = &gl.api;
    var t: u32 = 0;
    g.glGenTextures(1, &t);
    g.glBindTexture(gl.TEXTURE_2D, t);
    g.glTexImage2D(gl.TEXTURE_2D, 0, internal, w, h, 0, format, gl.UNSIGNED_BYTE, data);
    g.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
    g.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
    g.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    g.glTexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return t;
}

/// A program of `source`'s two stages, by their defines.
fn program(es: bool, comptime vs: []const u8, comptime fs: []const u8) !u32 {
    const g = &gl.api;
    const v = try shader(es, gl.VERTEX_SHADER, vs);
    defer g.glDeleteShader(v);
    const f = try shader(es, gl.FRAGMENT_SHADER, fs);
    defer g.glDeleteShader(f);
    const p = g.glCreateProgram();
    g.glAttachShader(p, v);
    g.glAttachShader(p, f);
    g.glLinkProgram(p);
    var ok: i32 = 0;
    g.glGetProgramiv(p, gl.LINK_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var len: i32 = 0;
        g.glGetProgramInfoLog(p, log.len, &len, &log);
        std.log.err("nanoui: OpenGL {s}+{s}: {s}", .{ vs, fs, log[0..@intCast(len)] });
        g.glDeleteProgram(p);
        return error.ShaderLink;
    }
    return p;
}

fn shader(es: bool, kind: u32, comptime define: []const u8) !u32 {
    const g = &gl.api;
    const s = g.glCreateShader(kind);
    const text = if (es)
        "#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2D;\n#define " ++ define ++ "\n" ++ source
    else
        "#version 330 core\n#define " ++ define ++ "\n" ++ source;
    const ptrs = [1][*]const u8{text.ptr};
    const lens = [1]i32{@intCast(text.len)};
    g.glShaderSource(s, 1, &ptrs, &lens);
    g.glCompileShader(s);
    var ok: i32 = 0;
    g.glGetShaderiv(s, gl.COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log: [2048]u8 = undefined;
        var len: i32 = 0;
        g.glGetShaderInfoLog(s, log.len, &len, &log);
        std.log.err("nanoui: OpenGL {s}: {s}", .{ define, log[0..@intCast(len)] });
        g.glDeleteShader(s);
        return error.ShaderCompile;
    }
    return s;
}

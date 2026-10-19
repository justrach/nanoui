//! OpenGL 3.3 core, loaded when first used (as GTK is, `linux/gtk.zig`):
//! no headers and no libraries at build time. Through libglvnd's
//! libOpenGL every function goes to whichever context is current, GLX or
//! EGL; where there is no libglvnd, libGL exports them. Each function is
//! looked up by the name of its field.
const std = @import("std");

pub const Api = struct {
    glGetError: *const fn () callconv(.c) u32,
    glGetString: *const fn (name: u32) callconv(.c) ?[*:0]const u8,
    glGetIntegerv: *const fn (name: u32, data: *i32) callconv(.c) void,
    glViewport: *const fn (x: i32, y: i32, w: i32, h: i32) callconv(.c) void,
    glClearColor: *const fn (r: f32, g: f32, b: f32, a: f32) callconv(.c) void,
    glClear: *const fn (mask: u32) callconv(.c) void,
    glEnable: *const fn (cap: u32) callconv(.c) void,
    glDisable: *const fn (cap: u32) callconv(.c) void,
    glBlendFunc: *const fn (src: u32, dst: u32) callconv(.c) void,
    glCreateShader: *const fn (kind: u32) callconv(.c) u32,
    glShaderSource: *const fn (shader: u32, count: i32, sources: [*]const [*]const u8, lengths: ?[*]const i32) callconv(.c) void,
    glCompileShader: *const fn (shader: u32) callconv(.c) void,
    glGetShaderiv: *const fn (shader: u32, name: u32, out: *i32) callconv(.c) void,
    glGetShaderInfoLog: *const fn (shader: u32, max: i32, len: ?*i32, log: [*]u8) callconv(.c) void,
    glDeleteShader: *const fn (shader: u32) callconv(.c) void,
    glCreateProgram: *const fn () callconv(.c) u32,
    glAttachShader: *const fn (program: u32, shader: u32) callconv(.c) void,
    glLinkProgram: *const fn (program: u32) callconv(.c) void,
    glGetProgramiv: *const fn (program: u32, name: u32, out: *i32) callconv(.c) void,
    glGetProgramInfoLog: *const fn (program: u32, max: i32, len: ?*i32, log: [*]u8) callconv(.c) void,
    glUseProgram: *const fn (program: u32) callconv(.c) void,
    glDeleteProgram: *const fn (program: u32) callconv(.c) void,
    glGetUniformLocation: *const fn (program: u32, name: [*:0]const u8) callconv(.c) i32,
    glUniform1i: *const fn (at: i32, v: i32) callconv(.c) void,
    glUniform1f: *const fn (at: i32, v: f32) callconv(.c) void,
    glUniform2f: *const fn (at: i32, x: f32, y: f32) callconv(.c) void,
    glUniform2i: *const fn (at: i32, x: i32, y: i32) callconv(.c) void,
    glUniform4i: *const fn (at: i32, x: i32, y: i32, z: i32, w: i32) callconv(.c) void,
    glGenVertexArrays: *const fn (n: i32, out: *u32) callconv(.c) void,
    glBindVertexArray: *const fn (vao: u32) callconv(.c) void,
    glDeleteVertexArrays: *const fn (n: i32, vaos: *const u32) callconv(.c) void,
    glGenBuffers: *const fn (n: i32, out: *u32) callconv(.c) void,
    glBindBuffer: *const fn (target: u32, buffer: u32) callconv(.c) void,
    glBufferData: *const fn (target: u32, size: isize, data: ?*const anyopaque, usage: u32) callconv(.c) void,
    glDeleteBuffers: *const fn (n: i32, buffers: *const u32) callconv(.c) void,
    glVertexAttribPointer: *const fn (index: u32, size: i32, kind: u32, normalized: u8, stride: i32, offset: usize) callconv(.c) void,
    glEnableVertexAttribArray: *const fn (index: u32) callconv(.c) void,
    glVertexAttribDivisor: *const fn (index: u32, divisor: u32) callconv(.c) void,
    glDrawArrays: *const fn (mode: u32, first: i32, count: i32) callconv(.c) void,
    glDrawArraysInstanced: *const fn (mode: u32, first: i32, count: i32, instances: i32) callconv(.c) void,
    glGenTextures: *const fn (n: i32, out: *u32) callconv(.c) void,
    glBindTexture: *const fn (target: u32, texture: u32) callconv(.c) void,
    glActiveTexture: *const fn (unit: u32) callconv(.c) void,
    glTexImage2D: *const fn (target: u32, level: i32, internal: i32, w: i32, h: i32, border: i32, format: u32, kind: u32, data: ?*const anyopaque) callconv(.c) void,
    glTexSubImage2D: *const fn (target: u32, level: i32, x: i32, y: i32, w: i32, h: i32, format: u32, kind: u32, data: *const anyopaque) callconv(.c) void,
    glTexParameteri: *const fn (target: u32, name: u32, v: i32) callconv(.c) void,
    glDeleteTextures: *const fn (n: i32, textures: *const u32) callconv(.c) void,
    glPixelStorei: *const fn (name: u32, v: i32) callconv(.c) void,
    glGenFramebuffers: *const fn (n: i32, out: *u32) callconv(.c) void,
    glBindFramebuffer: *const fn (target: u32, fbo: u32) callconv(.c) void,
    glFramebufferTexture2D: *const fn (target: u32, attachment: u32, textarget: u32, texture: u32, level: i32) callconv(.c) void,
    glCheckFramebufferStatus: *const fn (target: u32) callconv(.c) u32,
    glDeleteFramebuffers: *const fn (n: i32, fbos: *const u32) callconv(.c) void,
    glBlitFramebuffer: *const fn (sx0: i32, sy0: i32, sx1: i32, sy1: i32, dx0: i32, dy0: i32, dx1: i32, dy1: i32, mask: u32, filter: u32) callconv(.c) void,
    glReadPixels: *const fn (x: i32, y: i32, w: i32, h: i32, format: u32, kind: u32, data: *anyopaque) callconv(.c) void,
};

pub var api: Api = undefined;
var loaded = false;

/// Loads OpenGL's functions; false when it is not installed.
pub fn load() bool {
    if (loaded) return true;
    const lib = std.c.dlopen("libOpenGL.so.0", .{ .NOW = true }) orelse
        std.c.dlopen("libGL.so.1", .{ .NOW = true }) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = std.c.dlsym(lib, name) orelse {
            std.log.warn("nanoui: OpenGL lacks {s}", .{name});
            return false;
        };
        @field(api, name) = @ptrCast(@alignCast(sym));
    }
    loaded = true;
    return true;
}

pub const TRIANGLES = 0x0004;
pub const TRIANGLE_STRIP = 0x0005;
pub const FLOAT = 0x1406;
pub const UNSIGNED_BYTE = 0x1401;
pub const ARRAY_BUFFER = 0x8892;
pub const STREAM_DRAW = 0x88E0;
pub const TEXTURE_2D = 0x0DE1;
pub const TEXTURE0 = 0x84C0;
pub const R8 = 0x8229;
pub const RED = 0x1903;
pub const RGBA8 = 0x8058;
pub const BGRA = 0x80E1;
pub const TEXTURE_MAG_FILTER = 0x2800;
pub const TEXTURE_MIN_FILTER = 0x2801;
pub const TEXTURE_WRAP_S = 0x2802;
pub const TEXTURE_WRAP_T = 0x2803;
pub const LINEAR = 0x2601;
pub const NEAREST = 0x2600;
pub const CLAMP_TO_EDGE = 0x812F;
pub const UNPACK_ALIGNMENT = 0x0CF5;
pub const PACK_ALIGNMENT = 0x0D05;
pub const FRAMEBUFFER = 0x8D40;
pub const READ_FRAMEBUFFER = 0x8CA8;
pub const DRAW_FRAMEBUFFER = 0x8CA9;
pub const DRAW_FRAMEBUFFER_BINDING = 0x8CA6;
pub const COLOR_ATTACHMENT0 = 0x8CE0;
pub const FRAMEBUFFER_COMPLETE = 0x8CD5;
pub const COLOR_BUFFER_BIT = 0x4000;
pub const BLEND = 0x0BE2;
pub const DITHER = 0x0BD0;
pub const SCISSOR_TEST = 0x0C11;
pub const DEPTH_TEST = 0x0B71;
pub const FRAMEBUFFER_SRGB = 0x8DB9;
pub const ONE = 1;
pub const ONE_MINUS_SRC_ALPHA = 0x0303;
pub const VERTEX_SHADER = 0x8B31;
pub const FRAGMENT_SHADER = 0x8B30;
pub const COMPILE_STATUS = 0x8B81;
pub const LINK_STATUS = 0x8B82;
pub const VERSION = 0x1F02;
pub const RENDERER = 0x1F01;

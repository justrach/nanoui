//! OpenGL by name out of the Mac's framework, loaded the first time a page asks for a
//! context. Nowhere else has it yet: `available` is false and none of this is reached.
const std = @import("std");
const builtin = @import("builtin");

pub const available = builtin.os.tag == .macos;

const Ptr = ?*const anyopaque;
const MutPtr = ?*anyopaque;
const Str = [*:0]const u8;
fn F(comptime Params: []const type, comptime R: type) type {
    return *const @Fn(Params, &@splat(.{}), R, .{ .@"callconv" = .c });
}
fn V(comptime Params: []const type) type {
    return F(Params, void);
}
const U = u32;
const I = i32;
const Fl = f32;
const Sz = isize;
const B = u8;

pub const Api = struct {
    CGLChoosePixelFormat: F(&.{ [*]const c_int, *?*anyopaque, *c_int }, c_int),
    CGLDestroyPixelFormat: F(&.{?*anyopaque}, c_int),
    CGLCreateContext: F(&.{ ?*anyopaque, ?*anyopaque, *?*anyopaque }, c_int),
    CGLDestroyContext: F(&.{?*anyopaque}, c_int),
    CGLSetCurrentContext: F(&.{?*anyopaque}, c_int),
    CGLGetCurrentContext: F(&.{}, ?*anyopaque),

    glActiveTexture: V(&.{U}),
    glAttachShader: V(&.{ U, U }),
    glBindAttribLocation: V(&.{ U, U, Str }),
    glBindBuffer: V(&.{ U, U }),
    glBindFramebuffer: V(&.{ U, U }),
    glBindRenderbuffer: V(&.{ U, U }),
    glBindTexture: V(&.{ U, U }),
    glBlendColor: V(&.{ Fl, Fl, Fl, Fl }),
    glBlendEquation: V(&.{U}),
    glBlendEquationSeparate: V(&.{ U, U }),
    glBlendFunc: V(&.{ U, U }),
    glBlendFuncSeparate: V(&.{ U, U, U, U }),
    glBufferData: V(&.{ U, Sz, Ptr, U }),
    glBufferSubData: V(&.{ U, Sz, Sz, Ptr }),
    glCheckFramebufferStatus: F(&.{U}, U),
    glClear: V(&.{U}),
    glClearColor: V(&.{ Fl, Fl, Fl, Fl }),
    glClearDepth: V(&.{f64}),
    glClearStencil: V(&.{I}),
    glColorMask: V(&.{ B, B, B, B }),
    glCompileShader: V(&.{U}),
    glCopyTexImage2D: V(&.{ U, I, U, I, I, I, I, I }),
    glCopyTexSubImage2D: V(&.{ U, I, I, I, I, I, I, I }),
    glCreateProgram: F(&.{}, U),
    glCreateShader: F(&.{U}, U),
    glCullFace: V(&.{U}),
    glDeleteBuffers: V(&.{ I, *const U }),
    glDeleteFramebuffers: V(&.{ I, *const U }),
    glDeleteProgram: V(&.{U}),
    glDeleteRenderbuffers: V(&.{ I, *const U }),
    glDeleteShader: V(&.{U}),
    glDeleteTextures: V(&.{ I, *const U }),
    glDepthFunc: V(&.{U}),
    glDepthMask: V(&.{B}),
    glDepthRange: V(&.{ f64, f64 }),
    glDetachShader: V(&.{ U, U }),
    glDisable: V(&.{U}),
    glDisableVertexAttribArray: V(&.{U}),
    glDrawArrays: V(&.{ U, I, I }),
    glDrawElements: V(&.{ U, I, U, usize }),
    glEnable: V(&.{U}),
    glEnableVertexAttribArray: V(&.{U}),
    glFinish: V(&.{}),
    glFlush: V(&.{}),
    glFramebufferRenderbuffer: V(&.{ U, U, U, U }),
    glFramebufferTexture2D: V(&.{ U, U, U, U, I }),
    glFrontFace: V(&.{U}),
    glGenBuffers: V(&.{ I, *U }),
    glGenFramebuffers: V(&.{ I, *U }),
    glGenRenderbuffers: V(&.{ I, *U }),
    glGenTextures: V(&.{ I, *U }),
    glGenerateMipmap: V(&.{U}),
    glGetActiveAttrib: V(&.{ U, U, I, *I, *I, *U, [*]u8 }),
    glGetActiveUniform: V(&.{ U, U, I, *I, *I, *U, [*]u8 }),
    glGetAttribLocation: F(&.{ U, Str }, I),
    glGetBooleanv: V(&.{ U, [*]B }),
    glGetError: F(&.{}, U),
    glGetFloatv: V(&.{ U, [*]Fl }),
    glGetFramebufferAttachmentParameteriv: V(&.{ U, U, U, *I }),
    glGetIntegerv: V(&.{ U, [*]I }),
    glGetProgramInfoLog: V(&.{ U, I, *I, [*]u8 }),
    glGetProgramiv: V(&.{ U, U, *I }),
    glGetRenderbufferParameteriv: V(&.{ U, U, *I }),
    glGetShaderInfoLog: V(&.{ U, I, *I, [*]u8 }),
    glGetShaderiv: V(&.{ U, U, *I }),
    glGetString: F(&.{U}, ?Str),
    glGetTexParameteriv: V(&.{ U, U, *I }),
    glGetUniformLocation: F(&.{ U, Str }, I),
    glHint: V(&.{ U, U }),
    glIsEnabled: F(&.{U}, B),
    glLineWidth: V(&.{Fl}),
    glLinkProgram: V(&.{U}),
    glPixelStorei: V(&.{ U, I }),
    glPolygonOffset: V(&.{ Fl, Fl }),
    glReadPixels: V(&.{ I, I, I, I, U, U, MutPtr }),
    glRenderbufferStorage: V(&.{ U, U, I, I }),
    glSampleCoverage: V(&.{ Fl, B }),
    glScissor: V(&.{ I, I, I, I }),
    glShaderSource: V(&.{ U, I, *const [*]const u8, *const I }),
    glStencilFunc: V(&.{ U, I, U }),
    glStencilFuncSeparate: V(&.{ U, U, I, U }),
    glStencilMask: V(&.{U}),
    glStencilMaskSeparate: V(&.{ U, U }),
    glStencilOp: V(&.{ U, U, U }),
    glStencilOpSeparate: V(&.{ U, U, U, U }),
    glTexImage2D: V(&.{ U, I, I, I, I, I, U, U, Ptr }),
    glTexParameterf: V(&.{ U, U, Fl }),
    glTexParameteri: V(&.{ U, U, I }),
    glTexParameteriv: V(&.{ U, U, [*]const I }),
    glTexSubImage2D: V(&.{ U, I, I, I, I, I, U, U, Ptr }),
    glUniform1f: V(&.{ I, Fl }),
    glUniform2f: V(&.{ I, Fl, Fl }),
    glUniform3f: V(&.{ I, Fl, Fl, Fl }),
    glUniform4f: V(&.{ I, Fl, Fl, Fl, Fl }),
    glUniform1i: V(&.{ I, I }),
    glUniform2i: V(&.{ I, I, I }),
    glUniform3i: V(&.{ I, I, I, I }),
    glUniform4i: V(&.{ I, I, I, I, I }),
    glUniform1fv: V(&.{ I, I, Ptr }),
    glUniform2fv: V(&.{ I, I, Ptr }),
    glUniform3fv: V(&.{ I, I, Ptr }),
    glUniform4fv: V(&.{ I, I, Ptr }),
    glUniform1iv: V(&.{ I, I, Ptr }),
    glUniform2iv: V(&.{ I, I, Ptr }),
    glUniform3iv: V(&.{ I, I, Ptr }),
    glUniform4iv: V(&.{ I, I, Ptr }),
    glUniformMatrix2fv: V(&.{ I, I, B, Ptr }),
    glUniformMatrix3fv: V(&.{ I, I, B, Ptr }),
    glUniformMatrix4fv: V(&.{ I, I, B, Ptr }),
    glUseProgram: V(&.{U}),
    glValidateProgram: V(&.{U}),
    glVertexAttrib1f: V(&.{ U, Fl }),
    glVertexAttrib2f: V(&.{ U, Fl, Fl }),
    glVertexAttrib3f: V(&.{ U, Fl, Fl, Fl }),
    glVertexAttrib4f: V(&.{ U, Fl, Fl, Fl, Fl }),
    glVertexAttribPointer: V(&.{ U, I, U, B, I, usize }),
    glViewport: V(&.{ I, I, I, I }),

    // A legacy context's names for what WebGL 1 extensions need.
    glBindVertexArrayAPPLE: V(&.{U}),
    glDeleteVertexArraysAPPLE: V(&.{ I, *const U }),
    glGenVertexArraysAPPLE: V(&.{ I, *U }),
    glDrawArraysInstancedARB: V(&.{ U, I, I, I }),
    glDrawElementsInstancedARB: V(&.{ U, I, U, usize, I }),
    glVertexAttribDivisorARB: V(&.{ U, U }),

    // The core profile's, for WebGL 2.
    glBindVertexArray: V(&.{U}),
    glDeleteVertexArrays: V(&.{ I, *const U }),
    glGenVertexArrays: V(&.{ I, *U }),
    glDrawArraysInstanced: V(&.{ U, I, I, I }),
    glDrawElementsInstanced: V(&.{ U, I, U, usize, I }),
    glVertexAttribDivisor: V(&.{ U, U }),
    glVertexAttribIPointer: V(&.{ U, I, U, I, usize }),
    glBindBufferBase: V(&.{ U, U, U }),
    glBindBufferRange: V(&.{ U, U, U, Sz, Sz }),
    glGetUniformBlockIndex: F(&.{ U, Str }, U),
    glUniformBlockBinding: V(&.{ U, U, U }),
    glGetActiveUniformBlockiv: V(&.{ U, U, U, *I }),
    glGetActiveUniformBlockName: V(&.{ U, U, I, *I, [*]u8 }),
    glPrimitiveRestartIndex: V(&.{U}),
    glDrawBuffers: V(&.{ I, [*]const U }),
    glReadBuffer: V(&.{U}),
    glBlitFramebuffer: V(&.{ I, I, I, I, I, I, I, I, U, U }),
    glTexStorage2D: V(&.{ U, I, U, I, I }),
    glUniform1ui: V(&.{ I, U }),
    glUniform2ui: V(&.{ I, U, U }),
    glUniform3ui: V(&.{ I, U, U, U }),
    glUniform4ui: V(&.{ I, U, U, U, U }),
    glUniform1uiv: V(&.{ I, I, Ptr }),
    glUniform2uiv: V(&.{ I, I, Ptr }),
    glUniform3uiv: V(&.{ I, I, Ptr }),
    glUniform4uiv: V(&.{ I, I, Ptr }),
    glUniformMatrix2x3fv: V(&.{ I, I, B, Ptr }),
    glUniformMatrix3x2fv: V(&.{ I, I, B, Ptr }),
    glUniformMatrix2x4fv: V(&.{ I, I, B, Ptr }),
    glUniformMatrix4x2fv: V(&.{ I, I, B, Ptr }),
    glUniformMatrix3x4fv: V(&.{ I, I, B, Ptr }),
    glUniformMatrix4x3fv: V(&.{ I, I, B, Ptr }),
    glClearBufferfv: V(&.{ U, I, Ptr }),
    glClearBufferiv: V(&.{ U, I, Ptr }),
    glClearBufferuiv: V(&.{ U, I, Ptr }),
    glClearBufferfi: V(&.{ U, I, Fl, I }),
    glGetBufferSubData: V(&.{ U, Sz, Sz, MutPtr }),
};

/// The table, once `load` has found it.
pub var gl: Api = undefined;

var tried = false;
var loaded = false;

extern "c" fn dlopen(path: [*:0]const u8, mode: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;

/// True once `gl` can be called. A symbol this OS doesn't have means no WebGL at all
/// rather than a crash later.
pub fn load() bool {
    if (!available) return false;
    if (tried) return loaded;
    tried = true;
    const handle = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", 1) orelse return false;
    inline for (@typeInfo(Api).@"struct".field_names) |name| {
        const sym = dlsym(handle, name) orelse return false;
        @field(gl, name) = @ptrCast(@alignCast(sym));
    }
    loaded = true;
    return true;
}

pub const FRAMEBUFFER: u32 = 0x8D40;
pub const READ_FRAMEBUFFER: u32 = 0x8CA8;
pub const DRAW_FRAMEBUFFER: u32 = 0x8CA9;
pub const RENDERBUFFER: u32 = 0x8D41;
pub const COLOR_ATTACHMENT0: u32 = 0x8CE0;
pub const DEPTH_ATTACHMENT: u32 = 0x8D00;
pub const STENCIL_ATTACHMENT: u32 = 0x8D20;
pub const COLOR_BUFFER_BIT: u32 = 0x4000;
pub const DEPTH_BUFFER_BIT: u32 = 0x100;
pub const STENCIL_BUFFER_BIT: u32 = 0x400;
pub const SCISSOR_TEST: u32 = 0x0C11;
pub const BGRA: u32 = 0x80E1;
pub const UNSIGNED_INT_8_8_8_8_REV: u32 = 0x8367;
pub const PACK_ALIGNMENT: u32 = 0x0D05;
pub const UNPACK_ALIGNMENT: u32 = 0x0CF5;
pub const ARRAY_BUFFER: u32 = 0x8892;
pub const ELEMENT_ARRAY_BUFFER: u32 = 0x8893;
pub const UNIFORM_BUFFER: u32 = 0x8A11;
pub const COPY_READ_BUFFER: u32 = 0x8F36;
pub const COPY_WRITE_BUFFER: u32 = 0x8F37;
pub const COMPILE_STATUS: u32 = 0x8B81;
pub const LINK_STATUS: u32 = 0x8B82;
pub const INFO_LOG_LENGTH: u32 = 0x8B84;
pub const ACTIVE_UNIFORMS: u32 = 0x8B86;
pub const ACTIVE_ATTRIBUTES: u32 = 0x8B89;
pub const ACTIVE_ATTRIBUTE_MAX_LENGTH: u32 = 0x8B8A;
pub const ACTIVE_UNIFORM_MAX_LENGTH: u32 = 0x8B87;
pub const ACTIVE_UNIFORM_BLOCKS: u32 = 0x8A36;
pub const UNIFORM_BLOCK_BINDING: u32 = 0x8A3F;
pub const UNIFORM_BLOCK_DATA_SIZE: u32 = 0x8A40;

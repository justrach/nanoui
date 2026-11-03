//! OpenGL ES 3 for the activity's window, through EGL: one context for the
//! app, current on its thread, drawing into the window's surface while
//! there is a window (a tiny pbuffer keeps it current between windows, so
//! renderers can be made and freed then). The functions are OpenGL's as
//! on Linux (`ui/gl.zig` loads libGLESv3), the shaders GLSL ES's.
const std = @import("std");
const ndk = @import("ndk.zig");
const gl = @import("../ui/gl.zig");

pub const Gl = struct {
    display: ndk.EGLDisplay,
    config: ndk.EGLConfig,
    context: ndk.EGLContext,
    pbuffer: ndk.EGLSurface,
    /// The window's, while there is one.
    surface: ndk.EGLSurface = null,
    window: ?*ndk.ANativeWindow = null,

    /// A context of OpenGL ES 3, or null where there is none (the CPU
    /// renderer draws then).
    pub fn init() ?Gl {
        const display = ndk.eglGetDisplay(null);
        if (display == null or ndk.eglInitialize(display, null, null) == 0) return null;
        const attribs = [_]i32{
            ndk.EGL_RENDERABLE_TYPE, ndk.EGL_OPENGL_ES3_BIT,
            ndk.EGL_SURFACE_TYPE,    ndk.EGL_WINDOW_BIT | ndk.EGL_PBUFFER_BIT,
            ndk.EGL_RED_SIZE,        8,
            ndk.EGL_GREEN_SIZE,      8,
            ndk.EGL_BLUE_SIZE,       8,
            ndk.EGL_ALPHA_SIZE,      8,
            ndk.EGL_DEPTH_SIZE,      0,
            ndk.EGL_NONE,
        };
        var configs: [16]ndk.EGLConfig = undefined;
        var count: i32 = 0;
        if (ndk.eglChooseConfig(display, &attribs, &configs, configs.len, &count) == 0 or count == 0) {
            _ = ndk.eglTerminate(display);
            return null;
        }
        // Exactly eight bits a channel: a config with more comes first.
        var config = configs[0];
        for (configs[0..@intCast(count)]) |c| {
            var r: i32 = 0;
            var a: i32 = 0;
            _ = ndk.eglGetConfigAttrib(display, c, ndk.EGL_RED_SIZE, &r);
            _ = ndk.eglGetConfigAttrib(display, c, ndk.EGL_ALPHA_SIZE, &a);
            if (r == 8 and a == 8) {
                config = c;
                break;
            }
        }
        const context = ndk.eglCreateContext(display, config, null, &[_]i32{ ndk.EGL_CONTEXT_CLIENT_VERSION, 3, ndk.EGL_NONE });
        if (context == null) {
            _ = ndk.eglTerminate(display);
            return null;
        }
        const pbuffer = ndk.eglCreatePbufferSurface(display, config, &[_]i32{ ndk.EGL_WIDTH, 1, ndk.EGL_HEIGHT, 1, ndk.EGL_NONE });
        var g: Gl = .{ .display = display, .config = config, .context = context, .pbuffer = pbuffer };
        if (pbuffer == null or !g.makeCurrent() or !gl.loadEs()) {
            g.deinit();
            return null;
        }
        return g;
    }

    pub fn deinit(g: *Gl) void {
        g.detach();
        _ = ndk.eglMakeCurrent(g.display, null, null, null);
        if (g.pbuffer != null) _ = ndk.eglDestroySurface(g.display, g.pbuffer);
        _ = ndk.eglDestroyContext(g.display, g.context);
        _ = ndk.eglTerminate(g.display);
        // The thread's own EGL state too: the app's thread ends after this.
        _ = ndk.eglReleaseThread();
    }

    /// Draws into `window` from now on; false if EGL can't.
    pub fn attach(g: *Gl, window: *ndk.ANativeWindow) bool {
        if (g.window == window and g.surface != null) return g.makeCurrent();
        g.detach();
        // The window's buffers in the config's format.
        var format: i32 = 0;
        _ = ndk.eglGetConfigAttrib(g.display, g.config, ndk.EGL_NATIVE_VISUAL_ID, &format);
        _ = ndk.ANativeWindow_setBuffersGeometry(window, 0, 0, format);
        const s = ndk.eglCreateWindowSurface(g.display, g.config, window, null);
        if (s == null) {
            std.log.warn("nanoui: no EGL surface for the window (0x{x})", .{ndk.eglGetError()});
            return false;
        }
        g.surface = s;
        g.window = window;
        if (!g.makeCurrent()) return false;
        _ = ndk.eglSwapInterval(g.display, 1);
        return true;
    }

    /// The window goes: nothing draws into it after this.
    pub fn detach(g: *Gl) void {
        if (g.surface == null) return;
        _ = ndk.eglMakeCurrent(g.display, g.pbuffer, g.pbuffer, g.context);
        _ = ndk.eglDestroySurface(g.display, g.surface);
        g.surface = null;
        g.window = null;
    }

    /// The context current, on the window's surface if there is one.
    pub fn makeCurrent(g: *Gl) bool {
        const s = if (g.surface != null) g.surface else g.pbuffer;
        return ndk.eglMakeCurrent(g.display, s, s, g.context) != 0;
    }

    /// Shows what was drawn; false if it couldn't (the context lost, say).
    pub fn swap(g: *Gl) bool {
        if (g.surface == null) return true;
        if (ndk.eglSwapBuffers(g.display, g.surface) != 0) return true;
        const err = ndk.eglGetError();
        if (err == 0x3000) return true;
        std.log.warn("nanoui: eglSwapBuffers failed (0x{x})", .{err});
        return false;
    }
};

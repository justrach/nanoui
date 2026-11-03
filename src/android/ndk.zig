//! The NDK's C interface that nanoui uses on Android, declared as the
//! NDK's headers declare it (`android/native_activity.h`, `looper.h`,
//! `input.h`, `native_window.h`, `choreographer.h`,
//! `EGL/egl.h`, `android/log.h`): no headers at build time, the system's
//! libraries linked (libandroid, liblog, libEGL; OpenGL ES is loaded with
//! dlopen as on Linux, `ui/gl.zig`).
const std = @import("std");
const jni = @import("jni.zig");

pub const ALooper = opaque {};
pub const AInputQueue = opaque {};
pub const AInputEvent = opaque {};
pub const ANativeWindow = opaque {};
pub const AAssetManager = opaque {};
pub const AChoreographer = opaque {};

pub const ARect = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

pub const ANativeActivity = extern struct {
    callbacks: *Callbacks,
    vm: jni.VM,
    /// The main thread's: use only from it.
    env: jni.Env,
    /// The NativeActivity, a global reference while the activity lives.
    clazz: jni.Object,
    internalDataPath: ?[*:0]const u8,
    externalDataPath: ?[*:0]const u8,
    sdkVersion: i32,
    instance: ?*anyopaque,
    assetManager: ?*AAssetManager,
    obbPath: ?[*:0]const u8,
};

pub const Callbacks = extern struct {
    onStart: ?*const fn (*ANativeActivity) callconv(.c) void,
    onResume: ?*const fn (*ANativeActivity) callconv(.c) void,
    onSaveInstanceState: ?*const fn (*ANativeActivity, *usize) callconv(.c) ?*anyopaque,
    onPause: ?*const fn (*ANativeActivity) callconv(.c) void,
    onStop: ?*const fn (*ANativeActivity) callconv(.c) void,
    onDestroy: ?*const fn (*ANativeActivity) callconv(.c) void,
    onWindowFocusChanged: ?*const fn (*ANativeActivity, c_int) callconv(.c) void,
    onNativeWindowCreated: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void,
    onNativeWindowResized: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void,
    onNativeWindowRedrawNeeded: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void,
    onNativeWindowDestroyed: ?*const fn (*ANativeActivity, *ANativeWindow) callconv(.c) void,
    onInputQueueCreated: ?*const fn (*ANativeActivity, *AInputQueue) callconv(.c) void,
    onInputQueueDestroyed: ?*const fn (*ANativeActivity, *AInputQueue) callconv(.c) void,
    onContentRectChanged: ?*const fn (*ANativeActivity, *const ARect) callconv(.c) void,
    onConfigurationChanged: ?*const fn (*ANativeActivity) callconv(.c) void,
    onLowMemory: ?*const fn (*ANativeActivity) callconv(.c) void,
};

// The activity. These post to its main thread: callable from any thread.
pub extern "android" fn ANativeActivity_finish(activity: *ANativeActivity) void;
pub extern "android" fn ANativeActivity_setWindowFormat(activity: *ANativeActivity, format: i32) void;
pub extern "android" fn ANativeActivity_setWindowFlags(activity: *ANativeActivity, add: u32, remove: u32) void;
pub extern "android" fn ANativeActivity_showSoftInput(activity: *ANativeActivity, flags: u32) void;
pub extern "android" fn ANativeActivity_hideSoftInput(activity: *ANativeActivity, flags: u32) void;
pub const SHOW_SOFT_INPUT_IMPLICIT = 1;
pub const SHOW_SOFT_INPUT_FORCED = 2;
pub const HIDE_SOFT_INPUT_NOT_ALWAYS = 2;

// Loopers: a thread's event loop over file descriptors.
pub const LooperCallback = *const fn (fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) c_int;
pub extern "android" fn ALooper_forThread() ?*ALooper;
pub extern "android" fn ALooper_prepare(opts: c_int) *ALooper;
pub extern "android" fn ALooper_acquire(looper: *ALooper) void;
pub extern "android" fn ALooper_release(looper: *ALooper) void;
pub extern "android" fn ALooper_pollOnce(timeout_ms: c_int, fd: ?*c_int, events: ?*c_int, data: ?*?*anyopaque) c_int;
pub extern "android" fn ALooper_wake(looper: *ALooper) void;
pub extern "android" fn ALooper_addFd(looper: *ALooper, fd: c_int, ident: c_int, events: c_int, callback: ?LooperCallback, data: ?*anyopaque) c_int;
pub extern "android" fn ALooper_removeFd(looper: *ALooper, fd: c_int) c_int;
pub const LOOPER_PREPARE_ALLOW_NON_CALLBACKS = 1;
pub const LOOPER_POLL_CALLBACK = -2;
pub const LOOPER_POLL_TIMEOUT = -3;
pub const LOOPER_POLL_ERROR = -4;
pub const LOOPER_EVENT_INPUT = 1;
pub const LOOPER_EVENT_ERROR = 4;
pub const LOOPER_EVENT_HANGUP = 8;

// Input: the activity's queue of key and motion events.
pub extern "android" fn AInputQueue_attachLooper(queue: *AInputQueue, looper: *ALooper, ident: c_int, callback: ?LooperCallback, data: ?*anyopaque) void;
pub extern "android" fn AInputQueue_detachLooper(queue: *AInputQueue) void;
pub extern "android" fn AInputQueue_getEvent(queue: *AInputQueue, out: *?*AInputEvent) i32;
pub extern "android" fn AInputQueue_preDispatchEvent(queue: *AInputQueue, event: *AInputEvent) i32;
pub extern "android" fn AInputQueue_finishEvent(queue: *AInputQueue, event: *AInputEvent, handled: c_int) void;
pub extern "android" fn AInputEvent_getType(event: *const AInputEvent) i32;
pub extern "android" fn AInputEvent_getDeviceId(event: *const AInputEvent) i32;
pub extern "android" fn AInputEvent_getSource(event: *const AInputEvent) i32;
pub extern "android" fn AKeyEvent_getAction(event: *const AInputEvent) i32;
pub extern "android" fn AKeyEvent_getKeyCode(event: *const AInputEvent) i32;
pub extern "android" fn AKeyEvent_getMetaState(event: *const AInputEvent) i32;
pub extern "android" fn AKeyEvent_getRepeatCount(event: *const AInputEvent) i32;
pub extern "android" fn AMotionEvent_getAction(event: *const AInputEvent) i32;
pub extern "android" fn AMotionEvent_getMetaState(event: *const AInputEvent) i32;
pub extern "android" fn AMotionEvent_getButtonState(event: *const AInputEvent) i32;
pub extern "android" fn AMotionEvent_getEventTime(event: *const AInputEvent) i64;
pub extern "android" fn AMotionEvent_getPointerCount(event: *const AInputEvent) usize;
pub extern "android" fn AMotionEvent_getPointerId(event: *const AInputEvent, index: usize) i32;
pub extern "android" fn AMotionEvent_getToolType(event: *const AInputEvent, index: usize) i32;
pub extern "android" fn AMotionEvent_getX(event: *const AInputEvent, index: usize) f32;
pub extern "android" fn AMotionEvent_getY(event: *const AInputEvent, index: usize) f32;
pub extern "android" fn AMotionEvent_getAxisValue(event: *const AInputEvent, axis: i32, index: usize) f32;
pub const INPUT_EVENT_TYPE_KEY = 1;
pub const INPUT_EVENT_TYPE_MOTION = 2;
pub const KEY_EVENT_ACTION_DOWN = 0;
pub const KEY_EVENT_ACTION_UP = 1;
pub const MOTION_EVENT_ACTION_MASK = 0xff;
pub const MOTION_EVENT_ACTION_POINTER_INDEX_SHIFT = 8;
pub const MOTION_EVENT_ACTION_DOWN = 0;
pub const MOTION_EVENT_ACTION_UP = 1;
pub const MOTION_EVENT_ACTION_MOVE = 2;
pub const MOTION_EVENT_ACTION_CANCEL = 3;
pub const MOTION_EVENT_ACTION_POINTER_DOWN = 5;
pub const MOTION_EVENT_ACTION_POINTER_UP = 6;
pub const MOTION_EVENT_ACTION_HOVER_MOVE = 7;
pub const MOTION_EVENT_ACTION_SCROLL = 8;
pub const MOTION_EVENT_ACTION_HOVER_EXIT = 10;
pub const MOTION_EVENT_AXIS_VSCROLL = 9;
pub const MOTION_EVENT_AXIS_HSCROLL = 10;
pub const MOTION_EVENT_TOOL_TYPE_MOUSE = 3;
pub const MOTION_EVENT_BUTTON_PRIMARY = 1;
pub const META_SHIFT_ON = 0x01;
pub const META_ALT_ON = 0x02;
pub const META_CTRL_ON = 0x1000;
pub const META_CTRL_MASK = 0x7000;
pub const META_ALT_MASK = 0x32;
pub const META_META_MASK = 0x70000;

// Windows: the surface the activity's content draws on.
pub const ANativeWindow_Buffer = extern struct {
    width: i32,
    height: i32,
    stride: i32,
    format: i32,
    bits: ?[*]u8,
    reserved: [6]u32,
};
pub extern "android" fn ANativeWindow_acquire(window: *ANativeWindow) void;
pub extern "android" fn ANativeWindow_release(window: *ANativeWindow) void;
pub extern "android" fn ANativeWindow_getWidth(window: *ANativeWindow) i32;
pub extern "android" fn ANativeWindow_getHeight(window: *ANativeWindow) i32;
pub extern "android" fn ANativeWindow_setBuffersGeometry(window: *ANativeWindow, w: i32, h: i32, format: i32) i32;
pub extern "android" fn ANativeWindow_lock(window: *ANativeWindow, out: *ANativeWindow_Buffer, dirty: ?*ARect) i32;
pub extern "android" fn ANativeWindow_unlockAndPost(window: *ANativeWindow) i32;
pub const WINDOW_FORMAT_RGBA_8888 = 1;

// The choreographer: frames at the display's refresh (API 29).
pub const FrameCallback = *const fn (frame_time_ns: i64, data: ?*anyopaque) callconv(.c) void;
pub extern "android" fn AChoreographer_getInstance() ?*AChoreographer;
pub extern "android" fn AChoreographer_postFrameCallback64(c: *AChoreographer, callback: FrameCallback, data: ?*anyopaque) void;
pub extern "android" fn AChoreographer_postFrameCallbackDelayed64(c: *AChoreographer, callback: FrameCallback, data: ?*anyopaque, delay_ms: u32) void;

// The log (logcat).
pub extern "log" fn __android_log_write(priority: c_int, tag: [*:0]const u8, text: [*:0]const u8) c_int;
pub const LOG_INFO = 4;
pub const LOG_WARN = 5;
pub const LOG_FATAL = 7;

// EGL: OpenGL ES's surfaces and contexts.
pub const EGLDisplay = ?*anyopaque;
pub const EGLConfig = ?*anyopaque;
pub const EGLContext = ?*anyopaque;
pub const EGLSurface = ?*anyopaque;
pub extern "EGL" fn eglGetDisplay(display: ?*anyopaque) EGLDisplay;
pub extern "EGL" fn eglInitialize(display: EGLDisplay, major: ?*i32, minor: ?*i32) u32;
pub extern "EGL" fn eglTerminate(display: EGLDisplay) u32;
pub extern "EGL" fn eglChooseConfig(display: EGLDisplay, attribs: [*]const i32, configs: [*]EGLConfig, size: i32, count: *i32) u32;
pub extern "EGL" fn eglGetConfigAttrib(display: EGLDisplay, config: EGLConfig, attribute: i32, value: *i32) u32;
pub extern "EGL" fn eglCreateContext(display: EGLDisplay, config: EGLConfig, share: EGLContext, attribs: [*]const i32) EGLContext;
pub extern "EGL" fn eglDestroyContext(display: EGLDisplay, context: EGLContext) u32;
pub extern "EGL" fn eglCreateWindowSurface(display: EGLDisplay, config: EGLConfig, window: *ANativeWindow, attribs: ?[*]const i32) EGLSurface;
pub extern "EGL" fn eglCreatePbufferSurface(display: EGLDisplay, config: EGLConfig, attribs: [*]const i32) EGLSurface;
pub extern "EGL" fn eglDestroySurface(display: EGLDisplay, surface: EGLSurface) u32;
pub extern "EGL" fn eglMakeCurrent(display: EGLDisplay, draw: EGLSurface, read: EGLSurface, context: EGLContext) u32;
pub extern "EGL" fn eglSwapBuffers(display: EGLDisplay, surface: EGLSurface) u32;
pub extern "EGL" fn eglSwapInterval(display: EGLDisplay, interval: i32) u32;
pub extern "EGL" fn eglGetError() i32;
pub extern "EGL" fn eglReleaseThread() u32;
pub const EGL_NONE = 0x3038;
pub const EGL_RED_SIZE = 0x3024;
pub const EGL_GREEN_SIZE = 0x3023;
pub const EGL_BLUE_SIZE = 0x3022;
pub const EGL_ALPHA_SIZE = 0x3021;
pub const EGL_DEPTH_SIZE = 0x3025;
pub const EGL_SURFACE_TYPE = 0x3033;
pub const EGL_RENDERABLE_TYPE = 0x3040;
pub const EGL_WINDOW_BIT = 0x0004;
pub const EGL_PBUFFER_BIT = 0x0001;
pub const EGL_OPENGL_ES3_BIT = 0x0040;
pub const EGL_NATIVE_VISUAL_ID = 0x302E;
pub const EGL_CONTEXT_CLIENT_VERSION = 0x3098;
pub const EGL_WIDTH = 0x3057;
pub const EGL_HEIGHT = 0x3056;
pub const EGL_CONTEXT_LOST = 0x300E;

/// Writes `text` to the log under nanoui's tag.
pub fn log(priority: c_int, text: []const u8) void {
    var buf: [1024]u8 = undefined;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    _ = __android_log_write(priority, "nanoui", @ptrCast(&buf));
}

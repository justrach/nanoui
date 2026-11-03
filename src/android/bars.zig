//! The system's bars over the activity's window, through Java on the
//! activity's thread: the window spans the screen, under the status and
//! navigation bars (as Android 15 has every app do), whose icons follow
//! the view's colors; the insets say what the bars, the display's cutout
//! and the keyboard cover (`Context.safe_area`).
const std = @import("std");
const jni = @import("jni.zig");
const Insets = @import("activity.zig").Insets;

/// The window under the bars, on every Android since 10: drawn behind
/// them, which are see-through.
pub fn edgeToEdge(env: jni.Env, act: jni.Object, sdk: i32) void {
    const frame = jni.Frame.push(env, 16);
    defer frame.pop();
    const window = jni.call(env, act, "getWindow", "()Landroid/view/Window;", &.{}) orelse return;
    if (sdk >= 30) {
        _ = jni.call(env, window, "setDecorFitsSystemWindows", "(Z)V", &.{jni.boolean(false)});
    } else {
        const decor = jni.call(env, window, "getDecorView", "()Landroid/view/View;", &.{}) orelse return;
        // LAYOUT_STABLE | LAYOUT_HIDE_NAVIGATION | LAYOUT_FULLSCREEN
        _ = jni.call(env, decor, "setSystemUiVisibility", "(I)V", &.{jni.int(0x100 | 0x200 | 0x400)});
    }
    // See-through bars (Android 15 makes them so itself).
    if (sdk < 35) {
        _ = jni.call(env, window, "setStatusBarColor", "(I)V", &.{jni.int(0)});
        _ = jni.call(env, window, "setNavigationBarColor", "(I)V", &.{jni.int(0)});
    }
    fitContent(env, act);
    // Content into the display's cutout too: the insets keep it clear.
    const attrs = jni.call(env, window, "getAttributes", "()Landroid/view/WindowManager$LayoutParams;", &.{}) orelse return;
    // LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES (ALWAYS from Android 11)
    jni.setIntField(env, attrs, "layoutInDisplayCutoutMode", if (sdk >= 30) 3 else 1);
    _ = jni.call(env, window, "setAttributes", "(Landroid/view/WindowManager$LayoutParams;)V", &.{jni.ref(attrs)});
}

/// NativeActivity's view inside the bars and the keyboard: its place then
/// changes as they come and go, which NativeActivity tells (its content
/// rect), and the insets are read again. Nothing else tells when the
/// keyboard comes. It goes in a frame of its own that fits them (the
/// window's own content frame fits nothing when it spans the screen);
/// the window's surface, which nanoui draws, stays the whole screen.
fn fitContent(env: jni.Env, act: jni.Object) void {
    const content = jni.call(env, act, "findViewById", "(I)Landroid/view/View;", &.{jni.int(0x01020002)}) orelse return;
    const view = jni.call(env, content, "getChildAt", "(I)Landroid/view/View;", &.{jni.int(0)}) orelse return;
    const frame = jni.new(env, "android/widget/FrameLayout", "(Landroid/content/Context;)V", &.{jni.ref(act)});
    if (content == null or view == null or frame == null) return;
    const VG = "Landroid/view/ViewGroup$LayoutParams;";
    // MATCH_PARENT both ways.
    const fill = jni.new(env, "android/view/ViewGroup$LayoutParams", "(II)V", &.{ jni.int(-1), jni.int(-1) });
    _ = jni.call(env, content, "removeView", "(Landroid/view/View;)V", &.{jni.ref(view)});
    _ = jni.call(env, frame, "addView", "(Landroid/view/View;" ++ VG ++ ")V", &.{ jni.ref(view), jni.ref(fill) });
    _ = jni.call(env, frame, "setFitsSystemWindows", "(Z)V", &.{jni.boolean(true)});
    _ = jni.call(env, content, "addView", "(Landroid/view/View;" ++ VG ++ ")V", &.{ jni.ref(frame), jni.ref(fill) });
    _ = jni.call(env, view, "requestFocus", "()Z", &.{});
}

/// Dark icons on the bars over a light view, light ones over a dark view.
pub fn setLight(env: jni.Env, act: jni.Object, sdk: i32, light: bool) void {
    const frame = jni.Frame.push(env, 16);
    defer frame.pop();
    const window = jni.call(env, act, "getWindow", "()Landroid/view/Window;", &.{}) orelse return;
    if (sdk >= 30) {
        const c = jni.call(env, window, "getInsetsController", "()Landroid/view/WindowInsetsController;", &.{}) orelse return;
        // APPEARANCE_LIGHT_STATUS_BARS | APPEARANCE_LIGHT_NAVIGATION_BARS
        const both: i32 = 8 | 16;
        _ = jni.call(env, c, "setSystemBarsAppearance", "(II)V", &.{ jni.int(if (light) both else 0), jni.int(both) });
        return;
    }
    const decor = jni.call(env, window, "getDecorView", "()Landroid/view/View;", &.{}) orelse return;
    const flags = jni.call(env, decor, "getSystemUiVisibility", "()I", &.{}) orelse return;
    // LIGHT_STATUS_BAR | LIGHT_NAVIGATION_BAR
    const both: i32 = 0x2000 | 0x10;
    _ = jni.call(env, decor, "setSystemUiVisibility", "(I)V", &.{jni.int(if (light) flags | both else flags & ~both)});
}

/// What the bars, the cutout and the keyboard cover of the window, in
/// pixels; null before the window is laid out.
pub fn read(env: jni.Env, act: jni.Object, sdk: i32) ?Insets {
    const frame = jni.Frame.push(env, 16);
    defer frame.pop();
    const window = jni.call(env, act, "getWindow", "()Landroid/view/Window;", &.{}) orelse return null;
    const decor = jni.call(env, window, "getDecorView", "()Landroid/view/View;", &.{}) orelse return null;
    const insets = jni.call(env, decor, "getRootWindowInsets", "()Landroid/view/WindowInsets;", &.{}) orelse return null;
    if (insets == null) return null;
    var r: Insets = .{};
    if (sdk >= 30) {
        const T = "android/view/WindowInsets$Type";
        const bars = jni.callStatic(env, T, "systemBars", "()I", &.{}) orelse 0;
        const cutout = jni.callStatic(env, T, "displayCutout", "()I", &.{}) orelse 0;
        const ime = jni.callStatic(env, T, "ime", "()I", &.{}) orelse 0;
        const b = jni.call(env, insets, "getInsets", "(I)Landroid/graphics/Insets;", &.{jni.int(bars | cutout)}) orelse return null;
        r.bars = .{ field(env, b, "top"), field(env, b, "left"), field(env, b, "bottom"), field(env, b, "right") };
        const k = jni.call(env, insets, "getInsets", "(I)Landroid/graphics/Insets;", &.{jni.int(ime)}) orelse return r;
        r.keyboard = field(env, k, "bottom");
        return r;
    }
    // Android 10: the stable insets are the bars'; the system window's
    // bottom is the keyboard's when it's up.
    const top = jni.call(env, insets, "getStableInsetTop", "()I", &.{}) orelse 0;
    const left = jni.call(env, insets, "getStableInsetLeft", "()I", &.{}) orelse 0;
    const bottom = jni.call(env, insets, "getStableInsetBottom", "()I", &.{}) orelse 0;
    const right = jni.call(env, insets, "getStableInsetRight", "()I", &.{}) orelse 0;
    const system_bottom = jni.call(env, insets, "getSystemWindowInsetBottom", "()I", &.{}) orelse 0;
    r.bars = .{ top, left, bottom, right };
    r.keyboard = if (system_bottom > bottom) system_bottom else 0;
    return r;
}

fn field(env: jni.Env, obj: jni.Object, name: [*:0]const u8) i32 {
    return jni.intField(env, obj, name) orelse 0;
}

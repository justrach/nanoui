//! The activity's configuration, as the app draws by it: dark mode, the
//! display's density, and whether animations are off. Read from Java on
//! the activity's thread as it starts and as it changes: NativeActivity's
//! asset manager keeps the configuration it started with, while Android
//! gives the activity new resources for a new one.
const std = @import("std");
const jni = @import("jni.zig");

pub const Config = struct {
    dark: bool = false,
    /// Dots per inch (160 is one pixel a point).
    density: i32 = 160,
    /// "Remove animations" (the animator duration scale is 0).
    animations_off: bool = false,
};

pub fn read(env: jni.Env, act: jni.Object) Config {
    var c: Config = .{};
    const frame = jni.Frame.push(env, 16);
    defer frame.pop();
    const res = jni.call(env, act, "getResources", "()Landroid/content/res/Resources;", &.{}) orelse return c;
    const conf = jni.call(env, res, "getConfiguration", "()Landroid/content/res/Configuration;", &.{}) orelse return c;
    // UI_MODE_NIGHT_MASK, UI_MODE_NIGHT_YES
    if (jni.intField(env, conf, "uiMode")) |m| c.dark = m & 0x30 == 0x20;
    if (jni.intField(env, conf, "densityDpi")) |d| if (d > 0) {
        c.density = d;
    };
    const resolver = jni.call(env, act, "getContentResolver", "()Landroid/content/ContentResolver;", &.{}) orelse return c;
    const key = jni.string(env, "animator_duration_scale");
    const scale = jni.callStatic(env, "android/provider/Settings$Global", "getFloat", "(Landroid/content/ContentResolver;Ljava/lang/String;F)F", &.{ jni.ref(resolver), jni.ref(key), .{ .f = 1 } }) orelse 1;
    c.animations_off = scale == 0;
    return c;
}

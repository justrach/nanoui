//! The desktop's services on Android, through Java on the app's thread:
//! the clipboard (ClipboardManager), links opened in their apps (an
//! intent), the app's own folders, dark mode and the accent (the system's
//! palette, Android 12's Material You). Java is used from the app's
//! thread only: from another, these do nothing.
const std = @import("std");
const jni = @import("jni.zig");
const activity = @import("activity.zig");

/// The app's thread's Java, with the activity; null elsewhere.
fn java() ?struct { env: jni.Env, act: jni.Object } {
    const env = activity.env orelse return null;
    const a = activity.activity orelse return null;
    if (!activity.onAppThread()) return null;
    return .{ .env = env, .act = a.clazz };
}

fn service(env: jni.Env, act: jni.Object, name: []const u8) jni.Object {
    const n = jni.string(env, name);
    return jni.call(env, act, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", &.{jni.ref(n)}) orelse null;
}

pub const clipboard = struct {
    /// The clipboard's text, if it has any. Caller frees it.
    pub fn readText(gpa: std.mem.Allocator) !?[]u8 {
        const j = java() orelse return null;
        const frame = jni.Frame.push(j.env, 16);
        defer frame.pop();
        const cm = service(j.env, j.act, "clipboard");
        const clip = jni.call(j.env, cm, "getPrimaryClip", "()Landroid/content/ClipData;", &.{}) orelse return null;
        if (clip == null or (jni.call(j.env, clip, "getItemCount", "()I", &.{}) orelse 0) == 0) return null;
        const item = jni.call(j.env, clip, "getItemAt", "(I)Landroid/content/ClipData$Item;", &.{jni.int(0)}) orelse return null;
        const chars = jni.call(j.env, item, "coerceToText", "(Landroid/content/Context;)Ljava/lang/CharSequence;", &.{jni.ref(j.act)}) orelse return null;
        return try jni.toString(j.env, gpa, chars);
    }

    pub fn writeText(text: []const u8) void {
        const j = java() orelse return;
        const frame = jni.Frame.push(j.env, 16);
        defer frame.pop();
        const cm = service(j.env, j.act, "clipboard");
        const clip = jni.callStatic(j.env, "android/content/ClipData", "newPlainText", "(Ljava/lang/CharSequence;Ljava/lang/CharSequence;)Landroid/content/ClipData;", &.{
            jni.ref(jni.string(j.env, "text")), jni.ref(jni.string(j.env, text)),
        }) orelse return;
        _ = jni.call(j.env, cm, "setPrimaryClip", "(Landroid/content/ClipData;)V", &.{jni.ref(clip)});
    }

    /// Pictures and files on the clipboard: not read on Android yet.
    pub fn readImage(_: std.mem.Allocator) !?[]u8 {
        return null;
    }

    pub fn readFiles(_: std.mem.Allocator) !?[][]u8 {
        return null;
    }

    /// Android tells no count of the clipboard's changes.
    pub fn changeCount() isize {
        return 0;
    }
};

pub const shell = struct {
    /// Opens `url` in the app that takes it (the browser, mail); false if none does.
    pub fn openUrl(url: []const u8) bool {
        const j = java() orelse return false;
        const frame = jni.Frame.push(j.env, 16);
        defer frame.pop();
        const uri = jni.callStatic(j.env, "android/net/Uri", "parse", "(Ljava/lang/String;)Landroid/net/Uri;", &.{jni.ref(jni.string(j.env, url))}) orelse return false;
        const view = jni.string(j.env, "android.intent.action.VIEW");
        const intent = jni.new(j.env, "android/content/Intent", "(Ljava/lang/String;Landroid/net/Uri;)V", &.{ jni.ref(view), jni.ref(uri) });
        if (intent == null) return false;
        // FLAG_ACTIVITY_NEW_TASK
        _ = jni.call(j.env, intent, "addFlags", "(I)Landroid/content/Intent;", &.{jni.int(0x10000000)});
        // From the application, not the activity: an activity's own start
        // touches its views, which are Java's thread's.
        const ctx = jni.call(j.env, j.act, "getApplicationContext", "()Landroid/content/Context;", &.{}) orelse return false;
        // Throws when no app takes it (logged, and cleared).
        return jni.call(j.env, ctx, "startActivity", "(Landroid/content/Intent;)V", &.{jni.ref(intent)}) != null;
    }

    /// A file of the app's can't be handed to another app without a
    /// content provider, which nanoui's apps don't have.
    pub fn openPath(_: []const u8) bool {
        return false;
    }

    pub fn showInFolder(_: []const u8) void {}

    /// No trash on Android.
    pub fn trash(_: []const u8) bool {
        return false;
    }

    pub fn beep() void {}
};

pub const Directory = enum {
    /// The app's files/<app name>: settings, databases.
    data,
    /// The app's cache/<app name>: what can be made again.
    cache,
    /// The app's own folder.
    home,
    /// The app's folder on shared storage (Android/data/<id>/files),
    /// which a computer sees over USB.
    documents,
    downloads,
    desktop,
    temp,
};

/// The path of one of the app's folders; for `data` and `cache`, the
/// app's own, created if missing. Caller frees it.
pub fn path(gpa: std.mem.Allocator, dir: Directory, app_name: []const u8) ![]u8 {
    // The activity's, copied as it started (readable from any thread).
    const files = std.mem.sliceTo(&activity.files_dir, 0);
    if (files.len == 0) return error.NoSuchDirectory;
    switch (dir) {
        .home => return gpa.dupe(u8, std.fs.path.dirname(files) orelse files),
        .documents, .downloads, .desktop => return gpa.dupe(u8, std.mem.sliceTo(&activity.external_dir, 0)),
        .temp => if (std.c.getenv("TMPDIR")) |t| return gpa.dupe(u8, std.mem.span(t)),
        else => {},
    }
    const base = if (dir == .data) files else blk: {
        const parent = std.fs.path.dirname(files) orelse files;
        break :blk try std.fs.path.join(gpa, &.{ parent, "cache" });
    };
    defer if (dir != .data) gpa.free(base);
    if (dir == .temp) return gpa.dupe(u8, base);
    const full = try std.fs.path.join(gpa, &.{ base, app_name });
    errdefer gpa.free(full);
    std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), full) catch {};
    return full;
}

/// Whether the system shows dark mode.
pub fn isDark() bool {
    if (@import("app.zig").App.shared()) |app| return app.dark;
    return false;
}

/// The system's accent: Android 12's palette (Material You), from the
/// wallpaper; before, Android's blue.
pub fn accentColor() [3]f32 {
    const blue: [3]f32 = .{ 0.10, 0.45, 0.91 };
    const j = java() orelse return blue;
    const a = activity.activity orelse return blue;
    if (a.sdkVersion < 31) return blue;
    const frame = jni.Frame.push(j.env, 8);
    defer frame.pop();
    const id = jni.staticInt(j.env, "android/R$color", "system_accent1_500") orelse return blue;
    const res = jni.call(j.env, j.act, "getResources", "()Landroid/content/res/Resources;", &.{}) orelse return blue;
    const argb = jni.call(j.env, res, "getColor", "(ILandroid/content/res/Resources$Theme;)I", &.{ jni.int(id), jni.ref(null) }) orelse return blue;
    const c: u32 = @bitCast(argb);
    return .{
        @as(f32, @floatFromInt((c >> 16) & 0xff)) / 255,
        @as(f32, @floatFromInt((c >> 8) & 0xff)) / 255,
        @as(f32, @floatFromInt(c & 0xff)) / 255,
    };
}

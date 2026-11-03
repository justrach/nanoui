//! Dialogs on Android, with the desktop's calls: they return the user's
//! answer. A message is an AlertDialog, made and shown on Java's thread,
//! while the app's thread runs its loop until it's answered, as AppKit's
//! `runModal` does. Its buttons answer with messages to a Handler of the
//! app's thread, whose Java Looper nothing runs: they stay there for
//! `hasMessages` to find. The activity's window getting the focus back
//! as the dialog goes wakes the loop to look. Saving asks for a name in
//! an alert and answers a path in the app's documents folder, as on iOS.
//! There is no file picker yet: Android answers one in an activity's
//! result, which NativeActivity drops.
const std = @import("std");
const jni = @import("jni.zig");
const activity = @import("activity.zig");
const dialog_types = @import("../dialog_types.zig");
pub const OpenOptions = dialog_types.OpenOptions;
pub const SaveOptions = dialog_types.SaveOptions;
pub const MessageKind = dialog_types.MessageKind;
pub const MessageOptions = dialog_types.MessageOptions;
pub const MessageResult = dialog_types.MessageResult;
pub const freePaths = dialog_types.freePaths;

/// What a message's `what` says, from the request's own `base` (a dialog
/// asked for while another waits keeps apart): a button (0, 1, 2),
/// canceled (Back), or gone.
const canceled = 3;
const dismissed = 4;
const codes = 5;
/// AlertDialog's buttons: positive (the default), negative, neutral.
const which = [3]i32{ -1, -2, -3 };

const Request = struct {
    title: []const u8,
    detail: []const u8,
    buttons: []const []const u8,
    checkbox: []const u8 = "",
    /// Saving: the name the field starts with.
    field: ?[]const u8 = null,
    handler: jni.Object,
    /// Where its messages' codes start.
    base: i32 = 0,
    /// Set on Java's thread (global references).
    dialog: jni.Object = null,
    field_view: jni.Object = null,
    check_view: jni.Object = null,
    /// Java's thread ran the job asked for.
    done: std.atomic.Value(bool) = .init(false),
    /// What it read: the field's text, the checkbox.
    text: ?[]u8 = null,
    checked: bool = false,
};

/// The app's thread's Handler, on its Java Looper (made with the first
/// dialog, let go as the thread ends: `threadEnded`), and the next
/// request's codes.
var handler: jni.Object = null;
var next_base: i32 = 100;

fn handlerFor(env: jni.Env) jni.Object {
    if (handler != null) return handler;
    const frame = jni.Frame.push(env, 8);
    defer frame.pop();
    var looper = jni.callStatic(env, "android/os/Looper", "myLooper", "()Landroid/os/Looper;", &.{}) orelse null;
    if (looper == null) {
        _ = jni.callStatic(env, "android/os/Looper", "prepare", "()V", &.{});
        looper = jni.callStatic(env, "android/os/Looper", "myLooper", "()Landroid/os/Looper;", &.{}) orelse return null;
    }
    const h = jni.new(env, "android/os/Handler", "(Landroid/os/Looper;)V", &.{jni.ref(looper)});
    if (h == null) return null;
    handler = jni.newGlobal(env, h);
    return handler;
}

/// On the app's thread as it ends: its Handler goes, and its Java Looper,
/// which nothing ran, with it.
pub fn threadEnded(env: jni.Env) void {
    if (handler == null) return;
    jni.deleteGlobal(env, handler);
    handler = null;
    const frame = jni.Frame.push(env, 4);
    defer frame.pop();
    const looper = jni.callStatic(env, "android/os/Looper", "myLooper", "()Landroid/os/Looper;", &.{}) orelse return;
    _ = jni.call(env, looper, "quit", "()V", &.{});
}

/// Runs `job` on Java's thread and waits for it, the app's loop running;
/// false if the activity went first.
fn onJava(r: *Request, job: *const fn (?*anyopaque, jni.Env) void) bool {
    r.done.store(false, .release);
    if (!activity.onUiThread(r, job)) return false;
    activity.beginWait();
    while (!r.done.load(.acquire)) {
        if (activity.destroying) return false;
        activity.poll(-1);
    }
    return true;
}

/// Shows the request's dialog (on Java's thread).
fn show(ctx: ?*anyopaque, env: jni.Env) void {
    const r: *Request = @ptrCast(@alignCast(ctx.?));
    defer {
        r.done.store(true, .release);
        activity.wake();
    }
    const act = (activity.activity orelse return).clazz;
    const frame = jni.Frame.push(env, 32);
    defer frame.pop();
    const B = "Landroid/app/AlertDialog$Builder;";
    const builder = jni.new(env, "android/app/AlertDialog$Builder", "(Landroid/content/Context;)V", &.{jni.ref(act)});
    if (builder == null) return;
    _ = jni.call(env, builder, "setTitle", "(Ljava/lang/CharSequence;)" ++ B, &.{jni.ref(jni.string(env, r.title))});
    if (r.detail.len > 0) _ = jni.call(env, builder, "setMessage", "(Ljava/lang/CharSequence;)" ++ B, &.{jni.ref(jni.string(env, r.detail))});
    // A field (saving) or a checkbox under the message.
    var view: jni.Object = null;
    if (r.field) |name| {
        view = jni.new(env, "android/widget/EditText", "(Landroid/content/Context;)V", &.{jni.ref(act)});
        _ = jni.call(env, view, "setText", "(Ljava/lang/CharSequence;)V", &.{jni.ref(jni.string(env, name))});
        _ = jni.call(env, view, "setSingleLine", "(Z)V", &.{jni.boolean(true)});
        _ = jni.call(env, view, "selectAll", "()V", &.{});
        if (view != null) r.field_view = jni.newGlobal(env, view);
    } else if (r.checkbox.len > 0) {
        view = jni.new(env, "android/widget/CheckBox", "(Landroid/content/Context;)V", &.{jni.ref(act)});
        _ = jni.call(env, view, "setText", "(Ljava/lang/CharSequence;)V", &.{jni.ref(jni.string(env, r.checkbox))});
        if (view != null) r.check_view = jni.newGlobal(env, view);
    }
    const dialog = jni.call(env, builder, "create", "()Landroid/app/AlertDialog;", &.{}) orelse return;
    if (dialog == null) return;
    if (view != null) {
        // Inset as the message is: 20 points at the sides.
        const side: i32 = @divTrunc(20 * activity.ui_config.density, 160);
        const top: i32 = @divTrunc(8 * activity.ui_config.density, 160);
        _ = jni.call(env, dialog, "setView", "(Landroid/view/View;IIII)V", &.{ jni.ref(view), jni.int(side), jni.int(top), jni.int(side), jni.int(0) });
    }
    for (r.buttons, 0..) |label, i| {
        const msg = obtain(env, r.handler, r.base + @as(i32, @intCast(i))) orelse return;
        _ = jni.call(env, dialog, "setButton", "(ILjava/lang/CharSequence;Landroid/os/Message;)V", &.{ jni.int(which[i]), jni.ref(jni.string(env, label)), jni.ref(msg) });
    }
    _ = jni.call(env, dialog, "setCancelMessage", "(Landroid/os/Message;)V", &.{jni.ref(obtain(env, r.handler, r.base + canceled) orelse return)});
    _ = jni.call(env, dialog, "setDismissMessage", "(Landroid/os/Message;)V", &.{jni.ref(obtain(env, r.handler, r.base + dismissed) orelse return)});
    _ = jni.call(env, dialog, "setCanceledOnTouchOutside", "(Z)V", &.{jni.boolean(false)});
    if (jni.call(env, dialog, "show", "()V", &.{}) == null) return;
    r.dialog = jni.newGlobal(env, dialog);
    if (showing_len < showing.len) {
        showing[showing_len] = .{ .base = r.base, .dialog = jni.newGlobal(env, dialog) };
        showing_len += 1;
    }
}

/// The dialogs up, Java's thread's own references, by their requests'
/// codes: dismissed if the activity goes first (`dismissShowing`),
/// forgotten once answered (`forget`).
var showing: [8]struct { base: i32, dialog: jni.Object } = undefined;
var showing_len: usize = 0;

fn forget(ctx: ?*anyopaque, env: jni.Env) void {
    const base: i32 = @intCast(@intFromPtr(ctx));
    for (showing[0..showing_len], 0..) |d, i| if (d.base == base) {
        jni.deleteGlobal(env, d.dialog);
        showing[i] = showing[showing_len - 1];
        showing_len -= 1;
        return;
    };
}

/// On Java's thread, as the activity goes: its dialogs go before it.
pub fn dismissShowing(env: jni.Env) void {
    for (showing[0..showing_len]) |d| {
        _ = jni.call(env, d.dialog, "dismiss", "()V", &.{});
        jni.deleteGlobal(env, d.dialog);
    }
    showing_len = 0;
}

fn obtain(env: jni.Env, h: jni.Object, what: i32) ?jni.Object {
    return jni.callStatic(env, "android/os/Message", "obtain", "(Landroid/os/Handler;I)Landroid/os/Message;", &.{ jni.ref(h), jni.int(what) });
}

/// Reads the field's text and the checkbox (on Java's thread).
fn read(ctx: ?*anyopaque, env: jni.Env) void {
    const r: *Request = @ptrCast(@alignCast(ctx.?));
    defer {
        r.done.store(true, .release);
        activity.wake();
    }
    const frame = jni.Frame.push(env, 8);
    defer frame.pop();
    if (r.field_view != null) {
        const editable = jni.call(env, r.field_view, "getText", "()Landroid/text/Editable;", &.{}) orelse null;
        r.text = jni.toString(env, std.heap.c_allocator, editable) catch null;
    }
    if (r.check_view != null) r.checked = jni.call(env, r.check_view, "isChecked", "()Z", &.{}) orelse false;
}

/// Shows the request and waits for its answer: the button pressed, or
/// null if canceled (or not shown). Pair with `release`.
fn ask(r: *Request) ?usize {
    const env = activity.env orelse return null;
    if (!activity.onAppThread()) return null;
    r.handler = handlerFor(env);
    if (r.handler == null) return null;
    r.base = next_base;
    next_base = if (next_base > 1 << 30) 100 else next_base + 8;
    if (!onJava(r, show) or r.dialog == null) return null;
    while (true) {
        for (0..r.buttons.len) |i| if (has(env, r.handler, r.base + @as(i32, @intCast(i)))) return i;
        if (has(env, r.handler, r.base + canceled) or has(env, r.handler, r.base + dismissed)) return null;
        // The activity went, and its dialog with it.
        if (activity.destroying) return null;
        activity.beginWait();
        activity.poll(-1);
    }
}

fn has(env: jni.Env, h: jni.Object, what: i32) bool {
    return jni.call(env, h, "hasMessages", "(I)Z", &.{jni.int(what)}) orelse false;
}

/// Lets go of what the request made.
fn release(r: *Request) void {
    if (r.dialog != null) _ = activity.onUiThread(@ptrFromInt(@as(usize, @intCast(r.base))), forget);
    if (r.text) |t| std.heap.c_allocator.free(t);
    r.text = null;
    const env = activity.env orelse return;
    // Its own messages only: another request's may be waiting there.
    if (r.handler != null) for (0..codes) |i| {
        _ = jni.call(env, r.handler, "removeMessages", "(I)V", &.{jni.int(r.base + @as(i32, @intCast(i)))});
    };
    for ([_]*jni.Object{ &r.dialog, &r.field_view, &r.check_view }) |o| if (o.* != null) {
        jni.deleteGlobal(env, o.*);
        o.* = null;
    };
}

/// A message with buttons; the answer is the button pressed. The first
/// button is the default; an alert has three at most.
pub fn message(opts: MessageOptions) MessageResult {
    const labels: []const []const u8 = if (opts.buttons.len > 0) opts.buttons else &.{"OK"};
    if (labels.len > which.len) std.log.warn("nanoui: an Android alert has three buttons at most: {d} asked for", .{labels.len});
    const n = @min(labels.len, which.len);
    var r: Request = .{ .title = opts.title, .detail = opts.detail, .buttons = labels[0..n], .checkbox = opts.checkbox, .handler = null };
    defer release(&r);
    const answer = ask(&r);
    var checked = false;
    if (answer != null and r.check_view != null and onJava(&r, read)) checked = r.checked;
    // Canceled, or not shown: as a dialog closed without a choice.
    return .{ .button = answer orelse labels.len - 1, .checked = checked };
}

/// The paths the user chose: no file picker on Android yet (null, as
/// canceled). Free with `freePaths`.
pub fn open(gpa: std.mem.Allocator, opts: OpenOptions) !?[][]u8 {
    _ = gpa;
    _ = opts;
    std.log.warn("nanoui: no file picker on Android yet", .{});
    return null;
}

/// A path in the app's documents folder (or `directory`) named by the
/// user, or null if they canceled. Caller frees it.
pub fn save(gpa: std.mem.Allocator, opts: SaveOptions) !?[]u8 {
    const labels = [_][]const u8{ if (opts.button.len > 0) opts.button else "Save", "Cancel" };
    var r: Request = .{ .title = if (opts.title.len > 0) opts.title else "Save", .detail = opts.message, .buttons = &labels, .field = opts.name, .handler = null };
    defer release(&r);
    if (ask(&r) != 0 or !onJava(&r, read)) return null;
    const name = std.mem.trim(u8, r.text orelse return null, " ");
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    const dir = if (opts.directory.len > 0) try gpa.dupe(u8, opts.directory) else try @import("desktop.zig").path(gpa, .documents, "");
    defer gpa.free(dir);
    // The first extension allowed, when the name has none.
    const ext = if (opts.extensions.len > 0 and std.fs.path.extension(name).len == 0) opts.extensions[0] else "";
    const file = if (ext.len > 0) try std.fmt.allocPrint(gpa, "{s}.{s}", .{ name, ext }) else try gpa.dupe(u8, name);
    defer gpa.free(file);
    return try std.fs.path.join(gpa, &.{ dir, file });
}

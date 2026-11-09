//! The software keyboard. Android shows one only for a view that edits
//! text, which NativeActivity's isn't: a hidden EditText added to the
//! activity takes the focus while a nanoui field has it, and asks for the
//! keyboard. It is a real editor (`TYPE_CLASS_TEXT`), so input methods
//! compose into it — Chinese, Japanese, Korean, emoji, voice. Its text is
//! mirrored into the focused nanoui field, and the field's into it, from
//! `keys.syncText` each frame; the View calls it makes run on Java's
//! thread (`activity.onUiThread`), the compare and the ops on the app's.
const std = @import("std");
const jni = @import("jni.zig");
const activity = @import("activity.zig");

/// The EditText, a global reference, made once for the activity (and let
/// go with it, `release`).
var edit: jni.Object = null;

const c_alloc = std.heap.c_allocator;

/// Android's `InputType.TYPE_CLASS_TEXT`: a real text editor, so the
/// keyboard composes (pinyin, kana, hangul) instead of typing keys.
const TYPE_CLASS_TEXT: i32 = 0x0000_0001;

/// Text read off the EditText on Java's thread, waiting for the app's. A
/// single slot: a newer read replaces an older, unread one.
var read_text: ?[]u8 = null;
var read_ready: std.atomic.Value(bool) = .init(false);

/// A write of the app's field into the EditText, posted to Java's thread.
const Write = struct { text: []u8, caret: usize };

fn inputMethods(env: jni.Env, act: jni.Object) jni.Object {
    const name = jni.string(env, "input_method");
    return jni.call(env, act, "getSystemService", "(Ljava/lang/String;)Ljava/lang/Object;", &.{jni.ref(name)}) orelse null;
}

/// The keyboard up, for typing into the app's field.
pub fn show(_: ?*anyopaque, env: jni.Env) void {
    const a = activity.activity orelse return;
    const frame = jni.Frame.push(env, 16);
    defer frame.pop();
    if (edit == null) {
        const e = jni.new(env, "android/widget/EditText", "(Landroid/content/Context;)V", &.{jni.ref(a.clazz)});
        if (e == null) return;
        // A real text input type: the keyboard composes into the EditText,
        // and `syncText` mirrors that text into the nanoui field.
        _ = jni.call(env, e, "setInputType", "(I)V", &.{jni.int(TYPE_CLASS_TEXT)});
        _ = jni.call(env, e, "setFocusableInTouchMode", "(Z)V", &.{jni.boolean(true)});
        const params = jni.new(env, "android/view/ViewGroup$LayoutParams", "(II)V", &.{ jni.int(1), jni.int(1) });
        if (jni.call(env, a.clazz, "addContentView", "(Landroid/view/View;Landroid/view/ViewGroup$LayoutParams;)V", &.{ jni.ref(e), jni.ref(params) }) == null) return;
        edit = jni.newGlobal(env, e);
    }
    _ = jni.call(env, edit, "requestFocus", "()Z", &.{});
    _ = jni.call(env, inputMethods(env, a.clazz), "showSoftInput", "(Landroid/view/View;I)Z", &.{ jni.ref(edit), jni.int(0) });
}

/// The keyboard down; the activity's own view has the focus again.
pub fn hide(_: ?*anyopaque, env: jni.Env) void {
    const a = activity.activity orelse return;
    if (edit == null) return;
    const frame = jni.Frame.push(env, 8);
    defer frame.pop();
    const token = jni.call(env, edit, "getWindowToken", "()Landroid/os/IBinder;", &.{}) orelse return;
    _ = jni.call(env, inputMethods(env, a.clazz), "hideSoftInputFromWindow", "(Landroid/os/IBinder;I)Z", &.{ jni.ref(token), jni.int(0) });
    _ = jni.call(env, edit, "clearFocus", "()V", &.{});
}

/// The activity goes, with its view: the EditText is let go.
pub fn release(env: jni.Env) void {
    if (edit != null) jni.deleteGlobal(env, edit);
    edit = null;
    if (read_text) |t| c_alloc.free(t);
    read_text = null;
    read_ready.store(false, .release);
}

/// Asks Java's thread to read the EditText's text into `read_text`, for
/// the app's thread to take with `takeRead`. Ignored while one waits.
pub fn requestRead() void {
    if (read_ready.load(.acquire)) return;
    _ = activity.onUiThread(null, readJob);
}

fn readJob(_: ?*anyopaque, env: jni.Env) void {
    if (edit == null) return;
    const frame = jni.Frame.push(env, 16);
    defer frame.pop();
    const editable = jni.call(env, edit, "getText", "()Landroid/text/Editable;", &.{}) orelse return;
    defer jni.deleteLocal(env, editable);
    const text = committed(env, editable) orelse return;
    if (read_text) |old| c_alloc.free(old);
    read_text = text;
    read_ready.store(true, .release);
}

/// The EditText's text without the run the IME is still composing (the
/// pinyin letters): only committed text reaches the field, so tapping a
/// candidate shows the Chinese at once, not the pinyin it was typed as.
fn committed(env: jni.Env, editable: jni.Object) ?[]u8 {
    const len = jni.call(env, editable, "length", "()I", &.{}) orelse 0;
    const cs = composingEdge(env, editable, "getComposingSpanStart");
    const ce = composingEdge(env, editable, "getComposingSpanEnd");
    if (cs < 0 or ce <= cs or ce > len) return jni.toString(env, c_alloc, editable) catch null;
    const a = textOf(env, editable, 0, cs) orelse return null;
    defer c_alloc.free(a);
    const b = textOf(env, editable, ce, len) orelse return null;
    defer c_alloc.free(b);
    const out = c_alloc.alloc(u8, a.len + b.len) catch return null;
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

/// The IME's composing span on `editable`: a start or end offset (in the
/// Editable's own units), -1 when nothing is composing.
fn composingEdge(env: jni.Env, editable: jni.Object, name: [*:0]const u8) i32 {
    return jni.callStatic(env, "android/view/inputmethod/BaseInputConnection", name, "(Landroid/text/Spannable;)I", &.{jni.ref(editable)}) orelse -1;
}

/// `editable[a..b]`, as UTF-8 in `c_alloc`'s memory.
fn textOf(env: jni.Env, editable: jni.Object, a: i32, b: i32) ?[]u8 {
    const cs = jni.call(env, editable, "subSequence", "(II)Ljava/lang/CharSequence;", &.{ jni.int(a), jni.int(b) }) orelse return null;
    defer jni.deleteLocal(env, cs);
    return jni.toString(env, c_alloc, cs) catch null;
}

/// The EditText's text as last read, if a read has landed since the last
/// take. Caller frees it.
pub fn takeRead() ?[]u8 {
    if (!read_ready.swap(false, .acquire)) return null;
    const text = read_text;
    read_text = null;
    return text;
}

/// Whether a read has landed and not been taken.
pub fn readPending() bool {
    return read_ready.load(.acquire);
}

/// Has Java's thread put `text` into the EditText, with the caret at
/// `caret`. Runs on Java's thread, so a View is only touched there.
pub fn postWrite(text: []const u8, caret: usize) void {
    const w = c_alloc.create(Write) catch return;
    w.* = .{ .text = c_alloc.dupe(u8, text) catch {
        c_alloc.destroy(w);
        return;
    }, .caret = caret };
    if (!activity.onUiThread(w, writeJob)) {
        c_alloc.free(w.text);
        c_alloc.destroy(w);
    }
}

fn writeJob(ctx: ?*anyopaque, env: jni.Env) void {
    const w: *Write = @ptrCast(@alignCast(ctx.?));
    defer {
        c_alloc.free(w.text);
        c_alloc.destroy(w);
    }
    if (edit == null) return;
    const frame = jni.Frame.push(env, 8);
    defer frame.pop();
    const s = jni.string(env, w.text);
    _ = jni.call(env, edit, "setText", "(Ljava/lang/CharSequence;)V", &.{jni.ref(s)});
    jni.deleteLocal(env, s);
    const at: i32 = @intCast(@min(w.caret, w.text.len));
    _ = jni.call(env, edit, "setSelection", "(II)V", &.{ jni.int(at), jni.int(at) });
}

/// Forgets a waiting read (the keyboard is going, its text no longer
/// wanted).
pub fn dropRead() void {
    if (read_text) |t| c_alloc.free(t);
    read_text = null;
    read_ready.store(false, .release);
}

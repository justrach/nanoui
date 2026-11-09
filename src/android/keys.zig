//! Keys on Android: a hardware keyboard's, and the software keyboard's,
//! which comes up while a text field has the focus. NativeActivity's view
//! takes no text from input methods, so the software keyboard types as
//! key events, without composing (Latin letters, digits, symbols); Java's
//! KeyCharacterMap tells their characters. Combinations go to the menus'
//! accelerators and the view, as on Linux; Ctrl+C, X, V and A edit a
//! focused field. Back is the app's (`App.back`); the system's keys
//! (volume, power, media) stay the system's.
const std = @import("std");
const ndk = @import("ndk.zig");
const jni = @import("jni.zig");
const activity = @import("activity.zig");
const ime = @import("ime.zig");
const Event = @import("event.zig");
const ctx_mod = @import("../ui/context.zig");
const ui = @import("../ui/ui.zig");
const Key = @import("../ui/input.zig").Key;
const Surface = @import("surface.zig").Surface;

pub const State = struct {
    /// The text field the keyboard was brought up for (0: none).
    keyboard_for: u64 = 0,

    /// The text last known to be in the EditText (mirrored there from the
    /// field, or read back from it): the base the IME composed on. C heap,
    /// as the field's text may be long.
    mirror: std.ArrayList(u8) = .empty,
    have_mirror: bool = false,
    /// A read asked of the EditText but not yet taken, and the epoch it was
    /// asked at (a write bumps the epoch, so a read that ran before it is
    /// stale and dropped).
    read_in_flight: bool = false,
    read_epoch: u32 = 0,
    epoch: u32 = 0,
    /// Ops to give the focused field next frame (the IME's text), and the
    /// text they insert (owned, kept alive until the frame runs).
    sync_pending: bool = false,
    sync_ops: [2]ctx_mod.TextOp = undefined,
    sync_text: std.ArrayList(u8) = .empty,
    /// Reads only every other frame: a getText that often is enough.
    tick: u1 = 0,

    pub fn init(_: std.mem.Allocator) State {
        return .{};
    }

    pub fn deinit(s: *State, _: std.mem.Allocator) void {
        s.mirror.deinit(std.heap.c_allocator);
        s.sync_text.deinit(std.heap.c_allocator);
    }
};

const KEYCODE_BACK = 4;
const KEYCODE_UNKNOWN = 0;

/// The keys held, from an event's meta state. Control is the shortcuts'
/// key, as on Linux and Windows.
pub fn setModifiers(s: *Surface, meta: i32) void {
    const in = &s.ctx.input;
    in.shift = meta & ndk.META_SHIFT_ON != 0;
    in.ctrl = meta & ndk.META_CTRL_ON != 0;
    in.alt = meta & ndk.META_ALT_ON != 0;
    in.cmd = false;
}

/// Android's key codes of the keys that are not text.
fn keyOf(code: i32) ?Key {
    return switch (code) {
        67 => .backspace,
        112 => .delete,
        21 => .left,
        22 => .right,
        19 => .up,
        20 => .down,
        122 => .home,
        123 => .end,
        66, 160, 23 => .enter,
        61 => .tab,
        111 => .escape,
        92 => .page_up,
        93 => .page_down,
        131...142 => @fromBackingInt(@intCast(@backingInt(Key.f1) + @as(u8, @intCast(code - 131)))),
        else => null,
    };
}

/// Keys the system acts on: never the app's.
fn system(code: i32) bool {
    return switch (code) {
        3, 5, 6, 24, 25, 26, 27, 79, 80, 82, 84, 85...91, 126, 127, 164, 187, 219, 220, 221, 223, 224, 231 => true,
        else => false,
    };
}

/// Whether nanoui takes a key: the system's (volume, power, media) stay
/// the system's; Back is the app's (`App.back`).
pub fn takes(k: Event.Key) bool {
    return k.code == KEYCODE_BACK or !(system(k.code) or k.code == KEYCODE_UNKNOWN);
}

/// A key event for the surface, taken.
pub fn handle(s: *Surface, k: Event.Key) void {
    _ = s.enter();
    defer s.leave();
    setModifiers(s, k.meta);
    if (k.action != ndk.KEY_EVENT_ACTION_DOWN) return;
    if (k.code == KEYCODE_BACK) {
        if (k.repeat == 0) s.app.back();
        return;
    }
    _ = press(s, k.code, k.device, k.meta);
}

fn press(s: *Surface, code: i32, device: i32, meta: i32) bool {
    const in = &s.ctx.input;
    const ctrl = in.ctrl;
    const alt = in.alt;
    const key = keyOf(code);
    // Combinations go to the menus' accelerators, then the view.
    const special: ?u21 = if (key) |k| switch (k) {
        .up => ui.Shortcut.up,
        .down => ui.Shortcut.down,
        .left => ui.Shortcut.left,
        .right => ui.Shortcut.right,
        .tab => ui.Shortcut.tab,
        .escape => ui.Shortcut.escape,
        .enter => ui.Shortcut.enter,
        else => null,
    } else null;
    // The character without Control, Alt or Meta (either side's): the
    // key's own, for shortcuts.
    const cp = character(device, code, meta & ~@as(i32, ndk.META_CTRL_MASK | ndk.META_ALT_MASK | ndk.META_META_MASK)) orelse 0;
    const base: u21 = special orelse if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
    if (base != 0 and (ctrl or alt or (special != null and (base == ui.Shortcut.up or base == ui.Shortcut.down or base == ui.Shortcut.tab or base == ui.Shortcut.escape)))) {
        const sc: ui.Shortcut = .{ .key = base, .ctrl = ctrl, .alt = alt, .shift = in.shift };
        if (s.app.accelerator(sc)) return true;
        if (ctrl and s.ctx.focused_text != null and editShortcut(s, base)) return true;
        s.ctx.shortcut_taken = false;
        in.shortcut = sc;
        s.frame();
        if (s.dead) return true;
        in.shortcut = null;
        if (s.ctx.shortcut_taken) return true;
    }
    if (key) |k| {
        in.key = k;
        s.frame();
        return true;
    }
    if (ctrl or cp < 0x20 or cp == 0x7f) return false;
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return false;
    in.chars = buf[0..n];
    s.frame();
    if (!s.dead) in.chars = "";
    return true;
}

/// Escape for the view (Back): true if something took it. The shortcut
/// first (a menu, a sheet, a page closes), then the key: a text field with
/// the focus lets go of it.
pub fn escape(s: *Surface) bool {
    const in = &s.ctx.input;
    s.ctx.shortcut_taken = false;
    in.shortcut = .{ .key = ui.Shortcut.escape };
    s.frame();
    if (s.dead) return true;
    in.shortcut = null;
    if (s.ctx.shortcut_taken) return true;
    if (s.ctx.focused_text == null) return false;
    in.key = .escape;
    s.frame();
    return true;
}

/// Ctrl+C, X, V and A in a text field: copy, cut, paste, select all.
fn editShortcut(s: *Surface, key: u21) bool {
    const op: ctx_mod.TextOp = switch (key) {
        'c' => .{ .command = .copy },
        'x' => .{ .command = .cut },
        'a' => .{ .command = .select_all },
        'v' => {
            const pasted = @import("desktop.zig").clipboard.readText(s.gpa) catch return true;
            // No text: the view may take Ctrl+V for something else.
            const t = pasted orelse return false;
            defer s.gpa.free(t);
            for (t) |*ch| if (ch.* == '\n' or ch.* == '\r') {
                ch.* = ' ';
            };
            var ops = [1]ctx_mod.TextOp{.{ .insert = t }};
            s.ctx.input.ops = &ops;
            s.frame();
            if (!s.dead) s.ctx.input.ops = &.{};
            return true;
        },
        else => return false,
    };
    var ops = [1]ctx_mod.TextOp{op};
    s.ctx.input.ops = &ops;
    s.frame();
    if (!s.dead) s.ctx.input.ops = &.{};
    return true;
}

/// The character a key types with `meta`, from its device's key map
/// (Java's KeyCharacterMap); null for none, or a dead key's accent.
fn character(device: i32, code: i32, meta: i32) ?u21 {
    const env = activity.env orelse return null;
    const frame = jni.Frame.push(env, 8);
    defer frame.pop();
    const map = jni.callStatic(env, "android/view/KeyCharacterMap", "load", "(I)Landroid/view/KeyCharacterMap;", &.{jni.int(device)}) orelse return null;
    const c = jni.call(env, map, "get", "(II)I", &.{ jni.int(code), jni.int(meta) }) orelse return null;
    // COMBINING_ACCENT: a dead key, which composes; not taken.
    if (c <= 0 or c & @as(i32, @bitCast(@as(u32, 0x80000000))) != 0 or c > 0x10ffff) return null;
    return @intCast(c);
}

/// After a frame: a newly focused field brings up the software keyboard,
/// and it goes when no field has the focus.
pub fn syncFocus(s: *Surface) void {
    const want: u64 = if (s.ctx.focused_text) |f| f.id else 0;
    if (want == s.keys.keyboard_for) return;
    const had = s.keys.keyboard_for != 0;
    s.keys.keyboard_for = want;
    // A different field (or none): the mirror no longer describes it.
    s.keys.have_mirror = false;
    s.keys.read_in_flight = false;
    s.keys.sync_pending = false;
    ime.dropRead();
    if (want != 0 and !had) {
        _ = activity.onUiThread(null, ime.show);
    } else if (want == 0) {
        _ = activity.onUiThread(null, ime.hide);
    }
}

/// Keeps the hidden EditText and the focused nanoui field in step, so an
/// input method's composed text (Chinese, Japanese, Korean, emoji, voice)
/// reaches the field, and the field's own edits reach the IME. Runs on the
/// app's thread after a frame; the View reads and writes it posts run on
/// Java's. One direction a frame: read the IME's text, or push the field's.
pub fn syncText(s: *Surface) void {
    const c_alloc = std.heap.c_allocator;
    const st = &s.keys;
    if (st.keyboard_for == 0) return;
    const f = s.ctx.focused_text orelse return;
    st.tick +%= 1;

    // A read landed: the IME's text, if it changed the mirror.
    if (st.read_in_flight) {
        if (ime.takeRead()) |text| {
            defer c_alloc.free(text);
            st.read_in_flight = false;
            // A read asked before a write is stale: the write's text is
            // newer than what it saw.
            if (st.read_epoch == st.epoch and st.have_mirror and !std.mem.eql(u8, text, st.mirror.items)) {
                st.mirror.clearRetainingCapacity();
                st.mirror.appendSlice(c_alloc, text) catch {};
                st.have_mirror = true;
                // Hand it to the field next frame as a replace.
                st.sync_text.clearRetainingCapacity();
                st.sync_text.appendSlice(c_alloc, text) catch {};
                st.sync_ops[0] = .{ .command = .select_all };
                st.sync_ops[1] = .{ .insert = st.sync_text.items };
                st.sync_pending = true;
                s.app.wantFrame();
                return;
            }
        } else {
            return; // not landed yet
        }
    }

    // The field changed (typing, a paste): give the IME its new base.
    if (!st.have_mirror or !std.mem.eql(u8, f.text, st.mirror.items)) {
        st.mirror.clearRetainingCapacity();
        st.mirror.appendSlice(c_alloc, f.text) catch {};
        st.have_mirror = true;
        st.epoch +%= 1;
        ime.postWrite(f.text, f.caret);
        return;
    }

    // Ask the EditText for its text, one read at a time. Every frame: a
    // commit becomes the field within a frame or two, no visible lag.
    if (!st.read_in_flight and !st.sync_pending and !ime.readPending()) {
        st.read_epoch = st.epoch;
        st.read_in_flight = true;
        ime.requestRead();
    }
}

/// A tap: on a focused field whose keyboard went (Back took it down), the
/// keyboard comes back, as Android's own fields do.
pub fn tapped(s: *Surface) void {
    if (s.ctx.focused_text == null or activity.insets.keyboard > 0) return;
    _ = activity.onUiThread(null, ime.show);
}

/// The surface goes: its keyboard with it.
pub fn detach(s: *Surface) void {
    if (s.keys.keyboard_for == 0) return;
    s.keys.keyboard_for = 0;
    _ = activity.onUiThread(null, ime.hide);
}

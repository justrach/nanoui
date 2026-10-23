//! Vim's keys. The field starts in insert mode (^W ^U ^H edit there); Esc
//! goes to normal mode, where keys are commands:
//!
//!   motions    h l w W b B e E 0 ^ $ gg G, f F t T and ; , — with a count
//!   operators  d c y with a motion, a text object (iw aw i" a" i( a( i[ i{
//!              i<), or doubled for the line (dd cc yy) — 2dw, d3w, ci"
//!   commands   x X D C s S Y p P r ~ J u ^R, i a I A o O
//!   visual     v, then motions; d x y c s ~ u U r p, o to the other end
//!   history    j k step through the app's (`Result.history`) on the
//!              first and last lines
const std = @import("std");
const km = @import("keymap.zig");
const ctx_mod = @import("context.zig");
const tf = @import("textfield.zig");
const Context = ctx_mod.Context;
const EditState = ctx_mod.EditState;
const KeyState = @import("input.zig").KeyState;

pub fn handle(c: *Context, b: *tf.TextBuffer, e: *EditState, opts: tf.Options, r: *tf.Result) km.Took {
    const k = &e.keys;
    const sc = c.input.shortcut;
    const esc = if (sc) |x| x.key == ctx_mod.Shortcut.escape and !x.cmd and !x.ctrl else c.input.key == .escape;
    if (!k.vim_normal) return insert(c, b, e, opts, r, esc);
    if (k.vim_visual) e.caret = visualCaret(b.text(), e);
    defer if (k.vim_normal) settle(b.text(), e);
    // Esc in normal mode is the app's (stop what runs), unless it ends
    // visual mode or something waiting for its next key.
    if (esc) {
        if (!k.vim_visual and k.vim_op == 0 and k.vim_prefix == 0 and k.vim_count == 0) return .{};
        k.vim_visual = false;
        reset(k);
        if (sc != null) km.take(c);
        return .{ .key = true };
    }
    if (sc) |x| if (x.ctrl and !x.cmd and !x.alt and x.key == 'r') {
        for (0..count(k)) |_| km.undoStep(b, e, r, true);
        reset(k);
        km.take(c);
        return .{ .key = true };
    };
    // What is typed is commands.
    var typed: std.ArrayList(u8) = .empty;
    typed.appendSlice(c.alloc(), c.input.chars) catch {};
    for (c.input.ops) |op| if (op == .insert) typed.appendSlice(c.alloc(), op.insert) catch {};
    if (typed.items.len == 0) return .{};
    for (typed.items, 0..) |ch, i| {
        // A command that went to insert mode: the rest is typed.
        if (!k.vim_normal) {
            tf.apply(b, e, .{ .insert = typed.items[i..] }, opts, c.clipboard, r);
            break;
        }
        command(c, b, e, opts, r, ch);
        if (k.vim_normal and !k.vim_visual) clampCaret(b.text(), e);
    }
    c.changed = true;
    return .{ .text = true };
}

fn insert(c: *Context, b: *tf.TextBuffer, e: *EditState, opts: tf.Options, r: *tf.Result, esc: bool) km.Took {
    const k = &e.keys;
    if (esc) {
        // Insert → normal, the caret back onto the last character typed.
        k.vim_normal = true;
        reset(k);
        e.undo.group = false;
        if (e.caret > km.lineStart(b.text(), e.caret)) km.run(c, b, e, opts, r, .move_left);
        e.anchor = e.caret;
        if (c.input.shortcut != null) km.take(c);
        c.changed = true;
        return .{ .key = true };
    }
    const sc = c.input.shortcut orelse return .{};
    if (!sc.ctrl or sc.cmd or sc.alt) return .{};
    const s = b.text();
    switch (sc.key) {
        'w' => km.replace(b, e, km.wordStart(s, e.caret), e.caret, "", km.wordStart(s, e.caret), r),
        'u' => km.replace(b, e, km.lineStart(s, e.caret), e.caret, "", km.lineStart(s, e.caret), r),
        'h' => km.run(c, b, e, opts, r, .delete_backward),
        else => return .{},
    }
    km.take(c);
    return .{ .key = true };
}

fn reset(k: *KeyState) void {
    k.vim_count = 0;
    k.vim_op = 0;
    k.vim_op_count = 0;
    k.vim_prefix = 0;
}

fn count(k: *const KeyState) usize {
    return @as(usize, @max(1, k.vim_count)) * @max(1, k.vim_op_count);
}

fn nextChar(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + 1;
    while (j < s.len and (s[j] & 0xc0) == 0x80) j += 1;
    return j;
}

fn prevChar(s: []const u8, i: usize) usize {
    if (i == 0) return 0;
    var j = i - 1;
    while (j > 0 and (s[j] & 0xc0) == 0x80) j -= 1;
    return j;
}

/// The last character of the caret's line (its start when empty).
fn lastOnLine(s: []const u8, i: usize) usize {
    const ls = km.lineStart(s, i);
    const le = km.lineEnd(s, i);
    return if (le > ls) prevChar(s, le) else ls;
}

/// In normal mode the caret is on a character, never past its line's last.
fn clampCaret(s: []const u8, e: *EditState) void {
    e.caret = @min(e.caret, lastOnLine(s, e.caret));
    e.anchor = e.caret;
}

/// Visual mode's caret from what is drawn: the selection includes the
/// character under the caret, so it is drawn one past it.
fn visualCaret(s: []const u8, e: *const EditState) usize {
    return if (e.caret > e.anchor) prevChar(s, e.caret) else e.caret;
}

/// After the event: visual mode's selection drawn from where it began to
/// the caret, both characters included.
fn settle(s: []const u8, e: *EditState) void {
    const k = &e.keys;
    if (!k.vim_visual) return;
    const at = @min(e.caret, s.len);
    const from = @min(k.vim_anchor, s.len);
    if (at >= from) {
        e.anchor = from;
        e.caret = nextChar(s, at);
    } else {
        e.anchor = nextChar(s, from);
        e.caret = at;
    }
}

const Motion = struct { to: usize, inclusive: bool = false };

/// Where motion `ch` goes from the caret, `n` times.
fn motion(s: []const u8, e: *const EditState, ch: u8, n: usize) ?Motion {
    const k = &e.keys;
    const at = e.caret;
    var to = at;
    switch (ch) {
        'h' => for (0..n) |_| {
            if (to > km.lineStart(s, at)) to = prevChar(s, to);
        },
        'l' => {
            const limit = if (k.vim_op != 0) km.lineEnd(s, at) else lastOnLine(s, at);
            for (0..n) |_| to = @min(nextChar(s, to), limit);
        },
        'w', 'W' => {
            // cw is ce on a word, as Vim has it.
            if (k.vim_op == 'c' and at < s.len and !km.blank(s[at])) return motion(s, e, if (ch == 'w') 'e' else 'E', n);
            for (0..n) |_| to = km.nextStart(s, to, ch == 'W');
            if (k.vim_op == 0) to = @min(to, s.len -| 1);
        },
        'e', 'E' => {
            for (0..n) |_| to = km.endOf(s, to, ch == 'E');
            return .{ .to = to, .inclusive = true };
        },
        'b', 'B' => for (0..n) |_| {
            to = km.prevStart(s, to, ch == 'B');
        },
        '0' => to = km.lineStart(s, at),
        '^' => to = km.firstNonBlank(s, at),
        '$' => return .{ .to = lastOnLine(s, at), .inclusive = km.lineEnd(s, at) > km.lineStart(s, at) },
        'G' => return .{ .to = s.len -| 1, .inclusive = s.len > 0 },
        ';', ',' => {
            if (k.vim_find[0] == 0) return null;
            var kind = k.vim_find[0];
            if (ch == ',') kind = switch (kind) {
                'f' => 'F',
                'F' => 'f',
                't' => 'T',
                else => 't',
            };
            return find(s, at, kind, k.vim_find[1], n, true);
        },
        else => return null,
    }
    return .{ .to = to };
}

/// f F t T: the `n`th `target` on the line, forward or back.
fn find(s: []const u8, at: usize, kind: u8, target: u8, n: usize, repeat: bool) ?Motion {
    const ls = km.lineStart(s, at);
    const le = km.lineEnd(s, at);
    var j = at;
    var left = n;
    if (kind == 'f' or kind == 't') {
        // ; after t starts past the character it stopped before.
        if (repeat and kind == 't' and j + 1 < le and s[j + 1] == target) j += 1;
        while (j + 1 < le) {
            j += 1;
            if (s[j] == target) {
                left -= 1;
                if (left == 0) return .{ .to = if (kind == 't') j - 1 else j, .inclusive = true };
            }
        }
    } else {
        if (repeat and kind == 'T' and j > ls + 1 and s[j - 1] == target) j -= 1;
        while (j > ls) {
            j -= 1;
            if (s[j] == target) {
                left -= 1;
                if (left == 0) return .{ .to = if (kind == 'T') j + 1 else j };
            }
        }
    }
    return null;
}

/// A motion done: moves the caret, or is what the operator acts on.
fn moved(c: *Context, b: *tf.TextBuffer, e: *EditState, r: *tf.Result, m: Motion) void {
    const k = &e.keys;
    const s = b.text();
    if (k.vim_op != 0) {
        const at = e.caret;
        const end = if (m.inclusive) @min(nextChar(s, m.to), s.len) else m.to;
        if (m.to >= at) operate(c, b, e, r, at, end) else operate(c, b, e, r, m.to, at);
        return;
    }
    e.caret = m.to;
    reset(k);
}

/// d c y on [from, to).
fn operate(c: *Context, b: *tf.TextBuffer, e: *EditState, r: *tf.Result, from: usize, to: usize) void {
    _ = c;
    const k = &e.keys;
    const op = k.vim_op;
    reset(k);
    switch (op) {
        'y' => {
            if (to > from) km.keep(e, b.text()[from..to], false, false);
            e.caret = from;
        },
        'c' => {
            km.kill(b, e, from, to, r, false);
            toInsert(e);
        },
        else => km.kill(b, e, from, to, r, false),
    }
    k.last_kill = false;
}

fn toInsert(e: *EditState) void {
    e.keys.vim_normal = false;
    e.keys.vim_visual = false;
    e.anchor = e.caret;
    e.undo.join();
}

/// The caret's line and the `n - 1` after it: [start, end), with its
/// newline when `newline` (dd), else without (cc).
fn lines(s: []const u8, at: usize, n: usize, newline: bool) [2]usize {
    const from = km.lineStart(s, at);
    var to = km.lineEnd(s, at);
    for (1..n) |_| if (to < s.len) {
        to = km.lineEnd(s, to + 1);
    };
    if (!newline) return .{ from, to };
    if (to < s.len) return .{ from, to + 1 };
    // The last line: the newline before it.
    return .{ if (from > 0) from - 1 else from, to };
}

fn command(c: *Context, b: *tf.TextBuffer, e: *EditState, opts: tf.Options, r: *tf.Result, ch: u8) void {
    const k = &e.keys;
    const s = b.text();
    // A key waiting for this one: f F t T r g, or i a after an operator.
    if (k.vim_prefix != 0) {
        const p = k.vim_prefix;
        k.vim_prefix = 0;
        return prefixed(c, b, e, r, p, ch);
    }
    if ((ch >= '1' and ch <= '9') or (ch == '0' and k.vim_count > 0)) {
        k.vim_count = @min(9999, k.vim_count * 10 + (ch - '0'));
        return;
    }
    const n = count(k);
    if (k.vim_visual) return visual(c, b, e, opts, r, ch, n);
    // An operator doubled: the line (dd cc yy), `n` of them.
    if (k.vim_op != 0 and ch == k.vim_op) {
        const range = lines(s, e.caret, n, k.vim_op == 'd');
        return operate(c, b, e, r, range[0], range[1]);
    }
    if (k.vim_op != 0 and (ch == 'i' or ch == 'a')) {
        k.vim_prefix = ch;
        return;
    }
    if (motion(s, e, ch, n)) |m| return moved(c, b, e, r, m);
    switch (ch) {
        'f', 'F', 't', 'T', 'g' => return {
            k.vim_prefix = ch;
        },
        'r' => if (k.vim_op == 0) {
            k.vim_prefix = ch;
            return;
        },
        'd', 'c', 'y' => if (k.vim_op == 0) {
            k.vim_op = ch;
            k.vim_op_count = k.vim_count;
            k.vim_count = 0;
            return;
        },
        else => {},
    }
    // An operator and something that isn't a motion: nothing.
    if (k.vim_op != 0) return reset(k);
    reset(k);
    const at = e.caret;
    const ls = km.lineStart(s, at);
    const le = km.lineEnd(s, at);
    switch (ch) {
        'x' => {
            var to = at;
            for (0..n) |_| to = @min(nextChar(s, to), le);
            km.kill(b, e, at, to, r, false);
        },
        'X' => {
            var from = at;
            for (0..n) |_| from = @max(prevChar(s, from), ls);
            if (from < at) km.kill(b, e, from, at, r, false);
        },
        'D' => km.kill(b, e, at, le, r, false),
        'C' => {
            km.kill(b, e, at, le, r, false);
            toInsert(e);
        },
        's' => {
            var to = at;
            for (0..n) |_| to = @min(nextChar(s, to), le);
            km.kill(b, e, at, to, r, false);
            toInsert(e);
        },
        'S' => {
            km.kill(b, e, ls, le, r, false);
            toInsert(e);
        },
        'Y' => {
            const range = lines(s, at, n, false);
            km.keep(e, s[range[0]..range[1]], false, false);
        },
        'p', 'P' => {
            const where = if (ch == 'p' and le > ls) nextChar(s, at) else at;
            k.yanked = null;
            for (0..n) |_| km.put(b, e, if (k.yanked) |y| y[1] else where, 0, r);
            k.yanked = null;
            e.caret = prevChar(b.text(), e.caret);
        },
        '~' => {
            var j = at;
            for (0..n) |_| if (j < le) {
                b.buf.items[j] = flipCase(b.buf.items[j]);
                j = nextChar(s, j);
            };
            e.caret = j;
            r.changed = true;
        },
        'J' => if (le < s.len) {
            var to = le + 1;
            while (to < s.len and (s[to] == ' ' or s[to] == '\t')) to += 1;
            km.replace(b, e, le, to, " ", le, r);
        },
        'u' => for (0..n) |_| km.undoStep(b, e, r, false),
        'i' => toInsert(e),
        'a' => {
            if (le > ls) e.caret = nextChar(s, at);
            toInsert(e);
        },
        'I' => {
            e.caret = km.firstNonBlank(s, at);
            toInsert(e);
        },
        'A' => {
            e.caret = le;
            toInsert(e);
        },
        'o', 'O' => {
            const where = if (ch == 'o') le else ls;
            km.replace(b, e, where, where, "\n", if (ch == 'o') where + 1 else where, r);
            toInsert(e);
        },
        'v' => {
            k.vim_visual = true;
            k.vim_anchor = at;
        },
        // On the first or last line: the app's history; else a line up or down.
        'k' => if (ls == 0) {
            r.history = -1;
        } else {
            const above = km.lineStart(s, ls - 1);
            e.caret = @min(above + (at - ls), ls - 1);
        },
        'j' => if (le >= s.len) {
            r.history = 1;
        } else {
            const below_end = km.lineEnd(s, le + 1);
            e.caret = @min(le + 1 + (at - ls), below_end);
        },
        else => {},
    }
}

fn flipCase(ch: u8) u8 {
    return if (std.ascii.isUpper(ch)) std.ascii.toLower(ch) else std.ascii.toUpper(ch);
}

/// The key after f F t T r g, or after i a (an operator's or visual
/// mode's text object).
fn prefixed(c: *Context, b: *tf.TextBuffer, e: *EditState, r: *tf.Result, p: u8, ch: u8) void {
    const k = &e.keys;
    const s = b.text();
    const n = count(k);
    switch (p) {
        'f', 'F', 't', 'T' => {
            k.vim_find = .{ p, ch };
            if (find(s, e.caret, p, ch, n, false)) |m| return moved(c, b, e, r, m);
            reset(k);
        },
        'g' => if (ch == 'g') moved(c, b, e, r, .{ .to = 0 }) else reset(k),
        'r' => {
            if (k.vim_visual) {
                const sel = selection(s, e);
                @memset(b.buf.items[sel[0]..sel[1]], ch);
                k.vim_visual = false;
                e.caret = sel[0];
            } else {
                // `n` characters, if the line has them.
                const le = km.lineEnd(s, e.caret);
                if (e.caret + n <= le) @memset(b.buf.items[e.caret .. e.caret + n], ch);
                e.caret = @min(e.caret + n -| 1, le -| 1);
            }
            r.changed = true;
            reset(k);
        },
        'i', 'a' => {
            const range = km.object(s, e.caret, p == 'i', ch) orelse return reset(k);
            if (k.vim_visual) {
                k.vim_anchor = range[0];
                e.caret = prevChar(s, range[1]);
                reset(k);
            } else operate(c, b, e, r, range[0], range[1]);
        },
        else => reset(k),
    }
}

/// Visual mode's selection: [start, end), both ends' characters included.
fn selection(s: []const u8, e: *const EditState) [2]usize {
    const a = @min(e.keys.vim_anchor, s.len);
    const at = @min(e.caret, s.len);
    return .{ @min(a, at), @min(nextChar(s, @max(a, at)), s.len) };
}

fn visual(c: *Context, b: *tf.TextBuffer, e: *EditState, opts: tf.Options, r: *tf.Result, ch: u8, n: usize) void {
    _ = opts;
    const k = &e.keys;
    const s = b.text();
    if (motion(s, e, ch, n)) |m| {
        e.caret = m.to;
        reset(k);
        return;
    }
    const sel = selection(s, e);
    reset(k);
    switch (ch) {
        'f', 'F', 't', 'T', 'g', 'r', 'i', 'a' => k.vim_prefix = ch,
        'o' => {
            const at = e.caret;
            e.caret = k.vim_anchor;
            k.vim_anchor = at;
        },
        'v' => k.vim_visual = false,
        'd', 'x', 'D', 'X' => {
            k.vim_visual = false;
            km.kill(b, e, sel[0], sel[1], r, false);
        },
        'y', 'Y' => {
            k.vim_visual = false;
            km.keep(e, s[sel[0]..sel[1]], false, false);
            e.caret = sel[0];
        },
        'c', 's' => {
            km.kill(b, e, sel[0], sel[1], r, false);
            toInsert(e);
        },
        'p', 'P' => {
            // The selection swapped for what was put away (which then holds it).
            k.vim_visual = false;
            if (k.ring_count == 0) return;
            var keep: [256]u8 = undefined;
            const n_ = @min(k.ring_len[0], keep.len);
            @memcpy(keep[0..n_], k.ring[0][0..n_]);
            km.kill(b, e, sel[0], sel[1], r, false);
            const ins = b.insert(sel[0], keep[0..n_]);
            e.caret = sel[0] + ins -| 1;
        },
        '~', 'u', 'U' => {
            for (b.buf.items[sel[0]..sel[1]]) |*x| x.* = switch (ch) {
                'u' => std.ascii.toLower(x.*),
                'U' => std.ascii.toUpper(x.*),
                else => flipCase(x.*),
            };
            k.vim_visual = false;
            e.caret = sel[0];
            r.changed = true;
        },
        else => {},
    }
    k.last_kill = false;
    _ = c;
}

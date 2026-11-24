//! Picker behaviour without presentation: a highlight that follows stable
//! row ids, row identity across filtering, an input-method guard for the
//! query field, and the four keys a picker answers. The caller draws the
//! field and rows, owns its results and decides what each intent does.
//!
//!     const frame = s.composition.begin(c);
//!     if (frame.quiet()) if (kit.picker.keys(c, .{ .consume = true })) |intent| switch (intent) {
//!         .next => _ = kit.picker.step(&s.active, ids, .next, .wrap),
//!         .previous => _ = kit.picker.step(&s.active, ids, .previous, .wrap),
//!         .activate => run(s.active),
//!         .dismiss => close(),
//!     };
//!     const field = ui.textField(c, &s.query, .{});
//!     _ = s.composition.end(c, &s.query);
//!     _ = kit.picker.reconcile(&s.active, ids, .first);
//!     for (ids) |id| {
//!         kit.picker.rowKey(c, revision, id);
//!         // draw the row
//!     }
//!
//! There is no result-revision check here on purpose: whoever produces
//! results owns staleness (a request generation, a ticket, a controller
//! such as a search library's) and should not offer rows that are stale.
//! Nothing here allocates or keeps a pointer between calls.
const std = @import("std");
const ui = @import("../ui/ui.zig");

/// A row's identity, chosen by the caller and stable across filtering and
/// reorder. Unique within one call; hash string ids with a per-source prefix.
pub const Id = u64;

/// The most rows one call takes. Larger lists page or virtualize.
pub const max_rows = 4096;

pub const Step = enum { next, previous };

/// At an end of the list: go round to the other end, or stay.
pub const Edge = enum { wrap, clamp };

/// Where the highlight goes when its row is gone.
pub const Fallback = union(enum) {
    first,
    /// This row position, clamped to the new length.
    position: usize,
};

fn check(ids: []const Id) void {
    std.debug.assert(ids.len <= max_rows);
    if (std.debug.runtime_safety and ids.len <= 256) {
        for (ids, 0..) |a, i| for (ids[i + 1 ..]) |b| std.debug.assert(a != b);
    }
}

/// The position of `active` in `ids`.
pub fn indexOf(active: ?Id, ids: []const Id) ?usize {
    return std.mem.indexOfScalar(Id, ids, active orelse return null);
}

/// Moves the highlight one row. A null or vanished `active` counts as the
/// first row, so `next` from nothing lands on the second. Returns true when
/// the highlight changed.
pub fn step(active: *?Id, ids: []const Id, direction: Step, edge: Edge) bool {
    check(ids);
    if (ids.len == 0) {
        const had = active.* != null;
        active.* = null;
        return had;
    }
    const at = indexOf(active.*, ids) orelse 0;
    const last = ids.len - 1;
    const to: usize = switch (direction) {
        .next => if (at < last) at + 1 else switch (edge) {
            .wrap => 0,
            .clamp => last,
        },
        .previous => if (at > 0) at - 1 else switch (edge) {
            .wrap => last,
            .clamp => 0,
        },
    };
    const before = active.*;
    active.* = ids[to];
    return before != active.*;
}

/// Keeps the highlight on a row in `ids`: unchanged while its row is
/// present, else `fallback`; null when there are no rows. Idempotent, so
/// it can run every frame. Returns true when the highlight changed.
pub fn reconcile(active: *?Id, ids: []const Id, fallback: Fallback) bool {
    check(ids);
    const before = active.*;
    if (ids.len == 0) {
        active.* = null;
    } else if (indexOf(active.*, ids) == null) {
        active.* = switch (fallback) {
            .first => ids[0],
            .position => |p| ids[@min(p, ids.len - 1)],
        };
    }
    return before != active.*;
}

/// Keys the next box by `revision` and `id`, so its hover, motion and
/// scroll state follow the row rather than its position.
pub fn rowKey(c: *ui.Context, revision: u64, id: Id) void {
    ui.key(c, c.print("picker-row:{x}:{x}", .{ revision, id }));
}

/// Input-method state for one query field. Text being composed belongs to
/// the input method: the keys that commit or cancel it are not picker keys.
pub const Composition = struct {
    active: bool = false,

    pub const Change = enum { none, started, ended };

    /// What this frame's input holds, read before the field is drawn.
    pub const Frame = struct {
        /// Composing as the previous frame ended.
        was_active: bool,
        /// Typing, composing or committing text arrives in this frame.
        text_op: bool,
        /// Composition starts, changes or ends in this frame.
        marking: bool,

        /// No text input in play: picker keys may act.
        pub fn quiet(f: Frame) bool {
            return !f.was_active and !f.text_op;
        }

        /// Composition is under way or changing; plain typing is not.
        pub fn composing(f: Frame) bool {
            return f.was_active or f.marking;
        }
    };

    /// Before drawing the field.
    pub fn begin(s: *const Composition, c: *const ui.Context) Frame {
        var f: Frame = .{ .was_active = s.active, .text_op = false, .marking = false };
        for (c.input.ops) |op| switch (op) {
            .insert => f.text_op = true,
            .set_marked, .unmark => {
                f.text_op = true;
                f.marking = true;
            },
            else => {},
        };
        return f;
    }

    /// After drawing the field: whether `query` holds marked text now.
    pub fn end(s: *Composition, c: *const ui.Context, query: *const ui.TextBuffer) Change {
        const now = if (c.edits.get(query.last_id)) |edit| edit.marked != null else false;
        defer s.active = now;
        if (now == s.active) return .none;
        return if (now) .started else .ended;
    }
};

pub const Intent = enum { next, previous, activate, dismiss };

pub const KeyOptions = struct {
    /// Return reads as `activate` (off when the field's submit does it).
    activate: bool = true,
    /// Escape reads as `dismiss`.
    dismiss: bool = true,
    /// Also read AppKit's editing commands: move up/down, cancel, newline.
    commands: bool = true,
    /// Take the key, so the text field and widgets after the picker do not
    /// also act on it. Off by default: the caller opts in.
    consume: bool = false,
};

fn ofShortcut(key: u21, opts: KeyOptions) ?Intent {
    return switch (key) {
        ui.Shortcut.down => .next,
        ui.Shortcut.up => .previous,
        ui.Shortcut.enter => if (opts.activate) .activate else null,
        ui.Shortcut.escape => if (opts.dismiss) .dismiss else null,
        else => null,
    };
}

fn ofCommand(command: ui.Command, opts: KeyOptions) ?Intent {
    return switch (command) {
        .move_down => .next,
        .move_up => .previous,
        .insert_newline => if (opts.activate) .activate else null,
        .cancel => if (opts.dismiss) .dismiss else null,
        else => null,
    };
}

/// The picker intent in this frame's input, from an unmodified Up, Down,
/// Return or Escape offered as a shortcut, a key, or an editing command.
/// Skip it while `Composition.Frame.quiet` is false.
pub fn keys(c: *ui.Context, opts: KeyOptions) ?Intent {
    if (c.input.shortcut) |s| {
        const plain: ui.Shortcut = .{ .key = s.key };
        if (std.meta.eql(s.native(), plain.native())) if (ofShortcut(s.key, opts)) |intent| {
            if (opts.consume) std.debug.assert(c.shortcut(plain));
            return intent;
        };
    }
    if (c.input.key) |k| {
        const intent: ?Intent = switch (k) {
            .down => .next,
            .up => .previous,
            .enter => if (opts.activate) .activate else null,
            .escape => if (opts.dismiss) .dismiss else null,
            else => null,
        };
        if (intent) |found| {
            if (opts.consume) c.input.key = null;
            return found;
        }
    }
    if (!opts.commands) return null;
    for (c.input.ops, 0..) |op, i| {
        if (op != .command) continue;
        const intent = ofCommand(op.command, opts) orelse continue;
        if (opts.consume) {
            const rest = c.alloc().alloc(ui.TextOp, c.input.ops.len - 1) catch {
                c.input.ops = &.{};
                return intent;
            };
            @memcpy(rest[0..i], c.input.ops[0..i]);
            @memcpy(rest[i..], c.input.ops[i + 1 ..]);
            c.input.ops = rest;
        }
        return intent;
    }
    return null;
}

const testing = std.testing;

test "step wraps or clamps, and an absent highlight counts as the first row" {
    const ids = [_]Id{ 30, 10, 20 };
    var active: ?Id = null;
    try testing.expect(step(&active, &ids, .next, .wrap));
    try testing.expectEqual(@as(?Id, 10), active);
    _ = step(&active, &ids, .next, .wrap);
    _ = step(&active, &ids, .next, .wrap);
    try testing.expectEqual(@as(?Id, 30), active);
    _ = step(&active, &ids, .previous, .wrap);
    try testing.expectEqual(@as(?Id, 20), active);
    active = 30;
    try testing.expect(!step(&active, &ids, .previous, .clamp));
    try testing.expectEqual(@as(?Id, 30), active);
    active = 20;
    try testing.expect(!step(&active, &ids, .next, .clamp));
    active = 99;
    _ = step(&active, &ids, .previous, .wrap);
    try testing.expectEqual(@as(?Id, 20), active);
    try testing.expect(step(&active, &.{}, .next, .wrap));
    try testing.expectEqual(@as(?Id, null), active);
}

test "reconcile keeps a surviving row and falls back when it is gone" {
    var active: ?Id = 20;
    try testing.expect(!reconcile(&active, &.{ 5, 20, 7 }, .first));
    try testing.expectEqual(@as(?Id, 20), active);
    try testing.expect(reconcile(&active, &.{ 5, 7 }, .first));
    try testing.expectEqual(@as(?Id, 5), active);
    active = 99;
    _ = reconcile(&active, &.{ 1, 2, 3 }, .{ .position = 1 });
    try testing.expectEqual(@as(?Id, 2), active);
    active = 99;
    _ = reconcile(&active, &.{ 1, 2 }, .{ .position = 8 });
    try testing.expectEqual(@as(?Id, 2), active);
    _ = reconcile(&active, &.{}, .first);
    try testing.expectEqual(@as(?Id, null), active);
    try testing.expectEqual(@as(?usize, 1), indexOf(2, &.{ 1, 2 }));
    try testing.expectEqual(@as(?usize, null), indexOf(null, &.{ 1, 2 }));
}

/// A whole picker on the helpers: fixture rows filtered by substring, a
/// provider that answers late, a disabled row, and a trigger focus returns to.
const Fixture = struct {
    const Row = struct { id: Id, label: []const u8, enabled: bool = true };
    const rows = [_]Row{
        .{ .id = 11, .label = "Art history" },
        .{ .id = 12, .label = "Café notebooks" },
        .{ .id = 13, .label = "Design references", .enabled = false },
        .{ .id = 14, .label = "日本語の資料" },
        .{ .id = 15, .label = "Music scores" },
        .{ .id = 16, .label = "Notebook archive" },
    };

    open: bool = false,
    trigger: u64 = 0,
    query: ui.TextBuffer = .{},
    composition: Composition = .{},
    active: ?Id = null,
    chosen: ?Id = null,
    /// The provider: the query it was last asked, and when its answer lands.
    asked: u64 = 0,
    answered: u64 = 0,
    delay: u32 = 0,
    wait: u32 = 0,
    ids: [rows.len]Id = undefined,
    count: usize = 0,

    fn deinit(f: *Fixture) void {
        f.query.deinit();
    }

    fn row(id: Id) Row {
        for (rows) |r| if (r.id == id) return r;
        unreachable;
    }

    fn ask(f: *Fixture) void {
        f.asked += 1;
        f.wait = f.delay;
        if (f.wait == 0) f.answer();
    }

    /// Publishes for the latest question only; an older answer never lands.
    fn answer(f: *Fixture) void {
        f.answered = f.asked;
        f.count = 0;
        for (rows) |r| if (std.mem.indexOf(u8, r.label, f.query.text()) != null) {
            f.ids[f.count] = r.id;
            f.count += 1;
        };
    }

    fn current(f: *const Fixture) bool {
        return f.answered == f.asked;
    }

    fn close(f: *Fixture, c: *ui.Context) void {
        f.open = false;
        c.focus = f.trigger;
        c.changed = true;
    }

    fn view(f: *Fixture, c: *ui.Context) void {
        const column = ui.div(c).column().wFull().p(12).gap(6);
        defer column.end();
        ui.key(c, "trigger");
        const trigger = ui.div(c).row().p(6).control();
        f.trigger = c.node(trigger.index).id;
        ui.access.describe(c, trigger.index, .{ .label = "Choose collection" });
        if (c.interact(trigger.index, .{ .focusable = !f.open }).clicked and !f.open) {
            f.open = true;
            f.query.clear();
            f.query.focus();
            f.active = null;
            f.ask();
        }
        ui.label(c, "Choose collection");
        trigger.end();
        if (!f.open) return;
        if (f.wait > 0) {
            f.wait -= 1;
            if (f.wait == 0) f.answer();
        }
        const ids = f.ids[0..f.count];
        const frame = f.composition.begin(c);
        if (frame.quiet()) if (keys(c, .{ .consume = true })) |intent| switch (intent) {
            .next => _ = step(&f.active, ids, .next, .wrap),
            .previous => _ = step(&f.active, ids, .previous, .wrap),
            .activate => if (f.current()) if (f.active) |id| if (row(id).enabled) {
                f.chosen = id;
                return f.close(c);
            },
            .dismiss => return f.close(c),
        };
        const field = ui.textField(c, &f.query, .{ .placeholder = "Search collections", .width = .fill });
        if (f.composition.end(c, &f.query) != .none or field.changed) {
            f.active = null;
            f.ask();
        }
        _ = reconcile(&f.active, f.ids[0..f.count], .first);
        for (f.ids[0..f.count]) |id| {
            const r = row(id);
            rowKey(c, f.answered, id);
            const box = ui.div(c).row().p(6).wFull().control();
            defer box.end();
            ui.access.describe(c, box.index, .{ .label = r.label, .selected = f.active == id, .enabled = r.enabled and f.current() });
            ui.label(c, r.label);
        }
    }
};

const Seen = struct { role: ui.access.Role, selected: bool, enabled: bool };

fn accessible(t: *ui.Tester, label: []const u8) !Seen {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tree: std.ArrayList(ui.access.Element) = .empty;
    try ui.access.tree(&t.ctx, arena.allocator(), &tree);
    for (tree.items) |item| if (std.mem.eql(u8, item.label, label))
        return .{ .role = item.role, .selected = item.selected, .enabled = item.enabled };
    return error.MissingAccessibleElement;
}

test "keyboard only: open, filter, move, activate and return focus" {
    var f: Fixture = .{};
    defer f.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 360, .height = 420 });
    defer t.deinit();
    try t.clickText("Choose collection");
    t.typeText("o");
    try testing.expectEqual(@as(usize, 4), f.count);
    try testing.expectEqual(@as(?Id, 11), f.active);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try testing.expectEqual(@as(?Id, 12), f.active);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try testing.expectEqual(@as(?Id, 11), f.active);
    const art = try accessible(&t, "Art history");
    try testing.expect(art.selected and art.role == .button);
    try testing.expect(!(try accessible(&t, "Music scores")).selected);
    try testing.expectEqual(t.ctx.focus, t.ctx.focused_text.?.id);
    t.key(.up);
    try testing.expectEqual(@as(?Id, 16), f.active);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter }));
    try testing.expectEqual(@as(?Id, 16), f.chosen);
    try testing.expect(!f.open);
    t.frame();
    try testing.expectEqual(f.trigger, t.ctx.focus);
}

test "a composed query waits for its commit; Escape dismisses and returns focus" {
    var f: Fixture = .{};
    defer f.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 360, .height = 420 });
    defer t.deinit();
    try t.clickText("Choose collection");
    t.textOps(&.{.{ .set_marked = .{ .text = "に", .sel_start = 3, .sel_len = 0 } }});
    try testing.expect(f.composition.active);
    // The keys that drive the input method are not picker keys.
    _ = t.shortcut(.{ .key = ui.Shortcut.enter });
    _ = t.shortcut(.{ .key = ui.Shortcut.escape });
    try testing.expect(f.open and f.chosen == null);
    t.textOps(&.{.{ .insert = "日本" }});
    try testing.expect(!f.composition.active);
    try testing.expectEqualStrings("日本", f.query.text());
    try testing.expectEqual(@as(?Id, 14), f.active);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.escape }));
    try testing.expect(!f.open and f.chosen == null);
    t.frame();
    try testing.expectEqual(f.trigger, t.ctx.focus);
}

test "a late answer never lands as current; a disabled row cannot activate" {
    var f: Fixture = .{ .delay = 3 };
    defer f.deinit();
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&f, Fixture.view), .{ .width = 360, .height = 420 });
    defer t.deinit();
    try t.clickText("Choose collection");
    t.frame();
    t.frame();
    t.frame();
    try testing.expectEqual(@as(usize, 6), f.count);
    t.typeText("e");
    t.typeText("s");
    // "e" was superseded before it was answered; "es" has not landed.
    try testing.expect(!f.current());
    try testing.expect(!(try accessible(&t, "Art history")).enabled);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter }));
    try testing.expect(f.open and f.chosen == null);
    t.frame();
    t.frame();
    try testing.expect(f.current());
    try testing.expectEqual(@as(usize, 2), f.count);
    try testing.expectEqual(@as(?Id, 13), f.active);
    try testing.expect(!(try accessible(&t, "Design references")).enabled);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter }));
    try testing.expect(f.open and f.chosen == null);
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.down }));
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.enter }));
    try testing.expectEqual(@as(?Id, 15), f.chosen);
}

test "keys leave input alone unless asked to consume it" {
    const Key = @import("../ui/input.zig").Key;
    const Probe = struct {
        opts: KeyOptions,
        seen: ?Intent = null,
        after_key: ?Key = null,
        after_ops: usize = 0,
        fn view(p: *@This(), c: *ui.Context) void {
            p.seen = keys(c, p.opts);
            p.after_key = c.input.key;
            p.after_ops = c.input.ops.len;
        }
    };
    var p: Probe = .{ .opts = .{} };
    var t: ui.Tester = undefined;
    try t.init(testing.allocator, .init(&p, Probe.view), .{ .width = 100, .height = 100 });
    defer t.deinit();
    try testing.expect(!t.shortcut(.{ .key = ui.Shortcut.down }));
    try testing.expectEqual(@as(?Intent, .next), p.seen);
    try testing.expect(!t.shortcut(.{ .key = ui.Shortcut.down, .cmd = true }));
    try testing.expectEqual(@as(?Intent, null), p.seen);
    t.key(.escape);
    try testing.expectEqual(@as(?Intent, .dismiss), p.seen);
    try testing.expectEqual(@as(?Key, .escape), p.after_key);
    t.ctx.input.key = null;
    t.textOps(&.{ .{ .insert = "a" }, .{ .command = .move_up } });
    try testing.expectEqual(@as(?Intent, .previous), p.seen);
    try testing.expectEqual(@as(usize, 2), p.after_ops);
    p.opts = .{ .consume = true, .activate = false };
    try testing.expect(t.shortcut(.{ .key = ui.Shortcut.up }));
    try testing.expect(!t.shortcut(.{ .key = ui.Shortcut.enter }));
    try testing.expectEqual(@as(?Intent, null), p.seen);
    t.key(.down);
    try testing.expectEqual(@as(?Key, null), p.after_key);
    t.textOps(&.{ .{ .insert = "a" }, .{ .command = .cancel } });
    try testing.expectEqual(@as(?Intent, .dismiss), p.seen);
    try testing.expectEqual(@as(usize, 1), p.after_ops);
    p.opts = .{ .commands = false };
    t.textOps(&.{.{ .command = .move_down }});
    try testing.expectEqual(@as(?Intent, null), p.seen);
}

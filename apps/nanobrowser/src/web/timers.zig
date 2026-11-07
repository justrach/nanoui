//! `setTimeout` and `setInterval`. One platform timer is armed for the soonest
//! deadline: nothing polls, and an idle page has none armed. A `Wake` is what the
//! platform holds: a page can die with it armed, so it has its own allocation
//! with a cleared world pointer and frees itself when it fires.
const std = @import("std");
const nanoui = @import("nanoui");
const js = @import("../js/js.zig");
const bind = @import("bind.zig");
const world_mod = @import("world.zig");
const World = bind.World;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;

const wake_alloc = std.heap.smp_allocator;
const ns_per_ms = std.time.ns_per_ms;

const Wake = struct {
    world: ?*World,
    at: u64,
    prev: ?*Wake = null,
    next: ?*Wake = null,

    fn fire(ctx: ?*anyopaque) callconv(.c) void {
        const wake: *Wake = @ptrCast(@alignCast(ctx.?));
        const maybe = wake.world;
        const at = wake.at;
        if (maybe) |w| w.timers.unlink(wake);
        wake_alloc.destroy(wake);
        if (maybe) |w| w.timers.fired(w, at);
    }
};

const Timer = struct {
    id: u32,
    due: u64,
    interval_ms: ?u32,
    nesting: u32,
    callback: Value,
    args: []Value,
};

pub const Timers = struct {
    list: std.ArrayList(Timer) = .empty,
    wakes: ?*Wake = null,
    armed_at: ?u64 = null,
    next_id: u32 = 1,
    /// The nesting level of the timer running now.
    running_nesting: u32 = 0,

    pub fn deinit(t: *Timers, gpa: std.mem.Allocator) void {
        t.dropWakes();
        for (t.list.items) |x| gpa.free(x.args);
        t.list.deinit(gpa);
    }

    pub fn stopAll(t: *Timers, w: *World) void {
        t.dropWakes();
        for (t.list.items) |x| w.gpa.free(x.args);
        t.list.clearRetainingCapacity();
        t.armed_at = null;
    }

    fn dropWakes(t: *Timers) void {
        var at = t.wakes;
        while (at) |wake| : (at = wake.next) wake.world = null;
        t.wakes = null;
    }

    fn unlink(t: *Timers, wake: *Wake) void {
        if (wake.prev) |p| p.next = wake.next else t.wakes = wake.next;
        if (wake.next) |n| n.prev = wake.prev;
    }

    pub fn mark(t: *Timers, m: *js.Marker) void {
        for (t.list.items) |x| {
            m.mark(x.callback);
            m.markValues(x.args);
        }
    }

    fn insert(t: *Timers, gpa: std.mem.Allocator, timer: Timer) Error!void {
        var i = t.list.items.len;
        while (i > 0 and t.list.items[i - 1].due > timer.due) i -= 1;
        try t.list.insert(gpa, i, timer);
    }

    fn arm(t: *Timers, w: *World) void {
        if (t.list.items.len == 0 or w.page.dead) return;
        const due = t.list.items[0].due;
        if (t.armed_at) |a| if (a <= due) return;
        const wake = wake_alloc.create(Wake) catch return;
        wake.* = .{ .world = w, .at = due, .next = t.wakes };
        if (t.wakes) |h| h.prev = wake;
        t.wakes = wake;
        t.armed_at = due;
        const now = world_mod.monotonic();
        const ms = if (due > now) (due - now + ns_per_ms - 1) / ns_per_ms else 0;
        nanoui.App.after(ms, wake, Wake.fire);
    }

    /// A platform timer went off: everything due runs, each as its own task.
    fn fired(t: *Timers, w: *World, at: u64) void {
        if (t.armed_at) |a| if (a == at) {
            t.armed_at = null;
        };
        const p = w.page;
        p.busy += 1;
        defer {
            if (!p.dead and !w.stopped) t.arm(w);
            p.busy -= 1;
            p.maybeFree();
        }
        const now = world_mod.monotonic();
        var ran: u32 = 0;
        while (t.list.items.len > 0 and t.list.items[0].due <= now and ran < 64) : (ran += 1) {
            if (p.dead or w.stopped) return;
            const timer = t.list.orderedRemove(0);
            runOne(t, w, timer);
        }
    }

    fn runOne(t: *Timers, w: *World, timer: Timer) void {
        t.running_nesting = timer.nesting;
        var keep = false;
        // An interval goes back in before it runs, so that it can clear itself.
        if (timer.interval_ms) |ms| {
            var again = timer;
            again.due = world_mod.monotonic() + @as(u64, @max(ms, 1)) * ns_per_ms;
            again.nesting = timer.nesting + 1;
            if (t.insert(w.gpa, again)) keep = true else |_| {}
        }
        w.task(timer.callback, w.vm.global().value(), timer.args);
        t.running_nesting = 0;
        if (!keep) w.gpa.free(timer.args);
    }

    /// Adds a timer; `args` are copied.
    pub fn add(t: *Timers, w: *World, callback: Value, ms_in: f64, args: []const Value, repeat: bool) Error!u32 {
        const nesting = t.running_nesting + 1;
        var ms: u32 = if (ms_in >= 1 and ms_in < 2147483647) @intFromFloat(ms_in) else 0;
        if (nesting > 5 and ms < 4) ms = 4;
        const id = t.next_id;
        t.next_id += 1;
        const copy = try w.gpa.dupe(Value, args);
        errdefer w.gpa.free(copy);
        try t.insert(w.gpa, .{
            .id = id,
            .due = world_mod.monotonic() + @as(u64, ms) * ns_per_ms,
            .interval_ms = if (repeat) ms else null,
            .nesting = nesting,
            .callback = callback,
            .args = copy,
        });
        t.arm(w);
        return id;
    }

    pub fn clear(t: *Timers, w: *World, id: u32) void {
        for (t.list.items, 0..) |x, i| if (x.id == id) {
            w.gpa.free(x.args);
            _ = t.list.orderedRemove(i);
            return;
        };
    }
};

fn compileIfText(vm: *Vm, v: Value) Error!Value {
    if (v.isCallable()) return v;
    const code = try vm.toStringSlice(v);
    const f = try vm.global().get(vm, "Function");
    return vm.construct(f, &.{try vm.newString(code)});
}

fn startTimer(vm: *Vm, args: []const Value, repeat: bool) Error!Value {
    const w = bind.world(vm);
    if (w.stopped) return Value.fromInt(0);
    const f = try compileIfText(vm, bind.arg(args, 0));
    const ms = try vm.toNumber(bind.arg(args, 1));
    const rest: []const Value = if (args.len > 2) args[2..] else &.{};
    return Value.fromUsize(try w.timers.add(w, f, if (ms != ms) 0 else ms, rest, repeat));
}

fn setTimeout(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return startTimer(vm, args, false);
}

fn setInterval(vm: *Vm, _: Value, args: []const Value) Error!Value {
    return startTimer(vm, args, true);
}

fn clearTimer(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try vm.toNumber(bind.arg(args, 0));
    if (n >= 1 and n < 4294967295) bind.world(vm).timers.clear(bind.world(vm), @intFromFloat(n));
    return Value.undefined;
}

fn queueMicrotask(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const f = bind.arg(args, 0);
    if (!f.isCallable()) return vm.throwError(.TypeError, "queueMicrotask: the callback is not a function");
    try js.enqueueJob(vm, f);
    return Value.undefined;
}

fn requestAnimationFrame(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const f = bind.arg(args, 0);
    if (!f.isCallable()) return vm.throwError(.TypeError, "requestAnimationFrame: the callback is not a function");
    const id = w.next_animation;
    w.next_animation += 1;
    try w.animation.append(w.gpa, .{ .id = id, .callback = f });
    w.changed();
    return Value.fromUsize(id);
}

fn cancelAnimationFrame(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const n = try vm.toNumber(bind.arg(args, 0));
    for (w.animation.items, 0..) |a, i| {
        if (@as(f64, @floatFromInt(a.id)) == n) {
            _ = w.animation.orderedRemove(i);
            break;
        }
    }
    return Value.undefined;
}

pub const globals = [_]bind.Method{
    .{ .name = "setTimeout", .arity = 1, .f = setTimeout },
    .{ .name = "setInterval", .arity = 1, .f = setInterval },
    .{ .name = "clearTimeout", .arity = 1, .f = clearTimer },
    .{ .name = "clearInterval", .arity = 1, .f = clearTimer },
    .{ .name = "queueMicrotask", .arity = 1, .f = queueMicrotask },
    .{ .name = "requestAnimationFrame", .arity = 1, .f = requestAnimationFrame },
    .{ .name = "cancelAnimationFrame", .arity = 1, .f = cancelAnimationFrame },
};

//! CSS animations and transitions: which run on what, and each frame what they
//! make of an element's style. The cascade gives an element its after-change
//! style (`styled`); what runs is laid over it there and at each frame's `tick`,
//! written in place into the style boxes already point at. Opacity, transforms,
//! colors and the like blend (`animate_values.zig`); everything else jumps to its
//! end at the right time, so nothing waits on what can't be drawn in between.
//! Time is the frame's: a Tester's is simulated, and so is everything here.
const std = @import("std");
const dom = @import("../dom.zig");
const style = @import("style.zig");
const sheet = @import("sheet.zig");
const prop = @import("prop.zig");
const wide = @import("properties_wide.zig");
const vars = @import("vars.zig");
const diff = @import("style_diff.zig");
const v = @import("animate_values.zig");
const compute = @import("compute.zig");
const Engine = @import("cascade.zig").Engine;

const fx = style.fx;
const Style = style.Style;
const Smooth = v.Smooth;
const Value = v.Value;
const Allocator = std.mem.Allocator;

pub const Pseudo = enum(u8) { none, before, after, marker, backdrop };

pub const Key = struct { node: *dom.Node, pseudo: Pseudo };

/// One frame's style: its element's after-change style with its declarations over.
const Frame = struct { at: f32, style: Style, timing: ?fx.Timing };

const Running = struct {
    spec: fx.Animation,
    frames: []const Frame = &.{},
    /// When it started (before its delay), in the frames' time.
    start: f64,
    /// The generation `frames` belongs to, and the time it was paused at.
    generation: u32 = 0,
    paused_at: ?f64 = null,
    began: bool = false,
    done: bool = false,
    iteration: f64 = 0,
};

const Moving = struct {
    /// Null: it only tells of its end; the value itself jumped at its start.
    what: ?Smooth,
    name: []const u8,
    from: Value = .{ .floats = @splat(0) },
    to: Value = .{ .floats = @splat(0) },
    start: f64,
    delay: f32,
    duration: f32,
    timing: fx.Timing,
    began: bool = false,
};

const State = struct {
    base: Style,
    generation: u32,
    animations: std.ArrayList(Running) = .empty,
    moving: std.ArrayList(Moving) = .empty,
};

pub const Event = struct {
    node: *dom.Node,
    pseudo: Pseudo,
    kind: Kind,
    name: []const u8,
    elapsed: f32,

    pub const Kind = enum {
        animationstart,
        animationiteration,
        animationend,
        animationcancel,
        transitionrun,
        transitionstart,
        transitionend,
        transitioncancel,
    };
};

/// What the next frames are wanted for.
pub const Schedule = struct {
    /// Something shows a change every frame.
    frames: bool = false,
    /// Something happens this far off and nothing before.
    wake_in: ?f32 = null,
    /// A style changed what layout reads.
    layout: bool = false,
    /// A style changed what only paint reads.
    paint: bool = false,
};

/// Layout's properties watched for `transition: all`: they don't animate, but a
/// page may wait for their `transitionend`.
const jump_names = [_][]const u8{ "width", "height", "top", "right", "bottom", "left", "max-height", "min-height", "max-width", "min-width", "margin-top", "margin-right", "margin-bottom", "margin-left", "padding-top", "padding-right", "padding-bottom", "padding-left", "font-size" };

pub const Animator = struct {
    gpa: Allocator,
    states: std.AutoHashMapUnmanaged(Key, *State) = .empty,
    /// Lives as long as anything might need what was kept in it.
    kept: std.heap.ArenaAllocator,
    /// For what a blend makes: two, as last tick's is still in the styles.
    ticks: [2]std.heap.ArenaAllocator,
    tick_at: u1 = 0,
    events: std.ArrayList(Event) = .empty,

    pub fn init(gpa: Allocator) Animator {
        return .{ .gpa = gpa, .kept = .init(gpa), .ticks = .{ .init(gpa), .init(gpa) } };
    }

    pub fn deinit(a: *Animator) void {
        var it = a.states.valueIterator();
        while (it.next()) |s| a.freeState(s.*);
        a.states.deinit(a.gpa);
        a.kept.deinit();
        for (&a.ticks) |*t| t.deinit();
        a.events.deinit(a.gpa);
    }

    fn freeState(a: *Animator, s: *State) void {
        s.animations.deinit(a.gpa);
        s.moving.deinit(a.gpa);
        a.gpa.destroy(s);
    }

    fn tickArena(a: *Animator) Allocator {
        return a.ticks[a.tick_at].allocator();
    }

    pub fn busy(a: *const Animator) bool {
        return a.states.count() > 0;
    }

    /// The cascade has `fresh` for an element or pseudo-element: what starts,
    /// what goes on, and what shows of it now. `prior` is what it had before,
    /// when it had a style at all.
    pub fn styled(a: *Animator, e: *Engine, n: *dom.Node, which: Pseudo, parent: *const Style, scope: ?*const vars.Scope, prior: ?*const Style, fresh: *Style) Allocator.Error!void {
        const key: Key = .{ .node = n, .pseudo = which };
        const had = a.states.get(key);
        // Nothing running, nothing to run, and nothing to transition from.
        if (had == null and fresh.animations.len == 0) {
            if (fresh.transitions.len == 0) return;
            const b = prior orelse return;
            if (diff.compare(b, fresh) == .none) return;
        }
        if (fresh.display == .none) {
            if (had) |s| a.drop(key, s, e.now);
            return;
        }
        const s = had orelse blk: {
            const made = try a.gpa.create(State);
            made.* = .{ .base = fresh.*, .generation = e.generation };
            try a.states.put(a.gpa, key, made);
            break :blk made;
        };
        const before: ?*const Style = if (had != null) &s.base else prior;
        const unchanged = had != null and diff.compare(&s.base, fresh) == .none;
        if (before) |b| if (!unchanged) try a.startTransitions(s, key, b, fresh, e.now);
        s.base = fresh.*;
        s.generation = e.generation;
        try a.syncAnimations(e, s, key, parent, scope, unchanged, e.now);
        if (s.animations.items.len == 0 and s.moving.items.len == 0) {
            _ = a.states.remove(key);
            a.freeState(s);
            return;
        }
        a.overlay(s, key, fresh, e.now, null);
    }

    /// A pass over the whole document ended: what it never reached has no style.
    pub fn endGeneration(a: *Animator, generation: u32) void {
        var gone: std.ArrayList(Key) = .empty;
        defer gone.deinit(a.gpa);
        var it = a.states.iterator();
        while (it.next()) |x| if (x.value_ptr.*.generation != generation) gone.append(a.gpa, x.key_ptr.*) catch {};
        for (gone.items) |k| if (a.states.get(k)) |s| {
            _ = a.states.remove(k);
            a.freeState(s);
        };
    }

    fn drop(a: *Animator, key: Key, s: *State, now: f64) void {
        for (s.animations.items) |*an| {
            if (an.began and !an.done) a.tell(key, .animationcancel, an.spec.name, @floatCast(now - an.start));
        }
        for (s.moving.items) |m| a.tell(key, .transitioncancel, m.name, @floatCast(now - m.start));
        _ = a.states.remove(key);
        a.freeState(s);
    }

    fn tell(a: *Animator, key: Key, kind: Event.Kind, name: []const u8, elapsed: f32) void {
        a.events.append(a.gpa, .{ .node = key.node, .pseudo = key.pseudo, .kind = kind, .name = name, .elapsed = @max(elapsed, 0) }) catch {};
    }

    fn specFor(fresh: *const Style, what: Smooth) ?fx.Transition {
        var i = fresh.transitions.len;
        while (i > 0) {
            i -= 1;
            if (v.named(fresh.transitions[i].name, what)) return fresh.transitions[i];
        }
        return null;
    }

    fn startTransitions(a: *Animator, s: *State, key: Key, before: *const Style, fresh: *const Style, now: f64) Allocator.Error!void {
        const kept = a.kept.allocator();
        for (std.enums.values(Smooth)) |what| {
            const old = v.get(before, what);
            const new = v.get(fresh, what);
            if (v.equal(old, new)) continue;
            const running = movingOf(s, what);
            const spec = specFor(fresh, what) orelse {
                // No transition for it any more: it is where it is going.
                if (running) |i| _ = s.moving.orderedRemove(i);
                continue;
            };
            var from = old;
            if (running) |i| {
                const m = s.moving.items[i];
                from = sample(&m, now, a.tickArena());
                _ = s.moving.orderedRemove(i);
            }
            if (v.equal(from, new)) continue;
            const name = try kept.dupe(u8, v.eventName(what));
            try s.moving.append(a.gpa, .{ .what = what, .name = name, .from = try v.keep(kept, from), .to = try v.keep(kept, new), .start = now, .delay = spec.delay, .duration = spec.duration, .timing = spec.timing });
            a.tell(key, .transitionrun, name, 0);
        }
        try a.startJumps(s, key, before, fresh, now);
    }

    /// What can't blend jumped already; a page may still wait to hear it ended.
    fn startJumps(a: *Animator, s: *State, key: Key, before: *const Style, fresh: *const Style, now: f64) Allocator.Error!void {
        for (fresh.transitions) |t| {
            const all = std.ascii.eqlIgnoreCase(t.name, "all");
            const names: []const []const u8 = if (all) &jump_names else &.{t.name};
            for (names) |name| {
                const p = prop.lookup(name) orelse continue;
                if (isSmoothName(name)) continue;
                if (!changed(p, before, fresh)) continue;
                const kept_name = try a.kept.allocator().dupe(u8, name);
                try s.moving.append(a.gpa, .{ .what = null, .name = kept_name, .start = now, .delay = t.delay, .duration = t.duration, .timing = t.timing });
                a.tell(key, .transitionrun, kept_name, 0);
            }
        }
    }

    fn syncAnimations(a: *Animator, e: *Engine, s: *State, key: Key, parent: *const Style, scope: ?*const vars.Scope, unchanged: bool, now: f64) Allocator.Error!void {
        const specs = s.base.animations;
        // Those no longer named end.
        var i: usize = s.animations.items.len;
        while (i > 0) {
            i -= 1;
            const an = &s.animations.items[i];
            var found = false;
            for (specs) |sp| if (std.mem.eql(u8, sp.name, an.spec.name)) {
                found = true;
            };
            if (!found) {
                if (an.began and !an.done) a.tell(key, .animationcancel, an.spec.name, @floatCast(now - an.start));
                _ = s.animations.orderedRemove(i);
            }
        }
        // In the order of `animation-name`, a new one starting now.
        var order: std.ArrayList(Running) = .empty;
        defer order.deinit(a.gpa);
        for (specs) |sp| {
            const k = e.keyframes.get(sp.name) orelse continue;
            var run: ?Running = null;
            for (s.animations.items) |*an| if (std.mem.eql(u8, an.spec.name, sp.name)) {
                run = an.*;
                break;
            };
            var r = run orelse Running{ .spec = sp, .start = now };
            // A name goes through `kept`: events outlive the style that wrote it.
            r.spec = sp;
            r.spec.name = if (run) |old| old.spec.name else try a.kept.allocator().dupe(u8, sp.name);
            if (sp.paused and r.paused_at == null) r.paused_at = now;
            if (!sp.paused) if (r.paused_at) |at| {
                r.start += now - at;
                r.paused_at = null;
            };
            if (!unchanged or r.generation != e.generation or r.frames.len == 0) {
                r.frames = try buildFrames(e, key.node, parent, scope, &s.base, k);
                r.generation = e.generation;
            }
            try order.append(a.gpa, r);
        }
        s.animations.clearRetainingCapacity();
        try s.animations.appendSlice(a.gpa, order.items);
    }

    /// Lays what runs over `out` (its after-change style) at `now`. With `sched`,
    /// it is a tick: events go out, what finished goes, and it says what next.
    fn overlay(a: *Animator, s: *State, key: Key, out: *Style, now: f64, sched: ?*Schedule) void {
        const arena = a.tickArena();
        for (s.animations.items) |*an| a.runAnimation(an, s, key, out, now, sched, arena);
        var i: usize = 0;
        while (i < s.moving.items.len) {
            const m = &s.moving.items[i];
            const t: f32 = @floatCast(now - m.start);
            if (sched) |wanted| {
                if (!m.began and t >= m.delay) {
                    m.began = true;
                    a.tell(key, .transitionstart, m.name, 0);
                }
                if (t >= m.delay + m.duration) {
                    a.tell(key, .transitionend, m.name, m.duration);
                    _ = s.moving.orderedRemove(i);
                    continue;
                }
                if (t < m.delay) {
                    want(wanted, m.delay - t);
                } else if (m.what == null) {
                    want(wanted, m.delay + m.duration - t);
                } else wanted.frames = true;
            }
            if (m.what) |what| v.set(out, what, sample(m, now, arena));
            i += 1;
        }
    }

    fn runAnimation(a: *Animator, an: *Running, s: *State, key: Key, out: *Style, now: f64, sched: ?*Schedule, arena: Allocator) void {
        const sp = an.spec;
        const clock = an.paused_at orelse now;
        const elapsed: f64 = clock - an.start;
        const t = elapsed - sp.delay;
        const total: f64 = @as(f64, sp.duration) * sp.iterations;
        const finite = !std.math.isInf(sp.iterations);
        const after = finite and t >= total;
        if (sched) |wanted| {
            if (!an.began and t >= 0) {
                an.began = true;
                a.tell(key, .animationstart, sp.name, 0);
            }
            if (after and !an.done) {
                an.done = true;
                a.tell(key, .animationend, sp.name, @floatCast(total));
            }
            if (an.paused_at == null) {
                if (t < 0) {
                    want(wanted, @floatCast(-t));
                } else if (!after and sp.duration > 0) {
                    wanted.frames = true;
                    const it = @floor(t / sp.duration);
                    if (it > an.iteration) {
                        an.iteration = it;
                        a.tell(key, .animationiteration, sp.name, @floatCast(it * sp.duration));
                    }
                }
            }
        }
        if (t < 0) {
            if (sp.fill == .backwards or sp.fill == .both) applyAt(s, an, out, iterationProgress(sp, 0, 0), arena);
            return;
        }
        if (after) {
            if (sp.fill == .forwards or sp.fill == .both) {
                const last = if (sp.iterations > 0) sp.iterations - 1e-4 else 0;
                const at = if (sp.iterations == @floor(sp.iterations) and sp.iterations > 0) iterationProgress(sp, sp.iterations - 1, 1) else iterationProgress(sp, @floor(last), last - @floor(last));
                applyAt(s, an, out, at, arena);
            }
            return;
        }
        if (sp.duration <= 0) return;
        const it = @floor(t / sp.duration);
        applyAt(s, an, out, iterationProgress(sp, @floatCast(it), @floatCast(t / sp.duration - it)), arena);
    }

    /// What the next frames are wanted for, as things stand: nothing changes.
    pub fn plan(a: *const Animator, now: f64) Schedule {
        var p: Schedule = .{};
        var it = a.states.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            for (s.animations.items) |*an| {
                if (an.done or an.paused_at != null or an.spec.duration <= 0 and an.began) continue;
                const t = now - an.start - an.spec.delay;
                if (t < 0) want(&p, @floatCast(-t)) else p.frames = true;
            }
            for (s.moving.items) |*m| {
                const t: f32 = @floatCast(now - m.start);
                if (t < m.delay) {
                    want(&p, m.delay - t);
                } else if (m.what == null) {
                    want(&p, @max(m.delay + m.duration - t, 0));
                } else p.frames = true;
            }
        }
        return p;
    }

    /// One frame: every state's values worked out and written where boxes read
    /// them. Says what the page has to do about it.
    pub fn tick(a: *Animator, e: *Engine, now: f64) Schedule {
        var out_plan: Schedule = .{};
        if (a.states.count() == 0) {
            // Nothing runs: nor is anything told of it can still be read.
            if (a.events.items.len == 0) _ = a.kept.reset(.retain_capacity);
            return out_plan;
        }
        a.tick_at +%= 1;
        _ = a.ticks[a.tick_at].reset(.retain_capacity);
        var gone: std.ArrayList(Key) = .empty;
        defer gone.deinit(a.gpa);
        var it = a.states.iterator();
        while (it.next()) |x| {
            const key = x.key_ptr.*;
            const s = x.value_ptr.*;
            const slot = slotOf(key, e) orelse {
                gone.append(a.gpa, key) catch {};
                continue;
            };
            var out = s.base;
            a.overlay(s, key, &out, now, &out_plan);
            const change = diff.compare(slot, &out);
            const inherited = change != .none and inheritedDiffers(slot, &out);
            // Always: what it holds was blended in an arena that is going away.
            @constCast(slot).* = out;
            if (change != .none) {
                if (change == .layout) out_plan.layout = true else out_plan.paint = true;
                if (inherited and key.pseudo == .none and hasElementChild(key.node)) e.doc.markStyle(key.node);
            }
            if (s.animations.items.len == 0 and s.moving.items.len == 0) gone.append(a.gpa, key) catch {};
        }
        for (gone.items) |k| if (a.states.get(k)) |s| {
            _ = a.states.remove(k);
            a.freeState(s);
        };
        return out_plan;
    }
};

fn want(plan: *Schedule, seconds: f32) void {
    plan.wake_in = if (plan.wake_in) |w| @min(w, seconds) else seconds;
}

fn movingOf(s: *const State, what: Smooth) ?usize {
    for (s.moving.items, 0..) |m, i| if (m.what == what) return i;
    return null;
}

fn sample(m: *const Moving, now: f64, arena: Allocator) Value {
    const t: f32 = @floatCast(now - m.start);
    if (t <= m.delay) return m.from;
    if (m.duration <= 0 or t >= m.delay + m.duration) return m.to;
    const k = m.timing.at((t - m.delay) / m.duration);
    return v.blend(m.from, m.to, k, arena);
}

fn isSmoothName(name: []const u8) bool {
    for (std.enums.values(Smooth)) |what| if (v.named(name, what) and !std.ascii.eqlIgnoreCase(name, "all")) return true;
    return false;
}

/// Whether what `p` sets differs between two styles.
fn changed(p: prop.Prop, a: *const Style, b: *const Style) bool {
    var x: Style = .{};
    var y: Style = .{};
    wide.copy(p, &x, a);
    wide.copy(p, &y, b);
    return diff.compare(&x, &y) != .none;
}

fn slotOf(key: Key, e: *const Engine) ?*const Style {
    const n = key.node;
    if (n.style_generation != e.generation) return null;
    return switch (key.pseudo) {
        .none => n.computed,
        .before => n.before,
        .after => n.after,
        .marker => n.marker,
        .backdrop => n.backdrop,
    };
}

fn inheritedDiffers(a: *const Style, b: *const Style) bool {
    return !std.meta.eql(a.color, b.color) or a.visibility != b.visibility;
}

fn hasElementChild(n: *const dom.Node) bool {
    var c = n.first_child;
    while (c) |k| : (c = k.next) if (k.kind == .element) return true;
    return false;
}

/// Where an animation is within its keyframes: 0 to 1, its direction applied.
fn iterationProgress(sp: fx.Animation, iteration: f32, into: f32) f32 {
    const odd = @mod(iteration, 2) >= 1;
    const reversed = switch (sp.direction) {
        .normal => false,
        .reverse => true,
        .alternate => odd,
        .alternate_reverse => !odd,
    };
    return if (reversed) 1 - into else into;
}

fn buildFrames(e: *Engine, n: *dom.Node, parent: *const Style, scope: ?*const vars.Scope, base: *const Style, k: *const sheet.Keyframes) Allocator.Error![]const Frame {
    const arena = e.genArena();
    var out: std.ArrayList(Frame) = .empty;
    const starts_at_zero = k.frames.len > 0 and k.frames[0].at == 0;
    const ends_at_one = k.frames.len > 0 and k.frames[k.frames.len - 1].at == 1;
    if (!starts_at_zero) try out.append(arena, .{ .at = 0, .style = base.*, .timing = null });
    for (k.frames) |f| {
        var st: Style = undefined;
        try compute.frameStyle(e, n, parent, scope, base, f.decls, &st);
        var timing: ?fx.Timing = null;
        if (st.anim_raw != base.anim_raw) if (st.anim_raw) |raw| if (raw.timings.len > 0) {
            timing = raw.timings[0];
        };
        // Where several frames share a place, those after it say more.
        try out.append(arena, .{ .at = f.at, .style = st, .timing = timing });
    }
    if (!ends_at_one) try out.append(arena, .{ .at = 1, .style = base.*, .timing = null });
    return out.items;
}

/// `out` as the animation makes it at `at` (0 to 1) of its keyframes.
fn applyAt(s: *const State, an: *const Running, out: *Style, at: f32, arena: Allocator) void {
    const frames = an.frames;
    if (frames.len == 0) return;
    var i: usize = 0;
    while (i + 1 < frames.len and frames[i + 1].at <= at) i += 1;
    const a = &frames[i];
    const b = &frames[@min(i + 1, frames.len - 1)];
    const span = b.at - a.at;
    const local = if (span > 0) (at - a.at) / span else 1;
    const k = (a.timing orelse an.spec.timing).at(local);
    const base = &s.base;
    // What can't blend jumps half way through its stretch.
    inline for (@typeInfo(Style).@"struct".field_names) |f| {
        if (comptime skipsFrames(f)) continue;
        const T = @TypeOf(@field(base, f));
        if (!diff.same(T, @field(a.style, f), @field(base, f)) or !diff.same(T, @field(b.style, f), @field(base, f)))
            @field(out, f) = if (k < 0.5) @field(a.style, f) else @field(b.style, f);
    }
    for (std.enums.values(Smooth)) |what| {
        const x = v.get(&a.style, what);
        const y = v.get(&b.style, what);
        if (v.equal(x, y)) {
            if (!v.equal(x, v.get(base, what))) v.set(out, what, x);
        } else v.set(out, what, v.blend(x, y, k, arena));
    }
}

fn skipsFrames(comptime f: []const u8) bool {
    @setEvalBranchQuota(100000);
    const skip = [_][]const u8{ "anim_raw", "trans_raw", "animations", "transitions" };
    for (skip) |x| if (std.mem.eql(u8, f, x)) return true;
    return false;
}

test {
    _ = v;
}

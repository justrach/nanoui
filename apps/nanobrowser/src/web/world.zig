//! A page's script world: the VM, the wrappers and everything else JS keeps
//! alive from Zig, and the rules of a task. A task is a call from the host with
//! no JS beneath it: it gets a deadline, drains the microtasks after it, may
//! collect, and then does what the script asked of the page (a navigation).
const std = @import("std");
const nanoui = @import("nanoui");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const Page = @import("../page.zig").Page;
const bind = @import("bind.zig");
const classes = @import("classes.zig");
const prelude = @import("prelude.zig");
const timers = @import("timers.zig");
const scripts = @import("scripts.zig");
const modules = @import("modules.zig");
const custom = @import("custom.zig");
const Value = js.Value;
const Allocator = std.mem.Allocator;

/// The prelude's functions the Zig side calls, set with `$.hook`.
pub const Hooks = struct {
    domException: Value = Value.undefined,
    reportError: Value = Value.undefined,
    fire: Value = Value.undefined,
    fireAnimation: Value = Value.undefined,
    fireClick: Value = Value.undefined,
    firePointerMove: Value = Value.undefined,
    fireMouse: Value = Value.undefined,
    fireKey: Value = Value.undefined,
    fireWheel: Value = Value.undefined,
    fireFocus: Value = Value.undefined,
    makeRect: Value = Value.undefined,
    makeAttr: Value = Value.undefined,
    moRecord: Value = Value.undefined,
    frameObservers: Value = Value.undefined,
    viewportChanged: Value = Value.undefined,
    imageDone: Value = Value.undefined,
    hashChanged: Value = Value.undefined,
    historyStep: Value = Value.undefined,
    unhandled: Value = Value.undefined,
    makeRemote: Value = Value.undefined,
    remoteOp: Value = Value.undefined,
    deliverMessage: Value = Value.undefined,
    workerMessage: Value = Value.undefined,
    portMessage: Value = Value.undefined,
    closeWatcher: Value = Value.undefined,
    invoke: Value = Value.undefined,
    lightDismiss: Value = Value.undefined,
    detailsToggled: Value = Value.undefined,
};

/// What `CacheKey.kind` holds on to, one of each per node.
pub const Cached = enum(u8) { child_nodes, children, class_list, style, dataset, attributes, computed, rel_list };

pub const CacheKey = struct { node: *dom.Node, kind: Cached };

pub const Line = struct { level: u8, text: []u8 };

pub const AnimationFrame = struct { id: u32, callback: Value };

/// A `MutationObserver.observe` in force.
pub const Observed = struct {
    node: *dom.Node,
    observer: Value,
    child_list: bool,
    attributes: bool,
    character_data: bool,
    subtree: bool,
    old_attr: bool,
    old_data: bool,
    filter: Value,
};

pub const Extra = struct {
    node_list: *js.Object,
    html_collection: *js.Object,
    token_list: *js.Object,
    dom_string_map: *js.Object,
    named_node_map: *js.Object,
    style: *js.Object,
    computed_style: *js.Object,
    storage: *js.Object,
};

pub const ImageDone = struct { node: *dom.Node, ok: bool };

pub const Deferred = union(enum) {
    focus: struct { old: ?*dom.Node, now: ?*dom.Node },
    event: struct { node: *dom.Node, name: []const u8 },
    submit: struct { form: *dom.Node, submitter: ?*dom.Node },
};

pub const max_console = 1000;
/// How long one task may run. A test may shorten it.
pub var task_deadline_ns: u64 = 5 * std.time.ns_per_s;
const first_collection = 48 << 20;

pub var log_to_stderr = false;

pub const World = struct {
    page: *Page,
    gpa: Allocator,
    vm: *js.Vm,
    h: Hooks = .{},
    internals: *js.Object = undefined,
    protos: classes.Protos = undefined,
    /// Prototypes of what isn't in the Node hierarchy (`api_collections.zig`).
    extra: Extra = undefined,
    /// Every node wrapper ever made: nodes live as long as the page.
    wrappers: std.ArrayList(*js.Object) = .empty,
    cached: std.AutoHashMapUnmanaged(CacheKey, *js.Object) = .empty,

    /// JS calls under way that came from the host.
    depth: u32 = 0,
    /// Collect when the VM has passed this many bytes.
    gc_next: usize = first_collection,
    /// `location` asked to go here; done when the task ends.
    pending_nav: ?Page.Navigation = null,
    /// `history.go` past this document's own entries, also when the task ends.
    pending_history: i32 = 0,

    timers: timers.Timers = .{},
    runner: scripts.Runner = .{},
    mods: modules.Loader = .{},
    custom: custom.Registry = .{},
    animation: std.ArrayList(AnimationFrame) = .empty,
    next_animation: u32 = 1,
    observed: std.ArrayList(Observed) = .empty,
    /// Event types something listens for, to skip firing what nobody hears.
    listening: std.StringHashMapUnmanaged(void) = .empty,
    /// Pictures whose fate came since scripts last heard.
    images_done: std.ArrayList(ImageDone) = .empty,
    /// Elements scrolled since the last frame.
    scrolled: std.ArrayList(*dom.Node) = .empty,
    /// Scripts told not to run as they arrive (`script.async = false`).
    ordered: std.AutoHashMapUnmanaged(*dom.Node, void) = .empty,
    chunks_loaded: u32 = 0,
    /// Requests from `fetch` and XHR under way: they don't hold up `load`.
    net_pending: u32 = 0,
    /// What the console has said, the newest last, capped.
    console: std.ArrayList(Line) = .empty,
    console_dropped: usize = 0,
    /// A frame was asked for since the last one.
    redraw_asked: bool = false,
    /// Asking for one may draw it at once: that waits for the task's end.
    redraw_due: bool = false,
    /// A frame of this page is being drawn: asking for one waits for its end.
    in_frame: bool = false,
    /// A resize or intersection observer is live: check it each frame.
    frame_observers: bool = false,
    /// `onerror` handlers are running: what they throw isn't reported again.
    reporting: bool = false,
    /// The viewport last told to `matchMedia`.
    told_w: f32 = 0,
    told_h: f32 = 0,
    told_dark: bool = false,
    /// When the world started, for `performance.now`.
    started_ns: u64 = 0,
    stopped: bool = false,
    /// A frame is painting: script events wait until it has finished, as they
    /// might otherwise lay the page out under it.
    painting: bool = false,
    deferred_events: std.ArrayList(Deferred) = .empty,
    /// Something listens for pointer movement.
    pointer_heard: bool = false,
    /// What other worlds' proxies stand for, by the numbers they know them by; the
    /// proxies here for other worlds' objects; the page calling in right now.
    exports: std.ArrayList(Value) = .empty,
    export_ids: std.AutoHashMapUnmanaged(*js.Object, u32) = .empty,
    imports: std.AutoHashMapUnmanaged(*js.Object, @import("api_frames.zig").Remote) = .empty,
    caller: ?*Page = null,
    /// `document.open()` is in force: what's been written since.
    doc_open: bool = false,
    doc_written: std.ArrayList(u8) = .empty,
    /// A control should take the keyboard, or none, at the next frame.
    focus_request: ?*dom.Node = null,
    blur_request: bool = false,

    pub fn create(p: *Page) !*World {
        const gpa = p.gpa;
        const w = try gpa.create(World);
        errdefer gpa.destroy(w);
        const vm = try js.Vm.create(gpa);
        errdefer vm.deinit();
        w.* = .{ .page = p, .gpa = gpa, .vm = vm, .started_ns = monotonic() };
        vm.setRootsHook(w, markRoots);
        vm.setRejectionHook(w, rejected);
        vm.setDynamicImportHook(w, modules.dynamicImport);
        try classes.install(w);
        try prelude.install(w);
        p.js = w;
        return w;
    }

    pub fn destroy(w: *World) void {
        const gpa = w.gpa;
        w.timers.deinit(gpa);
        w.runner.deinit(gpa);
        w.mods.deinit(gpa);
        w.custom.deinit(gpa);
        w.animation.deinit(gpa);
        w.observed.deinit(gpa);
        w.cached.deinit(gpa);
        var names = w.listening.keyIterator();
        while (names.next()) |k| gpa.free(k.*);
        w.listening.deinit(gpa);
        w.scrolled.deinit(gpa);
        w.images_done.deinit(gpa);
        w.deferred_events.deinit(gpa);
        w.ordered.deinit(gpa);
        for (w.console.items) |l| gpa.free(l.text);
        w.console.deinit(gpa);
        w.wrappers.deinit(gpa);
        w.exports.deinit(gpa);
        w.doc_written.deinit(gpa);
        w.export_ids.deinit(gpa);
        w.imports.deinit(gpa);
        if (w.pending_nav) |n| {
            gpa.free(n.url);
            gpa.free(n.body);
        }
        w.vm.deinit();
        gpa.destroy(w);
    }

    /// The user pressed stop: nothing more arrives or fires.
    pub fn stop(w: *World) void {
        w.stopped = true;
        w.timers.stopAll(w);
    }

    fn markRoots(ctx: ?*anyopaque, m: *js.Marker) void {
        const w: *World = @ptrCast(@alignCast(ctx.?));
        inline for (@typeInfo(Hooks).@"struct".field_names) |name| m.mark(@field(w.h, name));
        m.markObj(w.internals);
        classes.mark(w, m);
        inline for (@typeInfo(Extra).@"struct".field_names) |name| m.markObj(@field(w.extra, name));
        for (w.wrappers.items) |o| m.markObj(o);
        for (w.exports.items) |v| m.mark(v);
        var imported = w.imports.keyIterator();
        while (imported.next()) |o| m.markObj(o.*);
        var it = w.cached.valueIterator();
        while (it.next()) |o| m.markObj(o.*);
        for (w.animation.items) |a| m.mark(a.callback);
        for (w.observed.items) |o| {
            m.mark(o.observer);
            m.mark(o.filter);
        }
        w.timers.mark(m);
        w.mods.mark(m);
        w.custom.mark(m);
    }

    /// Enters JS from the host. Every `enter` is matched by `leave`, which
    /// may free the page: touch nothing after it.
    pub fn enter(w: *World) void {
        if (w.depth == 0) {
            w.page.busy += 1;
            w.vm.setDeadline(task_deadline_ns);
        }
        w.depth += 1;
    }

    pub fn leave(w: *World) void {
        const vm = w.vm;
        // Microtasks are still this task: for them, JS is running.
        if (w.depth == 1) vm.runJobs();
        w.depth -= 1;
        if (w.depth != 0) return;
        vm.setDeadline(0);
        if (vm.bytesAllocated() > w.gc_next) {
            vm.collect();
            w.gc_next = @max(first_collection, vm.bytesAllocated() * 2);
        }
        const p = w.page;
        if (w.pending_nav) |to| {
            w.pending_nav = null;
            p.navigate(to);
            w.gpa.free(to.url);
            w.gpa.free(to.body);
        }
        if (w.pending_history != 0) {
            const by = w.pending_history;
            w.pending_history = 0;
            p.host.history(p.host.ctx, p, by);
        }
        if (w.redraw_due and !w.in_frame) {
            w.redraw_due = false;
            p.redraw();
        }
        p.busy -= 1;
        p.maybeFree();
    }

    /// Calls `f` as a task of its own. Holds the page while it runs, and the
    /// caller must not use the world afterwards unless it holds the page too.
    pub fn task(w: *World, f: Value, this: Value, args: []const Value) void {
        w.enter();
        if (w.callReported(f, this, args) == null and log_to_stderr and w.vm.deadline == null) {
            // Which function it was, when one is stopped.
            const text = w.vm.toStringSlice(f) catch "";
            w.logLine(0, text[0..@min(text.len, 400)]);
        }
        w.leave();
    }

    /// Calls `f` with no JS below: errors are reported, nothing escapes.
    pub fn callReported(w: *World, f: Value, this: Value, args: []const Value) ?Value {
        const r = w.vm.call(f, this, args) catch |e| {
            w.report(e);
            return null;
        };
        return r;
    }

    /// Calls `f` from inside a native: a throw is reported and execution goes
    /// on, but a termination goes up through the script that called us.
    pub fn callGuarded(w: *World, f: Value, this: Value, args: []const Value) js.Error!Value {
        return w.vm.call(f, this, args) catch |e| switch (e) {
            error.Thrown => {
                w.report(e);
                return Value.undefined;
            },
            else => e,
        };
    }

    /// What went wrong in a script: a throw goes to `onerror` and the console; a
    /// termination to the console alone, and the page lives on.
    pub fn report(w: *World, e: js.Error) void {
        const vm = w.vm;
        switch (e) {
            error.Terminated => {
                w.logLine(3, "A script ran too long and was stopped.");
                // Whatever called in from JS must end too.
                if (w.depth > 1) vm.setDeadline(1);
            },
            error.OutOfMemory => w.logLine(3, "A script ran out of memory."),
            error.Thrown => {
                const ex = vm.exception;
                vm.exception = Value.undefined;
                w.reportValue(ex);
            },
        }
    }

    pub fn reportValue(w: *World, ex: Value) void {
        const vm = w.vm;
        if (w.reporting or !w.h.reportError.isCallable()) {
            vm.exception = ex;
            w.logLine(3, vm.exceptionString());
            vm.exception = Value.undefined;
            return;
        }
        w.reporting = true;
        defer w.reporting = false;
        _ = vm.call(w.h.reportError, Value.undefined, &.{ex}) catch {
            w.logLine(3, vm.exceptionString());
            vm.exception = Value.undefined;
        };
    }

    fn rejected(ctx: ?*anyopaque, vm: *js.Vm, promise: Value, reason: Value) void {
        const w: *World = @ptrCast(@alignCast(ctx.?));
        if (promise.isUndefined() or !w.h.unhandled.isCallable()) return w.reportValue(reason);
        _ = vm.call(w.h.unhandled, Value.undefined, &.{ promise, reason }) catch {
            w.logLine(3, vm.exceptionString());
            vm.exception = Value.undefined;
        };
    }

    /// A line for the console's list: always kept (capped), to stderr when asked.
    pub fn logLine(w: *World, level: u8, text: []const u8) void {
        if (log_to_stderr) {
            const names = [_][]const u8{ "debug", "log", "warn", "error" };
            std.debug.print("[{s}] {s}\n", .{ names[@min(level, 3)], text });
        }
        if (w.console.items.len >= max_console) {
            const old = w.console.orderedRemove(0);
            w.gpa.free(old.text);
            w.console_dropped += 1;
        }
        const copy = w.gpa.dupe(u8, text) catch return;
        w.console.append(w.gpa, .{ .level = level, .text = copy }) catch w.gpa.free(copy);
    }

    /// Something a frame would show changed: ask for one, once.
    pub fn changed(w: *World) void {
        if (w.redraw_asked) return;
        w.redraw_asked = true;
        if (w.depth == 0) w.page.redraw() else w.redraw_due = true;
    }

    /// Asks for a navigation when the current task ends. The last one asked wins.
    pub fn queueNavigation(w: *World, url: []const u8, new_tab: bool) void {
        const copy = w.gpa.dupe(u8, url) catch return;
        if (w.pending_nav) |old| {
            w.gpa.free(old.url);
            w.gpa.free(old.body);
        }
        w.pending_nav = .{ .url = copy, .new_tab = new_tab, .body = w.gpa.alloc(u8, 0) catch "" };
    }

    pub fn queueHistory(w: *World, by: i32) void {
        w.pending_history = by;
    }

    pub fn listen(w: *World, event_type: []const u8) void {
        if (w.listening.contains(event_type)) return;
        if (std.mem.startsWith(u8, event_type, "mouse") or std.mem.startsWith(u8, event_type, "pointer")) w.pointer_heard = true;
        const copy = w.gpa.dupe(u8, event_type) catch return;
        w.listening.put(w.gpa, copy, {}) catch w.gpa.free(copy);
    }

    pub fn hears(w: *const World, event_type: []const u8) bool {
        return w.listening.contains(event_type);
    }

    /// Text of everything the console holds, for tests and a later panel.
    pub fn consoleHas(w: *const World, needle: []const u8) bool {
        for (w.console.items) |l| if (std.mem.indexOf(u8, l.text, needle) != null) return true;
        return false;
    }
};

pub fn monotonic() u64 {
    return @import("../js/conv.zig").monotonicNs();
}

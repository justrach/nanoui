//! `$`: the private natives the prelude is written on, and the global functions
//! with no better home. Scripts on the page can't reach `$`.
const std = @import("std");
const nanoui = @import("nanoui");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const css = @import("../css/css.zig");
const bind = @import("bind.zig");
const custom = @import("custom.zig");
const mutate = @import("mutate.zig");
const net = @import("net.zig");
const storage = @import("storage.zig");
const api_document = @import("api_document.zig");
const world_mod = @import("world.zig");
const page_input = @import("../page_input.zig");
const loader = @import("../loader.zig");
const typed = @import("../js/b_typed.zig");
const http = nanoui.http;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;

/// Makes an object `document.all` is: see `Flags.html_dda`.
fn markAll(_: *Vm, _: Value, args: []const Value) Error!Value {
    const v = bind.arg(args, 0);
    if (v.isObject()) v.asObject().flags.html_dda = true;
    return v;
}

fn hook(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const name = try bind.str(vm, args, 0);
    inline for (@typeInfo(world_mod.Hooks).@"struct".field_names) |f| {
        if (std.mem.eql(u8, f, name)) @field(w.h, f) = bind.arg(args, 1);
    }
    return Value.undefined;
}

fn listen(vm: *Vm, _: Value, args: []const Value) Error!Value {
    bind.world(vm).listen(try bind.str(vm, args, 0));
    return Value.undefined;
}

fn log(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const level = try vm.toNumber(bind.arg(args, 0));
    bind.world(vm).logLine(@intFromFloat(std.math.clamp(level, 0, 3)), try bind.str(vm, args, 1));
    return Value.undefined;
}

/// The handler text of `on<type>` on a node, or null.
fn inlineAttr(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = bind.asNode(bind.arg(args, 0)) orelse return Value.null;
    if (n.kind != .element) return Value.null;
    const t = try bind.str(vm, args, 1);
    var buf: [64]u8 = undefined;
    if (t.len + 2 > buf.len) return Value.null;
    buf[0] = 'o';
    buf[1] = 'n';
    @memcpy(buf[2..][0..t.len], t);
    return bind.optStr(vm, n.attr(buf[0 .. t.len + 2]));
}

/// The next object on an event's way up from a node.
fn eventParent(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = bind.asNode(bind.arg(args, 0)) orelse return Value.null;
    if (n.kind == .document) return if (n.doc == bind.world(vm).page.doc) vm.global().value() else Value.null;
    return bind.wrap(vm, n.parent);
}

fn isNode(_: *Vm, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(bind.asNode(bind.arg(args, 0)) != null);
}

fn pageUrl(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return vm.newString(bind.world(vm).page.url());
}

/// `$.setUrl(url, pushed)`: the page is at `url` now, with no load (`history`, a
/// hash), in a new history entry if `pushed`.
fn setUrl(vm: *Vm, _: Value, args: []const Value) Error!Value {
    bind.world(vm).page.setUrl(try bind.str(vm, args, 0), vm.toBoolean(bind.arg(args, 1)));
    return Value.undefined;
}

/// `ref` from this page: a bare fragment works on any address, `data:` too.
fn linkHere(w: *World, ref: []const u8) ?[]const u8 {
    if (ref.len > 0 and ref[0] == '#') {
        const here = w.page.url();
        const cut = here[0 .. std.mem.indexOfScalar(u8, here, '#') orelse here.len];
        return std.fmt.allocPrint(w.page.arena(), "{s}{s}", .{ cut, ref }) catch null;
    }
    return loader.linkFrom(w.page, ref);
}

fn navigate(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const to = linkHere(w, try bind.str(vm, args, 0)) orelse return Value.undefined;
    w.queueNavigation(to, vm.toBoolean(bind.arg(args, 1)));
    return Value.undefined;
}

fn resolveUrl(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    return bind.optStr(vm, linkHere(w, try bind.str(vm, args, 0)));
}

fn historyGo(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const by: i32 = @intFromFloat(std.math.clamp(try vm.toNumber(bind.arg(args, 0)), -1000, 1000));
    w.queueHistory(by);
    return Value.undefined;
}

fn fragment(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    _ = @import("api_geometry.zig").flushLayout(w);
    page_input.fragment(w.page, try bind.str(vm, args, 0));
    return Value.undefined;
}

fn mediaMatches(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const p = w.page;
    const text = try bind.str(vm, args, 0);
    var arena = std.heap.ArenaAllocator.init(w.gpa);
    defer arena.deinit();
    const list = try css.parseMedia(arena.allocator(), text);
    const size = p.host.viewport(p.host.ctx);
    return Value.fromBool(list.matches(.{
        .width = if (p.viewport_w > 0) p.viewport_w else size[0],
        .height = if (p.viewport_h > 0) p.viewport_h else size[1],
        .dark = p.dark,
    }));
}

fn now(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const w = bind.world(vm);
    const ns = world_mod.monotonic() -| w.started_ns;
    return Value.fromDouble(@as(f64, @floatFromInt(ns / std.time.ns_per_us)) / 1000);
}

fn randomFill(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const v = bind.arg(args, 0);
    if (!v.isObject() or v.asObject().class != .typedarray) return vm.throwError(.TypeError, "getRandomValues: not an integer array");
    const o = v.asObject();
    const n = typed.length(o) * typed.elemSize(o.payload.typed.kind);
    if (n > 65536) return bind.throwDom(vm, "QuotaExceededError", "The requested length exceeds 65536 bytes.");
    fillRandom(typed.bytesOf(o)[0..n]);
    return v;
}

/// The operating system's randomness, read once for a seed; after that a
/// ChaCha stream. Good enough for ids; nothing here signs anything.
fn fillRandom(buf: []u8) void {
    const S = struct {
        var rng: ?std.Random.DefaultCsprng = null;
    };
    if (S.rng == null) {
        var seed: [32]u8 = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        io.random(&seed);
        S.rng = std.Random.DefaultCsprng.init(seed);
    }
    S.rng.?.fill(buf);
}

fn observe(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const n = try bind.nodeArg(vm, args, 0, "observe");
    const observer = bind.arg(args, 1);
    const o = bind.arg(args, 2).asObject();
    const flag = struct {
        fn f(v: *Vm, x: *js.Object, name: []const u8) Error!bool {
            return v.toBoolean(try x.get(v, name));
        }
    }.f;
    const entry = world_mod.Observed{
        .node = n,
        .observer = observer,
        .child_list = try flag(vm, o, "childList"),
        .attributes = try flag(vm, o, "attributes"),
        .character_data = try flag(vm, o, "characterData"),
        .subtree = try flag(vm, o, "subtree"),
        .old_attr = try flag(vm, o, "attributeOldValue"),
        .old_data = try flag(vm, o, "characterDataOldValue"),
        .filter = try o.get(vm, "attributeFilter"),
    };
    for (w.observed.items) |*e| if (e.node == n and e.observer.same(observer)) {
        e.* = entry;
        return Value.undefined;
    };
    try w.observed.append(w.gpa, entry);
    return Value.undefined;
}

fn disconnectObserver(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    const observer = bind.arg(args, 0);
    var i: usize = 0;
    while (i < w.observed.items.len) {
        if (w.observed.items[i].observer.same(observer)) {
            _ = w.observed.orderedRemove(i);
        } else i += 1;
    }
    return Value.undefined;
}

fn frameObservers(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    w.frame_observers = vm.toBoolean(bind.arg(args, 0));
    if (w.frame_observers) w.changed();
    return Value.undefined;
}

fn setOrdered(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try bind.nodeArg(vm, args, 0, "async");
    const w = bind.world(vm);
    if (vm.toBoolean(bind.arg(args, 1))) try w.ordered.put(w.gpa, n, {}) else _ = w.ordered.remove(n);
    return Value.undefined;
}

fn isOrdered(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try bind.nodeArg(vm, args, 0, "async");
    return Value.fromBool(bind.world(vm).ordered.contains(n));
}

fn wasStarted(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try bind.nodeArg(vm, args, 0, "started");
    return Value.fromBool(bind.world(vm).runner.started.contains(n));
}

fn systemDark(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return Value.fromBool(bind.world(vm).page.dark);
}

fn setStyleText(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try bind.nodeArg(vm, args, 0, "sheet");
    try n.setTextContent(try bind.str(vm, args, 1));
    n.doc.touchStyle();
    bind.world(vm).changed();
    return Value.undefined;
}

fn imageWanted(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try bind.nodeArg(vm, args, 0, "image");
    try @import("api_forms.zig").imageAsked(bind.world(vm), n);
    return Value.undefined;
}

/// The pictures done since last asked, `[element, ok, …]`; none if nothing
/// hears either event, so that a page of pictures makes no wrappers for them.
fn takeImages(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const w = bind.world(vm);
    const arr = try vm.newArray(&.{});
    if (w.hears("load") or w.hears("error")) {
        var i: u32 = 0;
        for (w.images_done.items) |d| {
            try arr.setIdx(vm, i, try bind.wrap(vm, d.node));
            try arr.setIdx(vm, i + 1, Value.fromBool(d.ok));
            i += 2;
        }
    }
    w.images_done.clearRetainingCapacity();
    return arr.value();
}

const table = [_]bind.Method{
    .{ .name = "takeImages", .arity = 0, .f = takeImages },
    .{ .name = "hook", .arity = 2, .f = hook },
    .{ .name = "listen", .arity = 1, .f = listen },
    .{ .name = "log", .arity = 2, .f = log },
    .{ .name = "inlineAttr", .arity = 2, .f = inlineAttr },
    .{ .name = "eventParent", .arity = 1, .f = eventParent },
    .{ .name = "isNode", .arity = 1, .f = isNode },
    .{ .name = "markAll", .arity = 1, .f = markAll },
    .{ .name = "pageUrl", .arity = 0, .f = pageUrl },
    .{ .name = "setUrl", .arity = 1, .f = setUrl },
    .{ .name = "navigate", .arity = 2, .f = navigate },
    .{ .name = "resolveUrl", .arity = 1, .f = resolveUrl },
    .{ .name = "historyGo", .arity = 1, .f = historyGo },
    .{ .name = "fragment", .arity = 1, .f = fragment },
    .{ .name = "mediaMatches", .arity = 1, .f = mediaMatches },
    .{ .name = "now", .arity = 0, .f = now },
    .{ .name = "randomFill", .arity = 1, .f = randomFill },
    .{ .name = "observe", .arity = 3, .f = observe },
    .{ .name = "disconnectObserver", .arity = 1, .f = disconnectObserver },
    .{ .name = "frameObservers", .arity = 1, .f = frameObservers },
    .{ .name = "setOrdered", .arity = 2, .f = setOrdered },
    .{ .name = "isOrdered", .arity = 1, .f = isOrdered },
    .{ .name = "wasStarted", .arity = 1, .f = wasStarted },
    .{ .name = "systemDark", .arity = 0, .f = systemDark },
    .{ .name = "setStyleText", .arity = 2, .f = setStyleText },
    .{ .name = "imageWanted", .arity = 1, .f = imageWanted },
    .{ .name = "ceDefine", .arity = 6, .f = custom.define },
    .{ .name = "ceUpgrade", .arity = 1, .f = custom.upgradeTree },
};

/// Makes `$`.
pub fn make(w: *World) Error!*js.Object {
    const vm = w.vm;
    const o = try vm.newObject();
    try bind.methods(vm, o, &table);
    try bind.methods(vm, o, &net.internals);
    try bind.methods(vm, o, &storage.internals);
    try bind.methods(vm, o, &api_document.internals);
    try bind.methods(vm, o, &@import("api_frames.zig").internals);
    try bind.methods(vm, o, &@import("api_worker.zig").internals);
    try bind.methods(vm, o, &@import("api_webgl.zig").internals);
    try bind.methods(vm, o, &@import("api_webgpu.zig").internals);
    return o;
}

//! What scripts read of layout: anything here flushes style and layout first,
//! and answers zeros when no frame has drawn yet (fonts need a frame's context).
//! Mutations never lay out; a read after them does.
const std = @import("std");
const nanoui = @import("nanoui");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const bind = @import("bind.zig");
const layout = @import("../layout/layout.zig");
const box = @import("../layout/box.zig");
const view = @import("../page_view.zig");
const page_loader = @import("../loader.zig");
const classes = @import("classes.zig");
const display = @import("../paint/display.zig");
const css_transform = @import("../css/transform.zig");
const css_style = @import("../css/style.zig");
const Node = dom.Node;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;

/// Style brought up to date, for `getComputedStyle`.
pub fn flushStyle(w: *World) void {
    page_loader.sheetsNow(w.page);
    view.flushStyle(w.page);
}

/// Style and layout up to date. False when there is no context to measure with.
pub fn flushLayout(w: *World) bool {
    const p = w.page;
    if (w.painting) return p.tree != null;
    page_loader.sheetsNow(p);
    const size = p.host.viewport(p.host.ctx);
    const vw = if (p.viewport_w > 0) p.viewport_w else size[0];
    const vh = if (p.viewport_h > 0) p.viewport_h else size[1];
    if (!p.doc.style_dirty and !p.doc.layout_dirty and !p.list_dirty and p.list != null and vw == p.viewport_w and vh == p.viewport_h) return true;
    const c = p.host.uiContext(p.host.ctx) orelse return false;
    view.prepare(p, c, vw, vh);
    if (p.list) |*l| l.resolve(p.origin[0], p.origin[1], p.viewport_w, p.viewport_h);
    return p.tree != null;
}

fn thisElement(vm: *Vm, this: Value) Error!*Node {
    const n = try bind.thisNode(vm, this);
    if (n.kind != .element) return bind.illegal(vm);
    return n;
}

fn isRootElement(n: *const Node) bool {
    return n.doc.documentElement() == n;
}

/// How far `n`'s place in the document is from where the window shows it.
fn scrollOffset(p: anytype, n: *Node) [2]f32 {
    var x: f32 = 0;
    var y: f32 = 0;
    var fixed = false;
    var at: ?*Node = n;
    while (at) |a| : (at = a.parent) {
        if (a.kind == .element) {
            if (a.computed) |s| if (s.position == .fixed) {
                fixed = true;
                break;
            };
        }
        if (a != n) if (p.scrolls.get(a)) |s| if (a != p.doc.node) {
            x += s[0];
            y += s[1];
        };
    }
    if (!fixed) {
        const s = docScroll(p);
        x += s[0];
        y += s[1];
    }
    return .{ x, y };
}

pub fn docScroll(p: anytype) [2]f32 {
    if (p.list) |l| if (l.clips.len > 1) return .{ l.clips[1].scroll_x, l.clips[1].scroll_y };
    return p.scrolls.get(p.doc.node) orelse .{ 0, 0 };
}

fn clientRect(w: *World, n: *Node) ?box.Rect {
    if (!flushLayout(w)) return null;
    if (layout.boxOfNode(n) == null) return null;
    return placedRect(w.page, n);
}

/// Where `n`'s box is in the window as things stand, laid out or not. It has a box.
pub fn placedRect(p: anytype, n: *Node) box.Rect {
    const b = layout.boxOfNode(n).?;
    var r = transformedRect(n, b.borderRect());
    const o = scrollOffset(p, n);
    r.x -= o[0];
    r.y -= o[1];
    return r;
}

/// A rect of `n` where the transforms on it and around it put it.
fn transformedRect(n: *Node, r_in: box.Rect) box.Rect {
    var r = r_in;
    var at: ?*Node = n;
    while (at) |a| : (at = a.parent) {
        if (a.kind != .element) continue;
        const s = a.computed orelse continue;
        if (!s.hasTransform()) continue;
        const b = layout.boxOfNode(a) orelse continue;
        if (b.kind == .inline_box) continue;
        const m = css_transform.of(s, b.w, b.h) orelse continue;
        const whole = css_style.fx.Mat.translate(b.x, b.y).times(m).times(css_style.fx.Mat.translate(-b.x, -b.y));
        r = display.boundsOf(whole, r);
    }
    return r;
}

fn makeRect(vm: *Vm, r: box.Rect) Error!Value {
    const args = [_]Value{ .fromNumber(r.x), .fromNumber(r.y), .fromNumber(r.w), .fromNumber(r.h) };
    return vm.call(bind.world(vm).h.makeRect, Value.undefined, &args);
}

fn getBoundingClientRect(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return makeRect(vm, clientRect(bind.world(vm), try thisElement(vm, this)) orelse .{});
}

fn getClientRects(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try thisElement(vm, this);
    const w = bind.world(vm);
    const arr = try vm.newArray(&.{});
    if (!flushLayout(w)) return arr.value();
    const b = layout.boxOfNode(n) orelse return arr.value();
    const o = scrollOffset(w.page, n);
    if (b.frags.len > 0) {
        for (b.frags, 0..) |f, i| {
            try arr.setIdx(vm, @intCast(i), try makeRect(vm, .{ .x = f.x - o[0], .y = f.y - o[1], .w = f.w, .h = f.h }));
        }
    } else {
        try arr.setIdx(vm, 0, try makeRect(vm, .{ .x = b.x - o[0], .y = b.y - o[1], .w = b.w, .h = b.h }));
    }
    return arr.value();
}

fn boxFor(w: *World, n: *Node) ?*box.Box {
    if (!flushLayout(w)) return null;
    return layout.boxOfNode(n);
}

/// The clip of an element that has one: its scrolling place in the display list.
fn clipOf(p: anytype, n: *Node) ?u32 {
    const l = if (p.list) |*x| x else return null;
    if (isRootElement(n)) return if (l.clips.len > 1) 1 else null;
    for (l.clips, 0..) |c, i| {
        if (i > 1 and c.node == n) return @intCast(i);
    }
    return null;
}

fn clientWidth(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try thisElement(vm, this);
    const w = bind.world(vm);
    if (isRootElement(n)) {
        _ = flushLayout(w);
        return bind.num(w.page.viewport_w);
    }
    const b = boxFor(w, n) orelse return Value.fromInt(0);
    if (b.kind == .inline_box) return Value.fromInt(0);
    return bind.num(b.paddingRect().w);
}

fn clientHeight(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try thisElement(vm, this);
    const w = bind.world(vm);
    if (isRootElement(n)) {
        _ = flushLayout(w);
        return bind.num(w.page.viewport_h);
    }
    const b = boxFor(w, n) orelse return Value.fromInt(0);
    if (b.kind == .inline_box) return Value.fromInt(0);
    return bind.num(b.paddingRect().h);
}

fn clientLeft(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const b = boxFor(bind.world(vm), try thisElement(vm, this)) orelse return Value.fromInt(0);
    return bind.num(b.border.left);
}

fn clientTop(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const b = boxFor(bind.world(vm), try thisElement(vm, this)) orelse return Value.fromInt(0);
    return bind.num(b.border.top);
}

fn offsetWidth(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const b = boxFor(bind.world(vm), try thisElement(vm, this)) orelse return Value.fromInt(0);
    return bind.num(@round(b.w));
}

fn offsetHeight(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const b = boxFor(bind.world(vm), try thisElement(vm, this)) orelse return Value.fromInt(0);
    return bind.num(@round(b.h));
}

/// The box offsets count from: a static `<body>` counts from the page, as browsers do.
fn offsetOrigin(n: *Node) ?*box.Box {
    const o = layout.offsetParent(n) orelse return null;
    const b = layout.boxOfNode(o) orelse return null;
    if (o.isTag("body") and b.style.position == .static) return null;
    return b;
}

fn offsetLeft(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try thisElement(vm, this);
    const b = boxFor(bind.world(vm), n) orelse return Value.fromInt(0);
    var x = b.x;
    if (offsetOrigin(n)) |pb| x -= pb.x + pb.border.left;
    return bind.num(@round(x));
}

fn offsetTop(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try thisElement(vm, this);
    const b = boxFor(bind.world(vm), n) orelse return Value.fromInt(0);
    var y = b.y;
    if (offsetOrigin(n)) |pb| y -= pb.y + pb.border.top;
    return bind.num(@round(y));
}

fn offsetParent(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try thisElement(vm, this);
    if (!flushLayout(bind.world(vm))) return Value.null;
    return bind.wrap(vm, layout.offsetParent(n));
}

fn scrollSize(vm: *Vm, this: Value, height: bool) Error!Value {
    const n = try thisElement(vm, this);
    const w = bind.world(vm);
    if (!flushLayout(w)) return Value.fromInt(0);
    const p = w.page;
    if (clipOf(p, n)) |i| {
        const c = p.list.?.clips[i];
        return bind.num(@max(if (height) c.content_h else c.content_w, if (height) c.rect.h else c.rect.w));
    }
    const b = layout.boxOfNode(n) orelse return Value.fromInt(0);
    const inner = b.paddingRect();
    return bind.num(@max(if (height) inner.h else inner.w, if (height) b.content_h else b.content_w));
}

fn scrollWidth(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return scrollSize(vm, this, false);
}

fn scrollHeight(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return scrollSize(vm, this, true);
}

fn scrollGet(vm: *Vm, this: Value, axis: usize) Error!Value {
    const n = try thisElement(vm, this);
    const w = bind.world(vm);
    const p = w.page;
    if (isRootElement(n)) return bind.num(docScroll(p)[axis]);
    const s = p.scrolls.get(n) orelse return Value.fromInt(0);
    return bind.num(s[axis]);
}

/// Moves a scroller to `x`, `y` (null: where it is), asking for the frame.
fn scrollTo(w: *World, n: *Node, x: ?f32, y: ?f32) void {
    if (!flushLayout(w)) return;
    const p = w.page;
    const i = clipOf(p, n) orelse return;
    const l = &p.list.?;
    const c = l.clips[i];
    view.scrollBy(p, l, i, if (x) |v| v - c.scroll_x else 0, if (y) |v| v - c.scroll_y else 0);
    w.changed();
}

fn numArg(vm: *Vm, v: Value) Error!?f32 {
    if (v.isUndefined()) return null;
    const d = try vm.toNumber(v);
    if (d != d) return 0;
    const f: f32 = @floatCast(d);
    return f;
}

fn scrollTopGet(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return scrollGet(vm, this, 1);
}

fn scrollLeftGet(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return scrollGet(vm, this, 0);
}

fn scrollTopSet(vm: *Vm, this: Value, args: []const Value) Error!Value {
    scrollTo(bind.world(vm), try thisElement(vm, this), null, try numArg(vm, bind.arg(args, 0)));
    return Value.undefined;
}

fn scrollLeftSet(vm: *Vm, this: Value, args: []const Value) Error!Value {
    scrollTo(bind.world(vm), try thisElement(vm, this), try numArg(vm, bind.arg(args, 0)), null);
    return Value.undefined;
}

/// `el.scrollTo(x, y)` and `el.scrollTo({left, top})`, `by` adding to where it is.
fn scrollArgs(vm: *Vm, n: *Node, args: []const Value, by: bool) Error!void {
    const w = bind.world(vm);
    var x: ?f32 = null;
    var y: ?f32 = null;
    if (bind.arg(args, 0).isObject()) {
        const o = args[0].asObject();
        x = try numArg(vm, try o.get(vm, "left"));
        y = try numArg(vm, try o.get(vm, "top"));
    } else {
        x = try numArg(vm, bind.arg(args, 0));
        y = try numArg(vm, bind.arg(args, 1));
    }
    if (by) {
        if (!flushLayout(w)) return;
        const i = clipOf(w.page, n) orelse return;
        const c = w.page.list.?.clips[i];
        if (x) |v| x = v + c.scroll_x;
        if (y) |v| y = v + c.scroll_y;
    }
    scrollTo(w, n, x, y);
}

fn elScrollTo(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try scrollArgs(vm, try thisElement(vm, this), args, false);
    return Value.undefined;
}

fn elScrollBy(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try scrollArgs(vm, try thisElement(vm, this), args, true);
    return Value.undefined;
}

fn scrollIntoView(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try thisElement(vm, this);
    const w = bind.world(vm);
    if (!flushLayout(w)) return Value.undefined;
    const b = layout.boxOfNode(n) orelse return Value.undefined;
    var block: []const u8 = "start";
    if (bind.arg(args, 0).isObject()) {
        const v = try args[0].asObject().get(vm, "block");
        if (v.isString()) block = try vm.toStringSlice(v);
    } else if (bind.arg(args, 0).isBool() and !args[0].asBool()) block = "end";
    const p = w.page;
    const place = struct {
        fn f(how: []const u8, top: f32, h: f32, view_top: f32, view_h: f32) ?f32 {
            if (std.mem.eql(u8, how, "center")) return top - (view_h - h) / 2;
            if (std.mem.eql(u8, how, "end")) return top + h - view_h;
            if (std.mem.eql(u8, how, "nearest")) {
                if (top >= view_top and top + h <= view_top + view_h) return null;
                return if (top < view_top) top else top + h - view_h;
            }
            return top;
        }
    }.f;
    var at = n.parent;
    while (at) |a| : (at = a.parent) {
        if (a.kind != .element or isRootElement(a)) break;
        const i = clipOf(p, a) orelse continue;
        const c = p.list.?.clips[i];
        if (place(block, b.y - c.rect.y, b.h, c.scroll_y, c.rect.h)) |to| scrollTo(w, a, null, to);
    }
    const root = n.doc.documentElement() orelse return Value.undefined;
    if (place(block, b.y, b.h, docScroll(p)[1], p.viewport_h)) |to| scrollTo(w, root, null, to);
    return Value.undefined;
}

fn elementFromPoint(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    if (!flushLayout(w)) return Value.null;
    const p = w.page;
    const x: f32 = @floatCast(try vm.toNumber(bind.arg(args, 0)));
    const y: f32 = @floatCast(try vm.toNumber(bind.arg(args, 1)));
    if (x < 0 or y < 0 or x > p.viewport_w or y > p.viewport_h) return Value.null;
    const l = if (p.list) |*a| a else return Value.null;
    var n = l.hit(x + p.origin[0], y + p.origin[1]) orelse return bind.wrap(vm, p.doc.documentElement());
    while (n.kind != .element) n = n.parent orelse return Value.null;
    return bind.wrap(vm, n);
}

// The window's own geometry.

fn innerWidth(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const p = bind.world(vm).page;
    return bind.num(if (p.viewport_w > 0) p.viewport_w else p.host.viewport(p.host.ctx)[0]);
}

fn innerHeight(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const p = bind.world(vm).page;
    return bind.num(if (p.viewport_h > 0) p.viewport_h else p.host.viewport(p.host.ctx)[1]);
}

fn scrollX(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return bind.num(docScroll(bind.world(vm).page)[0]);
}

fn scrollY(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return bind.num(docScroll(bind.world(vm).page)[1]);
}

fn winScrollTo(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    if (w.page.doc.documentElement()) |root| try scrollArgs(vm, root, args, false);
    return Value.undefined;
}

fn winScrollBy(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const w = bind.world(vm);
    if (w.page.doc.documentElement()) |root| try scrollArgs(vm, root, args, true);
    return Value.undefined;
}

fn devicePixelRatio(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const p = bind.world(vm).page;
    const c = p.host.uiContext(p.host.ctx) orelse return Value.fromInt(1);
    return bind.num(c.scale);
}

pub fn install(w: *World) Error!void {
    const vm = w.vm;
    const element = classes.proto(w, "Element");
    try bind.accessors(vm, element, &.{
        .{ .name = "clientWidth", .get = clientWidth },
        .{ .name = "clientHeight", .get = clientHeight },
        .{ .name = "clientLeft", .get = clientLeft },
        .{ .name = "clientTop", .get = clientTop },
        .{ .name = "scrollWidth", .get = scrollWidth },
        .{ .name = "scrollHeight", .get = scrollHeight },
        .{ .name = "scrollTop", .get = scrollTopGet, .set = scrollTopSet },
        .{ .name = "scrollLeft", .get = scrollLeftGet, .set = scrollLeftSet },
    });
    try bind.methods(vm, element, &.{
        .{ .name = "getBoundingClientRect", .arity = 0, .f = getBoundingClientRect },
        .{ .name = "getClientRects", .arity = 0, .f = getClientRects },
        .{ .name = "scrollTo", .arity = 0, .f = elScrollTo },
        .{ .name = "scroll", .arity = 0, .f = elScrollTo },
        .{ .name = "scrollBy", .arity = 0, .f = elScrollBy },
        .{ .name = "scrollIntoView", .arity = 0, .f = scrollIntoView },
    });
    try bind.accessors(vm, w.protos.html, &.{
        .{ .name = "offsetWidth", .get = offsetWidth },
        .{ .name = "offsetHeight", .get = offsetHeight },
        .{ .name = "offsetLeft", .get = offsetLeft },
        .{ .name = "offsetTop", .get = offsetTop },
        .{ .name = "offsetParent", .get = offsetParent },
    });
    try classes.proto(w, "Document").defineMethod(vm, "elementFromPoint", 2, elementFromPoint);
    const g = vm.global();
    try bind.accessors(vm, g, &.{
        .{ .name = "innerWidth", .get = innerWidth },
        .{ .name = "innerHeight", .get = innerHeight },
        .{ .name = "outerWidth", .get = innerWidth },
        .{ .name = "outerHeight", .get = innerHeight },
        .{ .name = "scrollX", .get = scrollX },
        .{ .name = "scrollY", .get = scrollY },
        .{ .name = "pageXOffset", .get = scrollX },
        .{ .name = "pageYOffset", .get = scrollY },
        .{ .name = "devicePixelRatio", .get = devicePixelRatio },
    });
    try bind.methods(vm, g, &.{
        .{ .name = "scrollTo", .arity = 0, .f = winScrollTo },
        .{ .name = "scroll", .arity = 0, .f = winScrollTo },
        .{ .name = "scrollBy", .arity = 0, .f = winScrollBy },
    });
}

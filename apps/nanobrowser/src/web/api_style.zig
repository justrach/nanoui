//! `element.style` and `getComputedStyle`. The inline style is the `style`
//! attribute, parsed here into declarations and written back on each change;
//! values aren't validated or normalized beyond trimming (the cascade ignores
//! what it can't read), so a script reads back what it wrote.
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const bind = @import("bind.zig");
const mutate = @import("mutate.zig");
const world_mod = @import("world.zig");
const geometry = @import("api_geometry.zig");
const names = @import("style_names.zig");
const Node = dom.Node;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;

const tag_style: u32 = 0x5354594c;
const tag_computed: u32 = 0x434f4d50;

const Decl = struct { name: []const u8, value: []const u8, important: bool };

fn hostNode(o: *js.Object) *Node {
    return @ptrCast(@alignCast(o.host));
}

fn thisStyle(vm: *Vm, this: Value) Error!*Node {
    const o = this.objectOrNull() orelse return bind.illegal(vm);
    if (o.host_tag != tag_style) return bind.illegal(vm);
    return hostNode(o);
}

/// The attribute's declarations, slices of it; later ones win when asked by name.
fn parse(gpa: std.mem.Allocator, text: []const u8, out: *std.ArrayList(Decl)) Error!void {
    var i: usize = 0;
    while (i < text.len) {
        var depth: u32 = 0;
        var quote: u8 = 0;
        var colon: ?usize = null;
        const start = i;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (quote != 0) {
                if (c == '\\') i += 1 else if (c == quote) quote = 0;
                continue;
            }
            switch (c) {
                '"', '\'' => quote = c,
                '(' => depth += 1,
                ')' => depth -|= 1,
                ':' => if (colon == null and depth == 0) {
                    colon = i;
                },
                ';' => if (depth == 0) break,
                else => {},
            }
        }
        const end = @min(i, text.len);
        i = end + 1;
        const cl = colon orelse continue;
        const name = std.mem.trim(u8, text[start..cl], " \t\r\n\x0c");
        var value = std.mem.trim(u8, text[cl + 1 .. end], " \t\r\n\x0c");
        if (name.len == 0) continue;
        var important = false;
        if (std.ascii.endsWithIgnoreCase(value, "!important")) {
            important = true;
            value = std.mem.trim(u8, value[0 .. value.len - "!important".len], " \t\r\n\x0c");
        }
        try out.append(gpa, .{ .name = name, .value = value, .important = important });
    }
}

fn find(list: []const Decl, name: []const u8) ?Decl {
    var i = list.len;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(list[i].name, name)) return list[i];
    }
    return null;
}

fn write(w: *World, n: *Node, list: []const Decl) Error!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(w.gpa);
    for (list) |d| {
        if (out.items.len > 0) try out.append(w.gpa, ' ');
        try out.appendSlice(w.gpa, d.name);
        try out.appendSlice(w.gpa, ": ");
        try out.appendSlice(w.gpa, d.value);
        if (d.important) try out.appendSlice(w.gpa, " !important");
        try out.append(w.gpa, ';');
    }
    if (out.items.len == 0 and n.hasAttr("style")) {
        try mutate.removeAttr(w, n, "style");
    } else try mutate.setAttr(w, n, "style", out.items);
}

/// Sets (or, for "", removes) one property. `name` is dashed.
fn setValue(w: *World, n: *Node, name: []const u8, value: []const u8, important: bool) Error!void {
    const cur = n.attr("style") orelse "";
    const trimmed = std.mem.trim(u8, value, " \t\r\n\x0c");
    if (!important and cur.len == 0) {
        if (trimmed.len == 0) return;
        var sbuf: [256]u8 = undefined;
        if (name.len + trimmed.len + 3 <= sbuf.len) {
            @memcpy(sbuf[0..name.len], name);
            sbuf[name.len] = ':';
            sbuf[name.len + 1] = ' ';
            @memcpy(sbuf[name.len + 2 .. name.len + 2 + trimmed.len], trimmed);
            sbuf[name.len + 2 + trimmed.len] = ';';
            return mutate.setAttr(w, n, "style", sbuf[0 .. name.len + 3 + trimmed.len]);
        }
    }
    if (!important and cur.len > name.len + 2 and std.ascii.startsWithIgnoreCase(cur, name) and cur[name.len] == ':' and std.mem.indexOfScalar(u8, cur[name.len + 1 ..], ':') == null and std.mem.indexOfScalar(u8, cur[name.len + 1 ..], '!') == null) {
        const semi = std.mem.indexOfScalar(u8, cur[name.len + 1 ..], ';');
        if (semi == null or std.mem.trim(u8, cur[name.len + 1 + semi.? + 1 ..], " \t\r\n\x0c").len == 0) {
            if (trimmed.len == 0) return mutate.removeAttr(w, n, "style");
            var sbuf: [256]u8 = undefined;
            if (name.len + trimmed.len + 3 <= sbuf.len) {
                @memcpy(sbuf[0..name.len], name);
                sbuf[name.len] = ':';
                sbuf[name.len + 1] = ' ';
                @memcpy(sbuf[name.len + 2 .. name.len + 2 + trimmed.len], trimmed);
                sbuf[name.len + 2 + trimmed.len] = ';';
                return mutate.setAttr(w, n, "style", sbuf[0 .. name.len + 3 + trimmed.len]);
            }
        }
    }
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(w.gpa);
    try parse(w.gpa, cur, &list);
    var i: usize = 0;
    var place: ?usize = null;
    while (i < list.items.len) {
        if (std.ascii.eqlIgnoreCase(list.items[i].name, name)) {
            if (place == null) {
                place = i;
                i += 1;
            } else _ = list.orderedRemove(i);
        } else i += 1;
    }
    if (trimmed.len == 0) {
        if (place) |p| {
            _ = list.orderedRemove(p);
            try write(w, n, list.items);
        }
        return;
    }
    if (place) |p| {
        list.items[p].value = trimmed;
        list.items[p].important = important;
    } else try list.append(w.gpa, .{ .name = name, .value = trimmed, .important = important });
    try write(w, n, list.items);
}

/// camelCase to the dashed name, in `buf`; null when too long.
fn dashed(buf: []u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    var start: usize = 0;
    if (std.mem.startsWith(u8, name, "webkit") and name.len > 6 and name[6] >= 'A' and name[6] <= 'Z') {
        @memcpy(buf[0..7], "-webkit");
        i = 7;
        start = 6;
    }
    for (name[start..]) |c| {
        if (i + 2 > buf.len) return null;
        if (c >= 'A' and c <= 'Z') {
            buf[i] = '-';
            buf[i + 1] = c + 32;
            i += 2;
        } else {
            buf[i] = c;
            i += 1;
        }
    }
    return buf[0..i];
}

fn known(buf: []u8, name: []const u8) ?[]const u8 {
    if (name.len == 0 or name.len > 60) return null;
    if (std.mem.eql(u8, name, "cssFloat")) return "float";
    const d = dashed(buf, name) orelse return null;
    return if (names.isKnown(d)) d else null;
}

fn styleGet(vm: *Vm, o: *js.Object, name: []const u8) Error!?Value {
    var buf: [128]u8 = undefined;
    const prop = known(&buf, name) orelse return null;
    const cur = hostNode(o).attr("style") orelse "";
    if (cur.len == 0) return Value.fromString(vm.empty);
    const w = bind.world(vm);
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(w.gpa);
    try parse(w.gpa, cur, &list);
    const d = find(list.items, prop) orelse return Value.fromString(vm.empty);
    return try vm.newString(d.value);
}

fn styleSet(vm: *Vm, o: *js.Object, name: []const u8, v: Value) Error!bool {
    var buf: [128]u8 = undefined;
    const prop = known(&buf, name) orelse return false;
    const text = if (v.isNull()) "" else try vm.toStringSlice(v);
    try setValue(bind.world(vm), hostNode(o), prop, text, false);
    return true;
}


fn styleIndex(vm: *Vm, o: *js.Object, i: u32) Error!?Value {
    const w = bind.world(vm);
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(w.gpa);
    try parse(w.gpa, hostNode(o).attr("style") orelse "", &list);
    if (i >= list.items.len) return null;
    return try vm.newString(list.items[i].name);
}

fn styleLength(vm: *Vm, o: *js.Object) Error!u32 {
    const cur = hostNode(o).attr("style") orelse "";
    if (cur.len == 0) return 0;
    const w = bind.world(vm);
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(w.gpa);
    try parse(w.gpa, cur, &list);
    return @intCast(list.items.len);
}

const style_hooks = js.HostHooks{
    .get_named = styleGet,
    .set_named = styleSet,
    .get_index = styleIndex,
    .length_index = styleLength,
    .named_null_deterministic = true,
};

pub fn inlineStyle(w: *World, n: *Node) Error!Value {
    if (n.js_style) |p| {
        const o: *js.Object = @ptrCast(@alignCast(p));
        return o.value();
    }
    const key = world_mod.CacheKey{ .node = n, .kind = .style };
    if (w.cached.get(key)) |o| {
        n.js_style = o;
        return o.value();
    }
    const o = try w.vm.newExoticObject(w.extra.style, tag_style, n, &style_hooks);
    try w.cached.put(w.gpa, key, o);
    n.js_style = o;
    return o.value();
}

fn getPropertyValue(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try thisStyle(vm, this);
    const prop = try bind.str(vm, args, 0);
    const cur = n.attr("style") orelse "";
    if (cur.len == 0) return Value.fromString(vm.empty);
    const w = bind.world(vm);
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(w.gpa);
    try parse(w.gpa, cur, &list);
    const d = find(list.items, prop) orelse return Value.fromString(vm.empty);
    return vm.newString(d.value);
}

fn getPropertyPriority(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try thisStyle(vm, this);
    const w = bind.world(vm);
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(w.gpa);
    try parse(w.gpa, n.attr("style") orelse "", &list);
    const d = find(list.items, try bind.str(vm, args, 0)) orelse return vm.newString("");
    return vm.newString(if (d.important) "important" else "");
}

fn setProperty(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try thisStyle(vm, this);
    const name = try bind.str(vm, args, 0);
    const value = try bind.strNullEmpty(vm, args, 1);
    const priority = bind.arg(args, 2);
    const important = priority.isString() and std.ascii.eqlIgnoreCase(try vm.toStringSlice(priority), "important");
    try setValue(bind.world(vm), n, name, value, important);
    return Value.undefined;
}

fn removeProperty(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try thisStyle(vm, this);
    const w = bind.world(vm);
    const name = try bind.str(vm, args, 0);
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(w.gpa);
    try parse(w.gpa, n.attr("style") orelse "", &list);
    const old = try vm.newString(if (find(list.items, name)) |d| d.value else "");
    try setValue(w, n, name, "", false);
    return old;
}

fn cssText(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString((try thisStyle(vm, this)).attr("style") orelse "");
}

fn setCssText(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try thisStyle(vm, this);
    const text = try bind.strNullEmpty(vm, args, 0);
    const w = bind.world(vm);
    if (text.len == 0) try mutate.removeAttr(w, n, "style") else try mutate.setAttr(w, n, "style", text);
    return Value.undefined;
}

fn item(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try thisStyle(vm, this);
    const w = bind.world(vm);
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(w.gpa);
    try parse(w.gpa, n.attr("style") orelse "", &list);
    const i = try vm.toNumber(bind.arg(args, 0));
    if (!(i >= 0 and i < @as(f64, @floatFromInt(list.items.len)))) return vm.newString("");
    return vm.newString(list.items[@intFromFloat(i)].name);
}

// getComputedStyle.

fn computedOf(vm: *Vm, this: Value) Error!*Node {
    const o = this.objectOrNull() orelse return bind.illegal(vm);
    if (o.host_tag != tag_computed) return bind.illegal(vm);
    return hostNode(o);
}

/// A property's value: used sizes where layout has them.
fn computedText(vm: *Vm, n: *Node, prop: []const u8) Error!Value {
    const w = bind.world(vm);
    const p = w.page;
    if (std.mem.eql(u8, prop, "width") or std.mem.eql(u8, prop, "height")) {
        if (geometry.flushLayout(w)) {
            if (@import("../layout/layout.zig").boxOfNode(n)) |b| {
                const r = if (n.computed) |st| (if (st.box_sizing == .border_box) b.borderRect() else b.contentRect()) else b.contentRect();
                var buf: [64]u8 = undefined;
                const v = if (prop[0] == 'w') r.w else r.h;
                return vm.newString(std.fmt.bufPrint(&buf, "{d}px", .{v}) catch "0px");
            }
        }
    }
    geometry.flushStyleForNode(w, n);
    if (p.engine.computedValue(n, prop)) |v| return vm.newString(v);
    return vm.newString("");
}

fn computedGet(vm: *Vm, o: *js.Object, name: []const u8) Error!?Value {
    var buf: [128]u8 = undefined;
    const prop = known(&buf, name) orelse return null;
    return try computedText(vm, hostNode(o), prop);
}


fn computedLength(_: *Vm, _: *js.Object) Error!u32 {
    return @intCast(names.count);
}

fn computedIndex(vm: *Vm, _: *js.Object, i: u32) Error!?Value {
    if (i >= names.count) return null;
    return try vm.newString(names.all[i]);
}

const computed_hooks = js.HostHooks{
    .get_named = computedGet,
    .get_index = computedIndex,
    .length_index = computedLength,
    .named_null_deterministic = true,
};

fn getComputedStyle(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const n = try bind.nodeArg(vm, args, 0, "getComputedStyle");
    const w = bind.world(vm);
    const key = world_mod.CacheKey{ .node = n, .kind = .computed };
    if (w.cached.get(key)) |o| return o.value();
    const o = try vm.newExoticObject(w.extra.computed_style, tag_computed, n, &computed_hooks);
    try w.cached.put(w.gpa, key, o);
    return o.value();
}

fn computedProperty(vm: *Vm, this: Value, args: []const Value) Error!Value {
    return computedText(vm, try computedOf(vm, this), try bind.str(vm, args, 0));
}

fn computedPriority(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return vm.newString("");
}

fn computedItem(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const i = try vm.toNumber(bind.arg(args, 0));
    if (!(i >= 0 and i < @as(f64, @floatFromInt(names.count)))) return vm.newString("");
    return vm.newString(names.all[@intFromFloat(i)]);
}

fn illegalCtor(vm: *Vm, _: Value, _: []const Value) Error!Value {
    return vm.throwError(.TypeError, "Illegal constructor");
}

pub fn install(w: *World) Error!void {
    const vm = w.vm;
    const pair = try vm.newClass("CSSStyleDeclaration", 0, illegalCtor, null);
    try vm.global().defineData(vm, "CSSStyleDeclaration", pair.ctor.value(), js.PropFlags.hidden);
    w.extra.style = pair.proto;
    try bind.methods(vm, pair.proto, &.{
        .{ .name = "getPropertyValue", .arity = 1, .f = getPropertyValue },
        .{ .name = "getPropertyPriority", .arity = 1, .f = getPropertyPriority },
        .{ .name = "setProperty", .arity = 2, .f = setProperty },
        .{ .name = "removeProperty", .arity = 1, .f = removeProperty },
        .{ .name = "item", .arity = 1, .f = item },
    });
    try bind.accessors(vm, pair.proto, &.{.{ .name = "cssText", .get = cssText, .set = setCssText }});
    const computed = try vm.newObjectWithProto(pair.proto);
    w.extra.computed_style = computed;
    try bind.methods(vm, computed, &.{
        .{ .name = "getPropertyValue", .arity = 1, .f = computedProperty },
        .{ .name = "getPropertyPriority", .arity = 1, .f = computedPriority },
        .{ .name = "item", .arity = 1, .f = computedItem },
    });
    try vm.global().defineMethod(vm, "getComputedStyle", 1, getComputedStyle);
}

test "declarations read as written" {
    var list: std.ArrayList(Decl) = .empty;
    defer list.deinit(std.testing.allocator);
    try parse(std.testing.allocator, "color: red; background: url(a;b.png) !important;;width:1px", &list);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("url(a;b.png)", list.items[1].value);
    try std.testing.expect(list.items[1].important);
}

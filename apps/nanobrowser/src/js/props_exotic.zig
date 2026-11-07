//! Own-property behaviour of exotic objects: string wrappers, typed arrays, host
//! collections and module namespaces, and the branch to proxy traps. Every function
//! returns null to mean "behave as an ordinary object here".

const std = @import("std");
const Value = @import("value.zig").Value;
const PropKey = @import("value.zig").PropKey;
const shape_mod = @import("shape.zig");
const PropFlags = shape_mod.PropFlags;
const objmod = @import("object.zig");
const Object = objmod.Object;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const str = @import("string.zig");
const define = @import("props_define.zig");
const Desc = define.Desc;
const Own = define.Own;
const proxy = @import("b_proxy.zig");
const typed = @import("b_typed.zig");
const module = @import("module.zig");

pub const proxyHas = proxy.has;
pub const proxyGetProto = proxy.getProto;
pub const proxySetProto = proxy.setProto;
pub const proxyIsExtensible = proxy.isExtensible;
pub const proxyPreventExtensions = proxy.preventExtensions;
pub const proxyOwnKeys = proxy.ownKeys;

fn keyBytes(vm: *Vm, key: PropKey) Error!?[]const u8 {
    if (!key.isAtom()) return null;
    return try key.atom().flat(vm);
}

pub fn get(vm: *Vm, o: *Object, key: PropKey, receiver: Value) Error!?Value {
    switch (o.class) {
        .proxy => return try proxy.get(vm, o, key, receiver),
        .typedarray => if (key.isIndex()) return try typed.getIndex(vm, o, key.index()),
        .string => {
            const s = o.payload.value.asString();
            if (key.eql(vm.k.length)) return Value.fromUsize(s.len16);
            if (key.isIndex() and key.index() < s.len16) {
                return Value.fromString(try str.fromCodeUnit(vm, try s.unitAt(vm, key.index())));
            }
        },
        .host_exotic => {
            const h = o.payload.hooks;
            if (key.isIndex()) {
                if (h.get_index) |f| {
                    if (try f(vm, o, key.index())) |v| return v;
                }
            } else if (try keyBytes(vm, key)) |name| {
                // Real properties (methods on the prototype, own data) win over named items.
                if (h.get_named) |f| {
                    if (try f(vm, o, name)) |v| return v;
                }
                if (key.eql(vm.k.length)) {
                    if (h.length_index) |f| return Value.fromUsize(try f(vm, o));
                }
            }
        },
        .module_ns => return module.nsGet(vm, o, key, receiver),
        else => {},
    }
    return null;
}

pub fn set(vm: *Vm, o: *Object, key: PropKey, val: Value, receiver: Value) Error!?bool {
    switch (o.class) {
        .proxy => return try proxy.set(vm, o, key, val, receiver),
        .typedarray => if (key.isIndex()) {
            if (receiver.isObject() and receiver.asObject() == o) {
                try typed.setIndex(vm, o, key.index(), val);
                return true;
            }
            if (!typed.isValidIndex(o, key.index())) return true;
        },
        .string => {
            const s = o.payload.value.asString();
            if (key.eql(vm.k.length)) return false;
            if (key.isIndex() and key.index() < s.len16) return false;
        },
        .host_exotic => {
            const h = o.payload.hooks;
            if (key.isIndex()) {
                if (h.set_index) |f| return try f(vm, o, key.index(), val);
            } else if (try keyBytes(vm, key)) |name| {
                if (h.set_named) |f| {
                    if (try f(vm, o, name, val)) return true;
                }
            }
        },
        .module_ns => return false,
        else => {},
    }
    return null;
}

pub fn delete(vm: *Vm, o: *Object, key: PropKey) Error!?bool {
    switch (o.class) {
        .proxy => return try proxy.delete(vm, o, key),
        .typedarray => if (key.isIndex()) return !typed.isValidIndex(o, key.index()),
        .string => {
            const s = o.payload.value.asString();
            if (key.eql(vm.k.length)) return false;
            if (key.isIndex() and key.index() < s.len16) return false;
        },
        .host_exotic => if (try keyBytes(vm, key)) |name| {
            if (o.payload.hooks.delete_named) |f| {
                if (try f(vm, o, name)) return true;
            }
        },
        .module_ns => return !try module.nsHas(vm, o, key),
        else => {},
    }
    return null;
}

/// Null means ordinary; a null inside means "no such property".
pub fn getOwn(vm: *Vm, o: *Object, key: PropKey) Error!??Own {
    switch (o.class) {
        .proxy => return try proxy.getOwn(vm, o, key),
        .typedarray => if (key.isIndex()) {
            if (!typed.isValidIndex(o, key.index())) return @as(?Own, null);
            const own = Own{ .value = try typed.getIndex(vm, o, key.index()), .flags = .{} };
            return @as(?Own, own);
        },
        .string => {
            const s = o.payload.value.asString();
            if (key.eql(vm.k.length)) {
                const own = Own{ .value = Value.fromUsize(s.len16), .flags = PropFlags.readonly };
                return @as(?Own, own);
            }
            if (key.isIndex() and key.index() < s.len16) {
                const c = try str.fromCodeUnit(vm, try s.unitAt(vm, key.index()));
                const own = Own{ .value = Value.fromString(c), .flags = .{ .writable = false, .configurable = false } };
                return @as(?Own, own);
            }
        },
        .host_exotic => {
            const h = o.payload.hooks;
            if (key.isIndex()) {
                if (h.get_index) |f| {
                    if (try f(vm, o, key.index())) |v| {
                        const own = Own{ .value = v, .flags = .{ .writable = h.set_index != null } };
                        return @as(?Own, own);
                    }
                }
            } else if (try keyBytes(vm, key)) |name| {
                if (h.get_named) |f| {
                    if (try f(vm, o, name)) |v| {
                        const own = Own{ .value = v, .flags = .{ .writable = h.set_named != null } };
                        return @as(?Own, own);
                    }
                }
                if (key.eql(vm.k.length)) {
                    if (h.length_index) |f| {
                        const own = Own{ .value = Value.fromUsize(try f(vm, o)), .flags = PropFlags.readonly };
                        return @as(?Own, own);
                    }
                }
            }
        },
        .module_ns => return try module.nsGetOwn(vm, o, key),
        else => {},
    }
    return null;
}

pub fn defineOwn(vm: *Vm, o: *Object, key: PropKey, d: Desc) Error!?bool {
    switch (o.class) {
        .proxy => return try proxy.defineOwn(vm, o, key, d),
        .typedarray => if (key.isIndex()) {
            if (!typed.isValidIndex(o, key.index())) return false;
            if (d.isAccessor() or d.configurable == false or d.enumerable == false or d.writable == false) return false;
            if (d.value) |v| try typed.setIndex(vm, o, key.index(), v);
            return true;
        },
        .string => {
            const s = o.payload.value.asString();
            if (key.eql(vm.k.length) or (key.isIndex() and key.index() < s.len16)) {
                const cur = (try getOwn(vm, o, key)).?.?;
                if (d.isAccessor() or d.configurable == true) return false;
                if (d.enumerable) |e| if (e != cur.flags.enumerable) return false;
                if (d.writable == true) return false;
                if (d.value) |v| if (!@import("conv.zig").sameValue(vm, v, cur.value)) return false;
                return true;
            }
        },
        .host_exotic => {
            const h = o.payload.hooks;
            if (key.isIndex()) {
                if (h.set_index) |f| {
                    if (d.value) |v| return try f(vm, o, key.index(), v);
                }
            } else if (try keyBytes(vm, key)) |name| {
                if (h.set_named) |f| {
                    if (d.value) |v| {
                        if (try f(vm, o, name, v)) return true;
                    }
                }
            }
        },
        .module_ns => {
            const cur = try module.nsGetOwn(vm, o, key);
            const own = cur orelse return false;
            if (d.isAccessor() or d.configurable == true or d.enumerable == false or d.writable == false) return false;
            if (d.value) |v| return @import("conv.zig").sameValue(vm, v, own.value);
            return true;
        },
        else => {},
    }
    return null;
}

/// Keys the exotic part contributes ahead of the ordinary ones.
pub fn ownKeysPrefix(vm: *Vm, o: *Object, out: *std.ArrayList(PropKey)) Error!void {
    switch (o.class) {
        .typedarray => {
            const n = typed.length(o);
            var i: u32 = 0;
            while (i < n) : (i += 1) try out.append(vm.gpa, PropKey.fromIndex(i));
        },
        .string => {
            const n = o.payload.value.asString().len16;
            var i: u32 = 0;
            while (i < n) : (i += 1) try out.append(vm.gpa, PropKey.fromIndex(i));
            try out.append(vm.gpa, vm.k.length);
        },
        .host_exotic => {
            const h = o.payload.hooks;
            if (h.length_index) |f| {
                const n = try f(vm, o);
                var i: u32 = 0;
                while (i < n) : (i += 1) try out.append(vm.gpa, PropKey.fromIndex(i));
            }
            if (h.own_names) |f| {
                var names: std.ArrayList(Value) = .empty;
                defer names.deinit(vm.gpa);
                try f(vm, o, &names);
                for (names.items) |n| try out.append(vm.gpa, try str.toKey(vm, n.asString()));
            }
        },
        .module_ns => try module.nsOwnKeys(vm, o, out),
        else => {},
    }
}

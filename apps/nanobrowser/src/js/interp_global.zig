//! Global lexical and var inline-cache resolution, declaration, and ReferenceError helpers.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const bc = @import("bytecode.zig");
const Object = @import("object.zig").Object;
const props = @import("props.zig");
const str = @import("string.zig");

fn notDefined(vm: *Vm, key: PropKey) Error {
    var buf: [128]u8 = undefined;
    const name = str.keyText(vm, key, buf[0..64]);
    const m = std.fmt.bufPrint(buf[64..], "{s} is not defined", .{name[0..@min(name.len, 40)]}) catch "variable is not defined";
    return vm.throwError(.ReferenceError, m);
}

pub fn throwTdzKey(vm: *Vm, key: PropKey) Error {
    var buf: [128]u8 = undefined;
    const name = str.keyText(vm, key, buf[0..64]);
    const m = std.fmt.bufPrint(buf[64..], "Cannot access '{s}' before initialization", .{name[0..@min(name.len, 24)]}) catch "Cannot access variable before initialization";
    return vm.throwError(.ReferenceError, m);
}

fn fillGlobal(vm: *Vm, ic: *bc.IC, holder: *Object, slot: u32) void {
    ic.shape = vm.global_lex.shape;
    ic.holder_shape = vm.global_obj.shape;
    ic.holder = holder;
    ic.slot = slot;
    ic.epoch = vm.proto_epoch;
}

/// Reads a global. typeof uses getGlobalOrUndefined instead, which never throws for a missing name.
pub fn getGlobal(vm: *Vm, ic: *bc.IC) Error!Value {
    const lex = vm.global_lex;
    if (lex.shape.find(ic.key)) |slot| {
        const v = lex.slots[slot];
        if (v.isHole()) return throwTdzKey(vm, ic.key);
        fillGlobal(vm, ic, lex, slot);
        return v;
    }
    const g = vm.global_obj;
    if (g.shape.find(ic.key)) |slot| {
        if (!g.shape.flagsAt(slot).accessor) {
            fillGlobal(vm, ic, g, slot);
            return g.slots[slot];
        }
    }
    if (!try props.has(vm, g, ic.key)) return notDefined(vm, ic.key);
    return props.get(vm, g, ic.key);
}

pub fn getGlobalOrUndefined(vm: *Vm, ic: *bc.IC) Error!Value {
    const lex = vm.global_lex;
    if (lex.shape.find(ic.key)) |slot| {
        const v = lex.slots[slot];
        if (v.isHole()) return throwTdzKey(vm, ic.key);
        return v;
    }
    return props.get(vm, vm.global_obj, ic.key);
}

pub fn putGlobal(vm: *Vm, ic: *bc.IC, v: Value, strict: bool) Error!void {
    const lex = vm.global_lex;
    if (lex.shape.find(ic.key)) |slot| {
        if (lex.slots[slot].isHole()) return throwTdzKey(vm, ic.key);
        if (!lex.shape.flagsAt(slot).writable) return vm.throwError(.TypeError, "Assignment to constant variable.");
        lex.slots[slot] = v;
        fillGlobal(vm, ic, lex, slot);
        return;
    }
    const g = vm.global_obj;
    if (g.shape.find(ic.key)) |slot| {
        const f = g.shape.flagsAt(slot);
        if (f.writable and !f.accessor) {
            g.slots[slot] = v;
            fillGlobal(vm, ic, g, slot);
            return;
        }
    } else if (strict and !try props.has(vm, g, ic.key)) {
        return notDefined(vm, ic.key);
    }
    if (!try props.set(vm, g, ic.key, v) and strict) return props.throwReadonly(vm, ic.key);
}

/// let/const/class initialization at script level.
pub fn initGlobalLex(vm: *Vm, ic: *bc.IC, v: Value) Error!void {
    const lex = vm.global_lex;
    const slot = lex.shape.find(ic.key) orelse return notDefined(vm, ic.key);
    lex.slots[slot] = v;
}

pub fn declareGlobalLex(vm: *Vm, key: PropKey, is_const: bool) Error!void {
    const lex = vm.global_lex;
    if (lex.shape.find(key) != null) return redeclared(vm, key);
    if (vm.global_obj.shape.find(key)) |slot| {
        if (!vm.global_obj.shape.flagsAt(slot).configurable) return redeclared(vm, key);
    }
    try props.addProp(vm, lex, key, Value.hole, .{ .writable = !is_const });
}

pub fn declareGlobalVar(vm: *Vm, key: PropKey) Error!void {
    if (vm.global_lex.shape.find(key) != null) return redeclared(vm, key);
    const g = vm.global_obj;
    if (g.shape.find(key) != null) return;
    try props.addProp(vm, g, key, Value.undefined, .{ .configurable = false });
}

pub fn defineGlobalFn(vm: *Vm, key: PropKey, f: Value) Error!void {
    if (vm.global_lex.shape.find(key) != null) return redeclared(vm, key);
    try props.defineData(vm, vm.global_obj, key, f, .{ .configurable = false });
}

fn redeclared(vm: *Vm, key: PropKey) Error {
    var buf: [128]u8 = undefined;
    const name = str.keyText(vm, key, buf[0..64]);
    const m = std.fmt.bufPrint(buf[64..], "Identifier '{s}' has already been declared", .{name[0..@min(name.len, 24)]}) catch "Identifier has already been declared";
    return vm.throwError(.SyntaxError, m);
}

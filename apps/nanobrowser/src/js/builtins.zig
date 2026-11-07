//! Creates the global object and installs every built-in, in dependency order.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const objmod = @import("object.zig");
const shape = @import("shape.zig");
const props = @import("props.zig");
const api = @import("vm_api.zig");
const b_function = @import("b_function.zig");
const b_object = @import("b_object.zig");
const b_error = @import("b_error.zig");
const b_array = @import("b_array.zig");
const b_array_iter = @import("b_array_iter.zig");
const b_string = @import("b_string.zig");
const b_number = @import("b_number.zig");
const b_math = @import("b_math.zig");
const b_json = @import("b_json.zig");
const b_date = @import("b_date.zig");
const b_collections = @import("b_collections.zig");
const b_promise = @import("b_promise.zig");
const b_proxy = @import("b_proxy.zig");
const b_regexp = @import("b_regexp.zig");
const b_typed = @import("b_typed.zig");
const b_bigint = @import("b_bigint.zig");
const b_intl = @import("b_intl.zig");

pub fn init(vm: *Vm) Error!void {
    const p = &vm.protos;
    // The roots everything hangs from come first; Function.prototype is itself a function.
    p.object = try objmod.create(vm, null, .object);
    vm.object_root = try shape.rootFor(vm, p.object);
    const fn_data = try vm.gpa.create(objmod.NativeData);
    fn_data.* = .{ .func = b_function.protoFunction, .name = vm.empty, .arity = 0 };
    p.function = try objmod.create(vm, p.object, .native);
    p.function.payload = .{ .native = fn_data };
    p.function.flags.callable = true;
    p.function.flags.lazy_fn = true;
    vm.fn_root = try shape.rootFor(vm, p.function);
    p.array = try objmod.create(vm, p.object, .array);
    vm.array_root = try shape.rootFor(vm, p.array);
    p.string = try objmod.createExotic(vm, p.object, .string);
    p.string.payload = .{ .value = Value.fromString(vm.empty) };
    p.number = try objmod.create(vm, p.object, .number);
    p.number.payload = .{ .value = Value.fromInt(0) };
    p.boolean = try objmod.create(vm, p.object, .boolean);
    p.boolean.payload = .{ .value = Value.false };
    p.symbol = try objmod.create(vm, p.object, .object);
    vm.global_obj = try objmod.create(vm, p.object, .object);
    vm.global_lex = try objmod.create(vm, null, .object);
    var s = vm.object_root;
    s = try shape.transition(vm, s, vm.k.value, shape.PropFlags.all);
    s = try shape.transition(vm, s, vm.k.done, shape.PropFlags.all);
    vm.iter_result_shape = s;

    try b_array_iter.initIterators(vm);
    try b_object.init(vm);
    try b_function.init(vm);
    try b_error.init(vm);
    try b_array.init(vm);
    try b_string.init(vm);
    try b_bigint.init(vm);
    try b_number.init(vm);
    try b_math.init(vm);
    try b_json.init(vm);
    try b_date.init(vm);
    try b_collections.init(vm);
    try b_promise.init(vm);
    try b_proxy.init(vm);
    try b_regexp.init(vm);
    try b_typed.init(vm);
    try b_intl.init(vm);
}

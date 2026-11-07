//! Array.prototype.sort: a stable merge sort whose comparator may run JS and throw.

const std = @import("std");
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const u = @import("b_util.zig");
const Value = u.Value;
const Object = u.Object;
const props = @import("props.zig");
const conv = @import("conv.zig");
const str = @import("string.zig");
const calls = @import("interp_call.zig");
const arr = @import("b_array.zig");
const big = @import("b_bigint.zig");

const Item = struct { v: Value, s: ?*str.JSString };

const Cmp = struct {
    vm: *Vm,
    f: Value,
    numeric: bool,

    /// Whether b must come strictly before a.
    fn gt(c: Cmp, a: Item, b: Item) Error!bool {
        if (!c.f.isUndefined()) {
            const r = try calls.call(c.vm, c.f, Value.undefined, &.{ a.v, b.v });
            return (try conv.toNumber(c.vm, r)) > 0;
        }
        if (c.numeric) {
            if (a.v.isBigInt()) return big.order(a.v, b.v) == .gt;
            const x = a.v.asNumber();
            const y = b.v.asNumber();
            if (x != x) return y == y;
            if (y != y) return false;
            if (x == 0 and y == 0) return !std.math.signbit(x) and std.math.signbit(y);
            return x > y;
        }
        return (try str.compare(c.vm, a.s.?, b.s.?)) == .gt;
    }
};

fn mergeSort(c: Cmp, items: []Item, tmp: []Item) Error!void {
    const n = items.len;
    // Insertion sort small runs: short arrays are the common case.
    const run = 8;
    var i: usize = 0;
    while (i < n) : (i += run) {
        const end = @min(i + run, n);
        var j = i + 1;
        while (j < end) : (j += 1) {
            const x = items[j];
            var k = j;
            while (k > i and try c.gt(items[k - 1], x)) : (k -= 1) items[k] = items[k - 1];
            items[k] = x;
        }
    }
    var width: usize = run;
    var src = items;
    var dst = tmp;
    while (width < n) : (width *= 2) {
        var lo: usize = 0;
        while (lo < n) : (lo += width * 2) {
            const mid = @min(lo + width, n);
            const hi = @min(lo + width * 2, n);
            var a = lo;
            var b = mid;
            var o = lo;
            while (a < mid and b < hi) : (o += 1) {
                if (try c.gt(src[a], src[b])) {
                    dst[o] = src[b];
                    b += 1;
                } else {
                    dst[o] = src[a];
                    a += 1;
                }
            }
            while (a < mid) : (a += 1) {
                dst[o] = src[a];
                o += 1;
            }
            while (b < hi) : (b += 1) {
                dst[o] = src[b];
                o += 1;
            }
        }
        const t = src;
        src = dst;
        dst = t;
    }
    if (src.ptr != items.ptr) @memcpy(items, src[0..n]);
}

/// Sorts in place, undefineds last. Without a comparator the order is by string,
/// or numeric for typed arrays.
pub fn sortValues(vm: *Vm, vals: []Value, cmp: Value, numeric: bool) Error!void {
    const n = vals.len;
    const items = try vm.gpa.alloc(Item, n);
    defer vm.gpa.free(items);
    var m: usize = 0;
    for (vals) |v| {
        if (v.isUndefined()) continue;
        const s = if (cmp.isUndefined() and !numeric) try conv.toStr(vm, v) else null;
        items[m] = .{ .v = v, .s = s };
        m += 1;
    }
    const tmp = try vm.gpa.alloc(Item, m);
    defer vm.gpa.free(tmp);
    try mergeSort(.{ .vm = vm, .f = cmp, .numeric = numeric }, items[0..m], tmp);
    for (items[0..m], 0..) |it, i| vals[i] = it.v;
    for (vals[m..]) |*v| v.* = Value.undefined;
}

pub fn sort(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const cmp = u.arg(args, 0);
    if (!cmp.isUndefined() and !cmp.isCallable()) return vm.throwError(.TypeError, "The comparison function must be either a function or undefined");
    const o = try conv.toObject(vm, this);
    const n = try conv.lengthOf(vm, o);
    // Holes are removed and appear at the end again, as the spec's SortIndexedProperties does.
    var vals: std.ArrayList(Value) = .empty;
    defer vals.deinit(vm.gpa);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (try props.has(vm, o, arr.key(i))) try vals.append(vm.gpa, try props.get(vm, o, arr.key(i)));
    }
    try sortValues(vm, vals.items, cmp, false);
    for (vals.items, 0..) |v, j| try props.put(vm, o, arr.key(j), v);
    i = vals.items.len;
    while (i < n) : (i += 1) {
        if (!try props.delete(vm, o, arr.key(i))) return vm.throwError(.TypeError, "Cannot delete property");
    }
    return o.value();
}

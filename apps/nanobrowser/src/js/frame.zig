//! A bytecode activation. Frames live in a fixed array owned by the Vm; a suspended
//! generator or async function copies its frame's contents to a Coroutine.

const Value = @import("value.zig").Value;
const heap = @import("heap.zig");
const Object = @import("object.zig").Object;
const bc = @import("bytecode.zig");
const coroutine = @import("coroutine.zig");

pub const Frame = struct {
    fp: *bc.FuncProto,
    /// The next instruction, valid whenever this frame is not the running one or
    /// a slow operation is in progress.
    pc: [*]const u8,
    bp: [*]Value,
    /// The slot that receives the return value; everything from here up is discarded.
    ret_sp: [*]Value,
    env: ?*heap.Env,
    func: *Object,
    this: Value,
    new_target: Value,
    args: [*]Value,
    argc: u32,
    /// Returning from this frame returns from the native run() that started it.
    is_entry: bool,
    is_construct: bool,
    co: ?*coroutine.Coroutine,
};

/// Operand-stack markers. They hide in the internal tag with a low-bit pattern no
/// real pointer has; the unwinder scans for them.
const T_INTERNAL: u64 = 0xFFF8;

pub const iter_marker = Value{ .bits = (T_INTERNAL << 48) | 2 };
pub const async_iter_marker = Value{ .bits = (T_INTERNAL << 48) | 6 };
pub const dead_marker = Value{ .bits = (T_INTERNAL << 48) | 10 };

pub inline fn catchMarker(pc_offset: u32) Value {
    return .{ .bits = (T_INTERNAL << 48) | (@as(u64, pc_offset) << 3) | 1 };
}
pub inline fn isCatchMarker(v: Value) bool {
    return v.bits >> 48 == T_INTERNAL and v.bits & 7 == 1;
}
pub inline fn catchOffset(v: Value) u32 {
    return @intCast((v.bits & 0xFFFF_FFFF_FFFF) >> 3);
}

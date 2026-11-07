//! The tagged JS value (NaN-boxed into 64 bits) and the property key.
//! Doubles are stored as themselves; every other kind lives in the negative
//! quiet-NaN space, with a 16-bit tag and a 48-bit payload. int32 is a separate
//! tag so integer arithmetic stays cheap and never allocates.

const std = @import("std");
const heap = @import("heap.zig");
const JSString = @import("string.zig").JSString;
const Symbol = @import("string.zig").Symbol;
const BigInt = @import("heap.zig").BigInt;
const Object = @import("object.zig").Object;

const T_INTERNAL: u64 = 0xFFF8;
const T_INT: u64 = 0xFFF9;
const T_SPECIAL: u64 = 0xFFFA;
const T_OBJECT: u64 = 0xFFFB;
const T_STRING: u64 = 0xFFFC;
const T_SYMBOL: u64 = 0xFFFD;
const T_BIGINT: u64 = 0xFFFE;
const FIRST_TAG: u64 = T_INTERNAL << 48;
const PAYLOAD: u64 = (1 << 48) - 1;
const CANON_NAN: u64 = 0x7FF8_0000_0000_0000;

pub const Value = extern struct {
    bits: u64,

    pub const @"undefined" = Value{ .bits = (T_SPECIAL << 48) | 0 };
    pub const @"null" = Value{ .bits = (T_SPECIAL << 48) | 1 };
    pub const @"false" = Value{ .bits = (T_SPECIAL << 48) | 2 };
    pub const @"true" = Value{ .bits = (T_SPECIAL << 48) | 3 };
    /// The array hole and the temporal-dead-zone marker; never visible to JS.
    pub const hole = Value{ .bits = (T_SPECIAL << 48) | 4 };
    pub const nan = Value{ .bits = CANON_NAN };

    pub inline fn fromBool(b: bool) Value {
        return if (b) Value.true else Value.false;
    }
    pub inline fn fromInt(i: i32) Value {
        return .{ .bits = (T_INT << 48) | @as(u64, @as(u32, @bitCast(i))) };
    }
    pub inline fn fromDouble(d: f64) Value {
        if (d != d) return nan;
        return .{ .bits = @bitCast(d) };
    }
    /// Stores d as an int32 when it is one exactly (and not -0).
    pub inline fn fromNumber(d: f64) Value {
        if (d >= -2147483648.0 and d <= 2147483647.0) {
            const i: i32 = @intFromFloat(d);
            if (@as(f64, @floatFromInt(i)) == d and (i != 0 or !std.math.signbit(d))) return fromInt(i);
        }
        return fromDouble(d);
    }
    pub fn fromUsize(n: usize) Value {
        if (n <= std.math.maxInt(i32)) return fromInt(@intCast(n));
        return fromDouble(@floatFromInt(n));
    }
    pub inline fn fromObject(o: *Object) Value {
        return .{ .bits = (T_OBJECT << 48) | @intFromPtr(o) };
    }
    pub inline fn fromString(s: *JSString) Value {
        return .{ .bits = (T_STRING << 48) | @intFromPtr(s) };
    }
    pub inline fn fromSymbol(s: *Symbol) Value {
        return .{ .bits = (T_SYMBOL << 48) | @intFromPtr(s) };
    }
    pub inline fn fromBigInt(b: *BigInt) Value {
        return .{ .bits = (T_BIGINT << 48) | @intFromPtr(b) };
    }
    /// An engine-private heap cell (Env, accessor pair); only ever seen by the VM.
    pub inline fn fromCell(c: *heap.Cell) Value {
        return .{ .bits = (T_INTERNAL << 48) | @intFromPtr(c) };
    }

    pub inline fn tag(v: Value) u64 {
        return v.bits >> 48;
    }
    pub inline fn isDouble(v: Value) bool {
        return v.bits < FIRST_TAG;
    }
    pub inline fn isInt(v: Value) bool {
        return v.tag() == T_INT;
    }
    pub inline fn isNumber(v: Value) bool {
        return v.isDouble() or v.isInt();
    }
    pub inline fn isUndefined(v: Value) bool {
        return v.bits == Value.undefined.bits;
    }
    pub inline fn isNull(v: Value) bool {
        return v.bits == Value.null.bits;
    }
    pub inline fn isNullish(v: Value) bool {
        return v.bits | 1 == Value.null.bits;
    }
    pub inline fn isBool(v: Value) bool {
        return v.bits | 1 == Value.true.bits;
    }
    pub inline fn isHole(v: Value) bool {
        return v.bits == hole.bits;
    }
    pub inline fn isObject(v: Value) bool {
        return v.tag() == T_OBJECT;
    }
    pub inline fn isString(v: Value) bool {
        return v.tag() == T_STRING;
    }
    pub inline fn isSymbol(v: Value) bool {
        return v.tag() == T_SYMBOL;
    }
    pub inline fn isBigInt(v: Value) bool {
        return v.tag() == T_BIGINT;
    }
    pub inline fn isInternal(v: Value) bool {
        return v.tag() == T_INTERNAL;
    }
    pub fn isCallable(v: Value) bool {
        return v.isObject() and v.asObject().flags.callable;
    }
    pub fn isConstructor(v: Value) bool {
        return v.isObject() and v.asObject().flags.constructor;
    }

    pub inline fn asInt(v: Value) i32 {
        return @bitCast(@as(u32, @truncate(v.bits)));
    }
    pub inline fn asDouble(v: Value) f64 {
        return @bitCast(v.bits);
    }
    /// The numeric value of a value already known to be a number.
    pub inline fn asNumber(v: Value) f64 {
        return if (v.isInt()) @floatFromInt(v.asInt()) else v.asDouble();
    }
    pub inline fn asBool(v: Value) bool {
        return v.bits == Value.true.bits;
    }
    pub inline fn asObject(v: Value) *Object {
        return @ptrFromInt(v.bits & PAYLOAD);
    }
    pub inline fn asString(v: Value) *JSString {
        return @ptrFromInt(v.bits & PAYLOAD);
    }
    pub inline fn asSymbol(v: Value) *Symbol {
        return @ptrFromInt(v.bits & PAYLOAD);
    }
    pub inline fn asBigInt(v: Value) *BigInt {
        return @ptrFromInt(v.bits & PAYLOAD);
    }
    pub inline fn asCell(v: Value) *heap.Cell {
        return @ptrFromInt(v.bits & PAYLOAD);
    }
    /// The object inside v, or null when v is not an object.
    pub inline fn objectOrNull(v: Value) ?*Object {
        return if (v.isObject()) v.asObject() else null;
    }
    /// The heap cell behind any pointer-tagged value, for the marker.
    pub inline fn heapCell(v: Value) ?*heap.Cell {
        const t = v.tag();
        if (t == T_OBJECT or t == T_STRING or t == T_SYMBOL or t == T_BIGINT) {
            return @ptrFromInt(v.bits & PAYLOAD);
        }
        // Internal values are cells only when pointer-aligned; others are stack markers.
        if (t == T_INTERNAL and v.bits & 7 == 0 and v.bits & PAYLOAD != 0) {
            return @ptrFromInt(v.bits & PAYLOAD);
        }
        return null;
    }
    pub inline fn same(a: Value, b: Value) bool {
        return a.bits == b.bits;
    }
};

/// A property key: an interned string, a symbol, or an array index below 2^32-1.
/// Keys compare by bits. Zero is reserved for "no key" (a deleted table entry).
pub const PropKey = extern struct {
    bits: u64,

    pub const none = PropKey{ .bits = 0 };
    const TAG_MASK: u64 = 7;
    const TAG_ATOM: u64 = 0;
    const TAG_SYMBOL: u64 = 1;
    const TAG_INDEX: u64 = 2;

    pub inline fn fromAtom(s: *JSString) PropKey {
        return .{ .bits = @intFromPtr(s) };
    }
    pub inline fn fromSymbol(s: *Symbol) PropKey {
        return .{ .bits = @intFromPtr(s) | TAG_SYMBOL };
    }
    pub inline fn fromIndex(i: u32) PropKey {
        return .{ .bits = (@as(u64, i) << 3) | TAG_INDEX };
    }
    pub inline fn isAtom(k: PropKey) bool {
        return k.bits & TAG_MASK == TAG_ATOM and k.bits != 0;
    }
    pub inline fn isSymbol(k: PropKey) bool {
        return k.bits & TAG_MASK == TAG_SYMBOL;
    }
    pub inline fn isIndex(k: PropKey) bool {
        return k.bits & TAG_MASK == TAG_INDEX;
    }
    pub inline fn index(k: PropKey) u32 {
        return @intCast(k.bits >> 3);
    }
    pub inline fn atom(k: PropKey) *JSString {
        return @ptrFromInt(k.bits);
    }
    pub inline fn symbol(k: PropKey) *Symbol {
        return @ptrFromInt(k.bits & ~TAG_MASK);
    }
    pub inline fn eql(a: PropKey, b: PropKey) bool {
        return a.bits == b.bits;
    }
    pub inline fn hash(k: PropKey) u32 {
        const m = k.bits *% 0x9E37_79B9_7F4A_7C15;
        return @truncate(m >> 32);
    }
    pub fn isPrivate(k: PropKey) bool {
        return k.isSymbol() and k.symbol().is_private;
    }
};

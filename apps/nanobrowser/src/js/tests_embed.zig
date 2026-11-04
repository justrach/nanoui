//! The embedding API as the DOM bindings will use it.

const std = @import("std");
const js = @import("js.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Value = js.Value;

fn newVm() !*js.Vm {
    return js.Vm.create(std.testing.allocator);
}

fn addFn(vm: *js.Vm, _: Value, args: []const Value) js.Error!Value {
    return Value.fromNumber((try vm.toNumber(args[0])) + (try vm.toNumber(args[1])));
}

fn throwsFn(vm: *js.Vm, _: Value, _: []const Value) js.Error!Value {
    return vm.throwError(.RangeError, "from native");
}

fn callbackFn(vm: *js.Vm, this: Value, args: []const Value) js.Error!Value {
    return vm.call(args[0], this, &.{Value.fromInt(41)});
}

fn getterFn(_: *js.Vm, this: Value, _: []const Value) js.Error!Value {
    return this.asObject().get(undefined, "") catch Value.undefined;
}

fn captureFn(vm: *js.Vm, _: Value, _: []const Value) js.Error!Value {
    return vm.capture(0);
}

test "values and strings" {
    const vm = try newVm();
    defer vm.deinit();
    try expect(Value.undefined.isUndefined());
    try expect(Value.null.isNull());
    try expect(Value.fromBool(true).asBool());
    try expectEqual(@as(f64, 1.5), Value.fromNumber(1.5).asNumber());
    try expect(Value.fromNumber(3).isInt());
    try expect(Value.fromNumber(-0.0).isDouble());
    const s = try vm.newString("h\xC3\xA9");
    try expect(s.isString());
    try expectEqualStrings("h\xC3\xA9", try vm.toStringSlice(s));
    try expectEqualStrings("12", try vm.toStringSlice(Value.fromInt(12)));
    try expectEqualStrings("string", vm.typeOf(s));
    try expect(vm.toBoolean(s));
    try expectEqual(@as(f64, 7), try vm.toNumber(try vm.newString("7")));
    const bad = try vm.newString("\xFFa");
    try expectEqual(@as(usize, 2), bad.asString().len16);
}

test "objects, natives, calling in both directions" {
    const vm = try newVm();
    defer vm.deinit();
    const g = vm.global();
    try g.defineMethod(vm, "add", 2, addFn);
    try g.defineMethod(vm, "boom", 0, throwsFn);
    try g.defineMethod(vm, "cb", 1, callbackFn);
    const r = try vm.eval("add(40,2)", "t.js");
    try expectEqual(@as(f64, 42), r.asNumber());
    try expectEqualStrings("add", try vm.toStringSlice(try vm.eval("add.name", "t.js")));
    try expectEqual(@as(f64, 2), (try vm.eval("add.length", "t.js")).asNumber());
    try expectEqualStrings("RangeError:from native", try vm.toStringSlice(try vm.eval("try{boom()}catch(e){e.name+':'+e.message}", "t.js")));
    try expectEqual(@as(f64, 42), (try vm.eval("cb(x=>x+1)", "t.js")).asNumber());
    const o = try vm.newObject();
    try o.set(vm, "a", Value.fromInt(1));
    try expectEqual(@as(f64, 1), (try o.get(vm, "a")).asNumber());
    try o.setIdx(vm, 2, Value.fromInt(5));
    try expectEqual(@as(f64, 5), (try o.getIdx(vm, 2)).asNumber());
    try o.defineData(vm, "hidden", Value.fromInt(2), .{ .enumerable = false });
    try g.set(vm, "obj", o.value());
    try expectEqualStrings("2,a", try vm.toStringSlice(try vm.eval("Object.keys(obj).join()", "t.js")));
    const arr = try vm.newArray(&.{ Value.fromInt(1), Value.fromInt(2) });
    try g.set(vm, "arr", arr.value());
    try expectEqualStrings("1,2", try vm.toStringSlice(try vm.eval("arr.join()", "t.js")));
    const p = try vm.newObjectWithProto(arr);
    try expect((try p.getIdx(vm, 0)).asNumber() == 1);
    const f = try vm.eval("(function(a){return this.v+a})", "t.js");
    const this = try vm.newObject();
    try this.set(vm, "v", Value.fromInt(1));
    try expectEqual(@as(f64, 3), (try vm.call(f, this.value(), &.{Value.fromInt(2)})).asNumber());
    const C = try vm.eval("(class{constructor(x){this.x=x}})", "t.js");
    const inst = try vm.construct(C, &.{Value.fromInt(9)});
    try expectEqual(@as(f64, 9), (try inst.asObject().get(vm, "x")).asNumber());
    const clo = try vm.newNativeClosure("c", 0, captureFn, &.{Value.fromInt(77)});
    try expectEqual(@as(f64, 77), (try vm.call(clo, Value.undefined, &.{})).asNumber());
    // Errors from scripts and exceptionString.
    try std.testing.expectError(error.Thrown, vm.eval("function thrower(){throw new TypeError('bad')}\nthrower()", "file.js"));
    const text = vm.exceptionString();
    try expect(std.mem.indexOf(u8, text, "TypeError: bad") != null);
    try expect(std.mem.indexOf(u8, text, "thrower (file.js:1:") != null);
    try std.testing.expectError(error.Thrown, vm.eval("syntax error here", "x.js"));
    try std.testing.expect(vm.throwValue(Value.fromInt(1)) == error.Thrown);
    try expectEqual(@as(f64, 1), vm.exception.asNumber());
}

fn elementCtor(vm: *js.Vm, this: Value, args: []const Value) js.Error!Value {
    try this.asObject().set(vm, "tag", if (args.len > 0) args[0] else Value.undefined);
    this.asObject().host_tag = 42;
    return Value.undefined;
}

fn tagGetter(_: *js.Vm, this: Value, _: []const Value) js.Error!Value {
    return Value.fromInt(@intCast(this.asObject().host_tag));
}

fn tagSetter(vm: *js.Vm, this: Value, args: []const Value) js.Error!Value {
    this.asObject().host_tag = @intFromFloat(try vm.toNumber(args[0]));
    return Value.undefined;
}

test "native classes and accessors" {
    const vm = try newVm();
    defer vm.deinit();
    const base = try vm.newClass("Node", 0, elementCtor, null);
    const el = try vm.newClass("Element", 1, elementCtor, base.proto);
    try el.proto.defineAccessor(vm, "code", tagGetter, tagSetter);
    try vm.global().defineData(vm, "Element", el.ctor.value(), .{ .enumerable = false });
    try vm.global().defineData(vm, "Node", base.ctor.value(), .{ .enumerable = false });
    try expectEqualStrings("div", try vm.toStringSlice(try vm.eval("new Element('div').tag", "t.js")));
    try expectEqual(@as(f64, 42), (try vm.eval("new Element().code", "t.js")).asNumber());
    try expectEqual(@as(f64, 5), (try vm.eval("var e=new Element(); e.code=5; e.code", "t.js")).asNumber());
    try expect((try vm.eval("new Element() instanceof Element", "t.js")).asBool());
    try expectEqualStrings("TypeError", try vm.toStringSlice(try vm.eval("try{Element()}catch(e){e.name}", "t.js")));
    try expectEqualStrings("my,span,42", try vm.toStringSlice(try vm.eval(
        \\class My extends Element{constructor(){super('span');this.mine='my'}}
        \\var m=new My(); [m.mine,m.tag,m.code].join()
    , "t.js")));
    try expect((try vm.eval("new My() instanceof Element", "t.js")).asBool());
    try expect((try vm.eval("Object.getPrototypeOf(Element.prototype)===Node.prototype", "t.js")).asBool());
}

const Coll = struct {
    items: [2]i32 = .{ 10, 20 },
    set_seen: i32 = 0,
};

fn collOf(o: *js.Object) *Coll {
    return @ptrCast(@alignCast(o.host.?));
}
fn hGetIndex(_: *js.Vm, o: *js.Object, i: u32) js.Error!?Value {
    const c = collOf(o);
    return if (i < c.items.len) Value.fromInt(c.items[i]) else null;
}
fn hSetIndex(vm: *js.Vm, o: *js.Object, i: u32, v: Value) js.Error!bool {
    const c = collOf(o);
    if (i >= c.items.len) return false;
    c.items[i] = @intFromFloat(try vm.toNumber(v));
    return true;
}
fn hLen(_: *js.Vm, o: *js.Object) js.Error!u32 {
    return @intCast(collOf(o).items.len);
}
fn hGetNamed(vm: *js.Vm, o: *js.Object, name: []const u8) js.Error!?Value {
    if (std.mem.eql(u8, name, "first")) return Value.fromInt(collOf(o).items[0]);
    if (std.mem.eql(u8, name, "text")) return try vm.newString("t");
    return null;
}
fn hSetNamed(vm: *js.Vm, o: *js.Object, name: []const u8, v: Value) js.Error!bool {
    if (!std.mem.eql(u8, name, "first")) return false;
    collOf(o).set_seen = @intFromFloat(try vm.toNumber(v));
    return true;
}
fn hOwnNames(vm: *js.Vm, _: *js.Object, out: *std.ArrayList(Value)) js.Error!void {
    try out.append(vm.gpa, try vm.newString("first"));
}

const coll_hooks = js.HostHooks{
    .get_named = hGetNamed,
    .set_named = hSetNamed,
    .get_index = hGetIndex,
    .set_index = hSetIndex,
    .length_index = hLen,
    .own_names = hOwnNames,
};

test "host exotic objects" {
    const vm = try newVm();
    defer vm.deinit();
    var coll = Coll{};
    const proto = try vm.newObject();
    try proto.defineMethod(vm, "item", 1, addFn);
    const o = try vm.newExoticObject(proto, 7, &coll, &coll_hooks);
    try expectEqual(@as(u32, 7), o.host_tag);
    try vm.global().set(vm, "c", o.value());
    try expectEqual(@as(f64, 10), (try vm.eval("c[0]", "t.js")).asNumber());
    try expectEqual(@as(f64, 2), (try vm.eval("c.length", "t.js")).asNumber());
    try expectEqual(@as(f64, 10), (try vm.eval("c.first", "t.js")).asNumber());
    try expectEqualStrings("t", try vm.toStringSlice(try vm.eval("c.text", "t.js")));
    try expect((try vm.eval("c[5]", "t.js")).isUndefined());
    try expect((try vm.eval("c.nothing", "t.js")).isUndefined());
    try expectEqual(@as(f64, 3), (try vm.eval("c.item(1,2)", "t.js")).asNumber());
    _ = try vm.eval("c[1]=99", "t.js");
    try expectEqual(@as(i32, 99), coll.items[1]);
    _ = try vm.eval("c.first=5", "t.js");
    try expectEqual(@as(i32, 5), coll.set_seen);
    _ = try vm.eval("c.expando=5", "t.js");
    try expectEqual(@as(f64, 5), (try vm.eval("c.expando", "t.js")).asNumber());
    try expect((try vm.eval("0 in c", "t.js")).asBool());
    try expect(!(try vm.eval("2 in c", "t.js")).asBool());
    try expectEqualStrings("0,1,first,expando", try vm.toStringSlice(try vm.eval("Object.keys(c).join()", "t.js")));
    try expectEqualStrings("10,99", try vm.toStringSlice(try vm.eval("Array.prototype.slice.call(c).join()", "t.js")));
    try expectEqualStrings("10,99", try vm.toStringSlice(try vm.eval("Array.from({length:c.length},(_, i)=>c[i]).join()", "t.js")));
    // A named item shadows the prototype, whatever a shared call site saw before.
    try proto.set(vm, "first", Value.fromInt(1000));
    try vm.global().set(vm, "protoOwner", (try vm.newObjectWithProto(proto)).value());
    try expectEqual(@as(f64, 5), (try vm.eval("function h(x){return x.first}; h(protoOwner); h(protoOwner); c[0]=5; h(c)", "t.js")).asNumber());
    // Monomorphic site seeing exotics and ordinary objects: caches must not confuse them.
    try expectEqual(@as(f64, 2), (try vm.eval("function g(x){return x.first}; g({first:1}); g(c); g({first:2})", "t.js")).asNumber());
}

test "promises from the host, rejection hook, jobs" {
    const vm = try newVm();
    defer vm.deinit();
    const Hook = struct {
        var count: u32 = 0;
        var last: f64 = 0;
        fn f(_: ?*anyopaque, v: *js.Vm, _: Value, reason: Value) void {
            count += 1;
            last = v.toNumber(reason) catch -1;
        }
    };
    Hook.count = 0;
    vm.setRejectionHook(null, Hook.f);
    const cap = try vm.newPromiseCapability();
    try vm.global().set(vm, "p", cap.promise);
    _ = try vm.eval("var seen; p.then(v=>seen=v)", "t.js");
    try vm.resolvePromise(cap.promise, Value.fromInt(5));
    vm.runJobs();
    try expectEqual(@as(f64, 5), (try vm.eval("seen", "t.js")).asNumber());
    const cap2 = try vm.newPromiseCapability();
    _ = try vm.call(cap2.resolve, Value.undefined, &.{Value.fromInt(6)});
    _ = try vm.eval("Promise.reject(7)", "t.js");
    vm.runJobs();
    try expectEqual(@as(u32, 1), Hook.count);
    try expectEqual(@as(f64, 7), Hook.last);
    _ = try vm.eval("Promise.reject(8).catch(()=>{})", "t.js");
    vm.runJobs();
    try expectEqual(@as(u32, 1), Hook.count);
    _ = try vm.eval("Promise.reject(9); (async()=>{throw 10})()", "t.js");
    vm.runJobs();
    try expectEqual(@as(u32, 3), Hook.count);
    const q = try vm.eval("(function(){globalThis.ran=1})", "t.js");
    try js.enqueueJob(vm, q);
    vm.runJobs();
    try expectEqual(@as(f64, 1), (try vm.eval("ran", "t.js")).asNumber());
}

test "deadline interrupts runaway scripts" {
    const vm = try newVm();
    defer vm.deinit();
    vm.setDeadline(20 * std.time.ns_per_ms);
    try std.testing.expectError(error.Terminated, vm.eval("while(1){}", "t.js"));
    vm.setDeadline(20 * std.time.ns_per_ms);
    try std.testing.expectError(error.Terminated, vm.eval("try{for(;;){}}catch(e){} finally{globalThis.x=1}", "t.js"));
    try expect((try vm.eval("typeof x", "t.js")).isString());
    try expectEqualStrings("undefined", try vm.toStringSlice(try vm.eval("typeof x", "t.js")));
    vm.setDeadline(20 * std.time.ns_per_ms);
    try std.testing.expectError(error.Terminated, vm.eval("function f(){for(;;);} [1].map(f)", "t.js"));
    vm.setDeadline(20 * std.time.ns_per_ms);
    try std.testing.expectError(error.Terminated, vm.eval("(function*(){for(;;);})().next()", "t.js"));
    // The VM still works afterwards.
    try expectEqual(@as(f64, 2), (try vm.eval("1+1", "t.js")).asNumber());
    // A regexp that backtracks forever obeys the deadline too.
    vm.setDeadline(20 * std.time.ns_per_ms);
    const r = vm.eval("/(a|a)+$/.test('a'.repeat(50)+'b')", "t.js");
    try expect(if (r) |_| false else |e| (e == error.Terminated or e == error.Thrown));
    vm.setDeadline(0);
}

test "heap limit throws RangeError instead of crashing" {
    const vm = try newVm();
    defer vm.deinit();
    vm.setHeapLimit(vm.bytesAllocated() + 8 * 1024 * 1024);
    const r = try vm.eval("var r='none'; try{var a=[]; for(;;) a.push({x:1})}catch(e){r=e.name+':'+(e instanceof RangeError)} a=null; r", "t.js");
    try expectEqualStrings("RangeError:true", try vm.toStringSlice(r));
    vm.collect();
    vm.setHeapLimit(vm.bytesAllocated() + 8 * 1024 * 1024);
    const r2 = try vm.eval("try{var s='x'; for(;;) s+=s; }catch(e){e.name}", "t.js");
    try expectEqualStrings("RangeError", try vm.toStringSlice(r2));
    const r3 = try vm.eval("try{new Array(1e9).fill(0)}catch(e){e.name}", "t.js");
    try expectEqualStrings("RangeError", try vm.toStringSlice(r3));
    try expect(vm.bytesAllocated() > 0);
}

test "timezone hook" {
    const vm = try newVm();
    defer vm.deinit();
    const Tz = struct {
        fn f(_: f64) f64 {
            return 120;
        }
    };
    vm.tz_offset_fn = Tz.f;
    try expectEqual(@as(f64, -120), (try vm.eval("new Date(0).getTimezoneOffset()", "t.js")).asNumber());
    try expectEqual(@as(f64, 2), (try vm.eval("new Date(0).getHours()", "t.js")).asNumber());
    try expectEqual(@as(f64, 0), (try vm.eval("new Date(1970,0,1,2).getTime()", "t.js")).asNumber());
    try expectEqualStrings("Thu Jan 01 1970 02:00:00 GMT+0200 (Local Time)", try vm.toStringSlice(try vm.eval("String(new Date(0))", "t.js")));
    try expectEqual(@as(f64, -7200000), (try vm.eval("new Date('1970-01-01T00:00:00').getTime()", "t.js")).asNumber());
    try expectEqual(@as(f64, 0), (try vm.eval("new Date('1970-01-01').getTime()", "t.js")).asNumber());
}

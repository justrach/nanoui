//! ES modules through the embedding API: every import and export form, live bindings,
//! cycles, top-level await, import.meta and import().

const std = @import("std");
const js = @import("js.zig");

const Entry = struct { url: []const u8, src: []const u8 };

const Loader = struct {
    vm: *js.Vm,
    files: []const Entry,
    loaded: std.StringHashMapUnmanaged(*js.Module) = .empty,

    fn load(l: *Loader, url: []const u8) anyerror!*js.Module {
        if (l.loaded.get(url)) |m| return m;
        for (l.files) |f| {
            if (std.mem.eql(u8, f.url, url)) {
                const m = try l.vm.compileModule(f.src, f.url);
                try l.loaded.put(std.heap.smp_allocator, f.url, m);
                for (m.requests) |r| _ = try l.load(try r.flat(l.vm));
                return m;
            }
        }
        return error.NotFound;
    }

    fn resolve(ctx: ?*anyopaque, _: *js.Vm, spec: []const u8, _: *js.Module) ?*js.Module {
        const l: *Loader = @ptrCast(@alignCast(ctx.?));
        return l.load(spec) catch null;
    }
};

/// Runs "main" with these files, then compares String(globalThis.out).
fn expectModule(files: []const Entry, want: []const u8) !void {
    const gpa = std.heap.smp_allocator;
    const vm = try js.Vm.create(gpa);
    defer vm.deinit();
    var l = Loader{ .vm = vm, .files = files };
    defer l.loaded.deinit(gpa);
    const m = l.load("main") catch |e| {
        std.debug.print("\nmodule load failed: {s}: {s}\n", .{ @errorName(e), vm.exceptionString() });
        return error.TestFailed;
    };
    vm.linkModule(m, &l, Loader.resolve) catch |e| {
        std.debug.print("\nlink failed: {s}: {s}\n", .{ @errorName(e), vm.exceptionString() });
        return error.TestFailed;
    };
    const p = try vm.evaluateModule(m);
    vm.runJobs();
    const d = p.asObject().payload.promise;
    if (d.state == .rejected) {
        vm.exception = d.result;
        std.debug.print("\nmodule rejected: {s}\n", .{vm.exceptionString()});
        return error.TestFailed;
    }
    const v = try vm.eval("String(globalThis.out)", "t.js");
    const s = try vm.toStringSlice(v);
    if (!std.mem.eql(u8, s, want)) {
        std.debug.print("\nFAILED module: want {s} got {s}\n", .{ want, s });
        return error.TestFailed;
    }
}

test "import and export forms" {
    try expectModule(&.{
        .{ .url = "main", .src = "import d, {a, b as c} from 'x'; import * as ns from 'x'; globalThis.out=[d,a,c,ns.a,ns.default].join()" },
        .{ .url = "x", .src = "export default 9; export const a=1; const q=2; export {q as b}" },
    }, "9,1,2,1,9");
    try expectModule(&.{
        .{ .url = "main", .src = "import {f,C,v,g} from 'x'; globalThis.out=f()+new C().m()+v+g().next().value" },
        .{ .url = "x", .src = "export function f(){return 1}; export class C{m(){return 2}}; export var v=3; export function*g(){yield 4}" },
    }, "10");
    try expectModule(&.{
        .{ .url = "main", .src = "import {a,b,default as d} from 'r'; globalThis.out=a+b+d" },
        .{ .url = "r", .src = "export {a} from 'x'; export {b as b, default} from 'x'" },
        .{ .url = "x", .src = "export const a=1,b=2; export default 3" },
    }, "6");
    try expectModule(&.{
        .{ .url = "main", .src = "import {a} from 's'; import * as ns from 's'; globalThis.out=a+Object.keys(ns).join()+('default' in ns)" },
        .{ .url = "s", .src = "export * from 'x'; export const b=1" },
        .{ .url = "x", .src = "export const a=1; export default 2" },
    }, "1a,bfalse");
    try expectModule(&.{
        .{ .url = "main", .src = "import {n} from 's'; globalThis.out=n.a" },
        .{ .url = "s", .src = "export * as n from 'x'" },
        .{ .url = "x", .src = "export const a=5" },
    }, "5");
    try expectModule(&.{
        .{ .url = "main", .src = "import f from 'x'; import g from 'y'; import C from 'z'; globalThis.out=f()+g()+new C().v+f.name+C.name" },
        .{ .url = "x", .src = "export default function(){return 1}" },
        .{ .url = "y", .src = "export default function named(){return 2}" },
        .{ .url = "z", .src = "export default class{v=3}" },
    }, "6defaultdefault");
    try expectModule(&.{
        .{ .url = "main", .src = "import 'x'; globalThis.out=globalThis.side" },
        .{ .url = "x", .src = "globalThis.side=7" },
    }, "7");
    try expectModule(&.{
        .{ .url = "main", .src = "export {d as default}; const d=1; import * as me from 'main'; globalThis.out=me.default" },
    }, "1");
    try expectModule(&.{
        .{ .url = "main", .src = "import {a as x} from 'y'; export {x}; import * as me from 'main'; globalThis.out=me.x" },
        .{ .url = "y", .src = "export const a=3" },
    }, "3");
    try expectModule(&.{
        .{ .url = "main", .src = "export const {a,b:[c]}={a:1,b:[2]}; import {a as a2,c as c2} from 'main'; globalThis.out=a2+c2" },
    }, "3");
}

test "live bindings, strictness, namespace objects" {
    try expectModule(&.{
        .{ .url = "main", .src = "import {c,inc} from 'x'; inc(); globalThis.out=c" },
        .{ .url = "x", .src = "export let c=0; export function inc(){c++}" },
    }, "1");
    try expectModule(&.{
        .{ .url = "main", .src = "import {c} from 'x'; try{c=1}catch(e){globalThis.out=e.name}" },
        .{ .url = "x", .src = "export let c=0" },
    }, "TypeError");
    try expectModule(&.{
        .{ .url = "main", .src = "import * as ns from 'x'; var r=[Object.prototype.toString.call(ns),Object.isFrozen(ns),Object.isExtensible(ns),typeof ns.a,Reflect.ownKeys(ns).length]; try{ns.a=1}catch(e){r.push(e.name)} globalThis.out=r.join()" },
        .{ .url = "x", .src = "export var a=1; export var b=2" },
    }, "[object Module],false,false,number,3,TypeError");
    try expectModule(&.{
        .{ .url = "main", .src = "globalThis.out=(function(){return this===undefined})()+''+(this===undefined)" },
    }, "truetrue");
    try expectModule(&.{
        .{ .url = "main", .src = "try{undeclared=1}catch(e){globalThis.out=e.name}" },
    }, "ReferenceError");
    try expectModule(&.{
        .{ .url = "main", .src = "globalThis.out=import.meta.url+typeof import.meta" },
    }, "mainobject");
    try expectModule(&.{
        .{ .url = "main", .src = "var a=1; let b=2; const f=()=>a+b; function g(){return f()}; globalThis.out=g()" },
    }, "3");
}

test "cycles and evaluation order" {
    try expectModule(&.{
        .{ .url = "main", .src = "import {a} from 'x'; globalThis.log.push('main'); globalThis.out=globalThis.log.join()+a" },
        .{ .url = "x", .src = "import 'y'; globalThis.log.push('x'); export const a=1" },
        .{ .url = "y", .src = "globalThis.log=['y']" },
    }, "y,x,main1");
    try expectModule(&.{
        .{ .url = "main", .src = "import {f} from 'a'; globalThis.out=f()" },
        .{ .url = "a", .src = "import {g} from 'b'; export function f(){return g()+1}" },
        .{ .url = "b", .src = "import {f} from 'a'; export function g(){return 1}; export var hasF=typeof f" },
    }, "2");
    try expectModule(&.{
        .{ .url = "main", .src = "import 'a'; globalThis.out=globalThis.seen" },
        .{ .url = "a", .src = "import {v} from 'b'; export const w=1" },
        .{ .url = "b", .src = "import {w} from 'a'; try{w}catch(e){globalThis.seen=e.name}; export const v=1" },
    }, "ReferenceError");
    try expectModule(&.{
        .{ .url = "main", .src = "import {h} from 'b'; globalThis.out=globalThis.early" },
        .{ .url = "b", .src = "import {h as hh} from 'main2'; export function h(){}" },
        .{ .url = "main2", .src = "import {h as h2} from 'b'; globalThis.early=typeof h2; export function h(){}" },
    }, "function");
}

test "top-level await" {
    try expectModule(&.{
        .{ .url = "main", .src = "var v=await Promise.resolve(5); globalThis.out=v" },
    }, "5");
    try expectModule(&.{
        .{ .url = "main", .src = "import {a} from 'x'; globalThis.out=a" },
        .{ .url = "x", .src = "export const a=await Promise.resolve(6)" },
    }, "6");
    try expectModule(&.{
        .{ .url = "main", .src = "import 'x'; import 'y'; globalThis.out=globalThis.log.join()" },
        .{ .url = "x", .src = "globalThis.log=['x1']; await 0; globalThis.log.push('x2')" },
        .{ .url = "y", .src = "globalThis.log.push('y')" },
    }, "x1,y,x2");
    try expectModule(&.{
        .{ .url = "main", .src = "for await (var x of [1,2]) globalThis.out=x" },
    }, "2");
    try expectModule(&.{
        .{ .url = "main", .src = "var await_=1; const f=async()=>await 1; globalThis.out=await f()" },
    }, "1");
}

test "module errors" {
    const gpa = std.heap.smp_allocator;
    const vm = try js.Vm.create(gpa);
    defer vm.deinit();
    // A syntax error is thrown by compile.
    try std.testing.expectError(error.Thrown, vm.compileModule("export {", "a"));
    // A name nobody exports fails at link.
    const m = try vm.compileModule("import {nope} from 'x'", "m");
    var l = Loader{ .vm = vm, .files = &.{.{ .url = "x", .src = "export const a=1" }} };
    defer l.loaded.deinit(gpa);
    try std.testing.expectError(error.Thrown, vm.linkModule(m, &l, Loader.resolve));
    try std.testing.expect(std.mem.indexOf(u8, vm.exceptionString(), "does not provide an export named 'nope'") != null);
    // Throwing during evaluation rejects the promise.
    const m2 = try vm.compileModule("throw 5", "t");
    try vm.linkModule(m2, &l, Loader.resolve);
    const p = try vm.evaluateModule(m2);
    vm.runJobs();
    try std.testing.expect(p.asObject().payload.promise.state == .rejected);
}

const ImportHost = struct {
    pending_spec: ?[]u8 = null,
    cap: js.Capability = .{},
};

fn importHook(ctx: ?*anyopaque, vm: *js.Vm, spec: []const u8, _: []const u8, cap: js.Capability) void {
    const h: *ImportHost = @ptrCast(@alignCast(ctx.?));
    h.pending_spec = std.heap.smp_allocator.dupe(u8, spec) catch null;
    h.cap = cap;
    vm.protect(cap.promise) catch {};
}

fn noResolve(_: ?*anyopaque, _: *js.Vm, _: []const u8, _: *js.Module) ?*js.Module {
    return null;
}

test "dynamic import" {
    const gpa = std.heap.smp_allocator;
    const vm = try js.Vm.create(gpa);
    defer vm.deinit();
    var host = ImportHost{};
    vm.setDynamicImportHook(&host, importHook);
    _ = try vm.eval("var out; import('dyn').then(ns=>out=ns.v+ns.default)", "t.js");
    vm.runJobs();
    try std.testing.expectEqualStrings("dyn", host.pending_spec.?);
    std.heap.smp_allocator.free(host.pending_spec.?);
    const m = try vm.compileModule("export const v=1; export default 2", "dyn");
    try js.finishDynamicImport(vm, m, host.cap, null, noResolve);
    vm.unprotect(host.cap.promise);
    vm.runJobs();
    const v = try vm.eval("out", "t.js");
    try std.testing.expectEqual(@as(f64, 3), try vm.toNumber(v));
    // With no way to load, import() rejects instead of throwing.
    vm.setDynamicImportHook(null, null);
    _ = try vm.eval("var e2; import('x').catch(e=>e2=e.name)", "t.js");
    vm.runJobs();
    const e2 = try vm.eval("e2", "t.js");
    try std.testing.expectEqualStrings("TypeError", try vm.toStringSlice(e2));
}

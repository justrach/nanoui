//! A host for tc39/test262: the engine alone, with what the suite asks of a host
//! (`print`, `$262`). `tools/parity/test262.mjs` runs it once per test.
//!
//!     test262-host [--module] [--strict] [--include FILE]... TEST
//!
//! The last line on stderr says how it ended: `RESULT ok`, or `RESULT parse|resolution|
//! runtime Name: message`. There are no realms in this engine, nor agents, so
//! `$262.createRealm` and `$262.agent` aren't here and tests of them fail.
const std = @import("std");
const js = @import("js.zig");
const api = @import("vm_api.zig");
const promise = @import("promise.zig");

const Vm = js.Vm;
const Value = js.Value;
const Error = js.Error;
const gpa = std.heap.smp_allocator;
const deadline_ns = 50 * std.time.ns_per_s;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn read(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), path, gpa, .limited(64 << 20));
}

fn finish(phase: []const u8, detail: []const u8) noreturn {
    if (detail.len > 0) {
        std.debug.print("\nRESULT {s} {s}\n", .{ phase, detail });
    } else std.debug.print("\nRESULT {s}\n", .{phase});
    std.process.exit(0);
}

/// An error's `name`, else its constructor's: the harness's `Test262Error` has only that.
fn nameOf(vm: *Vm, o: *js.Object) []const u8 {
    const own = vm.getNamed(o, "name") catch return "Unknown";
    if (own.isString()) return vm.toStringSlice(own) catch "Unknown";
    const ctor = vm.getNamed(o, "constructor") catch return "Unknown";
    if (!ctor.isObject()) return "Unknown";
    const name = vm.getNamed(ctor.asObject(), "name") catch return "Unknown";
    return if (name.isString()) (vm.toStringSlice(name) catch "Unknown") else "Unknown";
}

/// `Name: message` of what's thrown.
fn thrown(vm: *Vm) []const u8 {
    const ex = vm.exception;
    if (!ex.isObject()) return "NonObject: thrown";
    const msg_v = vm.getNamed(ex.asObject(), "message") catch Value.undefined;
    const name = nameOf(vm, ex.asObject());
    const msg = if (msg_v.isString()) (vm.toStringSlice(msg_v) catch "") else "";
    return std.fmt.allocPrint(gpa, "{s}: {s}", .{ name, msg[0..@min(msg.len, 300)] }) catch "Unknown: oom";
}

fn fail(vm: *Vm, phase: []const u8, e: Error) noreturn {
    if (e == error.Terminated) finish(phase, "Timeout: deadline");
    finish(phase, thrown(vm));
}

fn print(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const s = if (args.len > 0) try vm.toStringSlice(args[0]) else "";
    std.debug.print("{s}\n", .{s});
    return Value.undefined;
}

fn evalScript(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const src = try vm.toStringSlice(if (args.len > 0) args[0] else Value.undefined);
    // Errors come back as they are: a syntax error is thrown to the caller.
    const f = try api.compileScript(vm, src, "evalScript.js", .script);
    return vm.call(f.value(), vm.global().value(), &.{});
}

fn detach(vm: *Vm, _: Value, args: []const Value) Error!Value {
    if (args.len == 0 or !args[0].isObject() or args[0].asObject().class != .arraybuffer) {
        return vm.throwError(.TypeError, "not an ArrayBuffer");
    }
    const b = args[0].asObject().payload.buffer;
    b.detached = true;
    gpa.free(b.bytes);
    b.bytes = &.{};
    return Value.null;
}

fn ddaCall(_: *Vm, _: Value, _: []const Value) Error!Value {
    return Value.null;
}

fn install(vm: *Vm) Error!void {
    const g = vm.global();
    try vm.setNamed(g, "print", (try vm.newNative("print", 1, print)).value());
    const h = try vm.newObject();
    try vm.setNamed(g, "$262", h.value());
    try vm.setNamed(h, "global", g.value());
    try vm.setNamed(h, "evalScript", (try vm.newNative("evalScript", 1, evalScript)).value());
    try vm.setNamed(h, "detachArrayBuffer", (try vm.newNative("detachArrayBuffer", 1, detach)).value());
    const dda = try vm.newNative("IsHTMLDDA", 0, ddaCall);
    dda.flags.html_dda = true;
    try vm.setNamed(h, "IsHTMLDDA", dda.value());
}

// Modules: read and compiled once each, by absolute path.
var modules: std.StringHashMapUnmanaged(*js.Module) = .empty;

fn resolvePath(spec: []const u8, referrer: []const u8) ![]const u8 {
    const dir = std.fs.path.dirname(referrer) orelse ".";
    return std.fs.path.resolve(gpa, &.{ dir, spec });
}

/// `path` and all it asks for; what fails to read or parse is thrown.
fn loadModule(vm: *Vm, path: []const u8) Error!*js.Module {
    if (modules.get(path)) |m| return m;
    const src = read(path) catch return vm.throwError(.SyntaxError, "can't read module");
    const m = try vm.compileModule(src, path);
    modules.put(gpa, path, m) catch return error.OutOfMemory;
    for (0..m.requests.len) |i| {
        const spec = try m.requestName(vm, i);
        const to = resolvePath(spec, path) catch return error.OutOfMemory;
        _ = try loadModule(vm, to);
    }
    return m;
}

fn resolveHook(_: ?*anyopaque, vm: *Vm, spec: []const u8, referrer: *js.Module) ?*js.Module {
    const from = referrer.url.flat(vm) catch return null;
    const to = resolvePath(spec, from) catch return null;
    return modules.get(to);
}

const Import = struct { spec: []const u8, referrer: []const u8, cap: js.Capability };
var imports: std.ArrayList(Import) = .empty;

fn importHook(_: ?*anyopaque, vm: *Vm, spec: []const u8, referrer: []const u8, cap: js.Capability) void {
    vm.protect(cap.promise) catch finish("harness", "Host: oom");
    const s = gpa.dupe(u8, spec) catch finish("harness", "Host: oom");
    const r = gpa.dupe(u8, referrer) catch finish("harness", "Host: oom");
    imports.append(gpa, .{ .spec = s, .referrer = r, .cap = cap }) catch finish("harness", "Host: oom");
}

/// Microtasks, and imports as they ask, until neither is left.
fn drain(vm: *Vm) void {
    while (true) {
        vm.setDeadline(deadline_ns);
        vm.runJobs();
        if (imports.items.len == 0) return;
        const im = imports.orderedRemove(0);
        const path = resolvePath(im.spec, im.referrer) catch continue;
        const m = loadModule(vm, path) catch |e| {
            if (e == error.Terminated) finish("runtime", "Timeout: deadline");
            const ex = vm.exception;
            vm.exception = Value.undefined;
            promise.callReject(vm, im.cap, ex) catch {};
            continue;
        };
        js.finishDynamicImport(vm, m, im.cap, null, resolveHook) catch |e| fail(vm, "runtime", e);
    }
}

var module_error: ?[]const u8 = null;

fn moduleRejected(vm: *Vm, _: Value, args: []const Value) Error!Value {
    vm.exception = if (args.len > 0) args[0] else Value.undefined;
    module_error = thrown(vm);
    vm.exception = Value.undefined;
    return Value.undefined;
}

fn runModule(vm: *Vm, path: []const u8) void {
    const watch = vm.eval("(function(){var t=Promise.prototype.then,a=Reflect.apply;return function(p,f){a(t,p,[undefined,f])}})()", "host.js") catch |e| fail(vm, "harness", e);
    const m = vm.compileModule(read(path) catch finish("harness", "Host: can't read test"), path) catch |e| fail(vm, "parse", e);
    modules.put(gpa, path, m) catch {};
    for (0..m.requests.len) |i| {
        const spec = m.requestName(vm, i) catch |e| fail(vm, "resolution", e);
        const to = resolvePath(spec, path) catch finish("harness", "Host: path");
        _ = loadModule(vm, to) catch |e| fail(vm, "resolution", e);
    }
    vm.linkModule(m, null, resolveHook) catch |e| fail(vm, "resolution", e);
    vm.setDeadline(deadline_ns);
    const done = vm.evaluateModule(m) catch |e| fail(vm, "runtime", e);
    const on = vm.newNative("rejected", 1, moduleRejected) catch |e| fail(vm, "harness", e);
    _ = vm.call(watch, Value.undefined, &.{ done, on.value() }) catch |e| fail(vm, "harness", e);
    drain(vm);
    if (module_error) |msg| finish("runtime", msg);
}

fn runScript(vm: *Vm, path: []const u8, strict: bool) void {
    const raw = read(path) catch finish("harness", "Host: can't read test");
    const src = if (strict) std.mem.concat(gpa, u8, &.{ "\"use strict\";\n", raw }) catch finish("harness", "Host: oom") else raw;
    vm.enterFromHost();
    const f = api.compileScript(vm, src, path, .script) catch |e| fail(vm, "parse", e);
    vm.setDeadline(deadline_ns);
    _ = vm.call(f.value(), vm.global().value(), &.{}) catch |e| fail(vm, "runtime", e);
    drain(vm);
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const vm = try Vm.create(gpa);
    install(vm) catch finish("harness", "Host: install");
    vm.setDynamicImportHook(null, importHook);
    var module = false;
    var strict = false;
    var test_path: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--module")) {
            module = true;
        } else if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else if (std.mem.eql(u8, a, "--include")) {
            i += 1;
            const src = read(args[i]) catch finish("harness", "Host: can't read include");
            _ = vm.eval(src, args[i]) catch |e| fail(vm, "harness", e);
        } else test_path = a;
    }
    if (module) runModule(vm, test_path) else runScript(vm, test_path, strict);
    finish("ok", "");
}

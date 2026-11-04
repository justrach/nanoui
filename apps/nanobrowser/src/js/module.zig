//! ES modules: compile, link (resolving imports to live bindings), evaluation with
//! top-level await, namespace objects, import.meta and dynamic import. The host owns
//! loading: it reads module.requests, compiles what's named, and passes a resolver to link.

const std = @import("std");
const Allocator = std.mem.Allocator;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const heap = @import("heap.zig");
const ast = @import("ast.zig");
const bc = @import("bytecode.zig");
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const define = @import("props_define.zig");
const shape = @import("shape.zig");
const str = @import("string.zig");
const JSString = str.JSString;
const parser = @import("parser.zig");
const scope = @import("scope.zig");
const compiler = @import("compiler.zig");
const calls = @import("interp_call.zig");
const interp_object = @import("interp_object.zig");
const promise = @import("promise.zig");
const api = @import("vm_api.zig");
const ops_ic = @import("interp_ic.zig");

pub const Status = enum(u8) { unlinked, linking, linked, evaluating, evaluated, errored };

/// What an import or export name finally refers to.
pub const Target = union(enum) {
    binding: struct { env: *heap.Env, slot: u32 },
    namespace: *Module,
};

pub const ImportRec = struct { imported: ?*JSString, local: *JSString, request: u32, target: ?Target = null };
pub const Binding = struct { name: *JSString, slot: u32 };

pub const Module = struct {
    cell: heap.Cell,
    url: *JSString,
    status: Status = .unlinked,
    has_tla: bool = false,
    /// Specifiers to load, in source order; `resolved` is filled by link.
    requests: []*JSString = &.{},
    resolved: []?*Module = &.{},
    imports: []ImportRec = &.{},
    exports: []ast.ExportEntry = &.{},
    bindings: []Binding = &.{},
    main: ?*bc.FuncProto = null,
    init: ?*bc.FuncProto = null,
    env: ?*heap.Env = null,
    namespace: ?*Object = null,
    meta: ?*Object = null,
    eval_promise: ?*Object = null,
    err: Value = Value.undefined,

    /// The i-th specifier the host must load, as UTF-8.
    pub fn requestName(mo: *Module, vm: *Vm, i: usize) Error![]const u8 {
        return mo.requests[i].flat(vm);
    }

    pub fn trace(mo: *Module, m: *heap.Marker) void {
        m.markStr(mo.url);
        for (mo.requests) |r| m.markStr(r);
        for (mo.resolved) |r| {
            if (r) |x| m.markCell(&x.cell);
        }
        for (mo.imports) |i| {
            m.markStr(i.imported);
            m.markStr(i.local);
            if (i.target) |t| switch (t) {
                .binding => |b| m.markCell(&b.env.cell),
                .namespace => |n| m.markCell(&n.cell),
            };
        }
        for (mo.exports) |e| {
            m.markStr(e.exported);
            m.markStr(e.local);
            m.markStr(e.imported);
        }
        for (mo.bindings) |b| m.markStr(b.name);
        if (mo.main) |p| m.markCell(&p.cell);
        if (mo.init) |p| m.markCell(&p.cell);
        if (mo.env) |e| m.markCell(&e.cell);
        m.markObj(mo.namespace);
        m.markObj(mo.meta);
        m.markObj(mo.eval_promise);
        m.mark(mo.err);
    }

    pub fn finalize(mo: *Module, gpa: Allocator) void {
        gpa.free(mo.requests);
        gpa.free(mo.resolved);
        gpa.free(mo.imports);
        gpa.free(mo.exports);
        gpa.free(mo.bindings);
    }
};

/// The host's resolver: the already-compiled module a specifier names, or null.
pub const ResolveFn = *const fn (ctx: ?*anyopaque, vm: *Vm, specifier: []const u8, referrer: *Module) ?*Module;
/// import(): the host loads (later) and finishes with finishDynamicImport.
pub const ImportHook = *const fn (ctx: ?*anyopaque, vm: *Vm, specifier: []const u8, referrer: []const u8, cap: promise.Capability) void;

fn setModuleOnProtos(p: *bc.FuncProto, m: *Module) void {
    p.module = m;
    for (p.protos) |c| setModuleOnProtos(c, m);
}

pub fn compile(vm: *Vm, source: []const u8, url: []const u8) Error!*Module {
    vm.enterFromHost();
    var arena = std.heap.ArenaAllocator.init(vm.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var prog = try parser.parseProgram(vm, a, source, .{ .is_module = true });
    const r = try scope.analyze(vm, a, &prog, source, .module);
    const src = try api.newSource(vm, source, url);
    const c = try compiler.compileProgram(vm, a, &prog, r, src);
    const gpa = vm.gpa;
    const m = try vm.heap.create(Module, .module);
    const cell = m.cell;
    m.* = .{ .cell = cell, .url = try str.fromUtf8(vm, url), .has_tla = prog.has_tla, .main = c.main, .init = c.module_init };
    m.requests = try gpa.dupe(*JSString, prog.requests);
    m.resolved = try gpa.alloc(?*Module, prog.requests.len);
    @memset(m.resolved, null);
    m.exports = try gpa.dupe(ast.ExportEntry, prog.exports);
    m.imports = try gpa.alloc(ImportRec, prog.imports.len);
    for (prog.imports, m.imports) |i, *o| o.* = .{ .imported = i.imported, .local = i.local, .request = i.request };
    const s = c.scope.?;
    m.bindings = try gpa.alloc(Binding, s.vars.items.len);
    for (s.vars.items, m.bindings) |v, *b| b.* = .{ .name = v.name, .slot = v.index };
    const env = try vm.heap.newEnv(null, c.env_size);
    @memset(env.slots()[0..c.env_size], Value.hole);
    m.env = env;
    setModuleOnProtos(c.main, m);
    setModuleOnProtos(c.module_init.?, m);
    try vm.modules.append(vm.gpa, m);
    return m;
}

fn bindingSlot(m: *Module, name: *JSString) ?u32 {
    for (m.bindings) |b| {
        if (b.name == name) return b.slot;
    }
    return null;
}

const Visit = struct { m: *Module, name: *JSString };

/// ResolveExport with the cycle guard. Null means not found; star ambiguity counts as not found.
fn resolveExport(vm: *Vm, m: *Module, name: *JSString, seen: *std.ArrayList(Visit)) Error!?Target {
    for (seen.items) |s| {
        if (s.m == m and s.name == name) return null;
    }
    try seen.append(vm.gpa, .{ .m = m, .name = name });
    for (m.exports) |e| {
        if (e.exported != name) continue;
        if (e.request) |r| {
            const dep = m.resolved[r] orelse return null;
            if (e.imported) |imp| return resolveExport(vm, dep, imp, seen);
            return .{ .namespace = dep };
        }
        const local = e.local.?;
        for (m.imports) |i| {
            if (i.local != local) continue;
            const dep = m.resolved[i.request] orelse return null;
            if (i.imported) |imp| return resolveExport(vm, dep, imp, seen);
            return .{ .namespace = dep };
        }
        const slot = bindingSlot(m, local) orelse return null;
        return .{ .binding = .{ .env = m.env.?, .slot = slot } };
    }
    if (name == vm.k.default.atom()) return null;
    var found: ?Target = null;
    for (m.exports) |e| {
        if (e.exported != null or e.request == null) continue;
        const dep = m.resolved[e.request.?] orelse continue;
        const t = (try resolveExport(vm, dep, name, seen)) orelse continue;
        if (found) |f| {
            const same = switch (f) {
                .binding => |a| t == .binding and t.binding.env == a.env and t.binding.slot == a.slot,
                .namespace => |a| t == .namespace and t.namespace == a,
            };
            if (!same) return null;
        } else found = t;
    }
    return found;
}

fn resolveName(vm: *Vm, m: *Module, name: *JSString) Error!?Target {
    var seen: std.ArrayList(Visit) = .empty;
    defer seen.deinit(vm.gpa);
    return resolveExport(vm, m, name, &seen);
}

/// Links a module and everything it requests.
pub fn link(vm: *Vm, m: *Module, ctx: ?*anyopaque, resolve_fn: ResolveFn) Error!void {
    vm.enterFromHost();
    var order: std.ArrayList(*Module) = .empty;
    defer order.deinit(vm.gpa);
    try linkLoad(vm, m, ctx, resolve_fn, &order);
    for (order.items) |x| try resolveImports(vm, x);
    for (order.items) |x| {
        x.status = .linked;
        const fnv = try interp_object.makeClosure(vm, x.init.?, x.env);
        _ = try calls.call(vm, fnv.value(), Value.undefined, &.{});
    }
}

fn linkLoad(vm: *Vm, m: *Module, ctx: ?*anyopaque, resolve_fn: ResolveFn, order: *std.ArrayList(*Module)) Error!void {
    if (m.status != .unlinked) return;
    try vm.checkNativeStack();
    m.status = .linking;
    for (m.requests, 0..) |spec, i| {
        const dep = resolve_fn(ctx, vm, try spec.flat(vm), m) orelse {
            var b: [200]u8 = undefined;
            const s = try spec.flat(vm);
            const msg = std.fmt.bufPrint(&b, "Cannot find module '{s}'", .{s[0..@min(s.len, 150)]}) catch "Cannot find module";
            return vm.throwError(.SyntaxError, msg);
        };
        m.resolved[i] = dep;
        try linkLoad(vm, dep, ctx, resolve_fn, order);
    }
    try order.append(vm.gpa, m);
}

fn resolveImports(vm: *Vm, m: *Module) Error!void {
    for (m.imports) |*imp| {
        const dep = m.resolved[imp.request].?;
        if (imp.imported) |name| {
            imp.target = try resolveName(vm, dep, name) orelse {
                var b: [200]u8 = undefined;
                const n = try name.flat(vm);
                const r = try m.requests[imp.request].flat(vm);
                const msg = std.fmt.bufPrint(&b, "The requested module '{s}' does not provide an export named '{s}'", .{ r[0..@min(r.len, 80)], n[0..@min(n.len, 40)] }) catch "The requested module does not provide this export";
                return vm.throwError(.SyntaxError, msg);
            };
        } else {
            imp.target = .{ .namespace = dep };
        }
    }
}

pub fn getImport(vm: *Vm, m: *Module, i: u32) Error!Value {
    const t = m.imports[i].target orelse return vm.throwError(.ReferenceError, "Import is not linked");
    return targetValue(vm, t, m.imports[i].local);
}

fn targetValue(vm: *Vm, t: Target, name: *JSString) Error!Value {
    switch (t) {
        .binding => |b| {
            const v = b.env.slots()[b.slot];
            if (v.isHole()) return ops_ic.throwTdzKey(vm, PropKey.fromAtom(name));
            return v;
        },
        .namespace => |n| return (try namespaceOf(vm, n)).value(),
    }
}

/// Runs a module's body; the value is a promise, already settled if it never awaited.
fn runBody(vm: *Vm, m: *Module) Error!*Object {
    const fnv = try interp_object.makeClosure(vm, m.main.?, m.env);
    const p = try calls.call(vm, fnv.value(), Value.undefined, &.{});
    return p.asObject();
}

fn afterBody(vm: *Vm, m: *Module, p: *Object) Error!?*Object {
    const d = p.payload.promise;
    switch (d.state) {
        .fulfilled => {
            m.status = .evaluated;
            return null;
        },
        .rejected => {
            d.handled = true;
            m.status = .errored;
            m.err = d.result;
            vm.exception = d.result;
            return error.Thrown;
        },
        .pending => {
            m.eval_promise = p;
            m.status = .evaluated;
            return p;
        },
    }
}

/// Evaluates dependencies then the body. Returns a promise only if something is still pending.
fn evalModule(vm: *Vm, m: *Module) Error!?*Object {
    switch (m.status) {
        .evaluated => {
            if (m.eval_promise) |p| {
                if (p.payload.promise.state == .pending) return p;
            }
            return null;
        },
        .errored => {
            vm.exception = m.err;
            return error.Thrown;
        },
        .evaluating => return null,
        else => {},
    }
    try vm.checkNativeStack();
    m.status = .evaluating;
    var pending: std.ArrayList(*Object) = .empty;
    defer pending.deinit(vm.gpa);
    for (m.resolved) |dep| {
        const p = evalModule(vm, dep.?) catch |e| {
            if (e == error.Thrown) {
                m.status = .errored;
                m.err = vm.exception;
            }
            return e;
        };
        if (p) |x| try pending.append(vm.gpa, x);
    }
    if (pending.items.len == 0) {
        const p = runBody(vm, m) catch |e| {
            if (e == error.Thrown) {
                m.status = .errored;
                m.err = vm.exception;
            }
            return e;
        };
        return afterBody(vm, m, p);
    }
    // Some dependency awaits: run this body once they have all settled.
    const outer = try promise.newPromise(vm, vm.protos.promise);
    m.eval_promise = outer;
    m.status = .evaluated;
    const counter = try objmod.newPlain(vm);
    counter.host_tag = @intCast(pending.items.len);
    const mv = Value.fromCell(&m.cell);
    const caps = [_]Value{ mv, outer.value(), counter.value() };
    const on_ok = try api.newNativeClosure(vm, "", 1, depSettled, &caps);
    const on_err = try api.newNativeClosure(vm, "", 1, depFailed, &caps);
    for (pending.items) |p| {
        try promise.addReaction(vm, p, .{ .kind = .then, .on_fulfill = on_ok, .on_reject = on_err });
    }
    return outer;
}

fn depSettled(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const m: *Module = @fieldParentPtr("cell", vm.capture(0).asCell());
    const outer = vm.capture(1).asObject();
    const counter = vm.capture(2).asObject();
    counter.host_tag -= 1;
    if (counter.host_tag != 0 or outer.payload.promise.state != .pending) return Value.undefined;
    const p = runBody(vm, m) catch |e| {
        if (e != error.Thrown) return e;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        m.status = .errored;
        m.err = ex;
        try promise.reject(vm, outer, ex);
        return Value.undefined;
    };
    try promise.resolve(vm, outer, p.value());
    return Value.undefined;
}

fn depFailed(vm: *Vm, _: Value, args: []const Value) Error!Value {
    const m: *Module = @fieldParentPtr("cell", vm.capture(0).asCell());
    const outer = vm.capture(1).asObject();
    const reason = if (args.len > 0) args[0] else Value.undefined;
    m.status = .errored;
    m.err = reason;
    try promise.reject(vm, outer, reason);
    return Value.undefined;
}

/// Evaluates a linked module; returns a promise for its completion.
pub fn evaluate(vm: *Vm, m: *Module) Error!Value {
    vm.enterFromHost();
    const pending = evalModule(vm, m) catch |e| {
        if (e != error.Thrown) return e;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        const p = try promise.newPromise(vm, vm.protos.promise);
        try promise.reject(vm, p, ex);
        return p.value();
    };
    if (pending) |p| return p.value();
    const p = try promise.newPromise(vm, vm.protos.promise);
    try promise.fulfill(vm, p, Value.undefined);
    return p.value();
}

fn exportedNames(vm: *Vm, m: *Module, out: *std.ArrayList(*JSString), seen: *std.ArrayList(*Module)) Error!void {
    for (seen.items) |s| {
        if (s == m) return;
    }
    try seen.append(vm.gpa, m);
    for (m.exports) |e| {
        if (e.exported) |name| {
            var dup = false;
            for (out.items) |x| {
                if (x == name) dup = true;
            }
            if (!dup) try out.append(vm.gpa, name);
        }
    }
    for (m.exports) |e| {
        if (e.exported == null and e.request != null) {
            const dep = m.resolved[e.request.?] orelse continue;
            const before = out.items.len;
            try exportedNames(vm, dep, out, seen);
            // `export *` never re-exports default.
            var i: usize = before;
            while (i < out.items.len) {
                if (out.items[i] == vm.k.default.atom()) {
                    _ = out.orderedRemove(i);
                } else i += 1;
            }
        }
    }
}

/// The module namespace object, made once.
pub fn namespaceOf(vm: *Vm, m: *Module) Error!*Object {
    if (m.namespace) |n| return n;
    const n = try objmod.createExotic(vm, null, .module_ns);
    n.flags.extensible = false;
    n.payload = .{ .module = m };
    m.namespace = n;
    const tag = try str.fromUtf8(vm, "Module");
    try props.addProp(vm, n, PropKey.fromSymbol(vm.sym.toStringTag), Value.fromString(tag), shape.PropFlags.readonly);
    return n;
}

fn nsNames(vm: *Vm, m: *Module) Error![]*JSString {
    var out: std.ArrayList(*JSString) = .empty;
    errdefer out.deinit(vm.gpa);
    var seen: std.ArrayList(*Module) = .empty;
    defer seen.deinit(vm.gpa);
    try exportedNames(vm, m, &out, &seen);
    // Only unambiguous names appear.
    var i: usize = 0;
    while (i < out.items.len) {
        if (try resolveName(vm, m, out.items[i]) == null) {
            _ = out.orderedRemove(i);
        } else i += 1;
    }
    std.mem.sort(*JSString, out.items, {}, struct {
        fn lt(_: void, a: *JSString, b: *JSString) bool {
            return std.mem.order(u8, a.ptr[0..a.byte_len], b.ptr[0..b.byte_len]) == .lt;
        }
    }.lt);
    return out.toOwnedSlice(vm.gpa);
}

pub fn nsGet(vm: *Vm, o: *Object, key: PropKey, _: Value) Error!?Value {
    if (!key.isAtom()) return null;
    const t = try resolveName(vm, o.payload.module, key.atom()) orelse return Value.undefined;
    return try targetValue(vm, t, key.atom());
}

pub fn nsHas(vm: *Vm, o: *Object, key: PropKey) Error!bool {
    if (!key.isAtom()) return false;
    return try resolveName(vm, o.payload.module, key.atom()) != null;
}

pub fn nsGetOwn(vm: *Vm, o: *Object, key: PropKey) Error!?define.Own {
    if (!key.isAtom()) {
        return define.ordinaryGetOwn(vm, o, key);
    }
    const t = try resolveName(vm, o.payload.module, key.atom()) orelse return null;
    return .{ .value = try targetValue(vm, t, key.atom()), .flags = .{ .configurable = false } };
}

pub fn nsOwnKeys(vm: *Vm, o: *Object, out: *std.ArrayList(PropKey)) Error!void {
    const names = try nsNames(vm, o.payload.module);
    defer vm.gpa.free(names);
    for (names) |n| try out.append(vm.gpa, PropKey.fromAtom(n));
}

pub fn importMeta(vm: *Vm, m: *Module) Error!Value {
    if (m.meta) |x| return x.value();
    const o = try objmod.create(vm, null, .object);
    try props.addProp(vm, o, vm.k.url, Value.fromString(m.url), shape.PropFlags.all);
    m.meta = o;
    return o.value();
}

/// `import(x)`: returns a promise and asks the host to load, unless the specifier fails first.
pub fn dynamicImport(vm: *Vm, fp: *bc.FuncProto, spec: Value) Error!Value {
    const p = try promise.newPromise(vm, vm.protos.promise);
    const s = @import("conv.zig").toStr(vm, spec) catch |e| {
        if (e != error.Thrown) return e;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        try promise.reject(vm, p, ex);
        return p.value();
    };
    const hook = vm.import_fn orelse {
        try promise.reject(vm, p, try api.makeError(vm, .TypeError, "Dynamic import is not available"));
        return p.value();
    };
    hook(vm.import_ctx, vm, try s.flat(vm), fp.source.name, .{ .promise = p.value() });
    return p.value();
}

/// The host finished loading for import(): link and evaluate, settling the promise with the namespace.
pub fn finishDynamicImport(vm: *Vm, m: *Module, cap: promise.Capability, ctx: ?*anyopaque, resolve_fn: ResolveFn) Error!void {
    link(vm, m, ctx, resolve_fn) catch |e| {
        if (e != error.Thrown) return e;
        const ex = vm.exception;
        vm.exception = Value.undefined;
        return promise.callReject(vm, cap, ex);
    };
    const done = try evaluate(vm, m);
    const caps = [_]Value{ Value.fromCell(&m.cell), cap.promise };
    const on_ok = try api.newNativeClosure(vm, "", 1, importDone, &caps);
    const on_err = try api.newNativeClosure(vm, "", 1, importFailed, &caps);
    try promise.addReaction(vm, done.asObject(), .{ .kind = .then, .on_fulfill = on_ok, .on_reject = on_err });
}

fn importDone(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const m: *Module = @fieldParentPtr("cell", vm.capture(0).asCell());
    try promise.resolve(vm, vm.capture(1).asObject(), (try namespaceOf(vm, m)).value());
    return Value.undefined;
}

fn importFailed(vm: *Vm, _: Value, args: []const Value) Error!Value {
    try promise.reject(vm, vm.capture(1).asObject(), if (args.len > 0) args[0] else Value.undefined);
    return Value.undefined;
}

/// Rejects a pending import() the host could not load.
pub fn failDynamicImport(vm: *Vm, cap: promise.Capability, message: []const u8) Error!void {
    try promise.callReject(vm, cap, try api.makeError(vm, .TypeError, message));
}

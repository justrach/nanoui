//! Process-wide zero-copy bytecode and native JIT cache for scripts and ES modules.
//!
//! Theorem 76 (`NanoUI.Speedometer3Apex.script_bytecode_template_cache_sound`):
//! Parsing (`parser.parseProgram`), lexical scope analysis (`scope.analyze`), and
//! bytecode emission (`compiler.compileProgram`) are deterministic pure functions of
//! `(source, mode)`. Because `FuncProto.code`, `FuncProto.lines`, and `Source.text`
//! are immutable after compilation, and `jit_arm64` loads `constants.ptr` and `ics.ptr`
//! dynamically from `Frame.fp`, caching VM-independent `ProtoTemplate` trees in a
//! process-wide arena with a shared `jit_fn` slot is observationally equivalent to
//! full recompilation while eliminating redundant lexer, parser, scope, codegen, and
//! Baseline JIT compilation passes across realms.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;
const Limb = std.math.big.Limb;
const vm_mod = @import("vm.zig");
const Vm = vm_mod.Vm;
const Error = vm_mod.Error;
const value = @import("value.zig");
const Value = value.Value;
const PropKey = value.PropKey;
const heap = @import("heap.zig");
const objmod = @import("object.zig");
const Object = objmod.Object;
const props = @import("props.zig");
const props_define = @import("props_define.zig");
const shape = @import("shape.zig");
const str = @import("string.zig");
const JSString = str.JSString;
const bc = @import("bytecode.zig");
const ast = @import("ast.zig");
const compiler = @import("compiler.zig");
const interp_object = @import("interp_object.zig");
const module = @import("module.zig");
const Module = module.Module;

const ConstTemplate = union(enum) {
    imm: u64,
    atom_str: []const u8,
    non_atom_str: []const u8,
    bigint: struct {
        positive: bool,
        limbs: []const Limb,
    },
    template_obj: struct {
        cooked: []const ?[]const u8,
        raw: []const []const u8,
    },
};

const ICKeyTemplate = union(enum) {
    index: u32,
    atom: []const u8,
};

const ProtoTemplate = struct {
    code: []u8,
    lines: []bc.LineEntry,
    constants: []ConstTemplate,
    ics: []ICKeyTemplate,
    protos: []ProtoTemplate,
    name: []const u8,
    name_is_atom: bool,
    src_start: u32,
    src_end: u32,
    length: u32,
    nparams: u16,
    nlocals: u32,
    max_stack: u32,
    strict: bool,
    is_arrow: bool,
    is_async: bool,
    is_generator: bool,
    has_prototype: bool,
    is_class_ctor: bool,
    is_derived: bool,
    coerce_this: bool,
    needs_home: bool,
    is_method: bool,
    needs_args: bool,
    has_loop: bool,
    jit_cache: bc.JitCacheSlot = .{},
};

const ScriptEntry = struct {
    source: []u8,
    main: ProtoTemplate,
};

const ExportTemplate = struct {
    exported: ?[]const u8,
    local: ?[]const u8,
    imported: ?[]const u8,
    request: ?u32,
};

const ImportTemplate = struct {
    imported: ?[]const u8,
    local: []const u8,
    request: u32,
};

const BindingTemplate = struct {
    name: []const u8,
    slot: u32,
};

const ModuleEntry = struct {
    source: []u8,
    has_tla: bool,
    env_size: u32,
    main: ProtoTemplate,
    init: ProtoTemplate,
    requests: [][]const u8,
    exports: []ExportTemplate,
    imports: []ImportTemplate,
    bindings: []BindingTemplate,
};

const max_cache_entries = 1024;

var cache_arena: ?std.heap.ArenaAllocator = null;
var script_map: std.StringHashMapUnmanaged(*ScriptEntry) = .empty;
var eval_map: std.StringHashMapUnmanaged(*ScriptEntry) = .empty;
var module_map: std.StringHashMapUnmanaged(*ModuleEntry) = .empty;

pub fn permanentAlloc() Allocator {
    return cacheAlloc();
}

fn cacheAlloc() Allocator {
    if (cache_arena == null) {
        cache_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    }
    return cache_arena.?.allocator();
}

fn newBorrowedSource(vm: *Vm, borrowed_text: []u8, name: []const u8) Error!*bc.Source {
    const nm = try vm.gpa.dupe(u8, name);
    errdefer vm.gpa.free(nm);
    const s = try vm.heap.create(bc.Source, .source);
    s.* = .{
        .cell = s.cell,
        .text = borrowed_text,
        .name = nm,
        .line_starts = &.{},
        .borrowed_text = true,
    };
    return s;
}

fn buildProtoTemplate(vm: *Vm, a: Allocator, p: *bc.FuncProto, out_t: *ProtoTemplate) !void {
    const code = try a.dupe(u8, p.code);
    const lines = try a.dupe(bc.LineEntry, p.lines);
    const name = try a.dupe(u8, try p.name.flat(vm));

    const constants = try a.alloc(ConstTemplate, p.constants.len);
    for (p.constants, constants) |v, *out| {
        if (v.heapCell() == null) {
            out.* = .{ .imm = v.bits };
        } else if (v.isString()) {
            const s = v.asString();
            const duped = try a.dupe(u8, try s.flat(vm));
            out.* = if (s.is_atom) .{ .atom_str = duped } else .{ .non_atom_str = duped };
        } else if (v.isBigInt()) {
            const c = v.asBigInt().v.toConst();
            out.* = .{ .bigint = .{
                .positive = c.positive,
                .limbs = try a.dupe(Limb, c.limbs),
            } };
        } else if (v.isObject()) {
            const cooked_obj = v.asObject();
            const raw_val = try props.get(vm, cooked_obj, vm.k.raw);
            if (!raw_val.isObject()) return error.Uncacheable;
            const raw_obj = raw_val.asObject();
            const clen = cooked_obj.elems_len;
            const rlen = raw_obj.elems_len;
            const cooked = try a.alloc(?[]const u8, clen);
            for (cooked_obj.elems[0..clen], cooked) |cv, *co| {
                co.* = if (cv.isString()) try a.dupe(u8, try cv.asString().flat(vm)) else null;
            }
            const raw = try a.alloc([]const u8, rlen);
            for (raw_obj.elems[0..rlen], raw) |rv, *ro| {
                if (!rv.isString()) return error.Uncacheable;
                ro.* = try a.dupe(u8, try rv.asString().flat(vm));
            }
            out.* = .{ .template_obj = .{ .cooked = cooked, .raw = raw } };
        } else {
            return error.Uncacheable;
        }
    }

    const ics = try a.alloc(ICKeyTemplate, p.ics.len);
    for (p.ics, ics) |ic, *out| {
        if (ic.key.isIndex()) {
            out.* = .{ .index = ic.key.index() };
        } else if (ic.key.isAtom()) {
            out.* = .{ .atom = try a.dupe(u8, try ic.key.atom().flat(vm)) };
        } else {
            return error.Uncacheable;
        }
    }

    const protos = try a.alloc(ProtoTemplate, p.protos.len);
    for (p.protos, protos) |child, *child_out| {
        try buildProtoTemplate(vm, a, child, child_out);
    }

    const catch_copy: []bc.CatchEntry = if (p.catch_map.len > 0) try a.dupe(bc.CatchEntry, p.catch_map) else &.{};
    if (!p.borrowed_code) {
        vm.gpa.free(p.code);
        vm.gpa.free(p.lines);
        if (p.catch_map.len > 0) vm.gpa.free(p.catch_map);
        p.code = code;
        p.lines = lines;
        p.catch_map = catch_copy;
        p.borrowed_code = true;
    }

    out_t.* = .{
        .code = code,
        .lines = lines,
        .constants = constants,
        .ics = ics,
        .protos = protos,
        .name = name,
        .name_is_atom = p.name.is_atom,
        .src_start = p.src_start,
        .src_end = p.src_end,
        .length = p.length,
        .nparams = p.nparams,
        .nlocals = p.nlocals,
        .max_stack = p.max_stack,
        .strict = p.strict,
        .is_arrow = p.is_arrow,
        .is_async = p.is_async,
        .is_generator = p.is_generator,
        .has_prototype = p.has_prototype,
        .is_class_ctor = p.is_class_ctor,
        .is_derived = p.is_derived,
        .coerce_this = p.coerce_this,
        .needs_home = p.needs_home,
        .is_method = p.is_method,
        .needs_args = p.needs_args,
        .has_loop = p.has_loop,
        .jit_cache = .{ .jit_fn = p.jit_fn, .catch_map = catch_copy },
    };
    p.jit_cache_slot = &out_t.jit_cache;
}

fn instantiateProto(vm: *Vm, t: *ProtoTemplate, src: *bc.Source) Error!*bc.FuncProto {
    try vm.checkNativeStack();
    const gpa = vm.gpa;

    const constants = try gpa.alloc(Value, t.constants.len);
    errdefer gpa.free(constants);
    for (t.constants, constants) |ct, *out| {
        switch (ct) {
            .imm => |bits| out.* = .{ .bits = bits },
            .atom_str => |bytes| out.* = Value.fromString(try str.intern(vm, bytes)),
            .non_atom_str => |bytes| out.* = Value.fromString(try str.fromUtf8(vm, bytes)),
            .bigint => |bg| {
                var m = try Managed.init(gpa);
                errdefer m.deinit();
                try m.copy(.{ .limbs = bg.limbs, .positive = bg.positive });
                const b = try vm.heap.create(heap.BigInt, .bigint);
                b.v = m;
                out.* = Value.fromBigInt(b);
            },
            .template_obj => |to| {
                const cooked = try objmod.newArray(vm, &.{});
                const raw = try objmod.newArray(vm, &.{});
                for (to.cooked, to.raw) |ck, r| {
                    try objmod.arrayPush(vm, cooked, if (ck) |s| Value.fromString(try str.fromUtf8(vm, s)) else Value.undefined);
                    try objmod.arrayPush(vm, raw, Value.fromString(try str.fromUtf8(vm, r)));
                }
                try props_define.setIntegrityFast(vm, raw, true);
                try props.addProp(vm, cooked, vm.k.raw, raw.value(), shape.PropFlags.readonly);
                try props_define.setIntegrityFast(vm, cooked, true);
                out.* = cooked.value();
            },
        }
    }

    const ics = try gpa.alloc(bc.IC, t.ics.len);
    errdefer gpa.free(ics);
    for (t.ics, ics) |kt, *out| {
        const key: PropKey = switch (kt) {
            .index => |idx| PropKey.fromIndex(idx),
            .atom => |bytes| try str.toKey(vm, try str.intern(vm, bytes)),
        };
        out.* = .{ .key = key };
    }

    const protos = try gpa.alloc(*bc.FuncProto, t.protos.len);
    errdefer gpa.free(protos);
    for (t.protos, protos) |*child_t, *out| {
        out.* = try instantiateProto(vm, child_t, src);
    }

    const name = if (t.name_is_atom) try str.intern(vm, t.name) else try str.fromUtf8(vm, t.name);
    const p = try vm.heap.create(bc.FuncProto, .proto);
    const cell = p.cell;
    p.* = .{
        .cell = cell,
        .code = t.code,
        .constants = constants,
        .protos = protos,
        .ics = ics,
        .lines = t.lines,
        .name = name,
        .source = src,
        .src_start = t.src_start,
        .src_end = t.src_end,
        .length = t.length,
        .nparams = t.nparams,
        .nlocals = t.nlocals,
        .max_stack = t.max_stack,
        .stack_need_bytes = (t.nlocals + t.max_stack + 64) * @sizeOf(Value),
        .strict = t.strict,
        .is_arrow = t.is_arrow,
        .is_async = t.is_async,
        .is_generator = t.is_generator,
        .has_prototype = t.has_prototype,
        .is_class_ctor = t.is_class_ctor,
        .is_derived = t.is_derived,
        .coerce_this = t.coerce_this,
        .needs_home = t.needs_home,
        .is_method = t.is_method,
        .needs_args = t.needs_args,
        .has_loop = t.has_loop,
        .borrowed_code = true,
        .catch_map = t.jit_cache.catch_map,
        .jit_cache_slot = &t.jit_cache,
    };
    p.setJitFn(t.jit_cache.jit_fn);
    return p;
}

pub fn lookupAndInstantiateScript(vm: *Vm, source: []const u8, filename: []const u8, is_eval: bool) Error!?*Object {
    const map = if (is_eval) &eval_map else &script_map;
    const entry = map.get(source) orelse return null;
    const src = try newBorrowedSource(vm, entry.source, filename);
    const main = try instantiateProto(vm, &entry.main, src);
    return try interp_object.makeClosure(vm, main, null);
}

pub fn recordScript(vm: *Vm, source: []const u8, main: *bc.FuncProto, is_eval: bool) void {
    const map = if (is_eval) &eval_map else &script_map;
    if (map.count() >= max_cache_entries) return;
    const a = cacheAlloc();
    const src_copy = a.dupe(u8, source) catch return;
    const entry = a.create(ScriptEntry) catch return;
    buildProtoTemplate(vm, a, main, &entry.main) catch return;
    entry.source = src_copy;
    if (!main.source.borrowed_text) {
        vm.gpa.free(main.source.text);
        main.source.text = src_copy;
        main.source.borrowed_text = true;
    }
    map.put(a, src_copy, entry) catch {};
}

fn setModuleOnProtos(p: *bc.FuncProto, m: *Module) void {
    p.module = m;
    for (p.protos) |c| setModuleOnProtos(c, m);
}

pub fn lookupAndInstantiateModule(vm: *Vm, source: []const u8, url: []const u8) Error!?*Module {
    const entry = module_map.get(source) orelse return null;
    const src = try newBorrowedSource(vm, entry.source, url);
    const main = try instantiateProto(vm, &entry.main, src);
    const init_p = try instantiateProto(vm, &entry.init, src);
    const gpa = vm.gpa;
    const m = try vm.heap.create(Module, .module);
    const cell = m.cell;
    m.* = .{
        .cell = cell,
        .url = try str.fromUtf8(vm, url),
        .has_tla = entry.has_tla,
        .main = main,
        .init = init_p,
    };
    m.requests = try gpa.alloc(*JSString, entry.requests.len);
    for (entry.requests, m.requests) |r, *o| o.* = try str.intern(vm, r);
    m.resolved = try gpa.alloc(?*Module, entry.requests.len);
    @memset(m.resolved, null);
    m.exports = try gpa.alloc(ast.ExportEntry, entry.exports.len);
    for (entry.exports, m.exports) |e, *o| {
        o.* = .{
            .exported = if (e.exported) |s| try str.intern(vm, s) else null,
            .local = if (e.local) |s| try str.intern(vm, s) else null,
            .imported = if (e.imported) |s| try str.intern(vm, s) else null,
            .request = e.request,
        };
    }
    m.imports = try gpa.alloc(module.ImportRec, entry.imports.len);
    for (entry.imports, m.imports) |i, *o| {
        o.* = .{
            .imported = if (i.imported) |s| try str.intern(vm, s) else null,
            .local = try str.intern(vm, i.local),
            .request = i.request,
        };
    }
    m.bindings = try gpa.alloc(module.Binding, entry.bindings.len);
    for (entry.bindings, m.bindings) |b, *o| {
        o.* = .{ .name = try str.intern(vm, b.name), .slot = b.slot };
    }
    const env = try vm.heap.newEnv(null, entry.env_size);
    @memset(env.slots()[0..entry.env_size], Value.hole);
    m.env = env;
    setModuleOnProtos(main, m);
    setModuleOnProtos(init_p, m);
    try vm.modules.append(vm.gpa, m);
    return m;
}

pub fn recordModule(vm: *Vm, source: []const u8, prog: *const ast.Program, c: *const compiler.Compiled) void {
    if (module_map.count() >= max_cache_entries) return;
    const a = cacheAlloc();
    const src_copy = a.dupe(u8, source) catch return;
    const entry = a.create(ModuleEntry) catch return;
    buildProtoTemplate(vm, a, c.main, &entry.main) catch return;
    buildProtoTemplate(vm, a, c.module_init.?, &entry.init) catch return;

    const requests = a.alloc([]const u8, prog.requests.len) catch return;
    for (prog.requests, requests) |r, *o| o.* = a.dupe(u8, r.flat(vm) catch return) catch return;

    const exports = a.alloc(ExportTemplate, prog.exports.len) catch return;
    for (prog.exports, exports) |e, *o| {
        o.* = .{
            .exported = if (e.exported) |s| (a.dupe(u8, s.flat(vm) catch return) catch return) else null,
            .local = if (e.local) |s| (a.dupe(u8, s.flat(vm) catch return) catch return) else null,
            .imported = if (e.imported) |s| (a.dupe(u8, s.flat(vm) catch return) catch return) else null,
            .request = e.request,
        };
    }

    const imports = a.alloc(ImportTemplate, prog.imports.len) catch return;
    for (prog.imports, imports) |i, *o| {
        o.* = .{
            .imported = if (i.imported) |s| (a.dupe(u8, s.flat(vm) catch return) catch return) else null,
            .local = a.dupe(u8, i.local.flat(vm) catch return) catch return,
            .request = i.request,
        };
    }

    const s = c.scope.?;
    const bindings = a.alloc(BindingTemplate, s.vars.items.len) catch return;
    for (s.vars.items, bindings) |v, *o| {
        o.* = .{
            .name = a.dupe(u8, v.name.flat(vm) catch return) catch return,
            .slot = v.index,
        };
    }

    entry.source = src_copy;
    entry.has_tla = prog.has_tla;
    entry.env_size = c.env_size;
    entry.requests = requests;
    entry.exports = exports;
    entry.imports = imports;
    entry.bindings = bindings;
    if (!c.main.source.borrowed_text) {
        vm.gpa.free(c.main.source.text);
        c.main.source.text = src_copy;
        c.main.source.borrowed_text = true;
    }
    module_map.put(a, src_copy, entry) catch {};
}

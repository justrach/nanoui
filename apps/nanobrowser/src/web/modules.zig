//! ES modules: fetching a module and everything it imports, resolving
//! specifiers (relative ones, and import maps, simply: `imports` only, exact and
//! prefix matches; `scopes` are ignored), linking, evaluating, and `import()`.
const std = @import("std");
const nanoui = @import("nanoui");
const js = @import("../js/js.zig");
const http = nanoui.http;
const bind = @import("bind.zig");
const net = @import("net.zig");
const scripts = @import("scripts.zig");
const loader = @import("../loader.zig");
const Page = @import("../page.zig").Page;
const World = bind.World;
const Value = js.Value;
const Error = js.Error;

const Rec = struct {
    url: []const u8,
    state: enum { fetching, ready, failed } = .fetching,
    module: ?*js.Module = null,
};

const Graph = struct {
    root: *Rec,
    entry: ?*scripts.Entry = null,
    cap: js.Capability = .{},
    dynamic: bool = false,
    done: bool = false,
};

pub const Loader = struct {
    recs: std.StringHashMapUnmanaged(*Rec) = .empty,
    graphs: std.ArrayList(*Graph) = .empty,
    /// The import map's entries, resolved.
    imports: std.StringHashMapUnmanaged([]const u8) = .empty,
    inline_count: u32 = 0,

    pub fn deinit(l: *Loader, gpa: std.mem.Allocator) void {
        var it = l.recs.valueIterator();
        while (it.next()) |r| gpa.destroy(r.*);
        l.recs.deinit(gpa);
        for (l.graphs.items) |g| gpa.destroy(g);
        l.graphs.deinit(gpa);
        l.imports.deinit(gpa);
    }

    pub fn mark(l: *Loader, m: *js.Marker) void {
        var it = l.recs.valueIterator();
        while (it.next()) |r| if (r.*.module) |x| m.markCell(&x.cell);
        for (l.graphs.items) |g| g.cap.trace(m);
    }
};

/// `<script type=importmap>`: its JSON read by the engine.
pub fn setImportMap(w: *World, text: []const u8) Error!void {
    const vm = w.vm;
    const json = try vm.global().get(vm, "JSON");
    const parse = try json.asObject().get(vm, "parse");
    const map = try vm.call(parse, json, &.{try vm.newString(text)});
    if (!map.isObject()) return;
    const imports = try map.asObject().get(vm, "imports");
    if (!imports.isObject()) return;
    const keys_fn = try (try vm.global().get(vm, "Object")).asObject().get(vm, "keys");
    const keys = (try vm.call(keys_fn, Value.undefined, &.{imports})).asObject();
    const len = try vm.toNumber(try keys.get(vm, "length"));
    const a = w.page.arena();
    var i: u32 = 0;
    while (@as(f64, @floatFromInt(i)) < len) : (i += 1) {
        const key_v = try keys.getIdx(vm, i);
        const key = try a.dupe(u8, try vm.toStringSlice(key_v));
        const to = try vm.toStringSlice(try imports.asObject().get(vm, key));
        const resolved = loader.linkFrom(w.page, to) orelse continue;
        try w.mods.imports.put(w.gpa, key, resolved);
    }
}

fn isRelative(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "./") or std.mem.startsWith(u8, s, "../") or std.mem.startsWith(u8, s, "/");
}

fn isAbsoluteUrl(s: []const u8) bool {
    const i = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (i == 0) return false;
    for (s[0..i]) |c| if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    return true;
}

/// Where a specifier imported from `base` leads, in the page's arena.
fn resolve(w: *World, spec: []const u8, base: []const u8) ?[]const u8 {
    const a = w.page.arena();
    const direct: ?[]const u8 = if (isRelative(spec)) http.resolve(a, base, spec) catch null else if (isAbsoluteUrl(spec)) a.dupe(u8, spec) catch null else null;
    if (w.mods.imports.get(direct orelse spec)) |to| return to;
    // The longest prefix mapping, `"lodash/": "/vendor/lodash/"`.
    var best: ?[]const u8 = null;
    var it = w.mods.imports.keyIterator();
    while (it.next()) |k| {
        const key = k.*;
        if (key.len == 0 or key[key.len - 1] != '/') continue;
        if (!std.mem.startsWith(u8, direct orelse spec, key)) continue;
        if (best == null or best.?.len < key.len) best = key;
    }
    if (best) |key| {
        const tail = (direct orelse spec)[key.len..];
        return std.fmt.allocPrint(a, "{s}{s}", .{ w.mods.imports.get(key).?, tail }) catch null;
    }
    return direct;
}

/// A `<script type=module>`: `text` when inline, else fetched from `url`.
pub fn loadRoot(w: *World, e: *scripts.Entry, url: []const u8, text: ?[]const u8) Error!void {
    const g = try w.gpa.create(Graph);
    errdefer w.gpa.destroy(g);
    if (text) |source| {
        // An inline module has no address of its own: one per script.
        w.mods.inline_count += 1;
        const key = try std.fmt.allocPrint(w.page.arena(), "{s}#inline-{d}", .{ url, w.mods.inline_count });
        const rec = try w.gpa.create(Rec);
        rec.* = .{ .url = url };
        try w.mods.recs.put(w.gpa, key, rec);
        g.* = .{ .root = rec, .entry = e };
        try w.mods.graphs.append(w.gpa, g);
        compiled(w, rec, source);
    } else {
        const rec = try request(w, url);
        g.* = .{ .root = rec, .entry = e };
        try w.mods.graphs.append(w.gpa, g);
    }
    check(w);
}

const Req = struct { page: *Page, rec: *Rec };

fn request(w: *World, url: []const u8) Error!*Rec {
    if (w.mods.recs.get(url)) |r| return r;
    const rec = try w.gpa.create(Rec);
    rec.* = .{ .url = url };
    try w.mods.recs.put(w.gpa, url, rec);
    const p = w.page;
    if (!net.allowed(p.url(), url)) {
        rec.state = .failed;
        return rec;
    }
    const r = try p.gpa.create(Req);
    r.* = .{ .page = p, .rec = rec };
    p.pending += 1;
    var headers: [4]http.Header = undefined;
    http.fetch(p.gpa, .{ .url = url, .headers = net.defaultHeaders(w, url, &headers), .timeout = 30 }, r, answered);
    return rec;
}

fn answered(r: *Req, res: http.Response) void {
    const p = r.page;
    const rec = r.rec;
    p.gpa.destroy(r);
    p.pending -= 1;
    p.busy += 1;
    defer {
        p.busy -= 1;
        p.maybeFree();
    }
    const w = p.js orelse return;
    if (p.dead) return;
    if (res.status >= 200 and res.status < 300) {
        compiled(w, rec, res.body);
    } else {
        rec.state = .failed;
        var buf: [300]u8 = undefined;
        w.logLine(3, std.fmt.bufPrint(&buf, "Module failed to load: {s}", .{rec.url[0..@min(rec.url.len, 256)]}) catch "Module failed to load");
    }
    check(w);
    scripts.pump(w);
    p.finishLoadCheck();
}

fn compiled(w: *World, rec: *Rec, source: []const u8) void {
    w.enter();
    defer w.leave();
    const vm = w.vm;
    const m = vm.compileModule(source, rec.url) catch |e| {
        rec.state = .failed;
        w.report(e);
        return;
    };
    rec.module = m;
    rec.state = .ready;
    for (m.requests) |spec_str| {
        const spec = spec_str.flat(vm) catch continue;
        const to = resolve(w, spec, rec.url) orelse {
            var buf: [300]u8 = undefined;
            w.logLine(3, std.fmt.bufPrint(&buf, "Can't resolve module '{s}'", .{spec[0..@min(spec.len, 200)]}) catch "Can't resolve module");
            rec.state = .failed;
            continue;
        };
        _ = request(w, to) catch {};
    }
}

const Walk = enum { fetching, failed, ready };

fn walk(w: *World, rec: *Rec, seen: *std.AutoHashMapUnmanaged(*Rec, void)) Walk {
    if (seen.contains(rec)) return .ready;
    seen.put(w.gpa, rec, {}) catch return .failed;
    switch (rec.state) {
        .fetching => return .fetching,
        .failed => return .failed,
        .ready => {},
    }
    const vm = w.vm;
    var out: Walk = .ready;
    for (rec.module.?.requests) |spec_str| {
        const spec = spec_str.flat(vm) catch return .failed;
        const to = resolve(w, spec, rec.url) orelse return .failed;
        const dep = w.mods.recs.get(to) orelse return .fetching;
        switch (walk(w, dep, seen)) {
            .failed => return .failed,
            .fetching => out = .fetching,
            .ready => {},
        }
    }
    return out;
}

/// Finishes every graph whose modules have all come.
fn check(w: *World) void {
    var i: usize = 0;
    while (i < w.mods.graphs.items.len) {
        const g = w.mods.graphs.items[i];
        var seen: std.AutoHashMapUnmanaged(*Rec, void) = .empty;
        const state = walk(w, g.root, &seen);
        seen.deinit(w.gpa);
        if (state == .fetching) {
            i += 1;
            continue;
        }
        _ = w.mods.graphs.orderedRemove(i);
        defer w.gpa.destroy(g);
        finish(w, g, state == .ready);
    }
}

fn finish(w: *World, g: *Graph, ok: bool) void {
    if (g.entry) |e| {
        if (ok) {
            e.module = g.root.module;
            e.state = .ready;
        } else e.state = .failed;
        if (e.mode == .async_) scripts.arrived(w, e);
        return;
    }
    w.enter();
    defer w.leave();
    if (ok) {
        js.finishDynamicImport(w.vm, g.root.module.?, g.cap, w, resolveHook) catch |err| w.report(err);
    } else {
        js.failDynamicImport(w.vm, g.cap, "Failed to fetch dynamically imported module") catch |err| w.report(err);
    }
}

fn resolveHook(ctx: ?*anyopaque, vm: *js.Vm, specifier: []const u8, referrer: *js.Module) ?*js.Module {
    const w: *World = @ptrCast(@alignCast(ctx.?));
    const base = referrer.url.flat(vm) catch return null;
    const to = resolve(w, specifier, base) orelse return null;
    const rec = w.mods.recs.get(to) orelse return null;
    return rec.module;
}

pub fn linkAndEvaluate(w: *World, m: *js.Module) Error!void {
    const vm = w.vm;
    try vm.linkModule(m, w, resolveHook);
    _ = try vm.evaluateModule(m);
}

/// `import()`: loads later, and settles `cap`.
pub fn dynamicImport(ctx: ?*anyopaque, vm: *js.Vm, specifier: []const u8, referrer: []const u8, cap: js.Capability) void {
    const w: *World = @ptrCast(@alignCast(ctx.?));
    const base = if (referrer.len > 0 and isAbsoluteUrl(referrer)) referrer else w.page.url();
    const fail = struct {
        fn f(x: *World, c: js.Capability) void {
            js.failDynamicImport(x.vm, c, "Failed to resolve module specifier") catch {};
        }
    }.f;
    _ = vm;
    const to = resolve(w, specifier, base) orelse return fail(w, cap);
    const rec = request(w, to) catch return fail(w, cap);
    const g = w.gpa.create(Graph) catch return fail(w, cap);
    g.* = .{ .root = rec, .cap = cap, .dynamic = true };
    w.mods.graphs.append(w.gpa, g) catch {
        w.gpa.destroy(g);
        return fail(w, cap);
    };
    if (rec.state != .fetching) check(w);
}

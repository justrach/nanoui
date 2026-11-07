//! Installs a page's world: the natives on their classes, then the part of the
//! web platform written in JS. `core` and `dom` run now; the others are compiled
//! the first time a script touches one of their globals, which most pages' first
//! scripts won't for most of them.
const std = @import("std");
const builtin = @import("builtin");
const js = @import("../js/js.zig");
const bind = @import("bind.zig");
const page_mod = @import("../page.zig");
const timers = @import("timers.zig");
const net = @import("net.zig");
const storage = @import("storage.zig");
const internals = @import("api_internals.zig");
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;

const Chunk = struct { name: []const u8, source: [:0]const u8, globals: []const []const u8 = &.{} };

const eager = [_]Chunk{
    .{ .name = "prelude:es", .source = @embedFile("prelude_es.js") },
    .{ .name = "prelude:events", .source = @embedFile("prelude_events.js") },
    .{ .name = "prelude:dom", .source = @embedFile("prelude_dom.js") },
    .{ .name = "prelude:elements", .source = @embedFile("prelude_elements.js") },
    .{ .name = "prelude:webgl", .source = @embedFile("prelude_webgl.js") },
    .{ .name = "prelude:wire", .source = @embedFile("prelude_wire.js") },
    .{ .name = "prelude:window", .source = @embedFile("prelude_window.js") },
    .{ .name = "prelude:webgpu", .source = @embedFile("prelude_webgpu.js") },
    .{ .name = "prelude:webgpu_layouts", .source = @embedFile("prelude_webgpu_layouts.js") },
    .{ .name = "prelude:webgpu_commands", .source = @embedFile("prelude_webgpu_commands.js") },
    .{ .name = "prelude:frames", .source = @embedFile("prelude_frames.js") },
    .{ .name = "prelude:gaps", .source = @embedFile("prelude_gaps.js") },
};

const lazy = [_]Chunk{
    .{ .name = "prelude:url", .source = @embedFile("prelude_url.js"), .globals = &.{ "URL", "URLSearchParams", "webkitURL" } },
    .{ .name = "prelude:net", .source = @embedFile("prelude_net.js"), .globals = &.{ "fetch", "Headers", "Request", "Response", "XMLHttpRequest", "FormData", "Blob", "File", "FileReader", "ProgressEvent", "AbortController", "AbortSignal", "TextEncoder", "TextDecoder", "structuredClone", "ReadableStream", "XMLHttpRequestEventTarget", "XMLHttpRequestUpload" } },
    .{ .name = "prelude:observers", .source = @embedFile("prelude_observers.js"), .globals = &.{ "MutationObserver", "MutationRecord", "ResizeObserver", "ResizeObserverEntry", "IntersectionObserver", "IntersectionObserverEntry", "MessageChannel", "MessagePort", "BroadcastChannel", "DOMParser", "XMLSerializer", "Range", "Selection", "NodeFilter", "TreeWalker", "NodeIterator", "getSelection" } },
    .{ .name = "prelude:matrix", .source = @embedFile("prelude_matrix.js"), .globals = &.{ "DOMMatrix", "DOMMatrixReadOnly", "WebKitCSSMatrix" } },
    .{ .name = "prelude:worker", .source = @embedFile("prelude_worker.js"), .globals = &.{"Worker"} },
};

fn platformName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "MacIntel",
        .ios => "iPhone",
        .windows => "Win32",
        else => "Linux x86_64",
    };
}

fn lazyGet(vm: *Vm, _: Value, _: []const Value) Error!Value {
    const i: usize = @intCast(vm.capture(0).asInt());
    const name = try vm.toStringSlice(vm.capture(1));
    try loadChunk(bind.world(vm), i);
    return vm.global().get(vm, name);
}

fn lazySet(vm: *Vm, _: Value, args: []const Value) Error!Value {
    // Replacing a global before it was used: it's the script's from now on,
    // and what it replaced still comes if the chunk loads for another name.
    const name = try vm.toStringSlice(vm.capture(0));
    const define = try (try vm.global().get(vm, "Object")).asObject().get(vm, "defineProperty");
    const desc = try vm.newObject();
    try desc.set(vm, "value", bind.arg(args, 0));
    try desc.set(vm, "writable", Value.true);
    try desc.set(vm, "configurable", Value.true);
    try desc.set(vm, "enumerable", Value.false);
    _ = try vm.call(define, Value.undefined, &.{ vm.global().value(), try vm.newString(name), desc.value() });
    return Value.undefined;
}

fn loadChunk(w: *World, i: usize) Error!void {
    if (w.chunks_loaded & (@as(u32, 1) << @intCast(i)) != 0) return;
    w.chunks_loaded |= @as(u32, 1) << @intCast(i);
    try runChunk(w, &lazy[i]);
}

/// What makes a worker's global a worker's: before its first script.
pub fn workerScope(w: *World) Error!void {
    try loadChunk(w, lazy.len - 1);
}

fn runChunk(w: *World, c: *const Chunk) Error!void {
    const vm = w.vm;
    const f = try vm.eval(c.source, c.name);
    _ = try vm.call(f, Value.undefined, &.{ w.internals.value(), vm.global().value() });
}

pub fn install(w: *World) Error!void {
    const vm = w.vm;
    const g = vm.global();
    try @import("api_collections.zig").install(w);
    try @import("api_style.zig").install(w);
    try storage.install(w);
    try @import("api_node.zig").install(w);
    try @import("api_element.zig").install(w);
    try @import("api_geometry.zig").install(w);
    try @import("api_forms.zig").install(w);
    try @import("api_document.zig").install(w);
    try bind.methods(vm, g, &timers.globals);
    try bind.methods(vm, g, &net.globals);
    w.internals = try internals.make(w);
    try w.internals.defineData(vm, "document", try bind.wrap(vm, w.page.doc.node), js.PropFlags.hidden);
    try w.internals.defineData(vm, "userAgent", try vm.newString(page_mod.user_agent), js.PropFlags.hidden);
    try w.internals.defineData(vm, "platform", try vm.newString(platformName()), js.PropFlags.hidden);
    for (lazy, 0..) |c, i| {
        for (c.globals) |name| {
            const key = try vm.newString(name);
            const getter = try vm.newNativeClosure(name, 0, lazyGet, &.{ Value.fromUsize(i), key });
            const setter = try vm.newNativeClosure(name, 1, lazySet, &.{key});
            const define = try (try g.get(vm, "Object")).asObject().get(vm, "defineProperty");
            const desc = try vm.newObject();
            try desc.set(vm, "get", getter);
            try desc.set(vm, "set", setter);
            try desc.set(vm, "configurable", Value.true);
            try desc.set(vm, "enumerable", Value.false);
            _ = try vm.call(define, Value.undefined, &.{ g.value(), key, desc.value() });
        }
    }
    for (&eager) |*c| {
        runChunk(w, c) catch |e| {
            if (e == error.Thrown) {
                std.debug.print("{s}: {s}\n", .{ c.name, vm.exceptionString() });
                vm.exception = Value.undefined;
            }
            return e;
        };
    }
}

//! Running a document's scripts in the order the HTML spec gives them. The
//! parser has finished before any of this starts: classic scripts then run in
//! document order (external ones fetched first, the order kept), `defer` and
//! module scripts after, `async` as they arrive; `readyState` moves on and
//! `DOMContentLoaded` and `load` fire at their points. Scripts added by scripts
//! run when connected, once.
const std = @import("std");
const nanoui = @import("nanoui");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const http = nanoui.http;
const bind = @import("bind.zig");
const net = @import("net.zig");
const modules = @import("modules.zig");
const loader = @import("../loader.zig");
const Page = @import("../page.zig").Page;
const World = bind.World;
const Node = dom.Node;
const Value = js.Value;
const Error = js.Error;

pub const Phase = enum { loading, interactive, complete };
pub const Mode = enum { blocking, deferred, async_, ordered };

pub const Entry = struct {
    node: *Node,
    is_module: bool,
    mode: Mode,
    state: enum { waiting, ready, failed, done } = .waiting,
    /// A classic script's text, owned; inline ones borrow none and own a copy.
    source: []const u8 = "",
    /// What errors and `import()` call it, in the page's arena.
    name: []const u8 = "",
    /// A module's root once its graph has loaded.
    module: ?*js.Module = null,
    has_src: bool = false,
};

pub const Runner = struct {
    entries: std.ArrayList(*Entry) = .empty,
    blocking: std.ArrayList(*Entry) = .empty,
    deferred: std.ArrayList(*Entry) = .empty,
    ordered: std.ArrayList(*Entry) = .empty,
    /// Scripts not yet finished that run as they arrive.
    async_count: u32 = 0,
    started: std.AutoHashMapUnmanaged(*Node, void) = .empty,
    phase: Phase = .loading,
    dom_ready: bool = false,
    load_fired: bool = false,
    current: ?*Node = null,
    /// Where `document.write` puts what it is given, and where scripts in it
    /// go in the queue.
    write_anchor: ?*Node = null,
    write_at: usize = 1,
    pumping: bool = false,

    pub fn deinit(r: *Runner, gpa: std.mem.Allocator) void {
        for (r.entries.items) |e| {
            gpa.free(e.source);
            gpa.destroy(e);
        }
        r.entries.deinit(gpa);
        r.blocking.deinit(gpa);
        r.deferred.deinit(gpa);
        r.ordered.deinit(gpa);
        r.started.deinit(gpa);
    }
};

const Kind = enum { classic, module, import_map };

fn eqlAny(s: []const u8, list: []const []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(s, x)) return true;
    return false;
}

fn kindOf(n: *const Node) ?Kind {
    const raw = n.attr("type") orelse "";
    const t = std.mem.trim(u8, raw, " \t\r\n\x0c");
    if (t.len == 0 or eqlAny(t, &.{ "text/javascript", "application/javascript", "application/x-javascript", "text/ecmascript", "application/ecmascript", "text/jscript", "text/livescript", "text/x-javascript", "text/x-ecmascript", "application/x-ecmascript" })) {
        return if (n.hasAttr("nomodule")) null else .classic;
    }
    if (std.ascii.eqlIgnoreCase(t, "module")) return .module;
    if (std.ascii.eqlIgnoreCase(t, "importmap")) return .import_map;
    return null;
}

pub fn hasScripts(doc: *dom.Document) bool {
    const root = doc.node;
    var at = root.first_child;
    while (at) |n| : (at = n.nextDeep(root)) {
        if (n.kind != .element) continue;
        if (n.isTag("script") and kindOf(n) != null) return true;
        for (n.attrs.items) |a| if (a.name.len > 2 and a.name[0] == 'o' and a.name[1] == 'n') return true;
    }
    return false;
}

/// The document has parsed: every script in it, in order. Runs what can run.
pub fn begin(w: *World) void {
    const root = w.page.doc.node;
    var at = root.first_child;
    while (at) |n| : (at = n.nextDeep(root)) {
        if (n.kind != .element) continue;
        for (n.attrs.items) |a| if (a.name.len > 2 and a.name[0] == 'o' and a.name[1] == 'n') w.listen(a.name[2..]);
        if (n.isTag("script")) parserScript(w, n, null) catch {};
    }
    pump(w);
}

/// A script as the parser found it. `at` is where it goes among the blocking.
fn parserScript(w: *World, n: *Node, at: ?*usize) Error!void {
    const r = &w.runner;
    const kind = kindOf(n) orelse return;
    const src = n.attr("src");
    if (kind == .import_map) {
        const text = try n.textContent(w.page.arena());
        modules.setImportMap(w, text) catch {};
        return;
    }
    if (src == null and (try n.textContent(w.page.arena())).len == 0) return;
    try r.started.put(w.gpa, n, {});
    const is_async = n.hasAttr("async");
    const mode: Mode = if (kind == .module) (if (is_async) .async_ else .deferred) else if (src != null and is_async) .async_ else if (src != null and n.hasAttr("defer")) .deferred else .blocking;
    const e = try newEntry(w, n, kind == .module, mode);
    switch (mode) {
        .blocking => if (at) |i| {
            try r.blocking.insert(w.gpa, @min(i.*, r.blocking.items.len), e);
            i.* += 1;
        } else try r.blocking.append(w.gpa, e),
        .deferred => try r.deferred.append(w.gpa, e),
        .ordered => try r.ordered.append(w.gpa, e),
        .async_ => r.async_count += 1,
    }
    try load(w, e);
}

fn newEntry(w: *World, n: *Node, is_module: bool, mode: Mode) Error!*Entry {
    const e = try w.gpa.create(Entry);
    errdefer w.gpa.destroy(e);
    e.* = .{ .node = n, .is_module = is_module, .mode = mode };
    try w.runner.entries.append(w.gpa, e);
    return e;
}

/// Asks for what the script needs. Inline classic ones are ready now.
fn load(w: *World, e: *Entry) Error!void {
    const p = w.page;
    if (e.node.attr("src")) |src| {
        e.has_src = true;
        const url = loader.linkFrom(p, src) orelse {
            e.state = .failed;
            return;
        };
        e.name = url;
        if (!net.allowed(p.url(), url)) {
            e.state = .failed;
            return;
        }
        if (e.is_module) return modules.loadRoot(w, e, url, null);
        return fetchScript(w, e, url);
    }
    e.name = p.url();
    const text = try e.node.textContent(p.arena());
    if (e.is_module) return modules.loadRoot(w, e, p.url(), text);
    e.source = try w.gpa.dupe(u8, text);
    e.state = .ready;
}

const Req = struct { page: *Page, entry: *Entry };

fn fetchScript(w: *World, e: *Entry, url: []const u8) Error!void {
    const p = w.page;
    const r = try p.gpa.create(Req);
    r.* = .{ .page = p, .entry = e };
    p.pending += 1;
    var headers: [4]http.Header = undefined;
    http.fetch(p.gpa, .{ .url = url, .headers = net.defaultHeaders(w, url, &headers), .timeout = 30 }, r, answered);
}

fn answered(r: *Req, res: http.Response) void {
    const p = r.page;
    const e = r.entry;
    p.gpa.destroy(r);
    p.pending -= 1;
    p.busy += 1;
    defer {
        p.busy -= 1;
        p.maybeFree();
    }
    const w = p.js orelse return;
    if (p.dead) return;
    net.storeCookies(res, res.url);
    if (res.status >= 200 and res.status < 300) {
        e.source = w.gpa.dupe(u8, res.body) catch "";
        e.state = .ready;
    } else e.state = .failed;
    if (res.url.len > 0) e.name = p.arena().dupe(u8, res.url) catch e.name;
    arrived(w, e);
    p.finishLoadCheck();
    p.redraw();
}

/// A script's fetching ended: if it runs as it arrives, now; then the queues.
pub fn arrived(w: *World, e: *Entry) void {
    if (e.mode == .async_ and !w.stopped) {
        finishOne(w, e);
        w.runner.async_count -|= 1;
    }
    pump(w);
}

/// Runs the queues as far as they will go.
pub fn pump(w: *World) void {
    const r = &w.runner;
    const p = w.page;
    if (r.pumping) return;
    r.pumping = true;
    p.busy += 1;
    defer {
        r.pumping = false;
        p.busy -= 1;
        p.maybeFree();
    }
    while (!p.dead and !w.stopped) {
        if (takeReady(w, &r.blocking)) continue;
        if (r.blocking.items.len > 0) break;
        if (r.phase == .loading) {
            r.phase = .interactive;
            fireDocument(w, "readystatechange", false);
            continue;
        }
        if (takeReady(w, &r.deferred)) continue;
        if (r.deferred.items.len > 0) break;
        if (!r.dom_ready) {
            r.dom_ready = true;
            fireDocument(w, "DOMContentLoaded", true);
            continue;
        }
        break;
    }
    while (!p.dead and !w.stopped and takeReady(w, &r.ordered)) {}
    checkLoad(w);
}

fn takeReady(w: *World, q: *std.ArrayList(*Entry)) bool {
    if (q.items.len == 0) return false;
    const e = q.items[0];
    if (e.state == .waiting) return false;
    w.runner.write_at = 1;
    finishOne(w, e);
    // Scripts it wrote went in behind it: it comes out from the front.
    if (q.items.len > 0 and q.items[0] == e) _ = q.orderedRemove(0);
    return true;
}

fn finishOne(w: *World, e: *Entry) void {
    const ok = e.state == .ready;
    if (ok) run(w, e) catch |err| w.report(err);
    e.state = .done;
    w.gpa.free(e.source);
    e.source = "";
    if (w.page.dead or !e.has_src) return;
    fireNode(w, e.node, if (ok) "load" else "error");
}

fn run(w: *World, e: *Entry) Error!void {
    const r = &w.runner;
    const saved = r.current;
    const saved_anchor = r.write_anchor;
    r.current = if (e.is_module) null else e.node;
    r.write_anchor = e.node.next;
    defer {
        r.current = saved;
        r.write_anchor = saved_anchor;
    }
    w.enter();
    defer w.leave();
    if (e.is_module) {
        if (e.module) |m| {
            modules.linkAndEvaluate(w, m) catch |err| w.report(err);
        }
        return;
    }
    _ = w.vm.eval(e.source, e.name) catch |err| w.report(err);
}

fn fireDocument(w: *World, event_type: []const u8, bubbles: bool) void {
    if (!w.hears(event_type)) return;
    fireOn(w, w.page.doc.node, event_type, bubbles);
}

fn fireNode(w: *World, n: *Node, event_type: []const u8) void {
    if (!w.hears(event_type) or w.stopped) return;
    fireOn(w, n, event_type, false);
}

fn fireOn(w: *World, n: *Node, event_type: []const u8, bubbles: bool) void {
    const vm = w.vm;
    w.enter();
    defer w.leave();
    const target = bind.wrap(vm, n) catch return;
    const name = vm.newString(event_type) catch return;
    _ = w.callReported(w.h.fire, Value.undefined, &.{ target, name, Value.fromBool(bubbles), Value.false });
}

/// `load` once the document and all it asked for have come.
pub fn checkLoad(w: *World) void {
    const r = &w.runner;
    const p = w.page;
    if (r.load_fired or !r.dom_ready or p.dead or w.stopped) return;
    if (r.async_count > 0 or r.ordered.items.len > 0) return;
    if (p.pending > w.net_pending) return;
    r.load_fired = true;
    r.phase = .complete;
    p.busy += 1;
    defer {
        p.busy -= 1;
        p.maybeFree();
    }
    fireDocument(w, "readystatechange", false);
    if (p.dead) return;
    if (!w.hears("load") and !w.hears("pageshow")) return;
    w.enter();
    defer w.leave();
    const vm = w.vm;
    const name = vm.newString("load") catch return;
    _ = w.callReported(w.h.fire, Value.undefined, &.{ vm.global().value(), name, Value.false, Value.false });
    const show = vm.newString("pageshow") catch return;
    _ = w.callReported(w.h.fire, Value.undefined, &.{ vm.global().value(), show, Value.false, Value.false });
}

/// A `<script>` in the page's tree: it runs, once, if it can.
pub fn connected(w: *World, n: *Node) Error!void {
    const r = &w.runner;
    if (r.started.contains(n)) return;
    const kind = kindOf(n) orelse return;
    if (kind == .import_map) {
        modules.setImportMap(w, try n.textContent(w.page.arena())) catch {};
        try r.started.put(w.gpa, n, {});
        return;
    }
    const has_src = n.attr("src") != null;
    if (!has_src and (try n.textContent(w.page.arena())).len == 0) return;
    try r.started.put(w.gpa, n, {});
    const mode: Mode = if (w.ordered.contains(n)) .ordered else .async_;
    const e = try newEntry(w, n, kind == .module, mode);
    if (mode == .ordered) try r.ordered.append(w.gpa, e) else r.async_count += 1;
    try load(w, e);
    if (e.state == .ready and !has_src and !e.is_module) {
        // Inline: now, inside whatever connected it.
        if (mode == .ordered) _ = r.ordered.pop() else r.async_count -|= 1;
        const saved = r.current;
        r.current = n;
        defer r.current = saved;
        e.state = .done;
        const name = e.name;
        const source = e.source;
        defer {
            w.gpa.free(source);
            e.source = "";
        }
        _ = w.vm.eval(source, name) catch |err| switch (err) {
            error.Thrown => w.report(err),
            else => return err,
        };
    } else if (e.state == .failed) {
        arrived(w, e);
    }
}

/// Scripts in what `document.write` wrote are parser-inserted ones: they run
/// before anything still waiting. Called before the fragment goes in.
pub fn adoptWritten(w: *World, fragment: *Node) Error!void {
    var at = fragment.first_child;
    while (at) |n| : (at = n.nextInTree(fragment)) {
        if (n.isTag("script")) try parserScript(w, n, &w.runner.write_at);
    }
}

/// Scripts in parsed fragments (`innerHTML`) never run.
pub fn markStarted(w: *World, fragment: *Node) Error!void {
    var at = fragment.first_child;
    while (at) |n| : (at = n.nextInTree(fragment)) {
        if (n.isTag("script")) try w.runner.started.put(w.gpa, n, {});
    }
}

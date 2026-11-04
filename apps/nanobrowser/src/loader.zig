//! What a page fetches: the document, its style sheets (in order, `@import`s
//! before what imported them), its pictures (a few at a time) and its icon.
//! `scan` walks the document for what it names, and runs again after scripts
//! change it, so a `<link>` or `<img>` added later is asked for too.
const std = @import("std");
const nanoui = @import("nanoui");
const dom = @import("dom.zig");
const css = @import("css/css.zig");
const page_mod = @import("page.zig");
const Page = page_mod.Page;
const http = nanoui.http;
const Allocator = std.mem.Allocator;

/// Pictures asked for at once: Linux and Windows give each its own thread.
const max_pictures = 6;
/// The most one response may hold; more is treated as failed by what it was for.
const net = @import("web/net.zig");
const web = @import("web/web.zig");

const headers = [_]http.Header{
    .{ .name = "User-Agent", .value = page_mod.user_agent },
    .{ .name = "Accept", .value = "text/html,application/xhtml+xml,image/png,image/jpeg,image/gif,image/svg+xml,text/css,*/*;q=0.8" },
    .{ .name = "Accept-Language", .value = "en" },
};

/// One sheet's place: its imports come before it.
pub const Slot = struct {
    sheet: ?*css.Sheet = null,
    imports: std.ArrayList(u32) = .empty,
    /// An `@import`'s own media, given to the sheet when it comes.
    media: ?*const css.MediaList = null,
    /// A top-level sheet, not one reached by `@import`.
    top: bool = true,
};

pub const Sheets = struct {
    slots: std.ArrayList(Slot) = .empty,
    /// `<style>` and `<link>` elements seen, and what `<style>` held.
    seen: std.AutoHashMapUnmanaged(*dom.Node, u64) = .empty,
    /// Where each of those elements' sheet goes.
    slot_of: std.AutoHashMapUnmanaged(*dom.Node, u32) = .empty,
    flat: std.ArrayList(*const css.Sheet) = .empty,

    pub fn deinit(s: *Sheets, gpa: Allocator) void {
        for (s.slots.items) |*x| x.imports.deinit(gpa);
        s.slots.deinit(gpa);
        s.seen.deinit(gpa);
        s.slot_of.deinit(gpa);
        s.flat.deinit(gpa);
    }

    fn add(s: *Sheets, gpa: Allocator, top: bool) !u32 {
        try s.slots.append(gpa, .{ .top = top });
        return @intCast(s.slots.items.len - 1);
    }

    fn flatten(s: *Sheets, gpa: Allocator, slot: u32, depth: u8) void {
        if (depth > 16) return;
        const x = &s.slots.items[slot];
        for (x.imports.items) |i| s.flatten(gpa, i, depth + 1);
        if (x.sheet) |sh| s.flat.append(gpa, sh) catch {};
    }

    /// Gives the engine what has arrived, in the document's order.
    fn apply(s: *Sheets, p: *Page) void {
        s.flat.clearRetainingCapacity();
        for (s.slots.items, 0..) |x, i| if (x.top) s.flatten(p.gpa, @intCast(i), 0);
        p.engine.setSheets(s.flat.items);
        p.doc.touchStyle();
    }
};

pub const Picture = struct {
    state: enum { queued, asked, here, failed } = .queued,
    bytes: []const u8 = "",
    /// The elements waiting for it; none for a background's.
    nodes: std.ArrayList(*dom.Node) = .empty,
};

pub const Pictures = struct {
    map: std.StringHashMapUnmanaged(*Picture) = .empty,
    queue: std.ArrayList([]const u8) = .empty,
    asked: u32 = 0,

    pub fn deinit(q: *Pictures, gpa: Allocator) void {
        var it = q.map.valueIterator();
        while (it.next()) |x| {
            x.*.nodes.deinit(gpa);
            gpa.destroy(x.*);
        }
        q.map.deinit(gpa);
        q.queue.deinit(gpa);
    }

    pub fn cancelQueued(q: *Pictures) void {
        q.queue.clearRetainingCapacity();
    }
};

/// A request under way, knowing what it was for.
const Req = struct {
    page: *Page,
    gpa: Allocator,
    kind: union(enum) {
        document,
        sheet: u32,
        picture: []const u8,
        icon: []const u8,
    },
};

fn send(p: *Page, url_in: []const u8, method: []const u8, body: []const u8, kind: @FieldType(Req, "kind")) void {
    // A page from the web doesn't reach the disk: this asks for nothing, and
    // what it was for fails the usual way.
    const is_document = kind == .document;
    const url = if (!is_document and !net.allowed(p.final_url, url_in)) "data:," else url_in;
    const r = p.gpa.create(Req) catch return;
    r.* = .{ .page = p, .gpa = p.gpa, .kind = kind };
    p.pending += 1;
    var with_cookie: [headers.len + 1]http.Header = undefined;
    @memcpy(with_cookie[0..headers.len], &headers);
    var list: []const http.Header = &headers;
    if (net.cookieLine(p.arena(), url)) |line| {
        with_cookie[headers.len] = .{ .name = "Cookie", .value = line };
        list = &with_cookie;
    }
    http.fetch(p.gpa, .{ .url = url, .method = method, .body = body, .headers = list, .timeout = 30 }, r, answered);
}

pub fn fetchDocument(p: *Page, url: []const u8, req: Page.Load) void {
    send(p, url, req.method, req.body, .document);
}

fn answered(r: *Req, res: http.Response) void {
    const p = r.page;
    const kind = r.kind;
    r.gpa.destroy(r);
    p.pending -= 1;
    p.busy += 1;
    defer {
        p.busy -= 1;
        p.maybeFree();
    }
    if (p.dead) return;
    net.storeCookies(res, res.url);
    switch (kind) {
        .document => p.documentArrived(res.status, res.body, res.url, res.header("content-type") orelse "", res.err),
        .sheet => |slot| sheetArrived(p, slot, res),
        .picture => |u| pictureArrived(p, u, res),
        .icon => |k| iconArrived(p, k, res),
    }
    if (p.dead) return;
    p.finishLoadCheck();
    if (p.state == .done) p.host.loaded(p.host.ctx, p);
    p.redraw();
}

/// A `file://` address: read here, answered at once.
pub fn readFile(p: *Page, url: []const u8) void {
    const path = url["file://".len..];
    const io = std.Io.Threaded.global_single_threaded.io();
    const body = std.Io.Dir.cwd().readFileAlloc(io, path, p.gpa, .limited(64 << 20)) catch |e| {
        return p.documentArrived(0, "", url, "", @errorName(e));
    };
    defer p.gpa.free(body);
    const kind = if (std.mem.endsWith(u8, path, ".txt")) "text/plain" else "";
    p.documentArrived(200, body, url, kind, "");
}

fn resolve(p: *Page, ref: []const u8) ?[]const u8 {
    return http.resolve(p.arena(), baseOf(p), ref) catch null;
}

/// `<base href>` when there is one.
fn baseOf(p: *Page) []const u8 {
    const head = p.doc.head() orelse return p.final_url;
    var c = head.first_child;
    while (c) |k| : (c = k.next) if (k.isTag("base")) if (k.attr("href")) |h| {
        return http.resolve(p.arena(), p.final_url, h) catch p.final_url;
    };
    return p.final_url;
}

/// `ref` as a link from this page reaches it: for script and links.
pub fn linkFrom(p: *Page, ref: []const u8) ?[]const u8 {
    return resolve(p, ref);
}

/// Walks the document for sheets, pictures and the icon not yet asked for.
pub fn scan(p: *Page) void {
    var changed = false;
    var at = p.doc.node.first_child;
    while (at) |n| : (at = n.nextInTree(p.doc.node)) {
        if (n.kind != .element) continue;
        if (n.isTag("style")) {
            changed = styleElement(p, n) or changed;
        } else if (n.isTag("link")) {
            linkElement(p, n, &changed);
        } else if (n.isTag("img") or n.isTag("source")) {
            imageElement(p, n);
        } else if (n.isTag("svg") and n.ns == .svg and n.image.len == 0) {
            inlineSvg(p, n);
        }
    }
    if (dropGone(p)) changed = true;
    if (changed) p.sheets.apply(p);
    if (!p.icon_asked and p.state != .failed and !std.mem.startsWith(u8, p.final_url, "file:")) {
        p.icon_asked = true;
        if (resolve(p, "/favicon.ico")) |u| send(p, u, "GET", "", .{ .icon = u });
    }
    pump(p);
}

/// An inline `<svg>`, as markup that nanoui draws.
fn inlineSvg(p: *Page, n: *dom.Node) void {
    const html = @import("html/html.zig");
    const text = html.serialize(p.arena(), n, true) catch return;
    n.image = text;
    n.image_key = std.fmt.allocPrint(p.arena(), "svg:{x}", .{std.hash.Wyhash.hash(0, text)}) catch "svg";
}

fn styleElement(p: *Page, n: *dom.Node) bool {
    // Looked at on every restyle: nothing is copied unless it changed.
    var hasher = std.hash.Wyhash.init(0);
    var k = n.first_child;
    while (k) |x| : (k = x.next) if (x.kind == .text) hasher.update(x.data);
    const h = hasher.final();
    const gop = p.sheets.seen.getOrPut(p.gpa, n) catch return false;
    if (gop.found_existing and gop.value_ptr.* == h) return false;
    gop.value_ptr.* = h;
    const text = n.textContent(p.arena()) catch return false;
    const media = n.attr("media");
    const sheet = css.parseSheetMedia(p.arena(), text, baseOf(p), media) catch return false;
    // A `<style>` whose text changed keeps its place.
    const slot_gop = p.sheets.slot_of.getOrPut(p.gpa, n) catch return false;
    if (!slot_gop.found_existing) slot_gop.value_ptr.* = p.sheets.add(p.gpa, true) catch return false;
    const slot = slot_gop.value_ptr.*;
    p.sheets.slots.items[slot].sheet = sheet;
    p.sheets.slots.items[slot].imports.clearRetainingCapacity();
    askImports(p, slot, sheet);
    return true;
}

fn connected(n: *const dom.Node) bool {
    var at: ?*const dom.Node = n;
    while (at) |x| : (at = x.parent) if (x.kind == .document) return true;
    return false;
}

/// Sheets whose element left the document go with it. True when any went.
fn dropGone(p: *Page) bool {
    var any = false;
    var it = p.sheets.slot_of.iterator();
    while (it.next()) |e| {
        if (connected(e.key_ptr.*)) continue;
        const slot = &p.sheets.slots.items[e.value_ptr.*];
        if (slot.sheet != null) any = true;
        slot.sheet = null;
        slot.imports.clearRetainingCapacity();
        // Back in the document, it is asked for again.
        _ = p.sheets.seen.remove(e.key_ptr.*);
    }
    return any;
}

/// A `<link>`'s address or kind changed: look at it again.
pub fn forget(p: *Page, n: *dom.Node) void {
    _ = p.sheets.seen.remove(n);
    if (p.sheets.slot_of.get(n)) |i| {
        p.sheets.slots.items[i].sheet = null;
        p.sheets.slots.items[i].imports.clearRetainingCapacity();
    }
    p.doc.touchStyle();
}

fn linkElement(p: *Page, n: *dom.Node, changed: *bool) void {
    const rel = n.attr("rel") orelse return;
    const href = n.attr("href") orelse return;
    if (hasWord(rel, "icon")) {
        if (!p.icon_asked or p.icon == null) if (resolve(p, href)) |u| {
            p.icon_asked = true;
            send(p, u, "GET", "", .{ .icon = u });
        };
        return;
    }
    if (!hasWord(rel, "stylesheet") or hasWord(rel, "alternate")) return;
    const gop = p.sheets.seen.getOrPut(p.gpa, n) catch return;
    if (gop.found_existing) return;
    gop.value_ptr.* = 0;
    const u = resolve(p, href) orelse return;
    const slot_gop = p.sheets.slot_of.getOrPut(p.gpa, n) catch return;
    if (!slot_gop.found_existing) slot_gop.value_ptr.* = p.sheets.add(p.gpa, true) catch return;
    send(p, u, "GET", "", .{ .sheet = slot_gop.value_ptr.* });
    _ = changed;
}

fn hasWord(list: []const u8, word: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |w| if (std.ascii.eqlIgnoreCase(w, word)) return true;
    return false;
}

/// A `<link>`'s fate, for its `load` or `error` event.
fn sheetDone(p: *Page, slot: u32, ok: bool) void {
    var it = p.sheets.slot_of.iterator();
    while (it.next()) |e| if (e.value_ptr.* == slot) {
        if (e.key_ptr.*.isTag("link")) web.imageDone(p, e.key_ptr.*, ok);
        return;
    };
}

fn sheetArrived(p: *Page, slot: u32, res: http.Response) void {
    const ok = res.status >= 200 and res.status < 300;
    defer sheetDone(p, slot, ok);
    if (!ok) return;
    const a = p.arena();
    const text = a.dupe(u8, res.body) catch return;
    const base = if (res.url.len > 0) a.dupe(u8, res.url) catch p.final_url else p.final_url;
    const sheet = css.parseSheet(a, text, base) catch return;
    sheet.media = p.sheets.slots.items[slot].media;
    p.sheets.slots.items[slot].sheet = sheet;
    askImports(p, slot, sheet);
    p.sheets.apply(p);
    // What it names as backgrounds is asked for as it is drawn.
}

fn askImports(p: *Page, parent: u32, sheet: *css.Sheet) void {
    for (sheet.imports) |imp| {
        if (imp.skip) continue;
        const child = p.sheets.add(p.gpa, false) catch return;
        p.sheets.slots.items[parent].imports.append(p.gpa, child) catch return;
        p.sheets.slots.items[child].media = imp.media;
        send(p, imp.url, "GET", "", .{ .sheet = child });
    }
}

/// The address a picture element wants: `src`, or the best of `srcset`.
pub fn sourceOf(n: *const dom.Node) ?[]const u8 {
    if (n.attr("srcset")) |set| if (bestOf(set)) |u| return u;
    if (n.attr("src")) |s| if (s.len > 0) return s;
    if (n.attr("data-src")) |s| if (s.len > 0) return s;
    return null;
}

/// The candidate nearest twice the page's scale, widths being unknown here: the
/// `2x`, else the first.
fn bestOf(set: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, set, ',');
    while (it.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " \t\r\n");
        if (entry.len == 0) continue;
        var parts = std.mem.tokenizeAny(u8, entry, " \t");
        const u = parts.next() orelse continue;
        if (first == null) first = u;
        if (parts.next()) |d| if (std.mem.eql(u8, d, "2x")) return u;
    }
    return first;
}

fn imageElement(p: *Page, n: *dom.Node) void {
    if (n.image_key.len > 0) return;
    const src = sourceOf(n) orelse return;
    const u = resolve(p, src) orelse return;
    n.image_key = u;
    const pic = want(p, u) orelse return;
    if (pic.state == .here) {
        n.image = pic.bytes;
        web.imageDone(p, n, true);
        return;
    }
    if (pic.state == .failed) return web.imageDone(p, n, false);
    pic.nodes.append(p.gpa, n) catch {};
}

/// Asks for an element's picture, wherever it is: `new Image()` isn't in the
/// document for `scan` to find.
pub fn askImage(p: *Page, n: *dom.Node) void {
    imageElement(p, n);
    pump(p);
}

/// `img.complete`: nothing to wait for, or it has come or failed.
pub fn imageComplete(p: *Page, n: *const dom.Node) bool {
    if (sourceOf(n) == null) return true;
    if (n.image.len > 0) return true;
    if (n.image_key.len == 0) return false;
    const pic = p.pictures.map.get(n.image_key) orelse return false;
    return pic.state == .here or pic.state == .failed;
}

fn want(p: *Page, u: []const u8) ?*Picture {
    const gop = p.pictures.map.getOrPut(p.gpa, u) catch return null;
    if (gop.found_existing) return gop.value_ptr.*;
    const pic = p.gpa.create(Picture) catch {
        _ = p.pictures.map.remove(u);
        return null;
    };
    pic.* = .{};
    gop.value_ptr.* = pic;
    p.pictures.queue.append(p.gpa, u) catch {};
    return pic;
}

/// A background's bytes, asking for them the first time.
pub fn background(p: *Page, url_in: []const u8) ?[]const u8 {
    const u = if (p.pictures.map.contains(url_in)) url_in else p.arena().dupe(u8, url_in) catch return null;
    const pic = want(p, u) orelse return null;
    if (pic.state == .here) return pic.bytes;
    if (pic.state == .queued) pump(p);
    return null;
}

fn pump(p: *Page) void {
    var q = &p.pictures;
    while (q.asked < max_pictures and q.queue.items.len > 0) {
        const u = q.queue.orderedRemove(0);
        const pic = q.map.get(u) orelse continue;
        // In the address itself: no request, and no client to read it wrong.
        if (std.ascii.startsWithIgnoreCase(u, "data:")) {
            if (http.decodeData(p.arena(), u)) |bytes| {
                pic.bytes = bytes;
                pic.state = .here;
                for (pic.nodes.items) |n| {
                    n.image = bytes;
                    web.imageDone(p, n, true);
                }
                pic.nodes.clearRetainingCapacity();
                p.doc.touchLayout();
            } else |_| {
                pic.state = .failed;
                for (pic.nodes.items) |n| web.imageDone(p, n, false);
                pic.nodes.clearRetainingCapacity();
            }
            continue;
        }
        pic.state = .asked;
        q.asked += 1;
        send(p, u, "GET", "", .{ .picture = u });
    }
}

fn pictureArrived(p: *Page, u: []const u8, res: http.Response) void {
    p.pictures.asked -|= 1;
    defer pump(p);
    const pic = p.pictures.map.get(u) orelse return;
    if (res.status < 200 or res.status >= 300 or res.body.len == 0) {
        pic.state = .failed;
        for (pic.nodes.items) |n| web.imageDone(p, n, false);
        pic.nodes.clearRetainingCapacity();
        return;
    }
    pic.bytes = p.arena().dupe(u8, res.body) catch "";
    pic.state = .here;
    for (pic.nodes.items) |n| {
        n.image = pic.bytes;
        web.imageDone(p, n, true);
    }
    pic.nodes.clearRetainingCapacity();
    // An intrinsic size is now known.
    p.doc.touchLayout();
}

fn iconArrived(p: *Page, key: []const u8, res: http.Response) void {
    if (res.status < 200 or res.status >= 300 or res.body.len == 0) return;
    if (std.mem.indexOf(u8, res.body[0..@min(res.body.len, 64)], "<html") != null) return;
    p.icon = p.arena().dupe(u8, res.body) catch return;
    p.icon_key = key;
}

test "srcset" {
    try std.testing.expectEqualStrings("b.png", bestOf("a.png 1x, b.png 2x, c.png 3x").?);
    try std.testing.expectEqualStrings("a.png", bestOf("a.png 480w, b.png 800w").?);
    try std.testing.expect(bestOf("  ") == null);
    try std.testing.expect(hasWord("shortcut ICON", "icon"));
    try std.testing.expect(!hasWord("stylesheets", "stylesheet"));
}

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
const webfonts = @import("webfonts.zig");
const frames = @import("frames.zig");
const source_pick = @import("web/source_pick.zig");

const headers = [_]http.Header{
    .{ .name = "User-Agent", .value = page_mod.user_agent },
    .{ .name = "Accept", .value = "text/html,application/xhtml+xml,image/avif,image/webp,image/png,image/jpeg,image/gif,image/svg+xml,text/css,*/*;q=0.8" },
    .{ .name = "Accept-Language", .value = "en-US,en;q=0.9" },
} ++ net.client_hints;

/// One sheet's place: its imports come before it.
pub const Slot = struct {
    sheet: ?*css.Sheet = null,
    imports: std.ArrayList(u32) = .empty,
    /// An `@import`'s own media, given to the sheet when it comes.
    media: ?*const css.MediaList = null,
    /// A top-level sheet, not one reached by `@import`.
    top: bool = true,
    /// The shadow root of the tree it applies to; null for the document.
    scope: ?*dom.Node = null,
};

pub const Sheets = struct {
    slots: std.ArrayList(Slot) = .empty,
    /// `<style>` and `<link>` elements seen, and what `<style>` held.
    seen: std.AutoHashMapUnmanaged(*dom.Node, u64) = .empty,
    /// Where each of those elements' sheet goes.
    slot_of: std.AutoHashMapUnmanaged(*dom.Node, u32) = .empty,
    flat: std.ArrayList(*const css.Sheet) = .empty,
    /// Sheets parsed from `<style>` text, by the text: a thousand instances of a
    /// custom element say the same thing.
    parsed: std.AutoHashMapUnmanaged(u64, *css.Sheet) = .empty,
    /// How many are on their way.
    asked: u32 = 0,
    /// One has arrived that the engine hasn't been given; see `sheetCame`.
    held: bool = false,
    /// When what's held is given to it though others are still coming.
    due: f64 = 0,

    pub fn deinit(s: *Sheets, gpa: Allocator) void {
        s.parsed.deinit(gpa);
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

    fn flatten(s: *Sheets, gpa: Allocator, slot: u32, depth: u8, out: *std.ArrayList(*const css.Sheet)) void {
        if (depth > 16) return;
        const x = &s.slots.items[slot];
        for (x.imports.items) |i| s.flatten(gpa, i, depth + 1, out);
        if (x.sheet) |sh| out.append(gpa, sh) catch {};
    }

    /// Gives the engine what has arrived, in the document's order, each shadow tree's apart.
    fn apply(s: *Sheets, p: *Page) void {
        s.held = false;
        const gpa = p.gpa;
        s.flat.clearRetainingCapacity();
        var trees: std.AutoArrayHashMapUnmanaged(*dom.Node, std.ArrayList(*const css.Sheet)) = .empty;
        defer {
            for (trees.values()) |*l| l.deinit(gpa);
            trees.deinit(gpa);
        }
        for (s.slots.items, 0..) |x, i| if (x.top) {
            if (x.scope) |root| {
                const got = trees.getOrPut(gpa, root) catch continue;
                if (!got.found_existing) got.value_ptr.* = .empty;
                s.flatten(gpa, @intCast(i), 0, got.value_ptr);
            } else s.flatten(gpa, @intCast(i), 0, &s.flat);
        };
        p.engine.setSheets(s.flat.items);
        webfonts.sync(p, s.flat.items);
        var lists: std.ArrayList([]const *const css.Sheet) = .empty;
        defer lists.deinit(gpa);
        for (trees.values()) |l| lists.append(gpa, l.items) catch {};
        p.engine.setScopedSheets(trees.keys()[0..lists.items.len], lists.items);
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
        font: *webfonts.Face,
    },
};

fn send(p: *Page, url_in: []const u8, method: []const u8, body: []const u8, kind: @FieldType(Req, "kind")) void {
    // A page from the web doesn't reach the disk: this asks for nothing, and
    // what it was for fails the usual way.
    const is_document = kind == .document;
    const url = if (!is_document and !net.allowed(p.final_url, url_in)) "data:," else url_in;
    if (@import("web/world.zig").log_to_stderr) std.debug.print("[net] {s} {s} ({s})\n", .{ method, url[0..@min(url.len, 110)], @tagName(kind) });
    const r = p.gpa.create(Req) catch return;
    r.* = .{ .page = p, .gpa = p.gpa, .kind = kind };
    p.pending += 1;
    if (kind == .sheet) p.sheets.asked += 1;
    var with_more: [headers.len + 2]http.Header = undefined;
    @memcpy(with_more[0..headers.len], &headers);
    var used: usize = headers.len;
    if (net.cookieLine(p.arena(), url)) |line| {
        with_more[used] = .{ .name = "Cookie", .value = line };
        used += 1;
    }
    // A tab's own document was asked for by no page; a frame's by the one holding it.
    const asker: ?*const Page = if (!is_document) p else if (p.frame) |f| f.owner else null;
    if (asker) |at| if (net.referrer(p.arena(), net.addressOf(at), url) catch null) |ref| {
        with_more[used] = .{ .name = "Referer", .value = ref };
        used += 1;
    };
    const list: []const http.Header = with_more[0..used];
    http.fetch(p.gpa, .{ .url = url, .method = method, .body = body, .headers = list, .timeout = 30 }, r, answered);
}

/// A font's file, wherever it is: fonts cross origins.
pub fn sendFont(p: *Page, url: []const u8, face: *webfonts.Face) void {
    send(p, url, "GET", "", .{ .font = face });
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
        .sheet => |slot| {
            p.sheets.asked -|= 1;
            sheetArrived(p, slot, res);
            // One that failed may have been all that was holding the others.
            sheetCame(p);
        },
        .picture => |u| pictureArrived(p, u, res),
        .icon => |k| iconArrived(p, k, res),
        .font => |f| webfonts.arrived(p, f, res.status, res.body),
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
    const own = addressOf(p);
    const head = p.doc.head() orelse return own;
    var c = head.first_child;
    while (c) |k| : (c = k.next) if (k.isTag("base")) if (k.attr("href")) |h| {
        return http.resolve(p.arena(), own, h) catch own;
    };
    return own;
}

/// What its relative addresses go from: a frame with no address has its owner's.
fn addressOf(p: *Page) []const u8 {
    if (std.mem.startsWith(u8, p.final_url, "about:")) if (p.frame) |f| return baseOf(f.owner);
    return p.final_url;
}

/// `ref` as a link from this page reaches it: for script and links.
pub fn linkFrom(p: *Page, ref: []const u8) ?[]const u8 {
    return resolve(p, ref);
}

/// Walks the document for sheets, pictures and the icon not yet asked for.
pub fn scan(p: *Page) void {
    var changed = false;
    const repick = pickChanged(p);
    var at = p.doc.node.first_child;
    while (at) |n| : (at = n.nextDeep(p.doc.node)) {
        if (n.kind != .element) continue;
        if (n.isTag("style")) {
            changed = styleElement(p, n) or changed;
        } else if (n.isTag("link")) {
            linkElement(p, n, &changed);
        } else if (n.isTag("iframe")) {
            frames.note(p, n);
        } else if (n.isTag("img")) {
            if (repick) repickImage(p, n);
            if (!isLazy(n)) imageElement(p, n);
        }
    }
    if (dropGone(p)) changed = true;
    if (changed) p.sheets.apply(p);
    frames.sweep(p);
    if (!p.icon_asked and p.worker == null and p.state != .failed and !std.mem.startsWith(u8, p.final_url, "file:")) {
        p.icon_asked = true;
        if (resolve(p, "/favicon.ico")) |u| send(p, u, "GET", "", .{ .icon = u });
    }
    pump(p);
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
    const media = n.attr("media");
    const key = std.hash.Wyhash.hash(h, media orelse "\x00");
    const known = p.sheets.parsed.get(key);
    const sheet = known orelse blk: {
        const text = n.textContent(p.arena()) catch return false;
        const made = css.parseSheetMedia(p.arena(), text, baseOf(p), media) catch return false;
        p.sheets.parsed.put(p.gpa, key, made) catch {};
        break :blk made;
    };
    // A `<style>` whose text changed keeps its place.
    const slot_gop = p.sheets.slot_of.getOrPut(p.gpa, n) catch return false;
    if (!slot_gop.found_existing) slot_gop.value_ptr.* = p.sheets.add(p.gpa, true) catch return false;
    const slot = slot_gop.value_ptr.*;
    p.sheets.slots.items[slot].sheet = sheet;
    p.sheets.slots.items[slot].scope = shadowOf(n);
    p.sheets.slots.items[slot].imports.clearRetainingCapacity();
    askImports(p, slot, sheet);
    return true;
}

/// The shadow root of the tree the element is in.
fn shadowOf(n: *const dom.Node) ?*dom.Node {
    var at = n.parent;
    while (at) |x| : (at = x.parent) if (x.is_shadow) return x;
    return null;
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
    p.sheets.slots.items[slot_gop.value_ptr.*].scope = shadowOf(n);
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
    p.sheets.held = true;
    // What it names as backgrounds is asked for as it is drawn.
}

/// How often sheets still coming are given to the engine, in seconds.
const sheet_pace = 0.3;

/// Sheets come one by one, and each given to the engine restyles the whole page:
/// GitHub's 37 cost 5 s that way, with the window frozen. So those that come
/// while others are on their way wait for them, or for `sheet_pace`.
fn sheetCame(p: *Page) void {
    const s = &p.sheets;
    if (!s.held) return;
    if (s.asked == 0) return s.apply(p);
    if (s.due <= p.engine.now) s.due = p.engine.now + sheet_pace;
}

/// A frame gives the engine what's held, once it's time.
pub fn sheetsDue(p: *Page, c: *nanoui.ui.Context) void {
    const s = &p.sheets;
    if (!s.held) return;
    if (c.time >= s.due) return s.apply(p);
    c.frameIn(@floatCast(@max(s.due - c.time, 0.001)));
}

/// A script asking about style sees every sheet that has arrived.
pub fn sheetsNow(p: *Page) void {
    if (p.sheets.held) p.sheets.apply(p);
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

/// The address a picture element wants, and what it says of density.
pub fn sourceOf(p: *Page, n: *const dom.Node) ?source_pick.Choice {
    return source_pick.choose(n, envOf(p), p.arena());
}

fn envOf(p: *Page) source_pick.Env {
    var w = p.viewport_w;
    var h = p.viewport_h;
    if (w <= 0) {
        const v = p.host.viewport(p.host.ctx);
        w = v[0];
        h = v[1];
    }
    const scale: f32 = if (p.host.uiContext(p.host.ctx)) |c| c.scale else 1;
    return .{ .scale = scale, .viewport = .{ .width = w, .height = h, .dark = p.dark } };
}

/// Whether the screen or the window have changed what `srcset` and `media` say.
fn pickChanged(p: *Page) bool {
    const e = envOf(p);
    const sig = std.hash.Wyhash.hash(0, std.mem.asBytes(&[3]f32{ e.scale, e.viewport.width, e.viewport.height }));
    if (sig == p.pick_signature) return false;
    p.pick_signature = sig;
    return true;
}

/// A picture already asked for, that the new screen or window would choose
/// differently: the old one goes, and the new one is asked for.
fn repickImage(p: *Page, n: *dom.Node) void {
    if (n.image_key.len == 0 or !source_pick.mayChange(n)) return;
    const choice = sourceOf(p, n) orelse return;
    const u = resolve(p, choice.url) orelse return;
    if (std.mem.eql(u8, u, n.image_key)) return;
    n.image_key = "";
    n.image = "";
    n.image_density = 1;
}

fn isLazy(n: *const dom.Node) bool {
    const v = n.attr("loading") orelse return false;
    return std.ascii.eqlIgnoreCase(v, "lazy");
}

fn imageElement(p: *Page, n: *dom.Node) void {
    if (n.image_key.len > 0) return;
    const choice = sourceOf(p, n) orelse return;
    const u = resolve(p, choice.url) orelse return;
    n.image_key = u;
    n.image_density = choice.density;
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
    if (n.image.len > 0) return true;
    if (sourceOf(p, n) == null) return true;
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

test "words in a list" {
    try std.testing.expect(hasWord("shortcut ICON", "icon"));
    try std.testing.expect(!hasWord("stylesheets", "stylesheet"));
}

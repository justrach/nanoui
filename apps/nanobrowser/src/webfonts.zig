//! `@font-face`: the faces sheets declare, fetched when text first needs them, so
//! the dozens of ranges a font service lists cost nothing until a character
//! falls in one. Text draws in the next family until then; when a face arrives it
//! is handed to nanoui, and style and layout run again. Nothing waits or polls:
//! the answer to the request is what moves things on.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const css = @import("css/css.zig");
const fonts_css = @import("css/font_family.zig");
const loader = @import("loader.zig");
const Page = @import("page.zig").Page;
const box = @import("layout/box.zig");
const Allocator = std.mem.Allocator;

pub const Display = enum { auto, block, swap, fallback, optional };

pub const Source = struct {
    url: []const u8 = "",
    local: []const u8 = "",
};

pub const Face = struct {
    /// With the page's mark: the name nanoui finds it by.
    family: []const u8,
    weight: [2]u16 = .{ 400, 400 },
    italic: bool = false,
    stretch: [2]u16 = .{ 100, 100 },
    ranges: []const [2]u21 = &.{},
    sources: []const Source = &.{},
    next_source: usize = 0,
    display: Display = .auto,
    state: State = .idle,
    asked_at_ms: i64 = 0,
    /// The later a rule, the earlier it is looked in among equals.
    order: u32 = 0,

    pub const State = enum { idle, loading, here, failed };
};

var next_scope: u32 = 0;

pub const Faces = struct {
    list: std.ArrayList(*Face) = .empty,
    seen: std.AutoHashMapUnmanaged(*const css.Declarations, void) = .empty,
    /// What has been looked at: a font and a character.
    checked: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// One came or went since text was last measured.
    changed: bool = false,
    scope: []const u8 = "",

    pub fn deinit(f: *Faces, gpa: Allocator) void {
        if (f.scope.len > 0) ui.unregisterFontFamilies(f.scope);
        f.list.deinit(gpa);
        f.seen.deinit(gpa);
        f.checked.deinit(gpa);
    }
};

/// The page's mark on its fonts' names: pages don't see each other's.
pub fn begin(p: *Page) void {
    next_scope +%= 1;
    p.faces.scope = std.fmt.allocPrint(p.arena(), "@{d}/", .{next_scope}) catch "@0/";
    p.engine.fonts.scope = p.faces.scope;
    p.engine.fonts.ctx = p;
    p.engine.fonts.probe = probe;
}

fn probe(ctx: *anyopaque, family: []const u8, size: f32, weight: u16, italic: bool) ?fonts_css.Units {
    const p: *Page = @ptrCast(@alignCast(ctx));
    const c = p.host.uiContext(p.host.ctx) orelse return null;
    if (size <= 0) return null;
    const f = c.text.font(.{ .size = size, .family = family, .css_weight = @max(weight, 1), .italic = italic });
    return .{ .ex = f.x_height, .ch = f.zero_width, .cap = f.cap_height };
}

/// Reads the `@font-face` rules of new sheets.
pub fn sync(p: *Page, sheets: []const *const css.Sheet) void {
    const faces = &p.faces;
    for (sheets) |s| for (s.font_faces) |rule| {
        const gop = faces.seen.getOrPut(p.gpa, rule.decls) catch continue;
        if (gop.found_existing) continue;
        const face = parse(p.arena(), rule.decls, faces.scope) catch continue;
        const f = face orelse continue;
        f.order = @intCast(faces.list.items.len);
        faces.list.append(p.gpa, f) catch continue;
        // Known before its file comes: CSS chooses among all a family's faces.
        ui.registerFontFace(p.gpa, .{
            .family = f.family,
            .pending = true,
            .weight = f.weight,
            .italic = f.italic,
            .stretch = f.stretch,
            .ranges = f.ranges,
            .order = f.order,
        }) catch {};
    };
}

fn parse(a: Allocator, d: *const css.Declarations, scope: []const u8) Allocator.Error!?*Face {
    const name = fonts_css.faceFamily(d) orelse return null;
    const f = try a.create(Face);
    f.* = .{ .family = try std.fmt.allocPrint(a, "{s}{s}", .{ scope, name }) };
    var has_src = false;
    for (d.items) |x| {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(x.name, "src")) {
            f.sources = try parseSources(a, x.value);
            has_src = true;
        } else if (eq(x.name, "font-weight")) {
            f.weight = parseWeight(x.value);
        } else if (eq(x.name, "font-style")) {
            f.italic = parseItalic(x.value);
        } else if (eq(x.name, "font-stretch") or eq(x.name, "font-width")) {
            f.stretch = parseStretch(x.value);
        } else if (eq(x.name, "unicode-range")) {
            f.ranges = try parseRanges(a, x.value);
        } else if (eq(x.name, "font-display")) {
            if (x.value.len > 0) f.display = std.meta.stringToEnum(Display, x.value[0].text) orelse .auto;
        }
    }
    return if (has_src) f else null;
}

const Token = @import("css/tokenizer.zig").Token;

fn parseWeight(t: []const Token) [2]u16 {
    var out: [2]u16 = .{ 400, 400 };
    var n: usize = 0;
    for (t) |k| {
        if (n == 2) break;
        const v: ?u16 = if (k.kind == .number) @intFromFloat(std.math.clamp(k.num, 1, 1000)) else if (k.isIdent("normal")) 400 else if (k.isIdent("bold")) 700 else null;
        if (v) |x| {
            out[n] = x;
            n += 1;
        }
    }
    if (n == 1) out[1] = out[0];
    return .{ @min(out[0], out[1]), @max(out[0], out[1]) };
}

fn parseItalic(t: []const Token) bool {
    for (t) |k| {
        if (k.isIdent("italic")) return true;
        // `oblique 0deg` is upright; `oblique 0deg 20deg` covers both.
        if (k.isIdent("oblique")) {
            var any_nonzero = t.len == 1;
            for (t) |o| if (o.kind == .dimension and o.num != 0) {
                any_nonzero = true;
            };
            return any_nonzero;
        }
    }
    return false;
}

fn stretchWord(w: []const u8) ?u16 {
    const m = std.StaticStringMap(u16).initComptime(.{
        .{ "ultra-condensed", 50 }, .{ "extra-condensed", 62 }, .{ "condensed", 75 },     .{ "semi-condensed", 87 }, .{ "normal", 100 },
        .{ "semi-expanded", 112 },  .{ "expanded", 125 },       .{ "extra-expanded", 150 }, .{ "ultra-expanded", 200 },
    });
    var buf: [16]u8 = undefined;
    if (w.len > buf.len) return null;
    return m.get(std.ascii.lowerString(&buf, w));
}

fn parseStretch(t: []const Token) [2]u16 {
    var out: [2]u16 = .{ 100, 100 };
    var n: usize = 0;
    for (t) |k| {
        if (n == 2) break;
        const v: ?u16 = if (k.kind == .percentage) @intFromFloat(std.math.clamp(k.num, 1, 1000)) else if (k.kind == .ident) stretchWord(k.text) else null;
        if (v) |x| {
            out[n] = x;
            n += 1;
        }
    }
    if (n == 1) out[1] = out[0];
    return .{ @min(out[0], out[1]), @max(out[0], out[1]) };
}

/// `src`'s entries in order, without what can't be read here.
fn parseSources(a: Allocator, t: []const Token) Allocator.Error![]const Source {
    var out: std.ArrayList(Source) = .empty;
    var i: usize = 0;
    while (i < t.len) : (i += 1) {
        var src: Source = .{};
        var ok = true;
        while (i < t.len and t[i].kind != .comma) : (i += 1) {
            const k = t[i];
            if (k.kind == .url) {
                src.url = k.text;
            } else if (k.isFunction("url")) {
                i += 1;
                if (i < t.len and t[i].kind == .string) src.url = t[i].text;
                while (i < t.len and t[i].kind != .rparen) i += 1;
            } else if (k.isFunction("local")) {
                i += 1;
                var name: std.ArrayList(u8) = .empty;
                while (i < t.len and t[i].kind != .rparen) : (i += 1) {
                    if (t[i].kind == .whitespace) continue;
                    if (name.items.len > 0) try name.append(a, ' ');
                    try name.appendSlice(a, t[i].text);
                }
                src.local = name.items;
            } else if (k.isFunction("format")) {
                i += 1;
                while (i < t.len and t[i].kind != .rparen) : (i += 1) {
                    if (t[i].kind == .string or t[i].kind == .ident) {
                        if (!supportedFormat(t[i].text)) ok = false;
                    }
                }
            } else if (k.isFunction("tech")) {
                i += 1;
                while (i < t.len and t[i].kind != .rparen) : (i += 1) {
                    if (t[i].kind == .ident and !supportedTech(t[i].text)) ok = false;
                }
            }
        }
        if (ok and (src.url.len > 0 or src.local.len > 0)) try out.append(a, src);
    }
    return out.items;
}

fn supportedFormat(f: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    return eq(f, "woff2") or eq(f, "woff") or eq(f, "truetype") or eq(f, "opentype") or eq(f, "woff2-variations") or eq(f, "woff-variations") or eq(f, "truetype-variations") or eq(f, "opentype-variations");
}

fn supportedTech(f: []const u8) bool {
    const eq = std.ascii.eqlIgnoreCase;
    return eq(f, "variations") or eq(f, "features-opentype") or eq(f, "features-aat");
}

/// `unicode-range`'s values in tokens: its raw spellings joined back, as the
/// tokenizer reads `U+0-FF` as anything but one thing.
fn parseRanges(a: Allocator, t: []const Token) Allocator.Error![]const [2]u21 {
    var out: std.ArrayList([2]u21) = .empty;
    var word: std.ArrayList(u8) = .empty;
    for (t, 0..) |k, i| {
        switch (k.kind) {
            .comma, .whitespace => {},
            .number, .percentage => try word.appendSlice(a, k.raw),
            .dimension => {
                try word.appendSlice(a, k.raw);
                try word.appendSlice(a, k.text);
            },
            .delim => try word.append(a, k.delim),
            else => try word.appendSlice(a, k.text),
        }
        const ends = i + 1 == t.len or k.kind == .comma or k.kind == .whitespace;
        if (ends and word.items.len > 0) {
            if (parseRange(word.items)) |r| try out.append(a, r);
            word.clearRetainingCapacity();
        }
    }
    return out.items;
}

/// `U+26`, `U+0-7F`, `U+4??`.
fn parseRange(w: []const u8) ?[2]u21 {
    if (w.len < 3 or (w[0] != 'U' and w[0] != 'u') or w[1] != '+') return null;
    const rest = w[2..];
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        const lo = std.fmt.parseInt(u32, rest[0..dash], 16) catch return null;
        const hi = std.fmt.parseInt(u32, rest[dash + 1 ..], 16) catch return null;
        if (lo > hi or hi > 0x10ffff) return null;
        return .{ @intCast(lo), @intCast(hi) };
    }
    var lo: u32 = 0;
    var hi: u32 = 0;
    for (rest) |c| {
        const v: u32 = if (c == '?') 0 else std.fmt.charToDigit(c, 16) catch return null;
        lo = (lo << 4) | v;
        hi = (hi << 4) | (if (c == '?') 0xf else v);
        if (hi > 0x10ffff) return null;
    }
    return .{ @intCast(lo), @intCast(hi) };
}

fn covers(f: *const Face, cp: u21) bool {
    if (f.ranges.len == 0) return true;
    for (f.ranges) |r| if (cp >= r[0] and cp <= r[1]) return true;
    return false;
}

fn nowMs() i64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds, std.time.ns_per_ms));
}

/// Asks for the faces `text` in `font` needs, and the one its line's metrics come
/// from (whichever holds the space, as CSS's first available font).
pub fn need(p: *Page, c: *ui.Context, font: box.Font, text: []const u8) void {
    if (p.faces.list.items.len == 0) return;
    needOne(p, c, font, ' ');
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const cp: u21 = if (i + n <= text.len) std.unicode.utf8Decode(text[i .. i + n]) catch 0xfffd else 0xfffd;
        i += n;
        if (cp != ' ' and cp != '\n' and cp != '\t') needOne(p, c, font, cp);
    }
}

fn needOne(p: *Page, c: *ui.Context, font: box.Font, cp: u21) void {
    var h = std.hash.Wyhash.init(cp);
    h.update(font.family);
    h.update(std.mem.asBytes(&font.weight));
    h.update(std.mem.asBytes(&font.stretch));
    h.update(&.{@intFromBool(font.italic)});
    const gop = p.faces.checked.getOrPut(p.gpa, h.final()) catch return;
    if (gop.found_existing) return;
    var names = std.mem.splitScalar(u8, font.family, ',');
    while (names.next()) |name| {
        if (name.len > 0 and name[0] == '@') {
            if (declaredCovers(p, name, font, cp)) return;
        } else if (c.text.familyHasChar(name, cp)) return;
    }
}

/// Whether this family will draw `cp`, asking for the face if it hasn't yet.
fn declaredCovers(p: *Page, name: []const u8, font: box.Font, cp: u21) bool {
    var top: u64 = std.math.maxInt(u64);
    var best: ?*const Face = null;
    for (p.faces.list.items) |f| {
        if (!std.ascii.eqlIgnoreCase(f.family, name)) continue;
        const score = ui.fontFaceScore(f.weight, f.italic, f.stretch, font.weight, font.italic, font.stretch);
        if (score < top) {
            top = score;
            best = f;
        }
    }
    const t = best orelse return false;
    var i = p.faces.list.items.len;
    while (i > 0) {
        i -= 1;
        const f = p.faces.list.items[i];
        if (!std.ascii.eqlIgnoreCase(f.family, name) or f.italic != t.italic or !std.mem.eql(u16, &f.weight, &t.weight) or !std.mem.eql(u16, &f.stretch, &t.stretch)) continue;
        if (!covers(f, cp)) continue;
        if (f.state == .idle) ask(p, f);
        if (f.state != .failed) return true;
    }
    return false;
}

/// Tries the face's next source.
fn ask(p: *Page, f: *Face) void {
    while (f.next_source < f.sources.len) {
        const src = f.sources[f.next_source];
        f.next_source += 1;
        if (src.local.len > 0) {
            const c = p.host.uiContext(p.host.ctx) orelse continue;
            if (!c.text.hasLocalFont(src.local)) continue;
            if (add(p, f, "", src.local)) return;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(src.url, "data:")) {
            const bytes = nanoui.http.decodeData(p.arena(), src.url) catch continue;
            if (add(p, f, bytes, "")) return;
            continue;
        }
        f.state = .loading;
        f.asked_at_ms = nowMs();
        loader.sendFont(p, src.url, f);
        return;
    }
    f.state = .failed;
}

/// Gives nanoui the font and starts over from style. False if it can't be read.
fn add(p: *Page, f: *Face, bytes: []const u8, local: []const u8) bool {
    ui.fillFontFace(f.family, f.order, bytes, if (local.len > 0) local else null) catch return false;
    f.state = .here;
    fontsChanged(p);
    return true;
}

/// Everything measured may now measure differently.
fn fontsChanged(p: *Page) void {
    p.faces.changed = true;
    p.doc.touchStyle();
    p.redraw();
}

/// Before style and layout: once the text system has caught up, which it does at
/// a frame's start, what was measured with the old fonts goes, and everything
/// that depends on them is worked out again.
pub fn catchUp(p: *Page, c: *ui.Context) void {
    if (!p.faces.changed or !c.text.fontsCurrent()) return;
    p.faces.changed = false;
    p.widths.clearRetainingCapacity();
    p.font_metrics.clearRetainingCapacity();
    p.doc.touchStyle();
}

/// The answer to a font request.
pub fn arrived(p: *Page, f: *Face, status: u32, body: []const u8) void {
    if (status >= 200 and status < 300 and body.len > 0) {
        // `font-display` said how long a late font may still replace what's up.
        const waited = nowMs() - f.asked_at_ms;
        const late = (f.display == .optional and waited > 100) or (f.display == .fallback and waited > 3000);
        if (late) {
            f.state = .failed;
            return;
        }
        if (add(p, f, body, "")) return;
    }
    f.state = .idle;
    ask(p, f);
}

test "unicode-range spellings" {
    try std.testing.expectEqual([2]u21{ 0x26, 0x26 }, parseRange("U+26").?);
    try std.testing.expectEqual([2]u21{ 0, 0x7f }, parseRange("u+0-7F").?);
    try std.testing.expectEqual([2]u21{ 0x400, 0x4ff }, parseRange("U+4??").?);
    try std.testing.expect(parseRange("U+110000") == null);
    try std.testing.expect(parseRange("U+7F-0") == null);
    try std.testing.expect(parseRange("x") == null);
}

test "an @font-face rule's descriptors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sheet = try css.parseSheet(a,
        \\@font-face { font-family: 'Inter'; font-style: italic; font-weight: 100 900; font-stretch: 75% 125%;
        \\  font-display: swap;
        \\  src: local("Inter Regular"), url(a.eot) format("embedded-opentype"), url(https://x.y/a.woff2) format('woff2'), url("b.woff") format(woff);
        \\  unicode-range: U+0000-00FF, U+0131, U+0025-00FF, U+4??, u+1e00-1fff, U+1F???; }
    , "https://site.test/css/s.css");
    const f = (try parse(a, sheet.font_faces[0].decls, "@1/")).?;
    try std.testing.expectEqualStrings("@1/Inter", f.family);
    try std.testing.expect(f.italic);
    try std.testing.expectEqual([2]u16{ 100, 900 }, f.weight);
    try std.testing.expectEqual([2]u16{ 75, 125 }, f.stretch);
    try std.testing.expectEqual(Display.swap, f.display);
    try std.testing.expectEqual(@as(usize, 3), f.sources.len);
    try std.testing.expectEqualStrings("Inter Regular", f.sources[0].local);
    try std.testing.expectEqualStrings("https://x.y/a.woff2", f.sources[1].url);
    try std.testing.expectEqualStrings("https://site.test/css/b.woff", f.sources[2].url);
    try std.testing.expectEqual(@as(usize, 6), f.ranges.len);
    try std.testing.expectEqual([2]u21{ 0, 0xff }, f.ranges[0]);
    try std.testing.expectEqual([2]u21{ 0x131, 0x131 }, f.ranges[1]);
    try std.testing.expectEqual([2]u21{ 0x25, 0xff }, f.ranges[2]);
    try std.testing.expectEqual([2]u21{ 0x400, 0x4ff }, f.ranges[3]);
    try std.testing.expectEqual([2]u21{ 0x1e00, 0x1fff }, f.ranges[4]);
    try std.testing.expectEqual([2]u21{ 0x1f000, 0x1ffff }, f.ranges[5]);
    try std.testing.expect(covers(f, 0x1f600) and !covers(f, 0x3000));
}

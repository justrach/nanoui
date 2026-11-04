//! The HTML tokenizer: WHATWG's state machine, written as scanners over the
//! source rather than one switch per character. Tag names and attribute
//! names come out lowercase. Tokens slice the source when they can, so the
//! source must outlive them (it is copied into the document's arena).
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const tags = @import("tags.zig");
const charrefs = @import("charrefs.zig");

pub const Tag = struct {
    name: []const u8,
    id: tags.T = .other,
    attrs: []dom.Attr = &.{},
    self_closing: bool = false,

    pub fn attr(t: *const Tag, name: []const u8) ?[]const u8 {
        for (t.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

pub const Doctype = struct {
    name: []const u8 = "",
    public_id: ?[]const u8 = null,
    system_id: ?[]const u8 = null,
    force_quirks: bool = false,
};

pub const Token = union(enum) {
    start_tag: Tag,
    end_tag: Tag,
    comment: []const u8,
    doctype: Doctype,
    character: []const u8,
    eof,
};

pub const State = enum { data, rcdata, rawtext, script_data, plaintext };

const max_attrs = 4096;

fn isWs(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\t' or c == '\r' or c == 0x0c;
}

fn isAlpha(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}

pub const Tokenizer = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    state: State = .data,
    /// The "appropriate end tag" for rcdata and rawtext.
    last_start: []const u8 = "",
    /// `<![CDATA[` is only one in foreign content; the tree builder says.
    allow_cdata: bool = false,
    attrs: std.ArrayList(dom.Attr) = .empty,

    /// Normalizes newlines of `source`, kept in the arena.
    pub fn init(arena: Allocator, source: []const u8) Allocator.Error!Tokenizer {
        return .{ .arena = arena, .src = try normalize(arena, source) };
    }

    pub fn next(t: *Tokenizer) Allocator.Error!Token {
        while (true) {
            const got = switch (t.state) {
                .data => try t.nextData(),
                .rcdata => try t.nextRaw(true),
                .rawtext => try t.nextRaw(false),
                .script_data => try t.nextScript(),
                .plaintext => try t.nextPlain(),
            };
            if (got) |tok| return tok;
        }
    }

    fn peekAt(t: *const Tokenizer, i: usize) u8 {
        return if (i < t.src.len) t.src[i] else 0;
    }

    fn startsWithCi(t: *const Tokenizer, at: usize, word: []const u8) bool {
        if (at + word.len > t.src.len) return false;
        return std.ascii.eqlIgnoreCase(t.src[at .. at + word.len], word);
    }

    fn nextData(t: *Tokenizer) Allocator.Error!?Token {
        var run: Run = .{ .t = t, .start = t.pos };
        while (t.pos < t.src.len) {
            const at = std.mem.indexOfAnyPos(u8, t.src, t.pos, "<&") orelse t.src.len;
            t.pos = at;
            if (at >= t.src.len) break;
            if (t.src[at] == '&') {
                try run.charref();
                continue;
            }
            const n = t.peekAt(at + 1);
            const opens = at + 1 < t.src.len and (isAlpha(n) or n == '!' or n == '?' or n == '/');
            if (!opens or (n == '/' and at + 2 >= t.src.len)) {
                t.pos = at + 1;
                if (n == '/' and at + 2 >= t.src.len) t.pos = at + 2;
                continue;
            }
            if (try run.take(at)) |text| return .{ .character = text };
            return try t.markup(at);
        }
        if (try run.take(t.src.len)) |text| return .{ .character = text };
        return .eof;
    }

    fn markup(t: *Tokenizer, at: usize) Allocator.Error!?Token {
        const n = t.src[at + 1];
        if (isAlpha(n)) return t.tag(at + 1, false);
        if (n == '/') {
            const m = t.peekAt(at + 2);
            if (isAlpha(m)) return t.tag(at + 2, true);
            if (m == '>') {
                t.pos = at + 3;
                return null;
            }
            return try t.bogusComment(at + 2);
        }
        if (n == '?') return try t.bogusComment(at + 1);
        // '!'
        if (std.mem.startsWith(u8, t.src[at + 2 ..], "--")) return try t.comment(at + 4);
        if (t.startsWithCi(at + 2, "doctype")) return try t.doctype(at + 9);
        if (t.allow_cdata and std.mem.startsWith(u8, t.src[at + 2 ..], "[CDATA[")) {
            const start = at + 9;
            const end = std.mem.indexOfPos(u8, t.src, start, "]]>");
            t.pos = if (end) |e| e + 3 else t.src.len;
            const text = t.src[start .. end orelse t.src.len];
            return if (text.len == 0) null else .{ .character = text };
        }
        return try t.bogusComment(at + 2);
    }

    fn bogusComment(t: *Tokenizer, start: usize) Allocator.Error!Token {
        const end = std.mem.indexOfScalarPos(u8, t.src, start, '>') orelse t.src.len;
        t.pos = @min(end + 1, t.src.len);
        return .{ .comment = try t.noNul(t.src[start..end]) };
    }

    fn comment(t: *Tokenizer, start: usize) Allocator.Error!Token {
        if (t.peekAt(start) == '>') {
            t.pos = start + 1;
            return .{ .comment = "" };
        }
        if (t.peekAt(start) == '-' and t.peekAt(start + 1) == '>') {
            t.pos = start + 2;
            return .{ .comment = "" };
        }
        var i = start;
        while (std.mem.indexOfPos(u8, t.src, i, "--")) |d| {
            if (t.peekAt(d + 2) == '>') {
                t.pos = d + 3;
                return .{ .comment = try t.noNul(t.src[start..d]) };
            }
            if (t.peekAt(d + 2) == '!' and t.peekAt(d + 3) == '>') {
                t.pos = d + 4;
                return .{ .comment = try t.noNul(t.src[start..d]) };
            }
            i = d + 1;
        }
        t.pos = t.src.len;
        return .{ .comment = try t.noNul(t.src[start..]) };
    }

    fn doctype(t: *Tokenizer, start: usize) Allocator.Error!Token {
        var i = start;
        var d: Doctype = .{};
        while (i < t.src.len and isWs(t.src[i])) : (i += 1) {}
        if (i >= t.src.len or t.src[i] == '>') {
            t.pos = @min(i + 1, t.src.len);
            d.force_quirks = true;
            return .{ .doctype = d };
        }
        const name_at = i;
        while (i < t.src.len and !isWs(t.src[i]) and t.src[i] != '>') : (i += 1) {}
        d.name = try t.lower(t.src[name_at..i]);
        while (i < t.src.len and isWs(t.src[i])) : (i += 1) {}
        if (i >= t.src.len) {
            t.pos = i;
            d.force_quirks = true;
            return .{ .doctype = d };
        }
        if (t.src[i] != '>') {
            if (t.startsWithCi(i, "public")) {
                i += 6;
                d.public_id = t.quoted(&i, &d);
                d.system_id = t.quoted(&i, null);
            } else if (t.startsWithCi(i, "system")) {
                i += 6;
                d.system_id = t.quoted(&i, &d);
            } else {
                d.force_quirks = true;
            }
        }
        const end = std.mem.indexOfScalarPos(u8, t.src, i, '>');
        if (end == null) d.force_quirks = true;
        t.pos = if (end) |e| e + 1 else t.src.len;
        return .{ .doctype = d };
    }

    /// A doctype's quoted identifier at `i`; `need` turns force_quirks on
    /// when it is missing. A `>` inside one ends the doctype.
    fn quoted(t: *Tokenizer, i: *usize, need: ?*Doctype) ?[]const u8 {
        while (i.* < t.src.len and isWs(t.src[i.*])) : (i.* += 1) {}
        const q = t.peekAt(i.*);
        if (q != '"' and q != '\'') {
            if (need) |d| d.force_quirks = true;
            return null;
        }
        const start = i.* + 1;
        var e = start;
        while (e < t.src.len and t.src[e] != q and t.src[e] != '>') : (e += 1) {}
        if (e >= t.src.len or t.src[e] == '>') {
            if (need) |d| d.force_quirks = true;
            i.* = e;
            return t.src[start..e];
        }
        i.* = e + 1;
        return t.src[start..e];
    }

    fn nextPlain(t: *Tokenizer) Allocator.Error!?Token {
        if (t.pos >= t.src.len) return .eof;
        const text = try t.noNul(t.src[t.pos..]);
        t.pos = t.src.len;
        return .{ .character = text };
    }

    fn isEndOf(t: *const Tokenizer, at: usize, name: []const u8) bool {
        if (at + 2 + name.len > t.src.len) return false;
        if (t.src[at] != '<' or t.src[at + 1] != '/') return false;
        if (!std.ascii.eqlIgnoreCase(t.src[at + 2 .. at + 2 + name.len], name)) return false;
        const c = t.peekAt(at + 2 + name.len);
        return at + 2 + name.len < t.src.len and (isWs(c) or c == '/' or c == '>');
    }

    /// RCDATA and RAWTEXT: everything up to the appropriate end tag.
    fn nextRaw(t: *Tokenizer, decode: bool) Allocator.Error!?Token {
        if (t.pos >= t.src.len) return .eof;
        var i = t.pos;
        var end = t.src.len;
        while (std.mem.indexOfPos(u8, t.src, i, "</")) |at| {
            if (t.isEndOf(at, t.last_start)) {
                end = at;
                break;
            }
            i = at + 2;
        }
        return t.rawResult(end, decode);
    }

    fn rawResult(t: *Tokenizer, end: usize, decode: bool) Allocator.Error!?Token {
        if (end == t.pos) {
            t.state = .data;
            return t.tag(end + 2, true);
        }
        const text = t.src[t.pos..end];
        t.pos = end;
        if (decode) return .{ .character = try t.decodeText(text, false) };
        return .{ .character = try t.noNul(text) };
    }

    /// Script data with its escaped and double-escaped states: `<!-- <script>`
    /// keeps a `</script>` from ending the element until `-->`.
    fn nextScript(t: *Tokenizer) Allocator.Error!?Token {
        if (t.pos >= t.src.len) return .eof;
        var i = t.pos;
        var esc: u2 = 0;
        var end = t.src.len;
        while (i < t.src.len) {
            const at = std.mem.indexOfAnyPos(u8, t.src, i, "<-") orelse break;
            i = at;
            if (t.src[at] == '-') {
                if (esc != 0 and std.mem.startsWith(u8, t.src[at..], "-->")) {
                    esc = 0;
                    i = at + 3;
                } else {
                    i = at + 1;
                }
                continue;
            }
            if (esc == 0 and std.mem.startsWith(u8, t.src[at..], "<!--")) {
                esc = 1;
                i = at + 2;
                continue;
            }
            if (t.isEndOf(at, "script")) {
                if (esc == 2) {
                    esc = 1;
                    i = at + 8;
                    continue;
                }
                end = at;
                break;
            }
            if (esc == 1 and t.startsWithCi(at + 1, "script")) {
                const c = t.peekAt(at + 7);
                if (isWs(c) or c == '/' or c == '>') esc = 2;
            }
            i = at + 1;
        }
        return t.rawResult(end, false);
    }

    /// Reads a tag from its name at `start`. Null at the end of the input:
    /// a tag not closed by then is dropped.
    fn tag(t: *Tokenizer, start: usize, is_end: bool) Allocator.Error!?Token {
        var i = start;
        while (i < t.src.len and !isWs(t.src[i]) and t.src[i] != '/' and t.src[i] != '>') : (i += 1) {}
        const name = try t.lower(t.src[start..i]);
        t.attrs.clearRetainingCapacity();
        var self_closing = false;
        while (true) {
            while (i < t.src.len and isWs(t.src[i])) : (i += 1) {}
            if (i >= t.src.len) {
                t.pos = i;
                return null;
            }
            const c = t.src[i];
            if (c == '>') {
                i += 1;
                break;
            }
            if (c == '/') {
                i += 1;
                if (t.peekAt(i) == '>' and i < t.src.len) {
                    self_closing = true;
                    i += 1;
                    break;
                }
                continue;
            }
            try t.attribute(&i);
        }
        t.pos = i;
        const out: Tag = .{
            .name = name,
            .id = tags.htmlId(name),
            .attrs = if (t.attrs.items.len == 0) &.{} else try t.arena.dupe(dom.Attr, t.attrs.items),
            .self_closing = self_closing,
        };
        if (is_end) return .{ .end_tag = out };
        t.last_start = name;
        return .{ .start_tag = out };
    }

    fn attribute(t: *Tokenizer, ip: *usize) Allocator.Error!void {
        var i = ip.*;
        const name_at = i;
        // A leading `=` is part of the name.
        if (t.src[i] == '=') i += 1;
        while (i < t.src.len and !isWs(t.src[i]) and t.src[i] != '/' and t.src[i] != '>' and t.src[i] != '=') : (i += 1) {}
        const name_end = i;
        while (i < t.src.len and isWs(t.src[i])) : (i += 1) {}
        var value: []const u8 = "";
        if (t.peekAt(i) == '=' and i < t.src.len) {
            i += 1;
            while (i < t.src.len and isWs(t.src[i])) : (i += 1) {}
            if (i < t.src.len and t.src[i] != '>') {
                const q = t.src[i];
                var raw: []const u8 = undefined;
                if (q == '"' or q == '\'') {
                    const e = std.mem.indexOfScalarPos(u8, t.src, i + 1, q) orelse t.src.len;
                    raw = t.src[i + 1 .. e];
                    i = @min(e + 1, t.src.len);
                } else {
                    const at = i;
                    while (i < t.src.len and !isWs(t.src[i]) and t.src[i] != '>') : (i += 1) {}
                    raw = t.src[at..i];
                }
                value = try t.decodeText(raw, true);
            }
        }
        ip.* = i;
        const name = try t.lower(t.src[name_at..name_end]);
        if (t.attrs.items.len >= max_attrs) return;
        for (t.attrs.items) |a| if (std.mem.eql(u8, a.name, name)) return;
        try t.attrs.append(t.arena, .{ .name = name, .value = value });
    }

    /// `s` in lowercase, a NUL as U+FFFD; `s` itself when already so.
    fn lower(t: *Tokenizer, s: []const u8) Allocator.Error![]const u8 {
        var plain = true;
        for (s) |c| if ((c >= 'A' and c <= 'Z') or c == 0) {
            plain = false;
            break;
        };
        if (plain) return s;
        const out = try t.noNul(s);
        const copy = try t.arena.dupe(u8, out);
        _ = std.ascii.lowerString(copy, copy);
        return copy;
    }

    /// NUL becomes U+FFFD outside the data state.
    fn noNul(t: *Tokenizer, s: []const u8) Allocator.Error![]const u8 {
        if (std.mem.indexOfScalar(u8, s, 0) == null) return s;
        return std.mem.replaceOwned(u8, t.arena, s, "\x00", "\u{FFFD}");
    }

    fn decodeText(t: *Tokenizer, raw: []const u8, in_attr: bool) Allocator.Error![]const u8 {
        const clean = try t.noNul(raw);
        if (std.mem.indexOfScalar(u8, clean, '&') == null) return clean;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < clean.len) {
            const at = std.mem.indexOfScalarPos(u8, clean, i, '&') orelse clean.len;
            try out.appendSlice(t.arena, clean[i..at]);
            i = at;
            if (at >= clean.len) break;
            if (charrefs.decode(clean, at, in_attr)) |d| {
                try out.appendSlice(t.arena, d.slice());
                i = at + d.consumed;
            } else {
                try out.append(t.arena, '&');
                i = at + 1;
            }
        }
        return out.items;
    }
};

/// A text run in the data state: a slice of the source until the first
/// reference forces a copy.
const Run = struct {
    t: *Tokenizer,
    start: usize,
    buf: std.ArrayList(u8) = .empty,
    copying: bool = false,

    fn charref(r: *Run) Allocator.Error!void {
        const t = r.t;
        const at = t.pos;
        const d = charrefs.decode(t.src, at, false) orelse {
            t.pos = at + 1;
            return;
        };
        r.copying = true;
        try r.buf.appendSlice(t.arena, t.src[r.start..at]);
        try r.buf.appendSlice(t.arena, d.slice());
        t.pos = at + d.consumed;
        r.start = t.pos;
    }

    /// The text up to `end`, if any; the tokenizer resumes at `end`.
    fn take(r: *Run, end: usize) Allocator.Error!?[]const u8 {
        const t = r.t;
        if (r.copying) {
            try r.buf.appendSlice(t.arena, t.src[r.start..end]);
            t.pos = end;
            r.start = end;
            return if (r.buf.items.len == 0) null else r.buf.items;
        }
        if (end == r.start) return null;
        t.pos = end;
        const s = t.src[r.start..end];
        r.start = end;
        return s;
    }
};

/// The input stream's preprocessing: CRLF and CR become LF, into a copy.
fn normalize(arena: Allocator, source: []const u8) Allocator.Error![]const u8 {
    const copy = try arena.dupe(u8, source);
    const first = std.mem.indexOfScalar(u8, copy, '\r') orelse return copy;
    var w = first;
    var i = first;
    while (i < copy.len) : (i += 1) {
        if (copy[i] == '\r') {
            copy[w] = '\n';
            w += 1;
            if (i + 1 < copy.len and copy[i + 1] == '\n') i += 1;
        } else {
            copy[w] = copy[i];
            w += 1;
        }
    }
    return copy[0..w];
}

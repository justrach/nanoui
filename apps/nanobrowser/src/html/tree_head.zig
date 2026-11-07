//! The insertion modes around the body: initial through after-head, the text
//! mode, after-body and the frameset modes.
const std = @import("std");
const tree = @import("tree.zig");
const tz = @import("tokenizer.zig");
const body = @import("tree_body.zig");

const Builder = tree.Builder;
const Token = tree.Token;
const Act = tree.Act;
const Error = tree.Error;

const quirks_public = [_][]const u8{
    "+//silmaril//dtd html pro v0r11 19970101//",                            "-//as//dtd html 3.0 aswedit + extensions//",
    "-//advasoft ltd//dtd html 3.0 aswedit + extensions//",                  "-//ietf//dtd html 2.0 level 1//",
    "-//ietf//dtd html 2.0 level 2//",                                       "-//ietf//dtd html 2.0 strict level 1//",
    "-//ietf//dtd html 2.0 strict level 2//",                                "-//ietf//dtd html 2.0 strict//",
    "-//ietf//dtd html 2.0//",                                               "-//ietf//dtd html 2.1e//",
    "-//ietf//dtd html 3.0//",                                               "-//ietf//dtd html 3.2 final//",
    "-//ietf//dtd html 3.2//",                                               "-//ietf//dtd html 3//",
    "-//ietf//dtd html level 0//",                                           "-//ietf//dtd html level 1//",
    "-//ietf//dtd html level 2//",                                           "-//ietf//dtd html level 3//",
    "-//ietf//dtd html strict level 0//",                                    "-//ietf//dtd html strict level 1//",
    "-//ietf//dtd html strict level 2//",                                    "-//ietf//dtd html strict level 3//",
    "-//ietf//dtd html strict//",                                            "-//ietf//dtd html//",
    "-//metrius//dtd metrius presentational//",                              "-//microsoft//dtd internet explorer 2.0 html strict//",
    "-//microsoft//dtd internet explorer 2.0 html//",                        "-//microsoft//dtd internet explorer 2.0 tables//",
    "-//microsoft//dtd internet explorer 3.0 html strict//",                 "-//microsoft//dtd internet explorer 3.0 html//",
    "-//microsoft//dtd internet explorer 3.0 tables//",                      "-//netscape comm. corp.//dtd html//",
    "-//netscape comm. corp.//dtd strict html//",                            "-//o'reilly and associates//dtd html 2.0//",
    "-//o'reilly and associates//dtd html extended 1.0//",                   "-//o'reilly and associates//dtd html extended relaxed 1.0//",
    "-//sq//dtd html 2.0 hotmetal + extensions//",                           "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//",
    "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//", "-//spyglass//dtd html 2.0 extended//",
    "-//sun microsystems corp.//dtd hotjava html//",                         "-//sun microsystems corp.//dtd hotjava strict html//",
    "-//w3c//dtd html 3 1995-03-24//",                                       "-//w3c//dtd html 3.2 draft//",
    "-//w3c//dtd html 3.2 final//",                                          "-//w3c//dtd html 3.2//",
    "-//w3c//dtd html 3.2s draft//",                                         "-//w3c//dtd html 4.0 frameset//",
    "-//w3c//dtd html 4.0 transitional//",                                   "-//w3c//dtd html experimental 19960712//",
    "-//w3c//dtd html experimental 970421//",                                "-//w3c//dtd w3 html//",
    "-//w3o//dtd w3 html 3.0//",                                             "-//webtechs//dtd mozilla html 2.0//",
    "-//webtechs//dtd mozilla html//",
};

fn lowerEql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn prefixCi(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

/// The doctype's verdict on quirks mode.
fn isQuirks(d: *const tz.Doctype) bool {
    if (d.force_quirks or !std.mem.eql(u8, d.name, "html")) return true;
    if (d.public_id) |p| {
        if (lowerEql(p, "-//w3o//dtd w3 html strict 3.0//en//") or lowerEql(p, "-/w3c/dtd html 4.0 transitional/en") or lowerEql(p, "html")) return true;
        for (quirks_public) |q| if (prefixCi(p, q)) return true;
        if (d.system_id == null and (prefixCi(p, "-//w3c//dtd html 4.01 frameset//") or prefixCi(p, "-//w3c//dtd html 4.01 transitional//"))) return true;
    }
    if (d.system_id) |s| if (lowerEql(s, "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd")) return true;
    return false;
}

pub fn initial(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| {
            const n = tree.wsPrefix(s);
            if (n == s.len) return .done;
            t.character = s[n..];
        },
        .comment => |s| {
            try b.insertComment(s, b.root);
            return .done;
        },
        .doctype => |*d| {
            const n = try b.arena.create(@TypeOf(b.root.*));
            n.* = .{ .kind = .doctype, .doc = b.doc, .data = d.name };
            b.root.appendChild(n);
            b.doc.quirks = isQuirks(d);
            b.mode = .before_html;
            return .done;
        },
        else => {},
    }
    // No doctype at all.
    b.doc.quirks = true;
    b.mode = .before_html;
    return .again;
}

pub fn beforeHtml(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .doctype => return .done,
        .comment => |s| {
            try b.insertComment(s, b.root);
            return .done;
        },
        .character => |s| {
            const n = tree.wsPrefix(s);
            if (n == s.len) return .done;
            t.character = s[n..];
        },
        .start_tag => |*s| if (s.id == .html) {
            const n = try b.insertNew(s.name, .html, s.attrs);
            try b.push(n);
            b.mode = .before_head;
            return .done;
        },
        .end_tag => |*s| switch (s.id) {
            .head, .body, .html, .br => {},
            else => return .done,
        },
        .eof => {},
    }
    const n = try b.insertNew("html", .html, &.{});
    try b.push(n);
    b.mode = .before_head;
    return .again;
}

pub fn beforeHead(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| {
            const n = tree.wsPrefix(s);
            if (n == s.len) return .done;
            t.character = s[n..];
        },
        .comment => |s| {
            try b.insertComment(s, null);
            return .done;
        },
        .doctype => return .done,
        .start_tag => |*s| {
            if (s.id == .html) return body.inBody(b, t);
            if (s.id == .head) {
                b.head_ptr = try b.insert(s);
                b.mode = .in_head;
                return .done;
            }
        },
        .end_tag => |*s| switch (s.id) {
            .head, .body, .html, .br => {},
            else => return .done,
        },
        .eof => {},
    }
    b.head_ptr = try b.insertImplied("head");
    b.mode = .in_head;
    return .again;
}

pub fn inHead(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| {
            const n = tree.wsPrefix(s);
            try b.insertText(s[0..n]);
            if (n == s.len) return .done;
            t.character = s[n..];
        },
        .comment => |s| {
            try b.insertComment(s, null);
            return .done;
        },
        .doctype => return .done,
        .start_tag => |*s| switch (s.id) {
            .html => return body.inBody(b, t),
            .base, .basefont, .bgsound, .link, .meta => {
                try b.insertVoid(s);
                return .done;
            },
            .title => {
                try b.parseRaw(s, .rcdata);
                return .done;
            },
            .noscript => {
                if (b.scripting) {
                    try b.parseRaw(s, .rawtext);
                } else {
                    _ = try b.insert(s);
                    b.mode = .in_head_noscript;
                }
                return .done;
            },
            .noframes, .style => {
                try b.parseRaw(s, .rawtext);
                return .done;
            },
            .script => {
                try b.parseRaw(s, .script_data);
                return .done;
            },
            .template => {
                if (!try declarativeShadow(b, s)) {
                    const made = try b.insert(s);
                    made.template_content = try b.doc.createFragment();
                }
                try b.formatting.append(b.arena, .{ .node = null });
                b.frameset_ok = false;
                b.mode = .in_template;
                try b.template_modes.append(b.arena, .in_template);
                return .done;
            },
            .head => return .done,
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .head => {
                b.pop();
                b.mode = .after_head;
                return .done;
            },
            .body, .html, .br => {},
            .template => {
                if (!b.onStack(.template)) return .done;
                b.generateThorough();
                b.popUntil(.template);
                body.clearFormattingToMarker(b);
                if (b.template_modes.items.len > 0) b.template_modes.items.len -= 1;
                b.resetMode();
                return .done;
            },
            else => return .done,
        },
        .eof => {},
    }
    b.pop();
    b.mode = .after_head;
    return .again;
}

pub fn inHeadNoscript(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .doctype => return .done,
        .start_tag => |*s| switch (s.id) {
            .html => return body.inBody(b, t),
            .basefont, .bgsound, .link, .meta, .noframes, .style => return inHead(b, t),
            .head, .noscript => return .done,
            else => {},
        },
        .end_tag => |*s| {
            if (s.id == .noscript) {
                b.pop();
                b.mode = .in_head;
                return .done;
            }
            if (s.id != .br) return .done;
        },
        .comment => return inHead(b, t),
        .character => |s| {
            const n = tree.wsPrefix(s);
            try b.insertText(s[0..n]);
            if (n == s.len) return .done;
            t.character = s[n..];
        },
        .eof => {},
    }
    b.pop();
    b.mode = .in_head;
    return .again;
}

pub fn afterHead(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| {
            const n = tree.wsPrefix(s);
            try b.insertText(s[0..n]);
            if (n == s.len) return .done;
            t.character = s[n..];
        },
        .comment => |s| {
            try b.insertComment(s, null);
            return .done;
        },
        .doctype => return .done,
        .start_tag => |*s| switch (s.id) {
            .html => return body.inBody(b, t),
            .body => {
                _ = try b.insert(s);
                b.frameset_ok = false;
                b.mode = .in_body;
                return .done;
            },
            .frameset => {
                _ = try b.insert(s);
                b.mode = .in_frameset;
                return .done;
            },
            .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => {
                // Inside the head, though it has been left.
                if (b.head_ptr) |h| try b.push(h);
                const act = try inHead(b, t);
                if (b.head_ptr) |h| b.removeFromStack(h);
                return act;
            },
            .head => return .done,
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .template => return inHead(b, t),
            .body, .html, .br => {},
            else => return .done,
        },
        .eof => {},
    }
    _ = try b.insertImplied("body");
    b.mode = .in_body;
    return .again;
}

pub fn text(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| try b.insertText(s),
        .eof => {
            b.pop();
            b.mode = b.original_mode;
            b.tok.state = .data;
            return .again;
        },
        .end_tag => {
            b.pop();
            b.mode = b.original_mode;
        },
        else => {},
    }
    return .done;
}

pub fn afterBody(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| if (tree.allWs(s)) return body.inBody(b, t),
        .comment => |s| {
            try b.insertComment(s, b.open.items[0].node);
            return .done;
        },
        .doctype => return .done,
        .start_tag => |*s| if (s.id == .html) return body.inBody(b, t),
        .end_tag => |*s| if (s.id == .html) {
            b.mode = .after_after_body;
            return .done;
        },
        .eof => return .done,
    }
    b.mode = .in_body;
    return .again;
}

pub fn inFrameset(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| {
            for (s) |c| if (tree.isWs(c)) try b.insertText(try b.arena.dupe(u8, &.{c}));
        },
        .comment => |s| try b.insertComment(s, null),
        .start_tag => |*s| switch (s.id) {
            .html => return body.inBody(b, t),
            .frameset => _ = try b.insert(s),
            .frame => try b.insertVoid(s),
            .noframes => return inHead(b, t),
            else => {},
        },
        .end_tag => |*s| if (s.id == .frameset and b.open.items.len > 1) {
            b.pop();
            if (b.context == null and b.cur() != .frameset) b.mode = .after_frameset;
        },
        else => {},
    }
    return .done;
}

pub fn afterFrameset(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| {
            for (s) |c| if (tree.isWs(c)) try b.insertText(try b.arena.dupe(u8, &.{c}));
        },
        .comment => |s| try b.insertComment(s, null),
        .start_tag => |*s| switch (s.id) {
            .html => return body.inBody(b, t),
            .noframes => return inHead(b, t),
            else => {},
        },
        .end_tag => |*s| if (s.id == .html) {
            b.mode = .after_after_frameset;
        },
        else => {},
    }
    return .done;
}

pub fn afterAfterBody(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .comment => |s| {
            try b.insertComment(s, b.root);
            return .done;
        },
        .doctype => return body.inBody(b, t),
        .character => |s| if (tree.allWs(s)) return body.inBody(b, t),
        .start_tag => |*s| if (s.id == .html) return body.inBody(b, t),
        .eof => return .done,
        .end_tag => {},
    }
    b.mode = .in_body;
    return .again;
}

pub fn afterAfterFrameset(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .comment => |s| try b.insertComment(s, b.root),
        .doctype => return body.inBody(b, t),
        .character => |s| {
            if (tree.allWs(s)) return body.inBody(b, t);
            for (s) |c| if (tree.isWs(c)) try b.insertText(try b.arena.dupe(u8, &.{c}));
        },
        .start_tag => |*s| {
            if (s.id == .html) return body.inBody(b, t);
            if (s.id == .noframes) return inHead(b, t);
        },
        else => {},
    }
    return .done;
}

/// `<template shadowrootmode>`: the element that holds it gets a shadow root, which
/// the template's content goes in, and the template itself goes nowhere. True when
/// it did. A second one on a host, or one in `innerHTML`, is an ordinary template.
fn declarativeShadow(b: *Builder, s: *const tz.Tag) Error!bool {
    var mode: ?[]const u8 = null;
    for (s.attrs) |a| if (std.mem.eql(u8, a.name, "shadowrootmode")) {
        mode = a.value;
    };
    const m = mode orelse return false;
    const open = std.ascii.eqlIgnoreCase(m, "open");
    if (!open and !std.ascii.eqlIgnoreCase(m, "closed")) return false;
    if (b.context != null) return false;
    const host = (b.current() orelse return false).node;
    if (host.kind != .element or host.shadow_root != null or host.isTag("template")) return false;
    const root = try host.attachShadow(!open, true);
    const tpl = try b.newElement(s.name, .html, s.attrs);
    tpl.template_content = root;
    try b.open.append(b.arena, .{ .node = tpl, .id = s.id });
    return true;
}

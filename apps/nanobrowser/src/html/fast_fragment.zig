//! Blink-style `HTMLFastPathParser` for well-formed HTML fragments (`innerHTML`,
//! `insertAdjacentHTML`, `outerHTML`). Falls back (`null`) to the full WHATWG
//! tree builder (`html.parseFragmentWith`) on any non-HTML context, void/block
//! implicit-close ambiguity, unclosed/misnested tag, script/style/table/form/svg
//!/custom element, CR/NUL normalization, or uncommon character reference.

const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const perf = @import("../perf_rules.zig");

const TagKind = enum(u8) {
    void_tag,
    inline_fmt,
    a_tag,
    button_tag,
    p_tag,
    li_tag,
    list_tag,
    dl_tag,
    dt_dd_tag,
    heading_tag,
    block_tag,
    custom_tag,
};

const TagSpec = struct {
    name: []const u8,
    kind: TagKind,
    html_tag: perf.HtmlTag = .other,
};

const tag_map = std.StaticStringMap(TagSpec).initComptime(.{
    .{ "div", TagSpec{ .name = "div", .kind = .block_tag } },
    .{ "span", TagSpec{ .name = "span", .kind = .inline_fmt } },
    .{ "li", TagSpec{ .name = "li", .kind = .li_tag } },
    .{ "ul", TagSpec{ .name = "ul", .kind = .list_tag, .html_tag = .list } },
    .{ "ol", TagSpec{ .name = "ol", .kind = .list_tag, .html_tag = .list } },
    .{ "input", TagSpec{ .name = "input", .kind = .void_tag, .html_tag = .input } },
    .{ "label", TagSpec{ .name = "label", .kind = .inline_fmt } },
    .{ "button", TagSpec{ .name = "button", .kind = .button_tag, .html_tag = .button } },
    .{ "a", TagSpec{ .name = "a", .kind = .a_tag } },
    .{ "p", TagSpec{ .name = "p", .kind = .p_tag } },
    .{ "br", TagSpec{ .name = "br", .kind = .void_tag, .html_tag = .br } },
    .{ "hr", TagSpec{ .name = "hr", .kind = .void_tag } },
    .{ "img", TagSpec{ .name = "img", .kind = .void_tag, .html_tag = .img } },
    .{ "h1", TagSpec{ .name = "h1", .kind = .heading_tag } },
    .{ "h2", TagSpec{ .name = "h2", .kind = .heading_tag } },
    .{ "h3", TagSpec{ .name = "h3", .kind = .heading_tag } },
    .{ "h4", TagSpec{ .name = "h4", .kind = .heading_tag } },
    .{ "h5", TagSpec{ .name = "h5", .kind = .heading_tag } },
    .{ "h6", TagSpec{ .name = "h6", .kind = .heading_tag } },
    .{ "section", TagSpec{ .name = "section", .kind = .block_tag } },
    .{ "article", TagSpec{ .name = "article", .kind = .block_tag } },
    .{ "header", TagSpec{ .name = "header", .kind = .block_tag } },
    .{ "footer", TagSpec{ .name = "footer", .kind = .block_tag } },
    .{ "main", TagSpec{ .name = "main", .kind = .block_tag } },
    .{ "nav", TagSpec{ .name = "nav", .kind = .block_tag } },
    .{ "aside", TagSpec{ .name = "aside", .kind = .block_tag } },
    .{ "strong", TagSpec{ .name = "strong", .kind = .inline_fmt } },
    .{ "em", TagSpec{ .name = "em", .kind = .inline_fmt } },
    .{ "b", TagSpec{ .name = "b", .kind = .inline_fmt } },
    .{ "i", TagSpec{ .name = "i", .kind = .inline_fmt } },
    .{ "u", TagSpec{ .name = "u", .kind = .inline_fmt } },
    .{ "s", TagSpec{ .name = "s", .kind = .inline_fmt } },
    .{ "small", TagSpec{ .name = "small", .kind = .inline_fmt } },
    .{ "code", TagSpec{ .name = "code", .kind = .inline_fmt } },
    .{ "blockquote", TagSpec{ .name = "blockquote", .kind = .block_tag } },
    .{ "dl", TagSpec{ .name = "dl", .kind = .dl_tag } },
    .{ "dt", TagSpec{ .name = "dt", .kind = .dt_dd_tag } },
    .{ "dd", TagSpec{ .name = "dd", .kind = .dt_dd_tag } },
    .{ "figure", TagSpec{ .name = "figure", .kind = .block_tag } },
    .{ "figcaption", TagSpec{ .name = "figcaption", .kind = .block_tag } },
    .{ "time", TagSpec{ .name = "time", .kind = .inline_fmt } },
    .{ "mark", TagSpec{ .name = "mark", .kind = .inline_fmt } },
    .{ "sub", TagSpec{ .name = "sub", .kind = .inline_fmt } },
    .{ "sup", TagSpec{ .name = "sup", .kind = .inline_fmt } },
    .{ "slot", TagSpec{ .name = "slot", .kind = .inline_fmt, .html_tag = .slot } },
});

const reserved_hyphen_tags = std.StaticStringMap(void).initComptime(.{
    .{"annotation-xml"}, .{"color-profile"},   .{"font-face"},
    .{"font-face-src"},  .{"font-face-uri"},   .{"font-face-format"},
    .{"font-face-name"}, .{"missing-glyph"},
});

const attr_name_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "class", "class" },                 .{ "id", "id" },                       .{ "type", "type" },
    .{ "value", "value" },                 .{ "data-id", "data-id" },             .{ "href", "href" },
    .{ "src", "src" },                     .{ "alt", "alt" },                     .{ "title", "title" },
    .{ "name", "name" },                   .{ "for", "for" },                     .{ "placeholder", "placeholder" },
    .{ "role", "role" },                   .{ "style", "style" },                 .{ "checked", "checked" },
    .{ "disabled", "disabled" },           .{ "selected", "selected" },           .{ "readonly", "readonly" },
    .{ "required", "required" },           .{ "hidden", "hidden" },               .{ "tabindex", "tabindex" },
    .{ "target", "target" },               .{ "rel", "rel" },                     .{ "width", "width" },
    .{ "height", "height" },               .{ "loading", "loading" },             .{ "aria-label", "aria-label" },
    .{ "aria-hidden", "aria-hidden" },     .{ "aria-expanded", "aria-expanded" }, .{ "aria-selected", "aria-selected" },
    .{ "aria-controls", "aria-controls" }, .{ "data-testid", "data-testid" },     .{ "data-action", "data-action" },
    .{ "data-index", "data-index" },       .{ "data-key", "data-key" },           .{ "data-type", "data-type" },
});

const attr_val_map = std.StaticStringMap([]const u8).initComptime(.{
    .{ "", "" },                         .{ "checkbox", "checkbox" },         .{ "text", "text" },
    .{ "button", "button" },             .{ "submit", "submit" },             .{ "toggle", "toggle" },
    .{ "destroy", "destroy" },           .{ "edit", "edit" },                 .{ "view", "view" },
    .{ "completed", "completed" },       .{ "selected", "selected" },         .{ "active", "active" },
    .{ "new-todo", "new-todo" },         .{ "todo-list", "todo-list" },       .{ "todo-count", "todo-count" },
    .{ "clear-completed", "clear-completed" }, .{ "true", "true" },           .{ "false", "false" },
    .{ "#", "#" },                       .{ "0", "0" },                       .{ "1", "1" },
});

const nl_spaces = "\n                                ";
const nl_tabs = "\n\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t\t";

fn staticWsSlice(raw: []const u8) ?[]const u8 {
    if (raw.len == 0) return "";
    if (raw[0] == '\n') {
        if (raw.len <= nl_spaces.len and std.mem.allEqual(u8, raw[1..], ' ')) return nl_spaces[0..raw.len];
        if (raw.len <= nl_tabs.len and std.mem.allEqual(u8, raw[1..], '\t')) return nl_tabs[0..raw.len];
    } else if (raw[0] == ' ' and raw.len <= nl_spaces.len - 1 and std.mem.allEqual(u8, raw, ' ')) {
        return nl_spaces[1 .. 1 + raw.len];
    }
    return null;
}

fn isCustomTagName(tname: []const u8) bool {
    if (tname.len < 2 or tname.len > 48) return false;
    if (tname[0] < 'a' or tname[0] > 'z') return false;
    var has_dash = false;
    for (tname) |c| {
        if (c == '-') {
            has_dash = true;
        } else if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '.')) {
            return false;
        }
    }
    if (!has_dash) return false;
    return !reserved_hyphen_tags.has(tname);
}

fn allowedContext(ctx: *const dom.Node) bool {
    if (ctx.kind == .fragment) return true;
    if (ctx.kind != .element or ctx.ns != .html) return false;
    if (ctx.is_shadow or std.mem.eql(u8, ctx.tag, "body") or std.mem.eql(u8, ctx.tag, "template")) return true;
    if (tag_map.get(ctx.tag)) |spec| {
        return switch (spec.kind) {
            .void_tag, .p_tag, .a_tag, .button_tag => false,
            else => true,
        };
    }
    return isCustomTagName(ctx.tag);
}

inline fn isHtmlWs(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\t' or c == 0x0c;
}

fn closesOpenP(kind: TagKind) bool {
    return switch (kind) {
        .block_tag, .list_tag, .li_tag, .p_tag, .heading_tag, .dl_tag, .dt_dd_tag => true,
        else => false,
    };
}

fn canOpenOnStack(stack: []const TagSpec, spec: TagSpec) bool {
    for (stack) |open| {
        if (open.kind == .p_tag and (closesOpenP(spec.kind) or std.mem.eql(u8, spec.name, "hr"))) return false;
        if (spec.kind == .a_tag and open.kind == .a_tag) return false;
        if (spec.kind == .button_tag and open.kind == .button_tag) return false;
        if (spec.kind == .heading_tag and open.kind == .heading_tag) return false;
    }
    if (spec.kind == .li_tag) {
        var idx = stack.len;
        while (idx > 0) {
            idx -= 1;
            if (stack[idx].kind == .list_tag) break;
            if (stack[idx].kind == .li_tag) return false;
        }
    } else if (spec.kind == .dt_dd_tag) {
        var idx = stack.len;
        while (idx > 0) {
            idx -= 1;
            if (stack[idx].kind == .dl_tag) break;
            if (stack[idx].kind == .dt_dd_tag) return false;
        }
    }
    return true;
}

const DecodeResult = union(enum) {
    ok: []const u8,
    bail,
    oom,
};

fn decodeText(arena: Allocator, raw: []const u8, is_attr: bool) DecodeResult {
    if (!is_attr) {
        if (staticWsSlice(raw)) |ws| return .{ .ok = ws };
    } else if (raw.len <= 16) {
        if (attr_val_map.get(raw)) |v| return .{ .ok = v };
    }
    var has_amp = false;
    var si: usize = 0;
    while (si + 8 <= raw.len) : (si += 8) {
        const w = std.mem.readInt(u64, raw[si..][0..8], .little);
        const z0 = (w -% 0x0101_0101_0101_0101) & ~w & 0x8080_8080_8080_8080;
        const wr = w ^ 0x0d0d_0d0d_0d0d_0d0d;
        const zr = (wr -% 0x0101_0101_0101_0101) & ~wr & 0x8080_8080_8080_8080;
        if ((z0 | zr) != 0) return .bail;
        const wa = w ^ 0x2626_2626_2626_2626;
        if (((wa -% 0x0101_0101_0101_0101) & ~wa & 0x8080_8080_8080_8080) != 0) has_amp = true;
    }
    while (si < raw.len) : (si += 1) {
        const c = raw[si];
        if (c == 0 or c == '\r') return .bail;
        if (c == '&') has_amp = true;
    }
    if (!has_amp) return .{ .ok = arena.dupe(u8, raw) catch return .oom };

    var out: std.ArrayList(u8) = .empty;
    out.ensureTotalCapacity(arena, raw.len) catch return .oom;
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '&') {
            out.appendAssumeCapacity(raw[i]);
            i += 1;
            continue;
        }
        const rem = raw[i + 1 ..];
        const semi = std.mem.indexOfScalar(u8, rem[0..@min(rem.len, 12)], ';') orelse return .bail;
        if (semi == 0) return .bail;
        const ent = rem[0..semi];
        if (std.mem.eql(u8, ent, "amp")) {
            out.append(arena, '&') catch return .oom;
        } else if (std.mem.eql(u8, ent, "lt")) {
            out.append(arena, '<') catch return .oom;
        } else if (std.mem.eql(u8, ent, "gt")) {
            out.append(arena, '>') catch return .oom;
        } else if (std.mem.eql(u8, ent, "quot")) {
            out.append(arena, '"') catch return .oom;
        } else if (std.mem.eql(u8, ent, "apos")) {
            out.append(arena, '\'') catch return .oom;
        } else if (std.mem.eql(u8, ent, "nbsp")) {
            out.appendSlice(arena, "\xc2\xa0") catch return .oom;
        } else if (ent[0] == '#' and ent.len >= 2) {
            const cp: u32 = if (ent[1] == 'x' or ent[1] == 'X')
                (if (ent.len >= 3) (std.fmt.parseInt(u32, ent[2..], 16) catch return .bail) else return .bail)
            else
                (std.fmt.parseInt(u32, ent[1..], 10) catch return .bail);
            if (cp == 0 or cp == '\r' or (cp >= 0x80 and cp <= 0x9f) or (cp >= 0xd800 and cp <= 0xdfff) or cp > 0x10ffff) return .bail;
            var u8buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cp), &u8buf) catch return .bail;
            out.appendSlice(arena, u8buf[0..len]) catch return .oom;
        } else return .bail;
        i += 1 + semi + 1;
    }
    return .{ .ok = out.items };
}

fn lowerAsciiBuf(raw: []const u8, buf: []u8) ?[]const u8 {
    if (raw.len == 0 or raw.len > buf.len) return null;
    var has_upper = false;
    for (raw) |c| {
        if (c >= 'A' and c <= 'Z') has_upper = true;
    }
    if (!has_upper) return raw;
    for (raw, 0..) |c, idx| buf[idx] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    return buf[0..raw.len];
}

pub fn tryParseFragment(doc: *dom.Document, context: *dom.Node, source: []const u8) Allocator.Error!?*dom.Node {
    if (!allowedContext(context)) return null;
    if (source.len > 512 * 1024) return null;

    const arena = doc.arena;
    const fragment = try doc.createFragment();
    var node_stack: [32]*dom.Node = undefined;
    var spec_stack: [32]TagSpec = undefined;
    var depth: usize = 0;
    var cur_parent: *dom.Node = fragment;

    var i: usize = 0;
    while (i < source.len) {
        const lt_rel = std.mem.indexOfScalarPos(u8, source, i, '<');
        const text_end = lt_rel orelse source.len;
        if (text_end > i) {
            const decoded = switch (decodeText(arena, source[i..text_end], false)) {
                .ok => |s| s,
                .bail => return null,
                .oom => return error.OutOfMemory,
            };
            const tn = try arena.create(dom.Node);
            tn.* = .{ .kind = .text, .doc = doc, .data = decoded };
            cur_parent.parserInsert(tn, null);
        }
        if (lt_rel == null) break;
        i = text_end + 1;
        if (i >= source.len) return null;

        if (source[i] == '?') {
            const end_gt = std.mem.indexOfScalarPos(u8, source, i, '>') orelse return null;
            for (source[i..end_gt]) |c| if (c == 0 or c == '\r') return null;
            const cn = try doc.createComment(source[i..end_gt]);
            cur_parent.parserInsert(cn, null);
            i = end_gt + 1;
            continue;
        }

        if (source[i] == '!') {
            if (i + 3 > source.len or source[i + 1] != '-' or source[i + 2] != '-') return null;
            i += 3;
            if (i < source.len and source[i] == '>') {
                const cn = try doc.createComment("");
                cur_parent.parserInsert(cn, null);
                i += 1;
                continue;
            }
            if (i + 1 < source.len and source[i] == '-' and source[i + 1] == '>') {
                const cn = try doc.createComment("");
                cur_parent.parserInsert(cn, null);
                i += 2;
                continue;
            }
            const end_rel = std.mem.indexOfPos(u8, source, i, "-->") orelse return null;
            const body = source[i..end_rel];
            for (body, 0..) |c, bi| {
                if (c == 0 or c == '\r') return null;
                if (c == '-' and bi + 2 < body.len and body[bi + 1] == '-' and body[bi + 2] == '!') return null;
            }
            const cn = try doc.createComment(body);
            cur_parent.parserInsert(cn, null);
            i = end_rel + 3;
            continue;
        }

        if (source[i] == '/') {
            i += 1;
            if (i >= source.len or !std.ascii.isAlphabetic(source[i])) return null;
            const name_start = i;
            while (i < source.len) : (i += 1) {
                const c = source[i];
                if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) break;
            }
            var tbuf: [48]u8 = undefined;
            const tname = lowerAsciiBuf(source[name_start..i], &tbuf) orelse return null;
            while (i < source.len and isHtmlWs(source[i])) : (i += 1) {}
            if (i >= source.len or source[i] != '>') return null;
            i += 1;
            if (depth == 0 or !std.mem.eql(u8, spec_stack[depth - 1].name, tname)) return null;
            depth -= 1;
            cur_parent = if (depth == 0) fragment else node_stack[depth - 1];
            continue;
        }

        if (!std.ascii.isAlphabetic(source[i])) return null;
        const name_start = i;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) break;
        }
        var tbuf: [48]u8 = undefined;
        const tname = lowerAsciiBuf(source[name_start..i], &tbuf) orelse return null;
        const spec: TagSpec = tag_map.get(tname) orelse blk: {
            if (!isCustomTagName(tname)) return null;
            break :blk .{ .name = try arena.dupe(u8, tname), .kind = .custom_tag };
        };
        if (!canOpenOnStack(spec_stack[0..depth], spec)) return null;
        if (i >= source.len) return null;
        if (source[i] != '>' and source[i] != '/' and !isHtmlWs(source[i])) return null;

        var attr_buf: [16]dom.Attr = undefined;
        var attr_len: usize = 0;
        var attr_extra: std.ArrayList(dom.Attr) = .empty;
        var self_close = false;

        while (true) {
            while (i < source.len and isHtmlWs(source[i])) : (i += 1) {}
            if (i >= source.len) return null;
            if (source[i] == '>') {
                i += 1;
                break;
            }
            if (source[i] == '/') {
                if (i + 1 >= source.len or source[i + 1] != '>') return null;
                self_close = true;
                i += 2;
                break;
            }
            const a_start = i;
            var a_upper = false;
            while (i < source.len) : (i += 1) {
                const c = source[i];
                if (isHtmlWs(c) or c == '=' or c == '>' or c == '/') break;
                if (c <= 0x1f or c == '"' or c == '\'' or c == '<') return null;
                if (c >= 'A' and c <= 'Z') a_upper = true;
            }
            if (i == a_start) return null;
            const raw_aname = source[a_start..i];
            const aname: []const u8 = if (!a_upper) (attr_name_map.get(raw_aname) orelse try arena.dupe(u8, raw_aname)) else blk: {
                const d = try arena.dupe(u8, raw_aname);
                _ = std.ascii.lowerString(d, d);
                break :blk d;
            };
            if (aname.len == 2 and aname[0] == 'i' and aname[1] == 's') return null;

            while (i < source.len and isHtmlWs(source[i])) : (i += 1) {}
            var aval: []const u8 = "";
            if (i < source.len and source[i] == '=') {
                i += 1;
                while (i < source.len and isHtmlWs(source[i])) : (i += 1) {}
                if (i >= source.len) return null;
                const q = source[i];
                if (q == '"' or q == '\'') {
                    i += 1;
                    const q_end = std.mem.indexOfScalarPos(u8, source, i, q) orelse return null;
                    aval = switch (decodeText(arena, source[i..q_end], true)) {
                        .ok => |s| s,
                        .bail => return null,
                        .oom => return error.OutOfMemory,
                    };
                    i = q_end + 1;
                } else {
                    const v_start = i;
                    while (i < source.len) : (i += 1) {
                        const c = source[i];
                        if (isHtmlWs(c) or c == '>') break;
                        if (c <= 0x1f or c == '"' or c == '\'' or c == '=' or c == '<' or c == '`' or c == '/') return null;
                    }
                    if (i == v_start) return null;
                    aval = switch (decodeText(arena, source[v_start..i], true)) {
                        .ok => |s| s,
                        .bail => return null,
                        .oom => return error.OutOfMemory,
                    };
                }
            }

            var dup = false;
            const existing = if (attr_extra.items.len > 0) attr_extra.items else attr_buf[0..attr_len];
            for (existing) |ea| if (std.mem.eql(u8, ea.name, aname)) {
                dup = true;
                break;
            };
            if (!dup) {
                if (attr_extra.items.len > 0) {
                    try attr_extra.append(arena, .{ .name = aname, .value = aval });
                } else if (attr_len < attr_buf.len) {
                    attr_buf[attr_len] = .{ .name = aname, .value = aval };
                    attr_len += 1;
                } else {
                    try attr_extra.appendSlice(arena, &attr_buf);
                    try attr_extra.append(arena, .{ .name = aname, .value = aval });
                }
            }
        }

        if (self_close and spec.kind != .void_tag) return null;

        const el = try arena.create(dom.Node);
        el.* = .{
            .kind = .element,
            .doc = doc,
            .tag = spec.name,
            .ns = .html,
            .html_tag = spec.html_tag,
            .has_resource = perf.isResourceTag(spec.name),
            .has_insertion_work = perf.isInsertionWorkTag(spec.name),
        };
        const final_attrs: []dom.Attr = if (attr_extra.items.len > 0)
            attr_extra.items
        else if (attr_len > 0)
            try arena.dupe(dom.Attr, attr_buf[0..attr_len])
        else
            &.{};
        if (final_attrs.len > 0) {
            el.attrs = .fromOwnedSlice(final_attrs);
            for (final_attrs) |a| {
                if (a.name.len > 2 and a.name[0] == 'o' and a.name[1] == 'n') el.has_on_attr = true;
                perf.syncNodeAttr(el, a.name, a.value);
            }
        }
        cur_parent.parserInsert(el, null);

        if (spec.kind != .void_tag) {
            if (depth >= node_stack.len) return null;
            node_stack[depth] = el;
            spec_stack[depth] = spec;
            depth += 1;
            cur_parent = el;
        }
    }

    if (depth != 0) return null;
    return fragment;
}

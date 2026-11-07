//! The "in body" insertion mode, the heart of the tree builder, with the
//! active formatting list's small operations.
const std = @import("std");
const dom = @import("../dom.zig");
const tree = @import("tree.zig");
const tags = @import("tags.zig");
const tz = @import("tokenizer.zig");
const head = @import("tree_head.zig");
const adoption = @import("tree_adoption.zig");
const foreign = @import("tree_foreign.zig");

const Builder = tree.Builder;
const Token = tree.Token;
const Act = tree.Act;
const Error = tree.Error;
const T = tags.T;

pub fn clearFormattingToMarker(b: *Builder) void {
    while (b.formatting.items.len > 0) {
        const e = b.formatting.pop().?;
        if (e.node == null) return;
    }
}

pub fn inBody(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| {
            try adoption.reconstruct(b);
            try b.insertText(s);
            if (!tree.allWs(s)) b.frameset_ok = false;
        },
        .comment => |s| try b.insertComment(s, null),
        .doctype => {},
        .eof => {
            if (b.template_modes.items.len > 0) return b.htmlIn(.in_template, t);
        },
        .start_tag => |*s| return startTag(b, t, s),
        .end_tag => |*s| return endTag(b, t, s),
    }
    return .done;
}

fn startTag(b: *Builder, t: *Token, s: *tz.Tag) Error!Act {
    switch (s.id) {
        .html => {
            if (!b.onStack(.template) and b.open.items.len > 0) try b.addMissingAttrs(b.open.items[0].node, s);
        },
        .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => return head.inHead(b, t),
        .body => {
            const items = b.open.items;
            if (items.len < 2 or items[1].id != .body or b.onStack(.template)) return .done;
            b.frameset_ok = false;
            try b.addMissingAttrs(items[1].node, s);
        },
        .frameset => {
            const items = b.open.items;
            if (items.len < 2 or items[1].id != .body or !b.frameset_ok) return .done;
            items[1].node.remove();
            b.open.items.len = 1;
            _ = try b.insert(s);
            b.mode = .in_frameset;
        },
        .address, .article, .aside, .blockquote, .center, .details, .dialog, .dir, .div, .dl, .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .main, .menu, .nav, .ol, .p, .search, .section, .summary, .ul => {
            b.closeP();
            _ = try b.insert(s);
        },
        .h1, .h2, .h3, .h4, .h5, .h6 => {
            b.closeP();
            if (tags.isHeading(b.cur())) b.pop();
            _ = try b.insert(s);
        },
        .pre, .listing => {
            b.closeP();
            _ = try b.insert(s);
            b.ignore_lf = true;
            b.frameset_ok = false;
        },
        .form => {
            const in_template = b.onStack(.template);
            if (b.form_ptr != null and !in_template) return .done;
            b.closeP();
            const n = try b.insert(s);
            if (!in_template) b.form_ptr = n;
        },
        .li => {
            listItem(b, .li);
            _ = try b.insert(s);
        },
        .dd, .dt => {
            listItem(b, s.id);
            _ = try b.insert(s);
        },
        .plaintext => {
            b.closeP();
            _ = try b.insert(s);
            b.tok.state = .plaintext;
        },
        .button => {
            if (b.inScope(.button)) {
                b.generateImplied(.other);
                b.popUntil(.button);
            }
            try adoption.reconstruct(b);
            _ = try b.insert(s);
            b.frameset_ok = false;
        },
        .a => {
            if (lastFormattingAnchor(b)) |n| {
                _ = try adoption.run(b, "a", .a);
                adoption.removeFormatting(b, n);
                b.removeFromStack(n);
            }
            try adoption.reconstruct(b);
            const n = try b.insert(s);
            try adoption.pushFormatting(b, n, s.id);
        },
        .b, .big, .code, .em, .font, .i, .s, .small, .strike, .strong, .tt, .u => {
            try adoption.reconstruct(b);
            const n = try b.insert(s);
            try adoption.pushFormatting(b, n, s.id);
        },
        .nobr => {
            try adoption.reconstruct(b);
            if (b.inScope(.nobr)) {
                _ = try adoption.run(b, "nobr", .nobr);
                try adoption.reconstruct(b);
            }
            const n = try b.insert(s);
            try adoption.pushFormatting(b, n, s.id);
        },
        .applet, .marquee, .object => {
            try adoption.reconstruct(b);
            _ = try b.insert(s);
            try b.formatting.append(b.arena, .{ .node = null });
            b.frameset_ok = false;
        },
        .table => {
            if (!b.doc.quirks) b.closeP();
            _ = try b.insert(s);
            b.frameset_ok = false;
            b.mode = .in_table;
        },
        .area, .br, .embed, .img, .keygen, .wbr => {
            try adoption.reconstruct(b);
            try b.insertVoid(s);
            b.frameset_ok = false;
        },
        .input => {
            try adoption.reconstruct(b);
            try b.insertVoid(s);
            const ty = s.attr("type") orelse "";
            if (!std.ascii.eqlIgnoreCase(ty, "hidden")) b.frameset_ok = false;
        },
        .param, .source, .track => try b.insertVoid(s),
        .hr => {
            b.closeP();
            try b.insertVoid(s);
            b.frameset_ok = false;
        },
        .image => {
            s.name = "img";
            s.id = .img;
            return .again;
        },
        .textarea => {
            _ = try b.insert(s);
            b.ignore_lf = true;
            b.tok.state = .rcdata;
            b.original_mode = b.mode;
            b.frameset_ok = false;
            b.mode = .text;
        },
        .xmp => {
            b.closeP();
            try adoption.reconstruct(b);
            b.frameset_ok = false;
            try b.parseRaw(s, .rawtext);
        },
        .iframe => {
            b.frameset_ok = false;
            try b.parseRaw(s, .rawtext);
        },
        .noembed => try b.parseRaw(s, .rawtext),
        .noscript => {
            if (b.scripting) {
                try b.parseRaw(s, .rawtext);
            } else {
                try adoption.reconstruct(b);
                _ = try b.insert(s);
            }
        },
        .select => {
            try adoption.reconstruct(b);
            _ = try b.insert(s);
            b.frameset_ok = false;
            b.mode = switch (b.mode) {
                .in_table, .in_caption, .in_table_body, .in_row, .in_cell => .in_select_in_table,
                else => .in_select,
            };
        },
        .optgroup, .option => {
            if (b.cur() == .option) b.pop();
            try adoption.reconstruct(b);
            _ = try b.insert(s);
        },
        .rb, .rtc => {
            if (b.inScope(.ruby)) b.generateImplied(.other);
            _ = try b.insert(s);
        },
        .rp, .rt => {
            if (b.inScope(.ruby)) b.generateImplied(.rtc);
            _ = try b.insert(s);
        },
        .math => {
            try adoption.reconstruct(b);
            foreign.adjustMathAttrs(s);
            foreign.adjustForeignAttrs(s);
            _ = try b.insertForeign(s.name, .mathml, s.attrs);
            if (s.self_closing) b.pop();
        },
        .svg => {
            try adoption.reconstruct(b);
            foreign.adjustSvgAttrs(s);
            foreign.adjustForeignAttrs(s);
            _ = try b.insertForeign(s.name, .svg, s.attrs);
            if (s.self_closing) b.pop();
        },
        .caption, .col, .colgroup, .frame, .head, .tbody, .td, .tfoot, .th, .thead, .tr => {},
        else => {
            try adoption.reconstruct(b);
            _ = try b.insert(s);
        },
    }
    return .done;
}

/// `<li>`, `<dd>`, `<dt>` close an open one of their own kind.
fn listItem(b: *Builder, id: T) void {
    b.frameset_ok = false;
    var i = b.open.items.len;
    while (i > 0) {
        i -= 1;
        const e = b.open.items[i].id;
        const same = if (id == .li) e == .li else e == .dd or e == .dt;
        if (same) {
            b.generateImplied(e);
            b.popUntil(e);
            break;
        }
        if (tags.isSpecial(e) and e != .address and e != .div and e != .p) break;
    }
    b.closeP();
}

/// An `a` in the formatting list after its last marker.
fn lastFormattingAnchor(b: *const Builder) ?*dom.Node {
    var i = b.formatting.items.len;
    while (i > 0) {
        i -= 1;
        const e = b.formatting.items[i];
        const n = e.node orelse return null;
        if (e.id == .a) return n;
    }
    return null;
}

fn endTag(b: *Builder, t: *Token, s: *tz.Tag) Error!Act {
    switch (s.id) {
        .template => return head.inHead(b, t),
        .body => {
            if (!b.inScope(.body)) return .done;
            b.mode = .after_body;
        },
        .html => {
            if (!b.inScope(.body)) return .done;
            b.mode = .after_body;
            return .again;
        },
        .address, .article, .aside, .blockquote, .button, .center, .details, .dialog, .dir, .div, .dl, .fieldset, .figcaption, .figure, .footer, .header, .hgroup, .listing, .main, .menu, .nav, .ol, .pre, .search, .section, .summary, .ul => {
            if (!b.inScope(s.id)) return .done;
            b.generateImplied(.other);
            b.popUntil(s.id);
        },
        .form => {
            if (!b.onStack(.template)) {
                const n = b.form_ptr;
                b.form_ptr = null;
                const node = n orelse return .done;
                if (!b.nodeInScope(node)) return .done;
                b.generateImplied(.other);
                b.removeFromStack(node);
            } else {
                if (!b.inScope(.form)) return .done;
                b.generateImplied(.other);
                b.popUntil(.form);
            }
        },
        .p => {
            if (!b.inButtonScope(.p)) _ = try b.insertImplied("p");
            b.closeP();
        },
        .li => {
            if (!b.inListScope(.li)) return .done;
            b.generateImplied(.li);
            b.popUntil(.li);
        },
        .dd, .dt => {
            if (!b.inScope(s.id)) return .done;
            b.generateImplied(s.id);
            b.popUntil(s.id);
        },
        .h1, .h2, .h3, .h4, .h5, .h6 => {
            if (!b.headingInScope()) return .done;
            b.generateImplied(.other);
            b.popUntilHeading();
        },
        .a, .b, .big, .code, .em, .font, .i, .nobr, .s, .small, .strike, .strong, .tt, .u => {
            if (try adoption.run(b, s.name, s.id)) try otherEnd(b, s);
        },
        .applet, .marquee, .object => {
            if (!b.inScope(s.id)) return .done;
            b.generateImplied(.other);
            b.popUntil(s.id);
            clearFormattingToMarker(b);
        },
        .br => {
            var br: tz.Tag = .{ .name = "br", .id = .br };
            try adoption.reconstruct(b);
            try b.insertVoid(&br);
            b.frameset_ok = false;
        },
        else => try otherEnd(b, s),
    }
    return .done;
}

/// "Any other end tag".
pub fn otherEnd(b: *Builder, s: *const tz.Tag) Error!void {
    var i = b.open.items.len;
    while (i > 0) {
        i -= 1;
        const e = b.open.items[i];
        if (e.node.ns == .html and std.mem.eql(u8, e.node.tag, s.name)) {
            // Implied end tags, keeping this one.
            while (b.open.items.len > 1) {
                const c = b.current().?;
                if (c.node == e.node or !tags.isImpliedEnd(c.id)) break;
                b.pop();
            }
            b.popUntilNode(e.node);
            return;
        }
        if (tags.isSpecial(e.id)) return;
    }
}

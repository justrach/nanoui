//! The table insertion modes, select and template: where content arriving in
//! the wrong place is fostered out in front of the table.
const std = @import("std");
const tree = @import("tree.zig");
const head = @import("tree_head.zig");
const body = @import("tree_body.zig");

const Builder = tree.Builder;
const Token = tree.Token;
const Act = tree.Act;
const Error = tree.Error;

fn clearToTable(b: *Builder) void {
    while (b.open.items.len > 1) switch (b.cur()) {
        .table, .template, .html => return,
        else => b.pop(),
    };
}

fn clearToBody(b: *Builder) void {
    while (b.open.items.len > 1) switch (b.cur()) {
        .tbody, .tfoot, .thead, .template, .html => return,
        else => b.pop(),
    };
}

fn clearToRow(b: *Builder) void {
    while (b.open.items.len > 1) switch (b.cur()) {
        .tr, .template, .html => return,
        else => b.pop(),
    };
}

/// Foster: run the token as in body, with insertions redirected.
fn asInBodyFostered(b: *Builder, t: *Token) Error!Act {
    b.foster = true;
    defer b.foster = false;
    return body.inBody(b, t);
}

pub fn inTable(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => {
            switch (b.cur()) {
                .table, .tbody, .template, .tfoot, .thead, .tr => {
                    b.pending_text.clearRetainingCapacity();
                    b.table_text_mode = b.mode;
                    b.mode = .in_table_text;
                    return .again;
                },
                else => return asInBodyFostered(b, t),
            }
        },
        .comment => |s| {
            try b.insertComment(s, null);
            return .done;
        },
        .doctype => return .done,
        .start_tag => |*s| switch (s.id) {
            .caption => {
                clearToTable(b);
                try b.formatting.append(b.arena, .{ .node = null });
                _ = try b.insert(s);
                b.mode = .in_caption;
                return .done;
            },
            .colgroup => {
                clearToTable(b);
                _ = try b.insert(s);
                b.mode = .in_column_group;
                return .done;
            },
            .col => {
                clearToTable(b);
                _ = try b.insertImplied("colgroup");
                b.mode = .in_column_group;
                return .again;
            },
            .tbody, .tfoot, .thead => {
                clearToTable(b);
                _ = try b.insert(s);
                b.mode = .in_table_body;
                return .done;
            },
            .td, .th, .tr => {
                clearToTable(b);
                _ = try b.insertImplied("tbody");
                b.mode = .in_table_body;
                return .again;
            },
            .table => {
                if (!b.inTableScope(.table)) return .done;
                b.popUntil(.table);
                b.resetMode();
                return .again;
            },
            .style, .script, .template => return head.inHead(b, t),
            .input => {
                const ty = s.attr("type") orelse "";
                if (!std.ascii.eqlIgnoreCase(ty, "hidden")) return asInBodyFostered(b, t);
                try b.insertVoid(s);
                return .done;
            },
            .form => {
                if (b.onStack(.template) or b.form_ptr != null) return .done;
                b.form_ptr = try b.insert(s);
                b.pop();
                return .done;
            },
            else => return asInBodyFostered(b, t),
        },
        .end_tag => |*s| switch (s.id) {
            .table => {
                if (!b.inTableScope(.table)) return .done;
                b.popUntil(.table);
                b.resetMode();
                return .done;
            },
            .body, .caption, .col, .colgroup, .html, .tbody, .td, .tfoot, .th, .thead, .tr => return .done,
            .template => return head.inHead(b, t),
            else => return asInBodyFostered(b, t),
        },
        .eof => return body.inBody(b, t),
    }
}

pub fn inTableText(b: *Builder, t: *Token) Error!Act {
    if (t.* == .character) {
        try b.pending_text.append(b.arena, t.character);
        return .done;
    }
    const pending = b.pending_text.items;
    var has_other = false;
    for (pending) |s| if (!tree.allWs(s)) {
        has_other = true;
        break;
    };
    b.mode = b.table_text_mode;
    if (has_other) {
        for (pending) |s| {
            var ct: Token = .{ .character = s };
            _ = try asInBodyFostered(b, &ct);
        }
    } else {
        for (pending) |s| try b.insertText(s);
    }
    b.pending_text.clearRetainingCapacity();
    return .again;
}

pub fn inCaption(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .start_tag => |*s| switch (s.id) {
            .caption, .col, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr => {
                if (!closeCaption(b)) return .done;
                return .again;
            },
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .caption => {
                _ = closeCaption(b);
                return .done;
            },
            .table => {
                if (!closeCaption(b)) return .done;
                return .again;
            },
            .body, .col, .colgroup, .html, .tbody, .td, .tfoot, .th, .thead, .tr => return .done,
            else => {},
        },
        else => {},
    }
    return body.inBody(b, t);
}

fn closeCaption(b: *Builder) bool {
    if (!b.inTableScope(.caption)) return false;
    b.generateImplied(.other);
    b.popUntil(.caption);
    body.clearFormattingToMarker(b);
    b.mode = .in_table;
    return true;
}

pub fn inColumnGroup(b: *Builder, t: *Token) Error!Act {
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
            .col => {
                try b.insertVoid(s);
                return .done;
            },
            .template => return head.inHead(b, t),
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .colgroup => {
                if (b.cur() != .colgroup) return .done;
                b.pop();
                b.mode = .in_table;
                return .done;
            },
            .col => return .done,
            .template => return head.inHead(b, t),
            else => {},
        },
        .eof => return body.inBody(b, t),
    }
    if (b.cur() != .colgroup) return .done;
    b.pop();
    b.mode = .in_table;
    return .again;
}

pub fn inTableBody(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .start_tag => |*s| switch (s.id) {
            .tr => {
                clearToBody(b);
                _ = try b.insert(s);
                b.mode = .in_row;
                return .done;
            },
            .th, .td => {
                clearToBody(b);
                _ = try b.insertImplied("tr");
                b.mode = .in_row;
                return .again;
            },
            .caption, .col, .colgroup, .tbody, .tfoot, .thead => return leaveBody(b),
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .tbody, .tfoot, .thead => {
                if (!b.inTableScope(s.id)) return .done;
                clearToBody(b);
                b.pop();
                b.mode = .in_table;
                return .done;
            },
            .table => return leaveBody(b),
            .body, .caption, .col, .colgroup, .html, .td, .th, .tr => return .done,
            else => {},
        },
        else => {},
    }
    return inTable(b, t);
}

fn leaveBody(b: *Builder) Act {
    if (!b.inTableScope(.tbody) and !b.inTableScope(.thead) and !b.inTableScope(.tfoot)) return .done;
    clearToBody(b);
    b.pop();
    b.mode = .in_table;
    return .again;
}

pub fn inRow(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .start_tag => |*s| switch (s.id) {
            .th, .td => {
                clearToRow(b);
                _ = try b.insert(s);
                b.mode = .in_cell;
                try b.formatting.append(b.arena, .{ .node = null });
                return .done;
            },
            .caption, .col, .colgroup, .tbody, .tfoot, .thead, .tr => return leaveRow(b),
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .tr => {
                _ = leaveRow(b);
                return .done;
            },
            .table => return leaveRow(b),
            .tbody, .tfoot, .thead => {
                if (!b.inTableScope(s.id)) return .done;
                return leaveRow(b);
            },
            .body, .caption, .col, .colgroup, .html, .td, .th => return .done,
            else => {},
        },
        else => {},
    }
    return inTable(b, t);
}

fn leaveRow(b: *Builder) Act {
    if (!b.inTableScope(.tr)) return .done;
    clearToRow(b);
    b.pop();
    b.mode = .in_table_body;
    return .again;
}

fn closeCell(b: *Builder) void {
    b.generateImplied(.other);
    while (b.open.items.len > 1) {
        const c = b.cur();
        b.pop();
        if (c == .td or c == .th) break;
    }
    body.clearFormattingToMarker(b);
    b.mode = .in_row;
}

pub fn inCell(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .start_tag => |*s| switch (s.id) {
            .caption, .col, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr => {
                if (!b.inTableScope(.td) and !b.inTableScope(.th)) return .done;
                closeCell(b);
                return .again;
            },
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .td, .th => {
                if (!b.inTableScope(s.id)) return .done;
                b.generateImplied(.other);
                b.popUntil(s.id);
                body.clearFormattingToMarker(b);
                b.mode = .in_row;
                return .done;
            },
            .body, .caption, .col, .colgroup, .html => return .done,
            .table, .tbody, .tfoot, .thead, .tr => {
                if (!b.inTableScope(s.id)) return .done;
                closeCell(b);
                return .again;
            },
            else => {},
        },
        else => {},
    }
    return body.inBody(b, t);
}

pub fn inSelect(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character => |s| try b.insertText(s),
        .comment => |s| try b.insertComment(s, null),
        .doctype => {},
        .start_tag => |*s| switch (s.id) {
            .html => return body.inBody(b, t),
            .option => {
                if (b.cur() == .option) b.pop();
                _ = try b.insert(s);
            },
            .optgroup => {
                if (b.cur() == .option) b.pop();
                if (b.cur() == .optgroup) b.pop();
                _ = try b.insert(s);
            },
            .select => {
                if (!b.inSelectScope(.select)) return .done;
                b.popUntil(.select);
                b.resetMode();
            },
            .input, .keygen, .textarea => {
                if (!b.inSelectScope(.select)) return .done;
                b.popUntil(.select);
                b.resetMode();
                return .again;
            },
            .script, .template => return head.inHead(b, t),
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .optgroup => {
                const items = b.open.items;
                if (b.cur() == .option and items.len >= 2 and items[items.len - 2].id == .optgroup) b.pop();
                if (b.cur() == .optgroup) b.pop();
            },
            .option => if (b.cur() == .option) b.pop(),
            .select => {
                if (!b.inSelectScope(.select)) return .done;
                b.popUntil(.select);
                b.resetMode();
            },
            .template => return head.inHead(b, t),
            else => {},
        },
        .eof => return body.inBody(b, t),
    }
    return .done;
}

pub fn inSelectInTable(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .start_tag => |*s| switch (s.id) {
            .caption, .table, .tbody, .tfoot, .thead, .tr, .td, .th => {
                b.popUntil(.select);
                b.resetMode();
                return .again;
            },
            else => {},
        },
        .end_tag => |*s| switch (s.id) {
            .caption, .table, .tbody, .tfoot, .thead, .tr, .td, .th => {
                if (!b.inTableScope(s.id)) return .done;
                b.popUntil(.select);
                b.resetMode();
                return .again;
            },
            else => {},
        },
        else => {},
    }
    return inSelect(b, t);
}

fn switchTemplateMode(b: *Builder, m: tree.Mode) Error!void {
    if (b.template_modes.items.len > 0) b.template_modes.items.len -= 1;
    try b.template_modes.append(b.arena, m);
    b.mode = m;
}

pub fn inTemplate(b: *Builder, t: *Token) Error!Act {
    switch (t.*) {
        .character, .comment, .doctype => return body.inBody(b, t),
        .start_tag => |*s| switch (s.id) {
            .base, .basefont, .bgsound, .link, .meta, .noframes, .script, .style, .template, .title => return head.inHead(b, t),
            .caption, .colgroup, .tbody, .tfoot, .thead => try switchTemplateMode(b, .in_table),
            .col => try switchTemplateMode(b, .in_column_group),
            .tr => try switchTemplateMode(b, .in_table_body),
            .td, .th => try switchTemplateMode(b, .in_row),
            else => try switchTemplateMode(b, .in_body),
        },
        .end_tag => |*s| {
            if (s.id == .template) return head.inHead(b, t);
            return .done;
        },
        .eof => {
            if (!b.onStack(.template)) return .done;
            b.popUntil(.template);
            body.clearFormattingToMarker(b);
            if (b.template_modes.items.len > 0) b.template_modes.items.len -= 1;
            b.resetMode();
        },
    }
    return .again;
}

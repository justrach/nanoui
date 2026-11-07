//! The HTML parser's interface: bytes to UTF-8, UTF-8 to a document tree or
//! a fragment, a tree back to markup. Scripts are not run here; they are
//! elements, which the host runs after parsing, in order.
const std = @import("std");
const Allocator = std.mem.Allocator;
const dom = @import("../dom.zig");
const tree = @import("tree.zig");
const tags = @import("tags.zig");
const encoding = @import("encoding.zig");
const serializer = @import("serialize.zig");

pub const tokenizer = @import("tokenizer.zig");
pub const entities = @import("entities.zig");

pub const Options = struct {
    /// Whether scripts will run: `<noscript>`'s contents are then raw text.
    scripting: bool = true,
};

/// Parses `source` into `doc`, which should be empty. Sets `doc.quirks`.
/// Strings are kept in `doc.arena`.
pub fn parseDocument(doc: *dom.Document, source: []const u8) Allocator.Error!void {
    return parseDocumentWith(doc, source, .{});
}

pub fn parseDocumentWith(doc: *dom.Document, source: []const u8, options: Options) Allocator.Error!void {
    var b = try tree.Builder.init(doc, source, doc.node);
    b.scripting = options.scripting;
    try b.run();
    doc.touchStyle();
}

/// Parses `source` as the contents of `context` (`innerHTML`): the result is
/// a fragment node holding them.
pub fn parseFragment(doc: *dom.Document, context: *dom.Node, source: []const u8) Allocator.Error!*dom.Node {
    return parseFragmentWith(doc, context, source, .{});
}

pub fn parseFragmentWith(doc: *dom.Document, context: *dom.Node, source: []const u8, options: Options) Allocator.Error!*dom.Node {
    const fragment = try doc.createFragment();
    var b = try tree.Builder.init(doc, source, fragment);
    b.scripting = options.scripting;

    // The context as the algorithm sees it: `body` for a non-element.
    var ctx_id = tags.idOf(context);
    if (context.kind != .element) ctx_id = .body;
    b.context = .{ .node = context, .id = ctx_id };
    b.tok.state = switch (ctx_id) {
        .title, .textarea => .rcdata,
        .style, .xmp, .iframe, .noembed, .noframes => .rawtext,
        .script => .script_data,
        .noscript => if (b.scripting) .rawtext else .data,
        .plaintext => .plaintext,
        else => .data,
    };
    b.tok.last_start = context.tag;

    // A stand-in root the children are later taken from.
    const root = try doc.createElement("html");
    try b.push(root);
    if (ctx_id == .template) try b.template_modes.append(b.arena, .in_template);
    b.resetMode();
    var form: ?*dom.Node = context;
    while (form) |f| : (form = f.parent) {
        if (f.isTag("form")) {
            b.form_ptr = f;
            break;
        }
    }
    try b.run();
    while (root.first_child) |k| fragment.appendChild(k);
    return fragment;
}

pub const serialize = serializer.serialize;
pub const toUtf8 = encoding.toUtf8;

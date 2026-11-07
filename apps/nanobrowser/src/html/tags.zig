//! The tag names the tree builder dispatches on, and the category tests the
//! WHATWG tree construction algorithm asks of them.
const std = @import("std");
const dom = @import("../dom.zig");

/// A known HTML element, or a foreign element the parser must recognise
/// (`f_*`), or `other` for any other HTML element, `f_other` for any other
/// foreign one. Comparing a `T` also compares the namespace.
pub const T = enum(u8) {
    other,
    a,
    address,
    applet,
    area,
    article,
    aside,
    b,
    base,
    basefont,
    bgsound,
    big,
    blockquote,
    body,
    br,
    button,
    caption,
    center,
    code,
    col,
    colgroup,
    dd,
    details,
    dialog,
    dir,
    div,
    dl,
    dt,
    em,
    embed,
    fieldset,
    figcaption,
    figure,
    font,
    footer,
    form,
    frame,
    frameset,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    head,
    header,
    hgroup,
    hr,
    html,
    i,
    iframe,
    image,
    img,
    input,
    keygen,
    li,
    link,
    listing,
    main,
    marquee,
    math,
    menu,
    meta,
    nav,
    nobr,
    noembed,
    noframes,
    noscript,
    object,
    ol,
    optgroup,
    option,
    p,
    param,
    plaintext,
    pre,
    rb,
    rp,
    rt,
    rtc,
    ruby,
    s,
    script,
    search,
    section,
    select,
    small,
    source,
    strike,
    strong,
    style,
    sub,
    summary,
    sup,
    svg,
    table,
    tbody,
    td,
    template,
    textarea,
    tfoot,
    th,
    thead,
    title,
    tr,
    track,
    tt,
    u,
    ul,
    wbr,
    xmp,
    f_other,
    f_mi,
    f_mo,
    f_mn,
    f_ms,
    f_mtext,
    f_annotation_xml,
    f_foreign_object,
    f_desc,
    f_title,
};

const by_name = blk: {
    const names = @typeInfo(T).@"enum".field_names;
    var pairs: [names.len]struct { []const u8, T } = undefined;
    var n: usize = 0;
    for (names) |name| {
        if (name.len >= 2 and name[0] == 'f' and name[1] == '_') continue;
        if (std.mem.eql(u8, name, "other")) continue;
        pairs[n] = .{ name, @field(T, name) };
        n += 1;
    }
    const final = pairs[0..n].*;
    break :blk std.StaticStringMap(T).initComptime(final);
};

/// The id of an HTML tag name (lowercase).
pub fn htmlId(name: []const u8) T {
    return by_name.get(name) orelse .other;
}

/// The id of an element by its node: namespace and name.
pub fn idOf(n: *const dom.Node) T {
    return switch (n.ns) {
        .html => htmlId(n.tag),
        .svg => if (std.mem.eql(u8, n.tag, "foreignObject"))
            .f_foreign_object
        else if (std.mem.eql(u8, n.tag, "desc"))
            .f_desc
        else if (std.mem.eql(u8, n.tag, "title")) .f_title else .f_other,
        .mathml => if (std.mem.eql(u8, n.tag, "mi"))
            .f_mi
        else if (std.mem.eql(u8, n.tag, "mo"))
            .f_mo
        else if (std.mem.eql(u8, n.tag, "mn"))
            .f_mn
        else if (std.mem.eql(u8, n.tag, "ms"))
            .f_ms
        else if (std.mem.eql(u8, n.tag, "mtext"))
            .f_mtext
        else if (std.mem.eql(u8, n.tag, "annotation-xml")) .f_annotation_xml else .f_other,
    };
}

/// The "special" category.
pub fn isSpecial(t: T) bool {
    return switch (t) {
        .address, .applet, .area, .article, .aside, .base, .basefont, .bgsound, .blockquote, .body, .br, .button, .caption, .center, .col, .colgroup, .dd, .details, .dir, .div, .dl, .dt, .embed, .fieldset, .figcaption, .figure, .footer, .form, .frame, .frameset, .h1, .h2, .h3, .h4, .h5, .h6, .head, .header, .hgroup, .hr, .html, .iframe, .img, .input, .keygen, .li, .link, .listing, .main, .marquee, .menu, .meta, .nav, .noembed, .noframes, .noscript, .object, .ol, .p, .param, .plaintext, .pre, .script, .search, .section, .select, .source, .style, .summary, .table, .tbody, .td, .template, .textarea, .tfoot, .th, .thead, .title, .tr, .track, .ul, .wbr, .xmp, .f_mi, .f_mo, .f_mn, .f_ms, .f_mtext, .f_annotation_xml, .f_foreign_object, .f_desc, .f_title => true,
        else => false,
    };
}

/// The formatting elements.
pub fn isFormatting(t: T) bool {
    return switch (t) {
        .a, .b, .big, .code, .em, .font, .i, .nobr, .s, .small, .strike, .strong, .tt, .u => true,
        else => false,
    };
}

pub fn isHeading(t: T) bool {
    return switch (t) {
        .h1, .h2, .h3, .h4, .h5, .h6 => true,
        else => false,
    };
}

pub fn isMathText(t: T) bool {
    return switch (t) {
        .f_mi, .f_mo, .f_mn, .f_ms, .f_mtext => true,
        else => false,
    };
}

/// What ends the default "has an element in scope" walk.
pub fn endsScope(t: T) bool {
    return switch (t) {
        .applet, .caption, .html, .table, .td, .th, .marquee, .object, .template, .f_mi, .f_mo, .f_mn, .f_ms, .f_mtext, .f_annotation_xml, .f_foreign_object, .f_desc, .f_title => true,
        else => false,
    };
}

/// Tags closed by "generate implied end tags".
pub fn isImpliedEnd(t: T) bool {
    return switch (t) {
        .dd, .dt, .li, .optgroup, .option, .p, .rb, .rp, .rt, .rtc => true,
        else => false,
    };
}

/// "Generate all implied end tags thoroughly".
pub fn isThoroughEnd(t: T) bool {
    return isImpliedEnd(t) or switch (t) {
        .caption, .colgroup, .tbody, .td, .tfoot, .th, .thead, .tr => true,
        else => false,
    };
}

pub fn isTableSection(t: T) bool {
    return t == .tbody or t == .thead or t == .tfoot;
}

/// Start tags that make foreign content give up back to HTML.
pub fn breaksForeign(t: T) bool {
    return switch (t) {
        .b, .big, .blockquote, .body, .br, .center, .code, .dd, .div, .dl, .dt, .em, .embed, .h1, .h2, .h3, .h4, .h5, .h6, .head, .hr, .i, .img, .li, .listing, .menu, .meta, .nobr, .ol, .p, .pre, .ruby, .s, .small, .strike, .strong, .sub, .sup, .table, .tt, .u, .ul => true,
        else => false,
    };
}

/// The other two foreign breakouts have no `T`.
pub fn breaksForeignName(name: []const u8) bool {
    return std.mem.eql(u8, name, "span") or std.mem.eql(u8, name, "var");
}

/// Void elements: no contents, no end tag when serialized.
pub fn isVoid(name: []const u8) bool {
    const set = std.StaticStringMap(void).initComptime(.{
        .{"area"},  .{"base"},  .{"basefont"}, .{"bgsound"}, .{"br"},    .{"col"},
        .{"embed"}, .{"frame"}, .{"hr"},       .{"img"},     .{"input"}, .{"keygen"},
        .{"link"},  .{"meta"},  .{"param"},    .{"source"},  .{"track"}, .{"wbr"},
    });
    return set.has(name);
}

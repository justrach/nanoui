//! Garbage through the whole engine: every property with hostile values, and
//! random pages under random sheets. Nothing may crash, hang or leak.
const std = @import("std");
const dom = @import("../dom.zig");
const html = @import("../html/html.zig");
const css = @import("css.zig");
const prop = @import("prop.zig");

const gpa = std.testing.allocator;

fn exercise(page: []const u8, sheet_text: []const u8) !void {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    const doc = try dom.Document.create(a);
    try html.parseDocument(doc, page);
    var e = css.Engine.init(gpa, doc);
    defer e.deinit();
    const s = try css.parseSheet(a, sheet_text, "https://x.test/");
    e.setSheets(&.{s});
    try e.restyleAll();
    var at: ?*dom.Node = doc.node;
    while (at) |n| : (at = n.nextInTree(doc.node)) {
        if (n.kind != .element) continue;
        _ = try e.restyleSubtree(n);
        _ = e.invalidatedByState(n, .hover);
        _ = e.computedValue(n, "color");
        _ = e.computedValue(n, "width");
        _ = e.computedValue(n, "--x");
        break;
    }
    e.setViewport(.{ .width = 0, .height = 0, .dark = true });
    try e.restyleAll();
    // Every property's computed value can be read back.
    const names = @typeInfo(prop.Prop).@"enum".field_names;
    if (doc.documentElement()) |root| inline for (names) |name| {
        var buf: [name.len]u8 = name[0..name.len].*;
        for (&buf) |*c| {
            if (c.* == '_') c.* = '-';
        }
        _ = e.computedValue(root, &buf);
    };
}

const values = [_][]const u8{
    "0",                   "1",                                "-1",                                  "1e30",                                    "-1e30",                 "1e-30",                              "inf",                       "NaN",                                          "1px",                                     "-1px",                "1e30px",                 "1e30em",         "50%",                      "1e30%",             "auto",                                "none",                              "inherit",                                                               "initial",         "unset",             "revert",
    "calc(",               "calc()",                           "calc(1)",                             "calc(1px)",                               "calc(1e30px * 1e30)",   "calc(1e30 * 1e30 * 0)",              "calc(1px / 0)",             "calc(1 / 0)",                                  "calc(0 / 0)",                             "min()",               "max(,)",                 "clamp(1)",       "clamp(1px,2px)",           "round(1px, 0px)",   "round(up, 1e30, 1e-30)",              "abs(-1px)",                         "var(--x)",                                                              "var(--x, 1px)",   "var(--x,",          "var()",
    "var(1)",              "env(x)",                           "env(x, 1px)",                         "env(x 1, 2)",                             "url(a)",                "url(",                               "url()",                     "\"s\"",                                        "'",                                       "#",                   "#f",                     "#ff",            "#ffff",                    "#fffffffff",        "#ggg",                                "red",                               "transparent",                                                           "currentcolor",    "rgb()",             "rgb(1)",
    "rgb(1,2)",            "rgb(1,2,3,4,5)",                   "rgb(1e30,1e30,1e30)",                 "rgb(calc(1e30 * 2) 0 0)",                 "hsl(1e30,1e30%,1e30%)", "hsl(1deg 2% 3% / 1e30)",             "hwb(1e30 1e30% 1e30%)",     "oklch(1e30 1e30 1e30)",                        "oklab(1e30 1e30 1e30)",                   "lab(1e30 1e30 1e30)", "lch(-1e30 -1e30 -1e30)", "color(srgb)",    "color(x 1 2 3)",           "color-mix()",       "color-mix(in srgb, red 0%, blue 0%)", "color-mix(in srgb, red -5%, blue)", "light-dark()",                                                          "light-dark(red)", "linear-gradient()", "linear-gradient(red)",
    "linear-gradient(to)", "linear-gradient(to nowhere, red)", "linear-gradient(1e30deg, red, blue)", "linear-gradient(red 1e30%, blue -1e30%)", "radial-gradient()",     "radial-gradient(circle, red, blue)", "conic-gradient(red, blue)", "repeating-linear-gradient(red 1px, blue 2px)", "-webkit-linear-gradient(top, red, blue)", "image-set()",         "image-set('a' 1x)",      "repeat(0, 1px)", "repeat(-1, 1px)",          "repeat(1e30, 1px)", "repeat(auto-fill)",                   "repeat(auto-fit, )",                "repeat(2, repeat(2, repeat(2, repeat(2, repeat(2, repeat(2, 1px))))))", "minmax()",        "minmax(1px)",       "minmax(1fr, 1fr)",
    "fit-content()",       "1fr",                              "-1fr",                                "1e30fr",                                  "span",                  "span 0",                             "span -1",                   "span 1e30",                                    "1 / 2 / 3 / 4 / 5 / 6",                   "/",                   "//",                     "translate()",    "translate(1e30px, 1e30%)", "scale()",           "scale(1e30)",                         "rotate(1deg)",                      "matrix()",                                                              "attr()",          "attr(x)",           "counter()",
    "counter(x) \"y\"",    "open-quote",                       "!",                                   "! important",                             ";",                     "{",                                  "}",                         "{}",                                           "(",                                       ")",                   "[",                      "]",              ",",                        ",,,",               "@media",                              "\\",                                "\\0",                                                                   "\xFF",            "\x00",
};

test "every property with hostile values" {
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    var sheet: std.ArrayList(u8) = .empty;
    const names = @typeInfo(prop.Prop).@"enum".field_names;
    inline for (names) |name| {
        if (comptime std.mem.eql(u8, name, "custom")) continue;
        var buf: [name.len]u8 = name[0..name.len].*;
        for (&buf) |*c| {
            if (c.* == '_') c.* = '-';
        }
        for (values) |v| {
            try sheet.appendSlice(a, "div{--x:1px;");
            try sheet.appendSlice(a, &buf);
            try sheet.append(a, ':');
            try sheet.appendSlice(a, v);
            try sheet.appendSlice(a, "}\n");
        }
    }
    try exercise("<!doctype html><body><div id=a data-x=y><span>t</span></div>", sheet.items);
    // And one at a time: a bad value must not hide behind a later good one.
    for (values) |v| {
        const one = try std.fmt.allocPrint(a, "div{{--x:{s};width:{s};color:{s};background:{s};font:{s};flex:{s};grid-template-columns:{s};transform:{s};box-shadow:{s};margin:{s};border:{s};z-index:{s};order:{s};font-weight:{s};aspect-ratio:{s};grid-row:{s};opacity:{s};line-height:{s};content:{s};tab-size:{s}}} div::before{{content:{s};width:{s}}}", .{ v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v, v });
        try exercise("<!doctype html><body><div id=a data-x=y><span>t</span></div>", one);
    }
}

test "random pages under random sheets" {
    var rng = std.Random.DefaultPrng.init(0x5eed);
    const r = rng.random();
    var ar = std.heap.ArenaAllocator.init(gpa);
    defer ar.deinit();
    const a = ar.allocator();
    const tags = [_][]const u8{ "div", "p", "span", "a href=x", "table", "tr", "td", "ul", "li", "b", "input", "select", "option", "button", "svg", "math", "template", "h1", "img width=9 height=3", "center", "font color=red", "body bgcolor=#123", "style", "pre", "code", "section", "br", "hr" };
    const selectors = [_][]const u8{ "*", "div", ".a", "#a", "[a]", "[a=b i]", ":hover", ":focus", ":active", ":first-child", ":nth-child(2n+1)", ":not(p)", ":is(a, b)", ":where(p)", ":has(a)", ":has(> a)", "::before", "::after", "a::before", "p > a", "p + a", "p ~ a", "p a", ":root", ":empty", ":checked", ":disabled", ":lang(en)", "&", "& a", ":nth-last-of-type(1)", ":only-child", ":focus-within", ":link" };
    const props = [_][]const u8{ "display:flex", "display:none", "display:contents", "display:table", "float:left", "position:absolute", "color:red", "color:var(--x)", "--x:var(--y)", "--y:var(--x, 1px)", "--x:1px", "width:var(--x)", "font-size:2em", "font-size:0", "line-height:1.5", "line-height:0", "margin:auto", "border:1px solid", "content:'x'", "content:attr(a)", "all:unset", "all:revert", "all:inherit", "color:inherit !important", "font-family:monospace", "text-align:-webkit-center", "color-scheme:dark", "background:linear-gradient(red,blue)", "display:revert", "display:unset" };
    for (0..300) |_| {
        var page: std.ArrayList(u8) = .empty;
        var sheet: std.ArrayList(u8) = .empty;
        try page.appendSlice(a, "<!doctype html>");
        for (0..r.uintLessThan(usize, 60)) |_| {
            const t = tags[r.uintLessThan(usize, tags.len)];
            const close = r.boolean();
            const attrs = [_][]const u8{ "", " class=a", " id=a", " a=b", " style='color:red;--x:2px'", " hidden", " lang=en", " disabled" };
            const w = try std.fmt.allocPrint(a, "{s}<{s}{s}>{s}", .{ if (close) "</p>" else "", t, attrs[r.uintLessThan(usize, attrs.len)], if (r.boolean()) "x" else "" });
            try page.appendSlice(a, w);
        }
        for (0..r.uintLessThan(usize, 25)) |_| {
            const w = try std.fmt.allocPrint(a, "{s} {s} {{ {s}; {s}; @media (min-width: {d}px) {{ {s} }} }}\n", .{
                selectors[r.uintLessThan(usize, selectors.len)],
                selectors[r.uintLessThan(usize, selectors.len)],
                props[r.uintLessThan(usize, props.len)],
                props[r.uintLessThan(usize, props.len)],
                r.uintLessThan(u32, 2000),
                props[r.uintLessThan(usize, props.len)],
            });
            try sheet.appendSlice(a, w);
        }
        try exercise(page.items, sheet.items);
    }
}

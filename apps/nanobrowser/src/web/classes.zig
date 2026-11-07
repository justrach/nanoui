//! The DOM's class hierarchy: one table of interfaces and their parents, which
//! elements get which class, and the constructors that scripts may call. The
//! members are installed by the `api_*` files and the prelude.
const std = @import("std");
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const bind = @import("bind.zig");
const custom = @import("custom.zig");
const World = bind.World;
const Value = js.Value;
const Vm = js.Vm;

const Class = struct { name: [:0]const u8, parent: ?[:0]const u8, ctor: Ctor = .illegal };
const Ctor = enum { illegal, event_target, text, comment, fragment, document, html };

/// Parents come before their children.
const table = [_]Class{
    .{ .name = "EventTarget", .parent = null, .ctor = .event_target },
    .{ .name = "Window", .parent = "EventTarget" },
    .{ .name = "Node", .parent = "EventTarget" },
    .{ .name = "Document", .parent = "Node", .ctor = .document },
    .{ .name = "HTMLDocument", .parent = "Document" },
    .{ .name = "XMLDocument", .parent = "Document" },
    .{ .name = "DocumentFragment", .parent = "Node", .ctor = .fragment },
    .{ .name = "ShadowRoot", .parent = "DocumentFragment" },
    .{ .name = "DocumentType", .parent = "Node" },
    .{ .name = "CharacterData", .parent = "Node" },
    .{ .name = "Text", .parent = "CharacterData", .ctor = .text },
    .{ .name = "CDATASection", .parent = "Text" },
    .{ .name = "Comment", .parent = "CharacterData", .ctor = .comment },
    .{ .name = "ProcessingInstruction", .parent = "CharacterData" },
    .{ .name = "Element", .parent = "Node" },
    .{ .name = "HTMLElement", .parent = "Element", .ctor = .html },
    .{ .name = "SVGElement", .parent = "Element" },
    .{ .name = "SVGGraphicsElement", .parent = "SVGElement" },
    .{ .name = "SVGSVGElement", .parent = "SVGGraphicsElement" },
    .{ .name = "SVGGeometryElement", .parent = "SVGGraphicsElement" },
    .{ .name = "SVGPathElement", .parent = "SVGGeometryElement" },
    .{ .name = "SVGRectElement", .parent = "SVGGeometryElement" },
    .{ .name = "SVGCircleElement", .parent = "SVGGeometryElement" },
    .{ .name = "SVGGElement", .parent = "SVGGraphicsElement" },
    .{ .name = "SVGUseElement", .parent = "SVGGraphicsElement" },
    .{ .name = "SVGTextElement", .parent = "SVGGraphicsElement" },
    .{ .name = "MathMLElement", .parent = "Element" },
} ++ htmlClass("HTMLAnchorElement") ++ htmlClass("HTMLAreaElement") ++ htmlClass("HTMLBRElement") ++ htmlClass("HTMLBaseElement") ++ htmlClass("HTMLBodyElement") ++ htmlClass("HTMLButtonElement") ++ htmlClass("HTMLCanvasElement") ++ htmlClass("HTMLDListElement") ++ htmlClass("HTMLDataElement") ++ htmlClass("HTMLDataListElement") ++ htmlClass("HTMLDetailsElement") ++ htmlClass("HTMLDialogElement") ++ htmlClass("HTMLDirectoryElement") ++ htmlClass("HTMLDivElement") ++ htmlClass("HTMLEmbedElement") ++ htmlClass("HTMLFieldSetElement") ++ htmlClass("HTMLFontElement") ++ htmlClass("HTMLFormElement") ++ htmlClass("HTMLFrameElement") ++ htmlClass("HTMLFrameSetElement") ++ htmlClass("HTMLHRElement") ++ htmlClass("HTMLHeadElement") ++ htmlClass("HTMLHeadingElement") ++ htmlClass("HTMLHtmlElement") ++ htmlClass("HTMLIFrameElement") ++ htmlClass("HTMLImageElement") ++ htmlClass("HTMLInputElement") ++ htmlClass("HTMLLIElement") ++ htmlClass("HTMLLabelElement") ++ htmlClass("HTMLLegendElement") ++ htmlClass("HTMLLinkElement") ++ htmlClass("HTMLMapElement") ++ htmlClass("HTMLMediaElement") ++ htmlClass("HTMLMenuElement") ++ htmlClass("HTMLMetaElement") ++ htmlClass("HTMLMeterElement") ++ htmlClass("HTMLModElement") ++ htmlClass("HTMLOListElement") ++ htmlClass("HTMLObjectElement") ++ htmlClass("HTMLOptGroupElement") ++ htmlClass("HTMLOptionElement") ++ htmlClass("HTMLOutputElement") ++ htmlClass("HTMLParagraphElement") ++ htmlClass("HTMLParamElement") ++ htmlClass("HTMLPictureElement") ++ htmlClass("HTMLPreElement") ++ htmlClass("HTMLProgressElement") ++ htmlClass("HTMLQuoteElement") ++ htmlClass("HTMLScriptElement") ++ htmlClass("HTMLSelectElement") ++ htmlClass("HTMLSlotElement") ++ htmlClass("HTMLSourceElement") ++ htmlClass("HTMLSpanElement") ++ htmlClass("HTMLStyleElement") ++ htmlClass("HTMLTableCaptionElement") ++ htmlClass("HTMLTableCellElement") ++ htmlClass("HTMLTableColElement") ++ htmlClass("HTMLTableElement") ++ htmlClass("HTMLTableRowElement") ++ htmlClass("HTMLTableSectionElement") ++ htmlClass("HTMLTemplateElement") ++ htmlClass("HTMLTextAreaElement") ++ htmlClass("HTMLTimeElement") ++ htmlClass("HTMLTitleElement") ++ htmlClass("HTMLTrackElement") ++ htmlClass("HTMLUListElement") ++ htmlClass("HTMLUnknownElement") ++ [_]Class{
    .{ .name = "HTMLVideoElement", .parent = "HTMLMediaElement", .ctor = .html },
    .{ .name = "HTMLAudioElement", .parent = "HTMLMediaElement", .ctor = .html },
};

fn htmlClass(comptime name: [:0]const u8) [1]Class {
    return .{.{ .name = name, .parent = "HTMLElement", .ctor = .html }};
}

fn indexOf(comptime name: []const u8) usize {
    @setEvalBranchQuota(100000);
    for (table, 0..) |c, i| if (std.mem.eql(u8, c.name, name)) return i;
    @compileError("no class " ++ name);
}

const tag_classes = std.StaticStringMap(u16).initComptime(.{
    .{ "a", indexOf("HTMLAnchorElement") },
    .{ "area", indexOf("HTMLAreaElement") },
    .{ "audio", indexOf("HTMLAudioElement") },
    .{ "br", indexOf("HTMLBRElement") },
    .{ "base", indexOf("HTMLBaseElement") },
    .{ "body", indexOf("HTMLBodyElement") },
    .{ "button", indexOf("HTMLButtonElement") },
    .{ "canvas", indexOf("HTMLCanvasElement") },
    .{ "dl", indexOf("HTMLDListElement") },
    .{ "data", indexOf("HTMLDataElement") },
    .{ "datalist", indexOf("HTMLDataListElement") },
    .{ "details", indexOf("HTMLDetailsElement") },
    .{ "dialog", indexOf("HTMLDialogElement") },
    .{ "dir", indexOf("HTMLDirectoryElement") },
    .{ "div", indexOf("HTMLDivElement") },
    .{ "embed", indexOf("HTMLEmbedElement") },
    .{ "fieldset", indexOf("HTMLFieldSetElement") },
    .{ "font", indexOf("HTMLFontElement") },
    .{ "form", indexOf("HTMLFormElement") },
    .{ "frame", indexOf("HTMLFrameElement") },
    .{ "frameset", indexOf("HTMLFrameSetElement") },
    .{ "hr", indexOf("HTMLHRElement") },
    .{ "head", indexOf("HTMLHeadElement") },
    .{ "h1", indexOf("HTMLHeadingElement") },
    .{ "h2", indexOf("HTMLHeadingElement") },
    .{ "h3", indexOf("HTMLHeadingElement") },
    .{ "h4", indexOf("HTMLHeadingElement") },
    .{ "h5", indexOf("HTMLHeadingElement") },
    .{ "h6", indexOf("HTMLHeadingElement") },
    .{ "html", indexOf("HTMLHtmlElement") },
    .{ "iframe", indexOf("HTMLIFrameElement") },
    .{ "img", indexOf("HTMLImageElement") },
    .{ "input", indexOf("HTMLInputElement") },
    .{ "li", indexOf("HTMLLIElement") },
    .{ "label", indexOf("HTMLLabelElement") },
    .{ "legend", indexOf("HTMLLegendElement") },
    .{ "link", indexOf("HTMLLinkElement") },
    .{ "map", indexOf("HTMLMapElement") },
    .{ "menu", indexOf("HTMLMenuElement") },
    .{ "meta", indexOf("HTMLMetaElement") },
    .{ "meter", indexOf("HTMLMeterElement") },
    .{ "del", indexOf("HTMLModElement") },
    .{ "ins", indexOf("HTMLModElement") },
    .{ "ol", indexOf("HTMLOListElement") },
    .{ "object", indexOf("HTMLObjectElement") },
    .{ "optgroup", indexOf("HTMLOptGroupElement") },
    .{ "option", indexOf("HTMLOptionElement") },
    .{ "output", indexOf("HTMLOutputElement") },
    .{ "p", indexOf("HTMLParagraphElement") },
    .{ "param", indexOf("HTMLParamElement") },
    .{ "picture", indexOf("HTMLPictureElement") },
    .{ "pre", indexOf("HTMLPreElement") },
    .{ "progress", indexOf("HTMLProgressElement") },
    .{ "q", indexOf("HTMLQuoteElement") },
    .{ "blockquote", indexOf("HTMLQuoteElement") },
    .{ "script", indexOf("HTMLScriptElement") },
    .{ "select", indexOf("HTMLSelectElement") },
    .{ "slot", indexOf("HTMLSlotElement") },
    .{ "source", indexOf("HTMLSourceElement") },
    .{ "span", indexOf("HTMLSpanElement") },
    .{ "style", indexOf("HTMLStyleElement") },
    .{ "caption", indexOf("HTMLTableCaptionElement") },
    .{ "td", indexOf("HTMLTableCellElement") },
    .{ "th", indexOf("HTMLTableCellElement") },
    .{ "col", indexOf("HTMLTableColElement") },
    .{ "colgroup", indexOf("HTMLTableColElement") },
    .{ "table", indexOf("HTMLTableElement") },
    .{ "tr", indexOf("HTMLTableRowElement") },
    .{ "thead", indexOf("HTMLTableSectionElement") },
    .{ "tbody", indexOf("HTMLTableSectionElement") },
    .{ "tfoot", indexOf("HTMLTableSectionElement") },
    .{ "template", indexOf("HTMLTemplateElement") },
    .{ "textarea", indexOf("HTMLTextAreaElement") },
    .{ "time", indexOf("HTMLTimeElement") },
    .{ "title", indexOf("HTMLTitleElement") },
    .{ "track", indexOf("HTMLTrackElement") },
    .{ "ul", indexOf("HTMLUListElement") },
    .{ "video", indexOf("HTMLVideoElement") },
});

const svg_classes = std.StaticStringMap(u16).initComptime(.{
    .{ "svg", indexOf("SVGSVGElement") },
    .{ "path", indexOf("SVGPathElement") },
    .{ "rect", indexOf("SVGRectElement") },
    .{ "circle", indexOf("SVGCircleElement") },
    .{ "g", indexOf("SVGGElement") },
    .{ "use", indexOf("SVGUseElement") },
    .{ "text", indexOf("SVGTextElement") },
});

/// Tags that are simply HTMLElement: known and with no class of their own.
const plain_tags = std.StaticStringMap(void).initComptime(.{
    .{"abbr"},    .{"address"}, .{"article"}, .{"aside"},  .{"b"},       .{"bdi"},  .{"bdo"},    .{"cite"},  .{"code"},  .{"dd"},   .{"dfn"},     .{"dt"},
    .{"em"},      .{"figcaption"}, .{"figure"}, .{"footer"}, .{"header"}, .{"hgroup"}, .{"i"}, .{"kbd"}, .{"main"}, .{"mark"}, .{"nav"}, .{"noscript"},
    .{"rp"},      .{"rt"},      .{"ruby"},    .{"s"},      .{"samp"},    .{"search"}, .{"section"}, .{"small"}, .{"strong"}, .{"sub"}, .{"summary"}, .{"sup"},
    .{"u"},       .{"var"},     .{"wbr"},     .{"center"}, .{"tt"},      .{"big"},  .{"strike"}, .{"nobr"},
});

pub const Protos = struct {
    all: [table.len]*js.Object = undefined,
    ctors: [table.len]*js.Object = undefined,
    html: *js.Object = undefined,
    element: *js.Object = undefined,
    svg: *js.Object = undefined,
    mathml: *js.Object = undefined,
    unknown: *js.Object = undefined,
    text: *js.Object = undefined,
    comment: *js.Object = undefined,
    fragment: *js.Object = undefined,
    shadow: *js.Object = undefined,
    document: *js.Object = undefined,
    html_document: *js.Object = undefined,
    doctype: *js.Object = undefined,
};

pub fn proto(w: *const World, comptime name: []const u8) *js.Object {
    return w.protos.all[comptime indexOf(name)];
}

pub fn protoFor(w: *const World, n: *const dom.Node) *js.Object {
    const p = &w.protos;
    return switch (n.kind) {
        .document => p.html_document,
        .fragment => p.fragment,
        .text => p.text,
        .comment => p.comment,
        .doctype => p.doctype,
        .element => elementProto(w, n),
    };
}

fn elementProto(w: *const World, n: *const dom.Node) *js.Object {
    const p = &w.protos;
    if (bind.isShadow(n)) return p.shadow;
    switch (n.ns) {
        .svg => return if (svg_classes.get(n.tag)) |i| p.all[i] else p.svg,
        .mathml => return p.mathml,
        .html => {},
    }
    if (tag_classes.get(n.tag)) |i| return p.all[i];
    if (plain_tags.has(n.tag) or std.mem.indexOfScalar(u8, n.tag, '-') != null) return p.html;
    return p.unknown;
}

pub fn mark(w: *World, m: *js.Marker) void {
    for (w.protos.all) |o| m.markObj(o);
    for (w.protos.ctors) |o| m.markObj(o);
}

/// Makes the classes and puts them on the global object.
pub fn install(w: *World) js.Error!void {
    const vm = w.vm;
    const global = vm.global();
    for (table, 0..) |c, i| {
        const parent: ?*js.Object = if (c.parent) |name| blk: {
            for (table[0..i], 0..) |x, j| if (std.mem.eql(u8, x.name, name)) break :blk w.protos.all[j];
            unreachable;
        } else null;
        const pair = try vm.newClass(c.name, 0, switch (c.ctor) {
            .illegal => illegalCtor,
            .event_target => eventTargetCtor,
            .text => textCtor,
            .comment => commentCtor,
            .fragment => fragmentCtor,
            .document => documentCtor,
            .html => custom.htmlElementCtor,
        }, parent);
        w.protos.all[i] = pair.proto;
        w.protos.ctors[i] = pair.ctor;
        try global.defineData(vm, c.name, pair.ctor.value(), js.PropFlags.hidden);
    }
    const p = &w.protos;
    p.html = proto(w, "HTMLElement");
    p.element = proto(w, "Element");
    p.svg = proto(w, "SVGElement");
    p.mathml = proto(w, "MathMLElement");
    p.unknown = proto(w, "HTMLUnknownElement");
    p.text = proto(w, "Text");
    p.comment = proto(w, "Comment");
    p.fragment = proto(w, "DocumentFragment");
    p.shadow = proto(w, "ShadowRoot");
    p.document = proto(w, "Document");
    p.html_document = proto(w, "HTMLDocument");
    p.doctype = proto(w, "DocumentType");
}

fn illegalCtor(vm: *Vm, _: Value, _: []const Value) js.Error!Value {
    return vm.throwError(.TypeError, "Illegal constructor");
}

fn eventTargetCtor(_: *Vm, _: Value, _: []const Value) js.Error!Value {
    return Value.undefined;
}

fn textCtor(vm: *Vm, this: Value, args: []const Value) js.Error!Value {
    const w = bind.world(vm);
    const data = if (args.len > 0) try vm.toStringSlice(args[0]) else "";
    return bind.adopt(w, this.asObject(), try w.page.doc.createText(data));
}

fn commentCtor(vm: *Vm, this: Value, args: []const Value) js.Error!Value {
    const w = bind.world(vm);
    const data = if (args.len > 0) try vm.toStringSlice(args[0]) else "";
    return bind.adopt(w, this.asObject(), try w.page.doc.createComment(data));
}

fn fragmentCtor(vm: *Vm, this: Value, _: []const Value) js.Error!Value {
    const w = bind.world(vm);
    return bind.adopt(w, this.asObject(), try w.page.doc.createFragment());
}

fn documentCtor(vm: *Vm, this: Value, _: []const Value) js.Error!Value {
    const w = bind.world(vm);
    const d = try dom.Document.create(w.page.arena());
    d.url = w.page.doc.url;
    return bind.adopt(w, this.asObject(), d.node);
}

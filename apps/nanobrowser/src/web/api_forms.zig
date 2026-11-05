//! Form controls and pictures: their properties share `Node.value`, `checked`
//! and `selected` with `paint/controls.zig`. `focus`, `blur` and `click` live
//! here too; what a click does is `page_input.zig`'s.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const js = @import("../js/js.zig");
const dom = @import("../dom.zig");
const bind = @import("bind.zig");
const mutate = @import("mutate.zig");
const classes = @import("classes.zig");
const page_input = @import("../page_input.zig");
const loader = @import("../loader.zig");
const web = @import("web.zig");
const replay = @import("../paint/replay.zig");
const Node = dom.Node;
const Value = js.Value;
const Vm = js.Vm;
const Error = js.Error;
const World = bind.World;
const nodeOf = bind.thisNode;

pub fn editorSet(e: *anyopaque, text: []const u8) void {
    const buf: *ui.TextBuffer = @ptrCast(@alignCast(e));
    buf.set(text);
}

fn typeIs(n: *const Node, kind: []const u8) bool {
    return std.ascii.eqlIgnoreCase(n.attr("type") orelse "text", kind);
}

fn inputValue(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (typeIs(n, "checkbox") or typeIs(n, "radio")) return vm.newString(n.attr("value") orelse "on");
    return vm.newString(n.value orelse n.attr("value") orelse "");
}

fn setInputValue(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    const s = try bind.strNullEmpty(vm, args, 0);
    if (typeIs(n, "checkbox") or typeIs(n, "radio")) {
        try mutate.setAttr(w, n, "value", s);
        return Value.undefined;
    }
    n.value = try bind.dupe(w, s);
    n.doc.touchLayout();
    w.changed();
    return Value.undefined;
}

fn defaultValue(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString((try nodeOf(vm, this)).attr("value") orelse "");
}

fn setDefaultValue(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try mutate.setAttr(bind.world(vm), try nodeOf(vm, this), "value", try bind.strNullEmpty(vm, args, 0));
    return Value.undefined;
}

fn textareaValue(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (n.value) |v| return vm.newString(v);
    return vm.newString(try n.textContent(bind.world(vm).page.arena()));
}

fn setTextareaValue(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    n.value = try bind.dupe(w, try bind.strNullEmpty(vm, args, 0));
    n.doc.touchLayout();
    w.changed();
    return Value.undefined;
}

fn textareaDefault(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString(try (try nodeOf(vm, this)).textContent(bind.world(vm).page.arena()));
}

fn setTextareaDefault(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try (try nodeOf(vm, this)).setTextContent(try bind.strNullEmpty(vm, args, 0));
    bind.world(vm).changed();
    return Value.undefined;
}

fn checked(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromBool(page_input.isChecked(try nodeOf(vm, this)));
}

fn setChecked(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const on = vm.toBoolean(bind.arg(args, 0));
    if (on and typeIs(n, "radio")) {
        if (page_input.formOf(n)) |f| page_input.uncheckGroup(f, n) else page_input.uncheckGroup(n.doc.node, n);
    }
    n.checked = on;
    // `:checked` and what follows it.
    n.doc.touchStyle();
    bind.world(vm).changed();
    return Value.undefined;
}

fn defaultChecked(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return Value.fromBool((try nodeOf(vm, this)).hasAttr("checked"));
}

fn setDefaultChecked(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    if (vm.toBoolean(bind.arg(args, 0))) try mutate.setAttr(w, n, "checked", "") else try mutate.removeAttr(w, n, "checked");
    return Value.undefined;
}

fn selectOf(option: *Node) ?*Node {
    var at = option.parent;
    while (at) |p| : (at = p.parent) if (p.isTag("select")) return p;
    return null;
}

fn optionSelected(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (selectOf(n)) |s| if (!s.hasAttr("multiple")) return Value.fromBool(page_input.selectedOption(s) == n);
    return Value.fromBool(n.selected orelse n.hasAttr("selected"));
}

fn chooseOption(select: *Node, chosen: ?*Node) void {
    var at = select.first_child;
    while (at) |x| : (at = x.nextInTree(select)) {
        if (x.isTag("option")) x.selected = x == chosen;
    }
    select.doc.touchLayout();
}

fn setOptionSelected(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const on = vm.toBoolean(bind.arg(args, 0));
    if (on) {
        if (selectOf(n)) |s| if (!s.hasAttr("multiple")) chooseOption(s, n);
    }
    n.selected = on;
    n.doc.touchLayout();
    bind.world(vm).changed();
    return Value.undefined;
}

fn optionValue(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (n.attr("value")) |v| return vm.newString(v);
    return vm.newString(try n.textContent(bind.world(vm).page.arena()));
}

fn setOptionValue(vm: *Vm, this: Value, args: []const Value) Error!Value {
    try mutate.setAttr(bind.world(vm), try nodeOf(vm, this), "value", try bind.str(vm, args, 0));
    return Value.undefined;
}

fn valueOfOption(w: *World, o: *Node) Error![]const u8 {
    return o.attr("value") orelse try o.textContent(w.page.arena());
}

fn selectValue(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const o = page_input.selectedOption(n) orelse return vm.newString("");
    return vm.newString(try valueOfOption(bind.world(vm), o));
}

fn setSelectValue(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    const want = try bind.str(vm, args, 0);
    var at = n.first_child;
    var found: ?*Node = null;
    while (at) |x| : (at = x.nextInTree(n)) {
        if (x.isTag("option") and std.mem.eql(u8, try valueOfOption(w, x), want)) {
            found = x;
            break;
        }
    }
    chooseOption(n, found);
    w.changed();
    return Value.undefined;
}

fn selectedIndex(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const chosen = page_input.selectedOption(n) orelse return Value.fromInt(-1);
    var i: i32 = 0;
    var at = n.first_child;
    while (at) |x| : (at = x.nextInTree(n)) {
        if (!x.isTag("option")) continue;
        if (x == chosen) return Value.fromInt(i);
        i += 1;
    }
    return Value.fromInt(-1);
}

fn setSelectedIndex(vm: *Vm, this: Value, args: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const want = try vm.toNumber(bind.arg(args, 0));
    var i: f64 = 0;
    var found: ?*Node = null;
    var at = n.first_child;
    while (at) |x| : (at = x.nextInTree(n)) {
        if (!x.isTag("option")) continue;
        if (i == want) found = x;
        i += 1;
    }
    chooseOption(n, found);
    bind.world(vm).changed();
    return Value.undefined;
}

fn submit(vm: *Vm, this: Value, _: []const Value) Error!Value {
    page_input.sendForm(bind.world(vm).page, try nodeOf(vm, this), null);
    return Value.undefined;
}

fn requestSubmit(vm: *Vm, this: Value, args: []const Value) Error!Value {
    page_input.submit(bind.world(vm).page, try nodeOf(vm, this), bind.asNode(bind.arg(args, 0)));
    return Value.undefined;
}

fn reset(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const form = try nodeOf(vm, this);
    const w = bind.world(vm);
    if (w.hears("reset")) {
        const args = [_]Value{ this, try vm.newString("reset"), Value.true, Value.true };
        const ok = try vm.call(w.h.fire, Value.undefined, &args);
        if (!vm.toBoolean(ok)) return Value.undefined;
    }
    page_input.reset(w.page, form);
    w.changed();
    return Value.undefined;
}

// Pictures.

/// A picture's address changed, or it was made: ask for it whether or not it's
/// in the document.
pub fn imageAsked(w: *World, n: *dom.Node) Error!void {
    loader.askImage(w.page, n);
    w.changed();
}

fn imageComplete(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    return Value.fromBool(loader.imageComplete(bind.world(vm).page, n));
}

fn imageSize(w: *World, n: *Node) ?ui.Size {
    if (n.image.len == 0) return null;
    const p = w.page;
    if (replay.isSvg(n.image)) {
        const v = replay.svgSize(n.image) orelse return null;
        return .{ .w = v[0], .h = v[1] };
    }
    const c = p.host.uiContext(p.host.ctx) orelse return null;
    const s = ui.imageSize(c, n.image_key, n.image) orelse return null;
    const d = @max(n.image_density, 0.001);
    return .{ .w = s.w / d, .h = s.h / d };
}

fn naturalWidth(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const s = imageSize(bind.world(vm), try nodeOf(vm, this)) orelse return Value.fromInt(0);
    return bind.num(s.w);
}

fn naturalHeight(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const s = imageSize(bind.world(vm), try nodeOf(vm, this)) orelse return Value.fromInt(0);
    return bind.num(s.h);
}

fn currentSrc(vm: *Vm, this: Value, _: []const Value) Error!Value {
    return vm.newString((try nodeOf(vm, this)).image_key);
}

// Focus and click.

fn isFocusable(n: *const Node) bool {
    if (n.kind != .element or n.hasAttr("disabled")) return false;
    return n.isTag("a") or n.isTag("button") or n.isTag("input") or n.isTag("select") or n.isTag("textarea") or n.hasAttr("tabindex") or n.hasAttr("contenteditable");
}

fn focus(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (!isFocusable(n)) return Value.undefined;
    web.setFocus(bind.world(vm).page, n);
    return Value.undefined;
}

fn blur(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    const w = bind.world(vm);
    if (w.page.doc.focus == n) web.setFocus(w.page, null);
    return Value.undefined;
}

fn click(vm: *Vm, this: Value, _: []const Value) Error!Value {
    const n = try nodeOf(vm, this);
    if (n.hasAttr("disabled") and (n.isTag("button") or n.isTag("input") or n.isTag("select") or n.isTag("textarea"))) return Value.undefined;
    const w = bind.world(vm);
    const args = [_]Value{ this, try vm.newString("click") };
    const ok = try vm.call(w.h.fireClick, Value.undefined, &args);
    if (vm.toBoolean(ok) and !w.page.dead) page_input.activate(w.page, n, 0, 0, .{}, false);
    return Value.undefined;
}

pub fn install(w: *World) Error!void {
    const vm = w.vm;
    try bind.accessors(vm, classes.proto(w, "HTMLInputElement"), &.{
        .{ .name = "value", .get = inputValue, .set = setInputValue },
        .{ .name = "defaultValue", .get = defaultValue, .set = setDefaultValue },
        .{ .name = "checked", .get = checked, .set = setChecked },
        .{ .name = "defaultChecked", .get = defaultChecked, .set = setDefaultChecked },
    });
    try bind.accessors(vm, classes.proto(w, "HTMLTextAreaElement"), &.{
        .{ .name = "value", .get = textareaValue, .set = setTextareaValue },
        .{ .name = "defaultValue", .get = textareaDefault, .set = setTextareaDefault },
    });
    try bind.accessors(vm, classes.proto(w, "HTMLSelectElement"), &.{
        .{ .name = "value", .get = selectValue, .set = setSelectValue },
        .{ .name = "selectedIndex", .get = selectedIndex, .set = setSelectedIndex },
    });
    try bind.accessors(vm, classes.proto(w, "HTMLOptionElement"), &.{
        .{ .name = "value", .get = optionValue, .set = setOptionValue },
        .{ .name = "selected", .get = optionSelected, .set = setOptionSelected },
    });
    try bind.methods(vm, classes.proto(w, "HTMLFormElement"), &.{
        .{ .name = "submit", .arity = 0, .f = submit },
        .{ .name = "requestSubmit", .arity = 0, .f = requestSubmit },
        .{ .name = "reset", .arity = 0, .f = reset },
    });
    try bind.accessors(vm, classes.proto(w, "HTMLImageElement"), &.{
        .{ .name = "complete", .get = imageComplete },
        .{ .name = "naturalWidth", .get = naturalWidth },
        .{ .name = "naturalHeight", .get = naturalHeight },
        .{ .name = "currentSrc", .get = currentSrc },
    });
    for ([_]*js.Object{ w.protos.html, w.protos.svg }) |o| {
        try bind.methods(vm, o, &.{
            .{ .name = "focus", .arity = 0, .f = focus },
            .{ .name = "blur", .arity = 0, .f = blur },
        });
    }
    try w.protos.html.defineMethod(vm, "click", 0, click);
}

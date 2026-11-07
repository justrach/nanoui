//! Typing into a page's fields as a person does: click, keys, Return. What's typed
//! reaches the page's scripts and comes back drawn. A field keeps the keys however
//! what's before it changes (its `:focus` style adds a shadow to what is drawn).
const std = @import("std");
const util = @import("tests_util.zig");
const testing = std.testing;
const Run = util.Run;

/// A small app in the shape of TodoMVC: an uncontrolled field, its focus ring
/// from CSS, Return adds a row, each row's checkbox and button work.
const todo =
    \\data:text/html,<!doctype html><title>Todo</title>
    \\<style>input:focus{box-shadow:0 0 2px 2px red;outline:1px solid blue}li.done{text-decoration:line-through}</style>
    \\<input id=f placeholder="What next?"><ul id=l></ul><p id=n>0 left</p>
    \\<script>
    \\const f=document.getElementById('f'),l=document.getElementById('l'),n=document.getElementById('n');
    \\function count(){n.textContent=l.querySelectorAll('li:not(.done)').length+' left'}
    \\f.addEventListener('keydown',e=>{if(e.key!=='Enter')return;
    \\  const v=e.target.value.trim();if(!v)return;
    \\  const li=document.createElement('li');
    \\  const c=document.createElement('input');c.type='checkbox';
    \\  c.addEventListener('change',()=>{li.classList.toggle('done',c.checked);count()});
    \\  const s=document.createElement('span');s.textContent=v;
    \\  const d=document.createElement('button');d.textContent='drop '+v;
    \\  d.addEventListener('click',()=>{li.remove();count()});
    \\  li.append(c,s,d);l.append(li);e.target.value='';count()});
    \\</script>
;

fn field(r: *Run) !*@import("../dom.zig").Node {
    return r.page().doc.getElementById("f") orelse error.NoField;
}

test "typed text stays in the field and is drawn" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open(todo);
    try r.t.clickText("What next?");
    r.t.settle(0.1);
    r.t.typeText("Buy milk");
    r.t.frame();
    try testing.expect(r.t.hasText("Buy milk"));
    r.t.typeText(" now");
    r.t.frame();
    try testing.expect(r.t.hasText("Buy milk now"));
    try testing.expectEqualStrings("Buy milk now", (try field(&r)).value.?);
}

test "a field in a box that scrolls keeps the keys as that box's clip comes and goes" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open(
        \\data:text/html,<!doctype html><style>input:focus{box-shadow:0 0 2px red}</style>
        \\<div style="height:100px;overflow:auto"><input id=f placeholder="Inner"><div style="height:900px"></div></div>
    );
    try r.t.clickText("Inner");
    r.t.settle(0.1);
    r.t.typeText("kept");
    r.t.frame();
    try testing.expectEqualStrings("kept", (try field(&r)).value.?);
}

test "text at font-size 0 takes no room and isn't drawn, as sites hide a label" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open(
        \\data:text/html,<!doctype html><label style="font-size:0;display:inline-block">Hidden label</label><p>Shown</p>
    );
    try testing.expect(r.t.hasText("Shown"));
    try testing.expect(!r.t.containsText("Hidden"));
}

test "Return reaches the page's script, a controlled app updates as a person uses it" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    r.open(todo);
    try r.t.clickText("What next?");
    r.t.settle(0.1);
    r.t.typeText("Buy milk");
    r.t.frame();
    r.t.key(.enter);
    r.spin(0.02);
    try testing.expect(r.t.hasText("Buy milk"));
    try testing.expect(r.t.hasText("1 left"));
    try testing.expectEqualStrings("", (try field(&r)).value.?);
    // The field still has the keys, and its old text is gone from the screen.
    r.t.typeText("Second");
    r.t.frame();
    r.t.key(.enter);
    r.spin(0.02);
    try testing.expect(r.t.hasText("2 left"));
    try r.t.clickText("drop Buy milk");
    r.spin(0.02);
    try testing.expect(r.t.hasText("1 left"));
    try testing.expect(!r.t.hasText("Buy milk"));
}

test "a field keeps the keys when its focus changes what's drawn around it" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    // Wikipedia's search box: focused, it shows a menu and a ring; and what holds a
    // field here is drawn by a chain of boxes that this kind of style changes.
    r.open(
        \\data:text/html,<!doctype html><style>.w:focus-within{opacity:.9;transform:translateX(1px)}.w:focus-within+.m{display:block}.m{display:none;opacity:.5;transform:scale(1)}</style>
        \\<div class=w><input id=f placeholder="Type here"></div><div class=m>menu</div>
        \\<script>var log=[];f.addEventListener('focus',()=>log.push('focus'));f.addEventListener('blur',()=>log.push('blur'))</script>
    );
    try r.t.clickText("Type here");
    r.t.settle(0.1);
    r.t.typeText("pen");
    r.t.settle(0.1);
    r.t.typeText("guin");
    r.t.settle(0.1);
    try r.expectJs("f.value", "penguin");
    try r.expectJs("document.activeElement === f", "true");
    try r.expectJs("log.join()", "focus");
    try r.expectNoErrors();
}

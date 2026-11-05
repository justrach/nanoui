//! What Chromium has that the engine and the DOM didn't, added from a census of
//! every global's members: `prelude_es.js` and `prelude_gaps.js`.
const std = @import("std");
const util = @import("tests_util.zig");
const Run = util.Run;

test "the language's newer builtins" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><script>0</script>");
    try util.table(&r, &.{
        .{ .js = "[1,2,3,4].values().filter(x => x % 2).map(x => x * 10).toArray().join()", .want = "10,30" },
        .{ .js = "Iterator.from([5,6,7]).drop(1).take(1).toArray().join()", .want = "6" },
        .{ .js = "[1,2,3].values().reduce((a, b) => a + b)", .want = "6" },
        .{ .js = "[1,2].values() instanceof Iterator && (function*(){})() instanceof Iterator", .want = "true" },
        .{ .js = "var a = new Int32Array(1); Atomics.add(a, 0, 5) + ',' + Atomics.load(a, 0) + ',' + Atomics.compareExchange(a, 0, 5, 9) + ',' + a[0]", .want = "0,5,5,9" },
        .{ .js = "new Set([1,2,3]).union(new Set([4])).size + ',' + [...new Set([1,2]).intersection(new Set([2,3]))] + ',' + [...new Set([1,2]).difference(new Set([2]))] + ',' + new Set([1]).isSubsetOf(new Set([1,2]))", .want = "4,2,1,true" },
        .{ .js = "var m = new Map(); m.getOrInsert('a', 1) + m.getOrInsert('a', 2) + m.getOrInsertComputed('b', () => 3)", .want = "5" },
        .{ .js = "'x'.anchor('a\"b') + 'y'.sub()", .want = "<a name=\"a&quot;b\">x</a><sub>y</sub>" },
        .{ .js = "new Uint8Array([104,105]).toBase64() + new Uint8Array([255]).toHex() + new Uint8Array([251]).toBase64({alphabet:'base64url',omitPadding:true})", .want = "aGk=ff-w" },
        .{ .js = "Array.from(Uint8Array.fromBase64('aGk=')).join() + '|' + Array.from(Uint8Array.fromHex('ff00')).join()", .want = "104,105|255,0" },
        .{ .js = "new ArrayBuffer(4).transfer(8).byteLength + ',' + new ArrayBuffer(2).resizable", .want = "8,false" },
        .{ .js = "typeof Symbol.dispose + Error.isError(new TypeError('x')) + Error.isError({})", .want = "symboltruefalse" },
        .{ .js = "[...new Intl.Segmenter('en', {granularity: 'word'}).segment('Hi there')].filter(s => s.isWordLike).map(s => s.segment).join()", .want = "Hi,there" },
        .{ .js = "[...new Intl.Segmenter().segment('ae\\u0301')].length + new Intl.Locale('en-GB').region", .want = "2GB" },
    });
    _ = try r.eval("Promise.try(() => 7).then(v => window.tried = v); Array.fromAsync([1, Promise.resolve(2)]).then(v => window.fromed = v.join()); 0");
    try r.waitJs("window.tried === 7 && window.fromed === '1,2'");
    try r.expectNoErrors();
}

test "what sites call without asking first says what a browser with nothing granted says" {
    var r: Run = undefined;
    try r.start();
    defer r.stop();
    try r.html("<!doctype html><table id=t></table><p id=a>one</p><p id=b>two</p><iframe id=f scrolling=no frameborder=0></iframe>");
    try util.table(&r, &.{
        .{ .js = "typeof navigator.permissions.query + typeof navigator.geolocation.getCurrentPosition + typeof navigator.mediaSession.setActionHandler", .want = "functionfunctionfunction" },
        .{ .js = "new DOMException('x', 'NotFoundError').code + ',' + DOMException.ABORT_ERR", .want = "8,20" },
        .{ .js = "new CloseEvent('close', {code: 1000}).code + new ToggleEvent('toggle', {newState: 'open'}).newState", .want = "1000open" },
        .{ .js = "CSS.px(4).toString() + CSS.percent(50) + CSS.number(2)", .want = "4px50%2" },
        .{ .js = "t.createTHead() === t.createTHead() && t.firstElementChild.localName", .want = "thead" },
        .{ .js = "t.deleteTHead(); t.querySelector('thead')", .want = "null" },
        .{ .js = "f.scrolling + f.frameBorder", .want = "no0" },
        .{ .js = "var x = document.createRange(); x.selectNode(a); [x.isPointInRange(a, 0), x.intersectsNode(b), x.commonAncestorContainer === document.body, x.compareBoundaryPoints(Range.START_TO_START, x)].join()", .want = "true,false,true,0" },
    });
    _ = try r.eval("navigator.permissions.query({name: 'notifications'}).then(s => window.perm = s.state); navigator.geolocation.getCurrentPosition(() => {}, e => window.geo = e.code); 0");
    try r.waitJs("window.perm === 'prompt' && window.geo === 1");
    try r.expectNoErrors();
}

//! Things that must fail cleanly rather than crash: runaway recursion of every flavour,
//! huge inputs, and truncated or scrambled source text.

const std = @import("std");
const js = @import("js.zig");
const t = @import("tests_util.zig");

test "recursion through natives ends in RangeError" {
    try t.expectAll(&.{
        .{ .src = "function f(){return [1].map(f)} try{f()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "var o={get x(){return this.x}}; try{o.x}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "var o={toString(){return ''+this}}; try{''+o}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "function f(){return new f()} try{f()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "class A{constructor(){new A()}}; try{new A()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "class A{}; class B extends A{constructor(){super();new B()}}; try{new B()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "function f(){return f.apply(null,[])} try{f()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "function f(){return f.call()} try{f()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "var f=function(){return g()},g=f.bind(); try{f()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "var p=new Proxy({},{get(t,k,r){return r[k]}}); try{p.x}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "var p={}; for(var i=0;i<100000;i++) p=new Proxy(p,{}); try{p.x;'done'}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "function*g(){yield*g()} try{g().next()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "function f(){[3,1].sort(f)} try{f()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "function f(){JSON.stringify({toJSON:f})} try{f()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "function f(){'a'.replace(/a/,f)} try{f()}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "var a=[]; for(var i=0;i<200000;i++) a=[a]; try{a.flat(Infinity);'ok'}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "var a=[]; for(var i=0;i<200000;i++) a=[a]; try{String(a);'ok'}catch(e){e.name}", .want = "RangeError" },
        .{ .src = "var o={}; for(var i=0;i<200000;i++) o={o}; try{JSON.stringify(o);'ok'}catch(e){e.name}", .want = "RangeError" },
    });
}

test "deep and huge source" {
    const gpa = std.heap.smp_allocator;
    const vm = try js.Vm.create(gpa);
    defer vm.deinit();
    const n = 200000;
    for ([_][]const u8{ "[", "(", "{", "!", "-", "a?", "function(){", "a=", "x=>", "new ", "`${", "class A{m(){", "if(1)", "async()=>" }) |unit| {
        const src = try gpa.alloc(u8, unit.len * n);
        defer gpa.free(src);
        for (0..n) |i| @memcpy(src[i * unit.len ..][0..unit.len], unit);
        const r = vm.eval(src, "deep.js");
        try std.testing.expect(if (r) |_| false else |e| e == error.Thrown);
    }
    // A very long flat expression isn't deep at all.
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    try list.appendSlice(gpa, "var a=1;a");
    for (0..200000) |_| try list.appendSlice(gpa, "+a");
    try std.testing.expectEqual(@as(f64, 200001), (try vm.eval(list.items, "long.js")).asNumber());
    // Spreading large arrays and big literals work.
    try std.testing.expectEqual(@as(f64, 99999), (try vm.eval("Math.max(...Array.from({length:100000},(_, i)=>i))", "t.js")).asNumber());
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, "[");
    for (0..100000) |_| try list.appendSlice(gpa, "1,");
    try list.appendSlice(gpa, "].length");
    try std.testing.expectEqual(@as(f64, 100000), (try vm.eval(list.items, "lit.js")).asNumber());
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, "var o={");
    for (0..5000) |i| {
        var b: [32]u8 = undefined;
        try list.appendSlice(gpa, try std.fmt.bufPrint(&b, "k{d}:{d},", .{ i, i }));
    }
    try list.appendSlice(gpa, "};o.k4999");
    try std.testing.expectEqual(@as(f64, 4999), (try vm.eval(list.items, "obj.js")).asNumber());
    // Thousands of top-level functions, and a function with thousands of locals.
    list.clearRetainingCapacity();
    for (0..5000) |i| {
        var b: [48]u8 = undefined;
        try list.appendSlice(gpa, try std.fmt.bufPrint(&b, "function fn{d}(){{return {d}}}\n", .{ i, i }));
    }
    try list.appendSlice(gpa, "fn4999()");
    try std.testing.expectEqual(@as(f64, 4999), (try vm.eval(list.items, "fns.js")).asNumber());
    list.clearRetainingCapacity();
    try list.appendSlice(gpa, "(function(){");
    for (0..5000) |i| {
        var b: [48]u8 = undefined;
        try list.appendSlice(gpa, try std.fmt.bufPrint(&b, "var v{d}={d};", .{ i, i }));
    }
    try list.appendSlice(gpa, "return v4999+v0})()");
    try std.testing.expectEqual(@as(f64, 4999), (try vm.eval(list.items, "locals.js")).asNumber());
    // Too much in one string or array is a RangeError, not a crash.
    try std.testing.expectEqualStrings("RangeError", try vm.toStringSlice(try vm.eval("try{'x'.repeat(2**30)}catch(e){e.name}", "t.js")));
    try std.testing.expectEqualStrings("RangeError", try vm.toStringSlice(try vm.eval("try{new ArrayBuffer(2**40)}catch(e){e.name}", "t.js")));
    try std.testing.expectEqualStrings("RangeError", try vm.toStringSlice(try vm.eval("try{'x'.padEnd(2**31)}catch(e){e.name}", "t.js")));
}

const corpus =
    \\'use strict';var a=1,b=[1,2,,3],{c,d:[e=2]}={c:1,d:[]};let f=`x${a+`y${b}`}z`;const g=/a[b/]c/gi;
    \\function*h(x,y=1,...z){try{yield*[x];for(const q of z)yield q}catch(e){throw e}finally{return 1}}
    \\class I extends Object{static #p=1;#q;get r(){return this.#q}set r(v){this.#q=v}static{I.#p=2}async *s(){await 1}['t'+1]=2}
    \\l:for(var i=0;i<1;i++){switch(i){case 0:continue l;default:break l}}
    \\async function u(){for await(var v of[]);return await import('x')}
    \\var w=a?.b?.[c]?.(d)??e||f&&g;w**=2;w>>>=1;w||=1;w&&=2;w??=3;
    \\var o={a,b:1,'c':2,3:4,[a]:5,get d(){return 1},set d(v){},async e(){},*f(){},async*g(){},...b,__proto__:null};
    \\new.target;x=>x;(x,y)=>({x,y});async x=>x;async(x)=>x;(a,b=1,[c],{d},...e)=>{};
    \\typeof a;void 0;delete o.a;!a;~a;-a;+a;++a;a--;a instanceof b;a in b;tag`a${b}c`;
    \\if(a)b;else c;do{}while(0);while(0);with(a){};try{}catch{}
    \\<!-- html
    \\export default 1;import x from 'y';
;

test "scrambled source never crashes the parser or compiler" {
    const gpa = std.heap.smp_allocator;
    const vm = try js.Vm.create(gpa);
    defer vm.deinit();
    // Every prefix.
    var i: usize = 0;
    while (i < corpus.len) : (i += 1) {
        _ = vm.eval(corpus[0..i], "p.js") catch {};
        vm.exception = js.Value.undefined;
    }
    // Every suffix, in a function so `return` and friends have somewhere to be.
    i = 0;
    while (i < corpus.len) : (i += 3) {
        _ = vm.eval(corpus[i..], "s.js") catch {};
    }
    // Cut out spans and swap in odd characters.
    var rng = std.Random.DefaultPrng.init(0x5EED);
    const r = rng.random();
    const buf = try gpa.alloc(u8, corpus.len);
    defer gpa.free(buf);
    const odd = "(){}[]`'\"/\\*+-=<>?:;,.#@!~\n\xE2\x80\xA8\xFF0a";
    var n: usize = 0;
    while (n < 1500) : (n += 1) {
        @memcpy(buf, corpus);
        for (0..1 + r.uintLessThan(usize, 4)) |_| buf[r.uintLessThan(usize, buf.len)] = odd[r.uintLessThan(usize, odd.len)];
        const a = r.uintLessThan(usize, buf.len);
        const b = @min(a + r.uintLessThan(usize, 300), buf.len);
        _ = vm.eval(buf[a..b], "m.js") catch {};
        const fnsrc = std.fmt.allocPrint(gpa, "(function(){{{s}}})", .{buf[a..b]}) catch continue;
        defer gpa.free(fnsrc);
        vm.setDeadline(50 * std.time.ns_per_ms);
        _ = vm.eval(fnsrc, "n.js") catch {};
        vm.setDeadline(0);
        _ = vm.compileModule(buf[a..b], "mod") catch {};
    }
    vm.exception = js.Value.undefined;
    vm.collect();
}

test "scrambled regular expressions never crash the compiler or matcher" {
    const gpa = std.heap.smp_allocator;
    const vm = try js.Vm.create(gpa);
    defer vm.deinit();
    var rng = std.Random.DefaultPrng.init(0xBEEF);
    const r = rng.random();
    const pieces = [_][]const u8{ "(", ")", "(?:", "(?=", "(?!", "(?<=", "(?<!", "(?<n>", "\\k<n>", "\\1", "[", "]", "[^", "a", "b", ".", "*", "+", "?", "{2}", "{1,3}", "{2,}", "|", "^", "$", "\\b", "\\d", "\\w", "\\s", "\\p{L}", "\\u0041", "\\u{1F600}", "-", "\\" };
    const flags = [_][]const u8{ "", "g", "i", "m", "s", "u", "y", "d", "iu", "gs" };
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(gpa);
    var n: usize = 0;
    while (n < 3000) : (n += 1) {
        list.clearRetainingCapacity();
        for (0..1 + r.uintLessThan(usize, 12)) |_| try list.appendSlice(gpa, pieces[r.uintLessThan(usize, pieces.len)]);
        const g = vm.global();
        try g.set(vm, "pat", try vm.newString(list.items));
        try g.set(vm, "flg", try vm.newString(flags[r.uintLessThan(usize, flags.len)]));
        vm.setDeadline(50 * std.time.ns_per_ms);
        _ = vm.eval("try{var rx=new RegExp(pat,flg);rx.exec('aab\\u{1F600}ba 12 aB');'aabab'.replace(rx,'x');'ab'.split(rx)}catch(e){}", "r.js") catch {};
        vm.setDeadline(0);
    }
}

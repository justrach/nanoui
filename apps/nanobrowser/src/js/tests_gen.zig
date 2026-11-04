//! Generators, async functions, async generators and microtask ordering.

const t = @import("tests_util.zig");

test "generators" {
    try t.expectAll(&.{
        .{ .src = "function*g(){yield 1;yield 2} [...g()].join()", .want = "1,2" },
        .{ .src = "function*g(){var x=yield 1;yield x*2} var i=g(); i.next(); i.next(4).value", .want = "8" },
        .{ .src = "function*g(){return 1} var i=g(); var r=i.next(); r.value+''+r.done", .want = "1true" },
        .{ .src = "function*g(){yield 1} var i=g(); i.next(); i.next(); i.next().done", .want = "true" },
        .{ .src = "function*g(){try{yield 1}finally{f=1}} var f,i=g(); i.next(); i.return(5).value+f", .want = "6" },
        .{ .src = "function*g(){try{yield 1}catch(e){yield e+1}} var i=g(); i.next(); i.throw(1).value", .want = "2" },
        .{ .src = "function*g(){yield 1} var i=g(); try{i.throw(9)}catch(e){e+''+i.next().done}", .want = "9true" },
        .{ .src = "function*g(){yield 1} var i=g(); i.return(3).value+''+i.next().done", .want = "3true" },
        .{ .src = "function*g(){yield*[1,2];yield*h()} function*h(){yield 3;return 4} [...g()].join()", .want = "1,2,3" },
        .{ .src = "function*h(){return 4} function*g(){return yield*h()} g().next().value", .want = "4" },
        .{ .src = "function*h(){try{yield 1}finally{c=1}} function*g(){yield*h()} var c,i=g(); i.next(); i.return(); c", .want = "1" },
        .{ .src = "function*h(){try{yield 1}catch(e){yield e}} function*g(){yield*h()} var i=g(); i.next(); i.throw(7).value", .want = "7" },
        .{ .src = "function*h(){var x=yield 1;return x} function*g(){var r=yield*h();yield r} var i=g(); i.next(); i.next(8).value", .want = "8" },
        .{ .src = "function*g(a,b=a){yield a+b} g(1).next().value", .want = "2" },
        .{ .src = "function*g(){yield arguments.length} g(1,2).next().value", .want = "2" },
        .{ .src = "function*g(){yield this.v} g.call({v:3}).next().value", .want = "3" },
        .{ .src = "function*g(){var i=0;while(true)yield i++} var it=g(); it.next();it.next();it.next().value", .want = "2" },
        .{ .src = "function*g(){for(var x of [1,2])yield x} [...g()].join()", .want = "1,2" },
        .{ .src = "function*g(){yield (yield 1)+(yield 2)} var i=g(); i.next();i.next(10);i.next(20).value", .want = "30" },
        .{ .src = "function*g(){var a=[yield 1,yield 2];yield a} var i=g(); i.next();i.next(5);i.next(6).value.join()", .want = "5,6" },
        .{ .src = "function*g(){yield} g().next().value", .want = "undefined" },
        .{ .src = "function*g(){i.next();yield} var i=g(); try{i.next()}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "function*g(){} g()[Symbol.iterator]().next().done", .want = "true" },
        .{ .src = "function*g(){} Object.getPrototypeOf(g).constructor.name", .want = "GeneratorFunction" },
        .{ .src = "function*g(){} g.prototype.m=function(){return 1}; g().m()", .want = "1" },
        .{ .src = "function*g(){} try{new g}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "function*g(){} Object.prototype.toString.call(g())", .want = "[object Generator]" },
        .{ .src = "var o={*g(){yield 1}}; o.g().next().value", .want = "1" },
        .{ .src = "function*g(){try{yield 1;}finally{yield 2}} var i=g(); i.next(); var a=i.return(9); var b=i.next(); a.value+''+b.value+b.done", .want = "29true" },
        .{ .src = "function*g(){for(let i=0;i<2;i++){let j=i;yield ()=>j}} [...g()].map(f=>f()).join()", .want = "0,1" },
        .{ .src = "function*f(){yield 1;yield 2;yield 3} var [a,b]=f(); a+b", .want = "3" },
        .{ .src = "function*g(){const x=yield;return x} var i=g(); i.next(); i.next(5).value", .want = "5" },
        .{ .src = "function*g(){throw 1} try{g().next()}catch(e){e}", .want = "1" },
    });
}

test "async functions and ordering" {
    try t.expectAll(&.{
        .{ .src = "var r; (async()=>{r=await 1})(); r", .want = "undefined" },
        .{ .src = "globalThis.r=0; (async()=>{r=await 1})(); 0", .want = "0" },
        .{ .src = "var log=[]; (async function(){log.push('a'); await 0; log.push('c')})(); log.push('b'); log.join()", .want = "a,b" },
        .{ .src = "async function f(){return 1} f() instanceof Promise", .want = "true" },
    });
}

test "array patterns longer than the array" {
    try @import("tests_util.zig").expectAll(&.{
        .{ .src = "var [a, b, c, d] = [1]; [a, b, c, d].join()", .want = "1,,," },
        .{ .src = "var [a, b, ...r] = []; String(a) + r.length", .want = "undefined0" },
        .{ .src = "var [x = 5, y = 6, z = 7] = [1]; x + y + z", .want = "14" },
    });
}

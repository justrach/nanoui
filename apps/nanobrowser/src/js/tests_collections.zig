//! Map, Set, WeakMap, WeakSet, WeakRef, FinalizationRegistry, iterator protocol.

const t = @import("tests_util.zig");

test "Map and Set" {
    try t.expectAll(&.{
        .{ .src = "var m=new Map(); m.set('a',1).set('b',2); m.get('b')+m.size", .want = "4" },
        .{ .src = "new Map([[1,'x']]).get(1)", .want = "x" },
        .{ .src = "var m=new Map([[NaN,1]]); m.get(NaN)", .want = "1" },
        .{ .src = "var m=new Map(); m.set(-0,1); Object.is([...m.keys()][0],0)", .want = "true" },
        .{ .src = "var m=new Map(); m.set(0,1); m.get(-0)", .want = "1" },
        .{ .src = "var m=new Map(); m.set(1.5,1); m.get(1.5)", .want = "1" },
        .{ .src = "var m=new Map(); m.set(1,'i'); m.set(1.0,'d'); m.size", .want = "1" },
        .{ .src = "var m=new Map(),k={}; m.set(k,1); m.get(k)+''+m.get({})", .want = "1undefined" },
        .{ .src = "var m=new Map(); m.set('a'+'b',1); m.get('ab')", .want = "1" },
        .{ .src = "var m=new Map([[1,1]]); m.has(1)+''+m.delete(1)+m.has(1)+m.delete(1)", .want = "truetruefalsefalse" },
        .{ .src = "var m=new Map([[1,1]]); m.clear(); m.size", .want = "0" },
        .{ .src = "var r=[]; new Map([[1,2]]).forEach((v,k,mm)=>r.push(v,k,mm.size)); r.join()", .want = "2,1,1" },
        .{ .src = "[...new Map([[1,2]])][0].join()", .want = "1,2" },
        .{ .src = "[...new Map([[1,2]]).keys()].join()+[...new Map([[1,2]]).values()].join()", .want = "12" },
        .{ .src = "var m=new Map([[3,0],[1,0],[2,0]]); [...m.keys()].join()", .want = "3,1,2" },
        .{ .src = "var m=new Map([[1,0],[2,0]]); m.delete(1); m.set(1,0); [...m.keys()].join()", .want = "2,1" },
        .{ .src = "var m=new Map([[1,0]]); var it=m.keys(); m.set(2,0); it.next(); it.next().value", .want = "2" },
        .{ .src = "var m=new Map([[1,0],[2,0]]); var r=[]; for(var [k] of m){ r.push(k); if(k==1) m.delete(2) } r.join()", .want = "1" },
        .{ .src = "var m=new Map([[1,0]]); var c=0; for(var [k] of m){ if(c++<3) m.set(k+1,0) } c", .want = "4" },
        .{ .src = "var m=new Map([[1,0]]); var it=m.entries(); m.clear(); it.next().done", .want = "true" },
        .{ .src = "var m=new Map(); for(var i=0;i<5000;i++)m.set('k'+i,i); m.get('k4999')+m.size", .want = "9999" },
        .{ .src = "var m=new Map(); for(var i=0;i<1000;i++)m.set(i,i); for(var i=0;i<1000;i+=2)m.delete(i); m.size+m.get(1)+''+m.get(2)", .want = "501undefined" },
        .{ .src = "Map.groupBy([1,2,3],x=>x%2).get(1).length", .want = "2" },
        .{ .src = "try{Map()}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "try{Map.prototype.get.call({},1)}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "try{new Map([1])}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "Object.prototype.toString.call(new Map().keys())", .want = "[object Map Iterator]" },
        .{ .src = "Map.prototype[Symbol.iterator]===Map.prototype.entries", .want = "true" },
        .{ .src = "var s=new Set([1,1,2]); s.size+''+s.has(1)", .want = "2true" },
        .{ .src = "var s=new Set(); s.add(1).add(2); [...s].join()", .want = "1,2" },
        .{ .src = "var s=new Set('aab'); s.size", .want = "2" },
        .{ .src = "var s=new Set([1]); s.delete(1)+''+s.size", .want = "true0" },
        .{ .src = "[...new Set([1]).entries()][0].join()", .want = "1,1" },
        .{ .src = "Set.prototype.keys===Set.prototype.values", .want = "true" },
        .{ .src = "var r=[]; new Set([5]).forEach((a,b)=>r.push(a,b)); r.join()", .want = "5,5" },
        .{ .src = "var s=new Set([1]); s.clear(); s.has(1)", .want = "false" },
        .{ .src = "var s=new Set([NaN,NaN,0,-0]); s.size", .want = "2" },
    });
}

test "weak collections" {
    try t.expectAll(&.{
        .{ .src = "var w=new WeakMap(),k={}; w.set(k,1); w.get(k)+''+w.has(k)+w.delete(k)+w.has(k)", .want = "1truetruefalse" },
        .{ .src = "try{new WeakMap().set(1,1)}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "new WeakMap().get(1)", .want = "undefined" },
        .{ .src = "var k={}; new WeakMap([[k,5]]).get(k)", .want = "5" },
        .{ .src = "var w=new WeakSet(),k={}; w.add(k); w.has(k)+''+w.delete(k)+w.has(k)", .want = "truetruefalse" },
        .{ .src = "try{new WeakSet().add(1)}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "var k={}; new WeakRef(k).deref()===k", .want = "true" },
        .{ .src = "try{new WeakRef(1)}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "var r=new FinalizationRegistry(()=>{}); r.register({},1); r.unregister({})", .want = "false" },
        .{ .src = "try{new FinalizationRegistry(1)}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "var w=new WeakMap(),s=Symbol(); w.set(s,1); w.get(s)", .want = "1" },
    });
}

test "iterators" {
    try t.expectAll(&.{
        .{ .src = "var it={[Symbol.iterator](){var i=0;return {next(){return i<2?{value:i++,done:false}:{done:true}}}}}; [...it].join()", .want = "0,1" },
        .{ .src = "try{[...1]}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "try{for(var x of {});}catch(e){e.message}", .want = "object is not iterable" },
        .{ .src = "var it={[Symbol.iterator](){return {next(){return 1}}}}; try{[...it]}catch(e){e.name}", .want = "TypeError" },
        .{ .src = "var ip=Object.getPrototypeOf(Object.getPrototypeOf([].values())); ip[Symbol.iterator]()===ip", .want = "true" },
        .{ .src = "Array.prototype[Symbol.iterator]=function*(){yield 'patched'}; var [a]=[1]; a", .want = "patched" },
        .{ .src = "var n=Object.getPrototypeOf([].values()); var old=n.next; n.next=function(){var r=old.call(this);if(!r.done)r.value*=2;return r}; [...[1,2]].join()", .want = "2,4" },
        .{ .src = "var a=[1,2,3]; var r=[]; for(var x of a){r.push(x); if(x==1)a.push(4)} r.length", .want = "4" },
        .{ .src = "var a=[1,,3]; var r=[]; for(var x of a) r.push(x); r[1]", .want = "undefined" },
    });
}

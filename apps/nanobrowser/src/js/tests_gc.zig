//! Collector stress under the leak-checking allocator: live and dead objects of every
//! kind across many tasks, weak semantics, roots, no use-after-free, no leaks.

const std = @import("std");
const js = @import("js.zig");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Value = js.Value;

test "collect between tasks keeps the live, frees the dead" {
    const vm = try js.Vm.create(std.testing.allocator);
    defer vm.deinit();
    _ = try vm.eval(
        \\var keep=[]; var m=new Map(); var s=new Set(); var w=new WeakMap();
        \\class K{#p=1; f=()=>this.#p; get p(){return this.#p}}
        \\function make(i){
        \\  var o={i:i,s:'str'+i,a:[i,i+1],n:{deep:{v:i}},f:function(){return i},d:new Date(i),r:/x/g,k:new K()};
        \\  m.set('k'+(i%50),o); s.add(o.s); if(i%10==0) keep.push(o); w.set(o,{back:o});
        \\  return o;
        \\}
        \\function task(i){
        \\  for(var j=0;j<200;j++) make(i*1000+j);
        \\  var garbage=''; for(var j=0;j<100;j++) garbage+=j;
        \\  var g=(function*(){yield i; yield garbage.length})(); g.next();
        \\  keep.push(g);
        \\  Promise.resolve(i).then(v=>keep.push(v));
        \\  (async()=>{await 0; keep.push('a'+i)})();
        \\  if(keep.length>400) keep.splice(0,200);
        \\  new Proxy({},{}); new Uint8Array(16); JSON.parse(JSON.stringify({a:[1,2,{b:'x'}]})); 'abc'.replace(/b/,'y'); BigInt(2)**64n;
        \\}
    , "gc.js");
    const before_full = vm.bytesAllocated();
    var i: u32 = 0;
    var peak: usize = 0;
    while (i < 60) : (i += 1) {
        var buf: [32]u8 = undefined;
        const src = try std.fmt.bufPrint(&buf, "task({d})", .{i});
        _ = try vm.eval(src, "t.js");
        vm.runJobs();
        peak = @max(peak, vm.bytesAllocated());
        vm.collect();
    }
    const after = vm.bytesAllocated();
    try expect(after < peak);
    try expect(after > before_full);
    // Everything still reachable still works after all those collections.
    const r = try vm.eval(
        \\var o=m.get('k1'); var ok=[o.s.startsWith('str'),o.n.deep.v===o.i,o.f()===o.i,o.d.getTime()===o.i,o.r.test('x'),o.k.p===1,o.k.f()===1,w.get(o).back===o,s.has(o.s)];
        \\var last=keep[keep.length-1]; ok.every(x=>x)+':'+typeof last+':'+keep.filter(x=>x&&x.next).map(g=>g.next().value).every(n=>n>0);
    , "t.js");
    try expectEqualStrings("true:string:true", try vm.toStringSlice(r));
    // Compiled code, shapes and atoms created before a collection stay usable, including caches.
    _ = try vm.eval("function get(o){return o.alpha}; var a1={alpha:1}; get(a1); get(a1)", "t.js");
    vm.collect();
    try expectEqual(@as(f64, 1), (try vm.eval("get(a1)", "t.js")).asNumber());
    try expectEqual(@as(f64, 2), (try vm.eval("get({alpha:2})", "t.js")).asNumber());
    _ = try vm.eval("for(var i=0;i<2000;i++) ({['dyn'+i]:1})", "t.js");
    vm.collect();
    try expectEqual(@as(f64, 9), (try vm.eval("var dd={}; dd['dyn'+5]=9; dd.dyn5", "t.js")).asNumber());
    vm.collect();
}

test "weak references follow reachability" {
    const vm = try js.Vm.create(std.testing.allocator);
    defer vm.deinit();
    _ = try vm.eval("var live={n:1}; var wr=new WeakRef(live); var dead=new WeakRef({n:2}); var wm=new WeakMap(); wm.set(live,{v:1}); (function(){var t={}; wm.set(t,{v:2}); globalThis.tcount=1})()", "t.js");
    vm.collect();
    try expect((try vm.eval("wr.deref()===live", "t.js")).asBool());
    try expect((try vm.eval("dead.deref()===undefined", "t.js")).asBool());
    try expectEqual(@as(f64, 1), (try vm.eval("wm.get(live).v", "t.js")).asNumber());
    // An ephemeron chain: each value is the next key, reachable only through the first.
    _ = try vm.eval("var head={}; var chain=new WeakMap(); (function(){var a=head; for(var i=0;i<50;i++){var b={i:i}; chain.set(a,b); a=b}})()", "t.js");
    vm.collect();
    try expectEqual(@as(f64, 49), (try vm.eval("var c=head; for(var i=0;i<50;i++) c=chain.get(c); c.i", "t.js")).asNumber());
    _ = try vm.eval("head=null", "t.js");
    vm.collect();
    vm.collect();
    // FinalizationRegistry is allowed to never call back, and doesn't crash either way.
    _ = try vm.eval("new FinalizationRegistry(()=>{}).register({},1)", "t.js");
    vm.collect();
}

const Roots = struct {
    v: Value,
    fn mark(ctx: ?*anyopaque, m: *js.Marker) void {
        const r: *Roots = @ptrCast(@alignCast(ctx.?));
        m.mark(r.v);
    }
};

test "host roots and protect" {
    const vm = try js.Vm.create(std.testing.allocator);
    defer vm.deinit();
    var roots = Roots{ .v = try vm.eval("({r:'rooted'})", "t.js") };
    vm.setRootsHook(&roots, Roots.mark);
    const prot = try vm.eval("({p:'protected'})", "t.js");
    try vm.protect(prot);
    try vm.protect(prot);
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        _ = try vm.eval("for(var i=0;i<1000;i++) ({a:i,b:'s'+i})", "t.js");
        vm.collect();
    }
    try expectEqualStrings("rooted", try vm.toStringSlice(try roots.v.asObject().get(vm, "r")));
    try expectEqualStrings("protected", try vm.toStringSlice(try prot.asObject().get(vm, "p")));
    vm.unprotect(prot);
    vm.collect();
    try expectEqualStrings("protected", try vm.toStringSlice(try prot.asObject().get(vm, "p")));
    vm.unprotect(prot);
    vm.collect();
    vm.setRootsHook(null, null);
    vm.collect();
}

test "suspended work survives collection" {
    const vm = try js.Vm.create(std.testing.allocator);
    defer vm.deinit();
    _ = try vm.eval(
        \\var res; var out=[];
        \\(async function f(){var local={v:'kept'}; var a=await new Promise(r=>res=r); out.push(local.v+a); for await(var x of g()) out.push(x)})();
        \\async function*g(){var o={n:1}; yield o.n; await 0; yield o.n+1}
        \\function*gen(){var o={n:5}; var got=yield o; yield got.x+o.n}
        \\var it=gen(); it.next();
    , "t.js");
    vm.runJobs();
    vm.collect();
    vm.collect();
    _ = try vm.eval("res('!')", "t.js");
    vm.runJobs();
    vm.collect();
    try expectEqualStrings("kept!,1,2", try vm.toStringSlice(try vm.eval("out.join()", "t.js")));
    try expectEqual(@as(f64, 6), (try vm.eval("it.next({x:1}).value", "t.js")).asNumber());
}

test "modules across collections, and a clean teardown of everything live" {
    const vm = try js.Vm.create(std.testing.allocator);
    defer vm.deinit();
    const dep = try vm.compileModule("export let n=1; export function inc(){n++}; export default class D{v=1}", "dep");
    const Res = struct {
        var d: *js.Module = undefined;
        fn f(_: ?*anyopaque, _: *js.Vm, _: []const u8, _: *js.Module) ?*js.Module {
            return d;
        }
    };
    Res.d = dep;
    const m = try vm.compileModule("import D,{n,inc} from 'dep'; import * as ns from 'dep'; globalThis.check=()=>{inc(); return n+ns.n+new D().v}", "main");
    vm.collect();
    try vm.linkModule(m, null, Res.f);
    vm.collect();
    _ = try vm.evaluateModule(m);
    vm.runJobs();
    vm.collect();
    try expectEqual(@as(f64, 5), (try vm.eval("check()", "t.js")).asNumber());
    // Leave plenty alive for deinit: ropes, closures, pending promises, generators, proxies, buffers.
    _ = try vm.eval(
        \\var x='a'; for(var i=0;i<100;i++) x+=i; var pend=new Promise(()=>{}); pend.then(()=>{});
        \\var g=(function*(){yield 1})(); g.next(); var p=new Proxy({},{}); var b=new Uint8Array(100); var r=/a+/g;
        \\var bound=function(){}.bind(1,2); var big=2n**100n; var sym=Symbol('s'); var wm=new WeakMap([[{},1]]);
        \\var arr=new Array(100); var o=Object.freeze({a:1}); var d=new DataView(new ArrayBuffer(4));
        \\var ag=(async function*(){yield 1})(); ag.next(); var it=[1].values();
    , "t.js");
}

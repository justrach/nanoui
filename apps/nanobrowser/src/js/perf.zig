//! The engine's performance bar. Not part of tests.zig; run it optimized:
//! zig test apps/nanobrowser/src/js/perf.zig -OReleaseFast

const std = @import("std");
const js = @import("js.zig");
const conv = @import("conv.zig");

fn bench(vm: *js.Vm, name: []const u8, src: []const u8) !void {
    const t0 = conv.monotonicNs();
    const r = vm.eval(src, "perf.js") catch |e| {
        std.debug.print("{s}: threw {s}\n", .{ name, vm.exceptionString() });
        return e;
    };
    const t1 = conv.monotonicNs();
    const shown = try vm.toStringSlice(r);
    std.debug.print("{s}: {d:.1} ms (result {s})\n", .{ name, @as(f64, @floatFromInt(t1 - t0)) / 1e6, shown[0..@min(shown.len, 24)] });
    vm.collect();
}

/// About a megabyte of realistic minified code: many small functions and object literals.
fn makeBundle(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const chunk =
        \\function a{0d}(e,t,n){{var r=e.length,i=0,o=[];for(;i<r;i++){{var s=e[i];if(s&&s.type==="x"+t)o.push({{id:s.id,value:s.value*2,name:n||"anon"}});else if(typeof s=="string")o.push(s.replace(/[a-z]+/g,function(c){{return c.toUpperCase()}}));}}return o.length?o:null}}
        \\var b{0d}=class extends Object{{#p=1;static s=2;get v(){{return this.#p}}m(e=1,{{f,g}}={{}},...h){{return[e,f,g,...h].map(x=>x?.y??0)}}async n(){{return await Promise.all([1,2].map(async x=>x*2))}}}},c{0d}={{alpha:1,beta:"two",gamma:[1,2,3],delta:{{e:null,f:void 0}},h(e){{return e+1}},get i(){{return this.alpha}}}};
        \\
    ;
    var d: u32 = 0;
    while (out.items.len < 1024 * 1024) : (d += 1) {
        var buf: [1024]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, chunk, .{d});
        try out.appendSlice(gpa, s);
    }
    return out.toOwnedSlice(gpa);
}

test "performance" {
    const gpa = std.heap.smp_allocator;
    const vm = try js.Vm.create(gpa);
    defer vm.deinit();
    try bench(vm, "10M integer additions, local", "(function(){var s=0;for(var i=0;i<10000000;i++)s=(s+i)|0;return s})()");
    try bench(vm, "10M additions, let, double sum", "(function(){let s=0;for(let i=0;i<10000000;i++)s+=i;return s})()");
    try bench(vm, "10M additions, script globals", "var gs=0;for(var gi=0;gi<10000000;gi++)gs+=gi;gs");
    try bench(vm, "1M property reads", "(function(){var o={a:1,b:2,c:3},s=0;for(var i=0;i<1000000;i++)s+=o.b;return s})()");
    try bench(vm, "1M prototype method calls", "(function(){class A{m(){return 1}} class B extends A{} var o=new B(),s=0;for(var i=0;i<1000000;i++)s+=o.m();return s})()");
    try bench(vm, "1M closure calls", "(function(){var c=0,f=function(x){c+=x};for(var i=0;i<1000000;i++)f(1);return c})()");
    try bench(vm, "1M object allocations", "(function(){var k;for(var i=0;i<1000000;i++)k={a:i,b:i+1};return k.b})()");
    try bench(vm, "1M array pushes", "(function(){var a=[];for(var i=0;i<1000000;i++)a.push(i);return a.length})()");
    try bench(vm, "1M element reads", "(function(){var a=[1,2,3,4],s=0;for(var i=0;i<1000000;i++)s+=a[i&3];return s})()");
    try bench(vm, "1M string appends", "(function(){var s='';for(var i=0;i<1000000;i++)s+='x';return s.length})()");
    try bench(vm, "100k Map set/get", "(function(){var m=new Map();for(var i=0;i<100000;i++)m.set('k'+i,i);var s=0;for(var i=0;i<100000;i++)s+=m.get('k'+i);return s})()");
    try bench(vm, "fib(30) recursion", "function fib(n){return n<2?n:fib(n-1)+fib(n-2)};fib(30)");
    try bench(vm, "100k regex tests", "(function(){var r=/(\\w+)@(\\w+)\\.com/,c=0;for(var i=0;i<100000;i++)if(r.test('hello bob@site.com'))c++;return c})()");
    try bench(vm, "JSON round trip x1000", "(function(){var o={a:[1,2,3],b:{c:'hello',d:[true,null]},e:'x'.repeat(100)},n=0;for(var i=0;i<1000;i++)n+=JSON.parse(JSON.stringify(o)).a.length;return n})()");
    const src = try makeBundle(gpa);
    defer gpa.free(src);
    var wrapped: std.ArrayList(u8) = .empty;
    defer wrapped.deinit(gpa);
    try wrapped.appendSlice(gpa, "(function never(){");
    try wrapped.appendSlice(gpa, src);
    try wrapped.appendSlice(gpa, "});1");
    const t0 = conv.monotonicNs();
    _ = try vm.eval(wrapped.items, "bundle.js");
    const t1 = conv.monotonicNs();
    std.debug.print("parse+compile {d} KB bundle: {d:.1} ms\n", .{ src.len / 1024, @as(f64, @floatFromInt(t1 - t0)) / 1e6 });
}

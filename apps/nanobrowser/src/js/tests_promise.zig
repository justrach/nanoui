//! Promises, async functions, async generators, for-await, and spec-exact microtask order.

const t = @import("tests_util.zig");

test "promise basics" {
    try t.expectOut(&.{
        .{ .src = "var out; Promise.resolve(1).then(v=>out=v+1)", .want = "2" },
        .{ .src = "var out; Promise.reject(1).catch(v=>out=v+1)", .want = "2" },
        .{ .src = "var out; new Promise(r=>r(5)).then(v=>out=v)", .want = "5" },
        .{ .src = "var out; new Promise((_,r)=>r(5)).then(null,v=>out=v)", .want = "5" },
        .{ .src = "var out; new Promise(()=>{throw 3}).catch(v=>out=v)", .want = "3" },
        .{ .src = "var out; new Promise(r=>{r(1);r(2)}).then(v=>out=v)", .want = "1" },
        .{ .src = "var out; Promise.resolve(1).then(()=>{throw 2}).catch(v=>out=v)", .want = "2" },
        .{ .src = "var out; Promise.resolve(1).then().then(v=>out=v)", .want = "1" },
        .{ .src = "var out; Promise.reject(1).then().catch(v=>out=v)", .want = "1" },
        .{ .src = "var out; Promise.resolve(1).then(v=>Promise.resolve(v+1)).then(v=>out=v)", .want = "2" },
        .{ .src = "var out; Promise.resolve({then(r){r(9)}}).then(v=>out=v)", .want = "9" },
        .{ .src = "var out; Promise.resolve({then(){throw 8}}).catch(v=>out=v)", .want = "8" },
        .{ .src = "var out; var p=Promise.resolve(); p.then(()=>p).catch(e=>out='never'); out='ok'", .want = "ok" },
        .{ .src = "var out; var p; p=new Promise(r=>setTimeoutLike=r); p.then(()=>0); var q=p.then(()=>q); q.catch(e=>out=e.name); setTimeoutLike()", .want = "TypeError" },
        .{ .src = "var out=''; Promise.resolve(1).finally(()=>{out+='f';return 9}).then(v=>out+=v)", .want = "f1" },
        .{ .src = "var out=''; Promise.reject(1).finally(()=>{out+='f'}).catch(v=>out+=v)", .want = "f1" },
        .{ .src = "var out=''; Promise.resolve(1).finally(()=>{throw 2}).catch(v=>out+=v)", .want = "2" },
        .{ .src = "var out; Promise.all([1,Promise.resolve(2)]).then(v=>out=v.join())", .want = "1,2" },
        .{ .src = "var out; Promise.all([]).then(v=>out=v.length)", .want = "0" },
        .{ .src = "var out; Promise.all([1,Promise.reject(2)]).catch(v=>out=v)", .want = "2" },
        .{ .src = "var out; Promise.all(1).catch(e=>out=e.name)", .want = "TypeError" },
        .{ .src = "var out; Promise.allSettled([1,Promise.reject(2)]).then(v=>out=v[0].status+v[0].value+v[1].status+v[1].reason)", .want = "fulfilled1rejected2" },
        .{ .src = "var out; Promise.any([Promise.reject(1),2]).then(v=>out=v)", .want = "2" },
        .{ .src = "var out; Promise.any([Promise.reject(1)]).catch(e=>out=e.name+e.errors[0])", .want = "AggregateError1" },
        .{ .src = "var out; Promise.any([]).catch(e=>out=e.errors.length)", .want = "0" },
        .{ .src = "var out; Promise.race([new Promise(()=>{}),2]).then(v=>out=v)", .want = "2" },
        .{ .src = "var out='p'; Promise.race([]).then(()=>out='x')", .want = "p" },
        .{ .src = "var out; var w=Promise.withResolvers(); w.promise.then(v=>out=v); w.resolve(3)", .want = "3" },
        .{ .src = "var out; class P extends Promise{}; out=P.resolve(1).then(()=>{}) instanceof P", .want = "true" },
        .{ .src = "var out; class P extends Promise{static get [Symbol.species](){return Promise}}; out=P.resolve(1).then(()=>{}) instanceof P", .want = "false" },
        .{ .src = "var out; var p=Promise.resolve(); out=Promise.resolve(p)===p", .want = "true" },
        .{ .src = "var out; try{Promise()}catch(e){out=e.name}", .want = "TypeError" },
        .{ .src = "var out; try{new Promise(1)}catch(e){out=e.name}", .want = "TypeError" },
    });
}

test "async functions" {
    try t.expectOut(&.{
        .{ .src = "var out; async function f(){return 1}; f().then(v=>out=v)", .want = "1" },
        .{ .src = "var out; async function f(){throw 1}; f().catch(v=>out=v)", .want = "1" },
        .{ .src = "var out; async function f(){return await 2}; f().then(v=>out=v)", .want = "2" },
        .{ .src = "var out; async function f(){try{await Promise.reject(3)}catch(e){return e}}; f().then(v=>out=v)", .want = "3" },
        .{ .src = "var out; async function f(a=(()=>{throw 4})()){}; f().catch(v=>out=v)", .want = "4" },
        .{ .src = "var out; var g=async()=>this===globalThis; g().then(v=>out=v)", .want = "true" },
        .{ .src = "var out; var o={async m(){return this.v},v:5}; o.m().then(v=>out=v)", .want = "5" },
        .{ .src = "var out; class A{async m(){return await this.n()} async n(){return 6}}; new A().m().then(v=>out=v)", .want = "6" },
        .{ .src = "var out; class A{m(){return 7}}; class B extends A{async m(){await 0;return super.m()}}; new B().m().then(v=>out=v)", .want = "7" },
        .{ .src = "var out=0; async function f(){for(var i=0;i<3;i++)out+=await i}; f()", .want = "3" },
        .{ .src = "var out=''; async function f(){for(var x of [1,2]){out+=await x}}; f()", .want = "12" },
        .{ .src = "var out; async function f(){var [a,b]=await Promise.all([1,2]);return a+b}; f().then(v=>out=v)", .want = "3" },
        .{ .src = "var out; async function f(){try{return await 1}finally{out='fin'}}; f()", .want = "fin" },
        .{ .src = "var out; async function f(){return {then(r){r(8)}}}; f().then(v=>out=v)", .want = "8" },
        .{ .src = "var out; async function f(){await {then(r){out='thenable';r()}}}; f()", .want = "thenable" },
        .{ .src = "var out; async function f(){var c=0;const g=async()=>{c++};await g();await g();return c}; f().then(v=>out=v)", .want = "2" },
        .{ .src = "var out; async function r(n){return n?1+await r(n-1):0}; r(100).then(v=>out=v)", .want = "100" },
        .{ .src = "var out; async function f(){var a=[1,await 2,3];return a.join()}; f().then(v=>out=v)", .want = "1,2,3" },
        .{ .src = "var out; async function f(x){return x+await 1+await 2}; f(1).then(v=>out=v)", .want = "4" },
        .{ .src = "var out; var f=new (Object.getPrototypeOf(async function(){}).constructor)('return 1'); f().then(v=>out=v)", .want = "1" },
    });
}

test "microtask order is spec-correct" {
    try t.expectOut(&.{
        .{ .src = "var out=[]; Promise.resolve().then(()=>out.push(1)); out.push(0); Promise.resolve().then(()=>out.push(2))", .want = "0,1,2" },
        // A promise resolved with a native promise takes two extra ticks.
        .{ .src = "var out=[]; new Promise(r=>r(Promise.resolve())).then(()=>out.push('a')); Promise.resolve().then(()=>out.push(1)).then(()=>out.push(2)).then(()=>out.push(3))", .want = "1,2,a,3" },
        // await on a native promise takes one tick.
        .{ .src = "var out=[]; (async()=>{await Promise.resolve();out.push('a')})(); Promise.resolve().then(()=>out.push(1)).then(()=>out.push(2))", .want = "a,1,2" },
        .{ .src = "var out=[]; async function a1(){out.push('a1s');await a2();out.push('a1e')} async function a2(){out.push('a2')} out.push('s'); a1(); new Promise(r=>{out.push('p');r()}).then(()=>out.push('t1')).then(()=>out.push('t2')); out.push('e')", .want = "s,a1s,a2,p,e,a1e,t1,t2" },
        // Returning a promise from an async function takes three ticks.
        .{ .src = "var out=[]; (async()=>Promise.resolve())().then(()=>out.push('a')); Promise.resolve().then(()=>out.push(1)).then(()=>out.push(2)).then(()=>out.push(3)).then(()=>out.push(4))", .want = "1,2,a,3,4" },
        .{ .src = "var out=[]; (async()=>{out.push(0);await null;out.push(2);await null;out.push(4)})(); Promise.resolve().then(()=>out.push(1)).then(()=>out.push(3)).then(()=>out.push(5))", .want = "0,2,1,4,3,5" },
        .{ .src = "var out=[]; var th={then(r){out.push('th');r()}}; (async()=>{await th;out.push('a')})(); Promise.resolve().then(()=>out.push(1)).then(()=>out.push(2))", .want = "th,1,a,2" },
        .{ .src = "var out=[]; Promise.reject(1).catch(()=>out.push('c')).finally(()=>out.push('f')); Promise.resolve().then(()=>out.push(1)).then(()=>out.push(2))", .want = "c,1,f,2" },
    });
}

test "async generators and for-await" {
    try t.expectOut(&.{
        .{ .src = "var out=''; async function*g(){yield 1;yield 2} (async()=>{for await(var x of g())out+=x})()", .want = "12" },
        .{ .src = "var out=''; (async()=>{for await(var x of [1,Promise.resolve(2)])out+=x})()", .want = "12" },
        .{ .src = "var out; async function*g(){yield await 5} g().next().then(r=>out=r.value+''+r.done)", .want = "5false" },
        .{ .src = "var out; async function*g(){return 5} g().next().then(r=>out=r.value+''+r.done)", .want = "5true" },
        .{ .src = "var out; async function*g(){throw 5} g().next().catch(v=>out=v)", .want = "5" },
        .{ .src = "var out; async function*g(){var x=yield 1;yield x*2} var i=g(); i.next().then(()=>i.next(4)).then(r=>out=r.value)", .want = "8" },
        .{ .src = "var out; async function*g(){try{yield 1}finally{out='fin'}} var i=g(); i.next().then(()=>i.return(2))", .want = "fin" },
        .{ .src = "var out; async function*g(){yield 1} var i=g(); i.return(7).then(r=>out=r.value+''+r.done)", .want = "7true" },
        .{ .src = "var out; async function*g(){try{yield 1}catch(e){yield e+1}} var i=g(); i.next().then(()=>i.throw(1)).then(r=>out=r.value)", .want = "2" },
        .{ .src = "var out; async function*g(){yield 1} var i=g(); i.throw(3).catch(v=>out=v)", .want = "3" },
        .{ .src = "var out=''; async function*g(){yield 1;yield 2} var i=g(); Promise.all([i.next(),i.next(),i.next()]).then(rs=>out=rs.map(r=>r.value+''+r.done).join())", .want = "1false,2false,undefinedtrue" },
        .{ .src = "var out=''; async function*h(){yield 1;yield 2} async function*g(){yield*h();yield 3} (async()=>{for await(var x of g())out+=x})()", .want = "123" },
        .{ .src = "var out=''; async function*g(){yield*[1,2]} (async()=>{for await(var x of g())out+=x})()", .want = "12" },
        .{ .src = "var out=''; function*s(){yield 1} async function*g(){var r=yield*s();out+=r} (async()=>{for await(var x of g())out+=x})()", .want = "1undefined" },
        .{ .src = "var out; var it={[Symbol.asyncIterator](){return {next(){return Promise.resolve({done:true})},return(){out='r';return {}}}}}; (async()=>{for await(var x of it);})().then(()=>out=out||'noclose')", .want = "noclose" },
        .{ .src = "var out; var it={[Symbol.asyncIterator](){return {next(){return Promise.resolve({value:1,done:false})},return(){out='closed';return {}}}}}; (async()=>{for await(var x of it)break})()", .want = "closed" },
        .{ .src = "var out; var it={[Symbol.asyncIterator](){return {next(){return Promise.resolve({value:1,done:false})},return(){out='closed';return {}}}}}; (async()=>{try{for await(var x of it)throw 1}catch(e){}})()", .want = "closed" },
        .{ .src = "var out; async function*g(){} out=Object.prototype.toString.call(g())", .want = "[object AsyncGenerator]" },
        .{ .src = "var out; async function*g(){} var i=g(); out=i[Symbol.asyncIterator]()===i", .want = "true" },
        .{ .src = "var out; var o={async*g(){yield 1}}; o.g().next().then(r=>out=r.value)", .want = "1" },
        .{ .src = "var out; class A{async *g(){yield this.v}v=2}; new A().g().next().then(r=>out=r.value)", .want = "2" },
    });
}

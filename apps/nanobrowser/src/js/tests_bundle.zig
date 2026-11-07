//! Bundle-shaped stress: webpack-style module wrappers, a React-like reconciler, a jQuery-like
//! fluent wrapper, an event emitter, async pipelines, regex tokenizing and JSON together.

const std = @import("std");
const js = @import("js.zig");

const bundle =
    \\(function(modules){
    \\  var cache={};
    \\  function __webpack_require__(id){
    \\    if(cache[id]) return cache[id].exports;
    \\    var module=cache[id]={i:id,l:false,exports:{}};
    \\    modules[id].call(module.exports,module,module.exports,__webpack_require__);
    \\    module.l=true;
    \\    return module.exports;
    \\  }
    \\  __webpack_require__.d=function(e,n,g){if(!Object.prototype.hasOwnProperty.call(e,n))Object.defineProperty(e,n,{enumerable:true,get:g})};
    \\  __webpack_require__.r=function(e){"undefined"!=typeof Symbol&&Symbol.toStringTag&&Object.defineProperty(e,Symbol.toStringTag,{value:"Module"});Object.defineProperty(e,"__esModule",{value:!0})};
    \\  globalThis.req=__webpack_require__;
    \\  return __webpack_require__(0);
    \\})([
    \\function(module,exports,req){"use strict";
    \\  req.r(exports);
    \\  var R=req(1),Q=req(2),E=req(3),T=req(4);
    \\  function Counter(props){
    \\    var s=R.useState(props.start),c=s[0],set=s[1];
    \\    R.useEffect(function(){log.push("effect:"+c)},[c]);
    \\    return R.h("div",{id:"c",onClick:function(){set(c+1)}},R.h("span",null,"count ",c),props.children);
    \\  }
    \\  var List=function(props){return R.h("ul",null,props.items.map(function(x,i){return R.h("li",{key:i},x)}))};
    \\  var log=[];
    \\  var root=R.render(R.h(Counter,{start:1},R.h(List,{items:["a","b"]})));
    \\  var before=R.serialize(root.tree);
    \\  root.tree.props.onClick();root.flush();
    \\  var after=R.serialize(root.tree);
    \\  var q=Q([1,2,3,4]).filter(function(x){return x%2}).map(function(x){return x*10}).each(function(x){log.push(x)}).get().join();
    \\  var em=new E();var got=[];em.on("x",function(a,b){got.push(a+b)});em.once("x",function(a){got.push(-a)});em.emit("x",1,2);em.emit("x",3,4);
    \\  var toks=T.tokenize("let x1 = 42 + foo(\"bar\", 3.5); // done");
    \\  var cfg=JSON.parse(JSON.stringify({a:[1,{b:new Date(0)}],m:Array.from(new Map([["k",1]]))},null,2));
    \\  class Store{#state;#subs=new Set();static create(s){return new Store(s)}constructor(s){this.#state=Object.freeze({...s})}
    \\    get state(){return this.#state}subscribe(f){this.#subs.add(f);return()=>this.#subs.delete(f)}
    \\    async dispatch(action){var next=await this.reduce(this.#state,action);this.#state=Object.freeze(next);for(const f of this.#subs)f(next);return next}
    \\    async reduce(s,{type,by=1}){switch(type){case"inc":return{...s,n:s.n+by};case"reset":return{...s,n:0};default:return s}}}
    \\  var store=Store.create({n:1});var seen=[];var off=store.subscribe(function(s){seen.push(s.n)});
    \\  async function pipeline(){
    \\    await store.dispatch({type:"inc",by:2});await store.dispatch({type:"inc"});off();await store.dispatch({type:"reset"});
    \\    var rs=await Promise.all([1,2,3].map(async function(x,i){await null;return x*i}));
    \\    async function*tick(n){for(var i=0;i<n;i++){await 0;yield i}}
    \\    var sum=0;for await(const v of tick(4))sum+=v;
    \\    return{rs:rs,sum:sum,n:store.state.n};
    \\  }
    \\  globalThis.result={before:before,after:after,q:q,log:log,got:got,toks:toks,cfg:cfg};
    \\  pipeline().then(function(p){globalThis.result.p=p;globalThis.result.seen=seen});
    \\},
    \\function(module,exports){"use strict";
    \\  var hooks=[],idx=0,dirty=null,effects=[];
    \\  exports.h=function(type,props){var kids=[];for(var i=2;i<arguments.length;i++)kids.push(arguments[i]);return{type:type,props:Object.assign({},props,{children:kids.flat(Infinity).filter(function(k){return k!=null})})}};
    \\  exports.useState=function(init){var i=idx++;if(!(i in hooks))hooks[i]=init;return[hooks[i],function(v){hooks[i]=v;dirty&&dirty()}]};
    \\  exports.useEffect=function(f,deps){var i=idx++,old=hooks[i];if(!old||deps.some(function(d,j){return d!==old[j]})){effects.push(f);hooks[i]=deps}};
    \\  function expand(v){if(typeof v!=="object"||v===null)return v;if(typeof v.type==="function"){return expand(v.type(Object.assign({},v.props,{children:v.props.children})))}return{type:v.type,props:Object.assign({},v.props,{children:v.props.children.map(expand)})}}
    \\  exports.render=function(el){var r={tree:null,flush:function(){if(r.pending){r.pending=false;paint()}},pending:false};function paint(){idx=0;r.tree=expand(el);effects.splice(0).forEach(function(f){f()})}dirty=function(){r.pending=true};paint();return r};
    \\  exports.serialize=function ser(n){if(typeof n!=="object")return String(n);var a=Object.keys(n.props).filter(function(k){return k!=="children"&&typeof n.props[k]!=="function"}).map(function(k){return" "+k+'="'+n.props[k]+'"'}).join("");return"<"+n.type+a+">"+n.props.children.map(ser).join("")+"</"+n.type+">"};
    \\},
    \\function(module){
    \\  function Q(items){if(!(this instanceof Q))return new Q(items);this.items=items;this.length=items.length}
    \\  Q.prototype={constructor:Q,filter:function(f){return new Q(this.items.filter(f))},map:function(f){return new Q(this.items.map(f))},each:function(f){for(var i=0;i<this.length;i++)if(f.call(this.items[i],this.items[i],i)===false)break;return this},get:function(){return this.items.slice()}};
    \\  module.exports=Q;
    \\},
    \\function(module){
    \\  var E=function(){this._e=Object.create(null)};
    \\  E.prototype.on=function(n,f){(this._e[n]||(this._e[n]=[])).push(f);return this};
    \\  E.prototype.once=function(n,f){var s=this;function w(){s.off(n,w);f.apply(this,arguments)}return this.on(n,w)};
    \\  E.prototype.off=function(n,f){this._e[n]=(this._e[n]||[]).filter(function(g){return g!==f});return this};
    \\  E.prototype.emit=function(n){var a=[].slice.call(arguments,1);(this._e[n]||[]).slice().forEach(function(f){f.apply(this,a)},this);return this};
    \\  module.exports=E;
    \\},
    \\function(module,exports){
    \\  var re=/\s*(?:(\/\/.*)|(\d+(?:\.\d+)?)|([A-Za-z_]\w*)|("(?:[^"\\]|\\.)*")|(.))/gy;
    \\  exports.tokenize=function(src){var m,out=[];re.lastIndex=0;while(re.lastIndex<src.length&&(m=re.exec(src))){if(m[1])continue;out.push(m[2]?"N:"+m[2]:m[3]?"I:"+m[3]:m[4]?"S:"+m[4].slice(1,-1):"P:"+m[5])}return out};
    \\}
    \\]);
;

test "webpack-style bundle with a little of everything" {
    const vm = try js.Vm.create(std.heap.smp_allocator);
    defer vm.deinit();
    _ = vm.eval(bundle, "bundle.js") catch |e| {
        std.debug.print("\nbundle threw {s}: {s}\n", .{ @errorName(e), vm.exceptionString() });
        return e;
    };
    vm.runJobs();
    const r = vm.eval("JSON.stringify(result)", "t.js") catch |e| {
        std.debug.print("\nresult threw {s}: {s}\n", .{ @errorName(e), vm.exceptionString() });
        return e;
    };
    const want =
        \\{"before":"<div id=\"c\"><span>count 1</span><ul><li key=\"0\">a</li><li key=\"1\">b</li></ul></div>","after":"<div id=\"c\"><span>count 2</span><ul><li key=\"0\">a</li><li key=\"1\">b</li></ul></div>","q":"10,30","log":["effect:1","effect:2",10,30],"got":[3,-1,7],"toks":["I:let","I:x1","P:=","N:42","P:+","I:foo","P:(","S:bar","P:,","N:3.5","P:)","P:;"],"cfg":{"a":[1,{"b":"1970-01-01T00:00:00.000Z"}],"m":[["k",1]]},"p":{"rs":[0,2,6],"sum":6,"n":0},"seen":[3,4]}
    ;
    try std.testing.expectEqualStrings(want, try vm.toStringSlice(r));
}

test "the minifier's idioms" {
    const t = @import("tests_util.zig");
    try t.expectAll(&.{
        .{ .src = "!function(e){return e}(1)", .want = "false" },
        .{ .src = "var a=function(){return 1}(),b=void 0===a?2:a;b", .want = "1" },
        .{ .src = "for(var e=0,t=[1,2],n=t.length;e<n;e++)if(t[e]>1)break;e", .want = "1" },
        .{ .src = "var o={};(o.a=o.a||{}).b=1,o.a.b", .want = "1" },
        .{ .src = "var i=0,r=i++,s=++i;[i,r,s].join()", .want = "2,0,2" },
        .{ .src = "function f(e,t){return arguments.length>1&&void 0!==t?t:e}f(1,2)", .want = "2" },
        .{ .src = "var n=function(){function e(){}return e.prototype.m=function(){return 1},e}();(new n).m()", .want = "1" },
        .{ .src = "var r=(0,function(){return 2})();r", .want = "2" },
        .{ .src = "var t={get a(){return 1},set a(e){}},n=Object.getOwnPropertyDescriptor(t,'a');typeof n.set", .want = "function" },
        .{ .src = "\"use strict\";var e=1;e", .want = "1" },
        .{ .src = "var c=class{static x=1;y=2},d=new c;c.x+d.y", .want = "3" },
        .{ .src = "var g=async(e)=>e,h=async e=>e;typeof g+typeof h", .want = "functionfunction" },
        .{ .src = "var u=(e,t=1)=>({...e,t});u({a:1}).t", .want = "1" },
        .{ .src = "var s=`a${1}`+`b`,l=s.length;l", .want = "3" },
        .{ .src = "var x=1;x>0?x<2?'m':'h':'l'", .want = "m" },
        .{ .src = "var y=[1,2,3].map(e=>e*2).filter(Boolean).reduce((e,t)=>e+t,0);y", .want = "12" },
        .{ .src = "var p=/[a-z]/i.test('A')?1:0;p", .want = "1" },
        .{ .src = "var d2=a=>b=>a/b/2;d2(8)(2)", .want = "2" },
        .{ .src = "var k=1;k\n/2/1", .want = "0.5" },
        .{ .src = "function z(){return/x/.test('x')}z()", .want = "true" },
        .{ .src = "var w=[];w[w.length]=1,w[w.length]=2;w.length", .want = "2" },
        .{ .src = "typeof globalThis!='undefined'&&typeof window=='undefined'", .want = "true" },
        .{ .src = "var ex={};Object.defineProperty(ex,'__esModule',{value:!0}),ex.default=1;ex.__esModule&&ex.default", .want = "1" },
        .{ .src = "var hasOwn={}.hasOwnProperty,toS=Object.prototype.toString;hasOwn.call({a:1},'a')+toS.call([])", .want = "true[object Array]" },
        .{ .src = "var slice=[].slice;(function(){return slice.call(arguments,1)})(1,2).length", .want = "1" },
        .{ .src = "var isA=Array.isArray||function(e){};isA([])", .want = "true" },
        .{ .src = "var inh=function(c,p){function t(){this.constructor=c}c.prototype=(t.prototype=p.prototype,new t)};function P(){}P.prototype.m=function(){return 1};function C(){}inh(C,P);new C().m()", .want = "1" },
        .{ .src = "var __assign=Object.assign||function(){};__assign({},{a:1}).a", .want = "1" },
        .{ .src = "var gl=function(){if(typeof self!=='undefined')return self;if(typeof globalThis!=='undefined')return globalThis}();gl===globalThis", .want = "true" },
        .{ .src = "var o2={f(){return this}};(0,o2.f)()===globalThis", .want = "true" },
        .{ .src = "var o3={f(){return this}};(o3.f)()===o3", .want = "true" },
        .{ .src = "label:for(;;){break label}1", .want = "1" },
        .{ .src = "if(1)function ff(){}\ntypeof ff", .want = "function" },
        .{ .src = "var e=[];for(var n in{a:1})e.push(n);for(const t of[1])e.push(t);e.join()", .want = "a,1" },
    });
}

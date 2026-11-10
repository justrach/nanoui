// Other frames' objects, as proxies: every operation crosses to the VM that owns it
// (`api_frames.zig`). A window is one object for as long as its frame lasts, whatever
// it shows meanwhile: this origin's page, another's, or nothing any more.
(function ($, g) {
"use strict";

const blocked = (what) => { throw new DOMException(`Failed to read a named property '${String(what)}' from 'Window': Blocked a frame with origin "${$.pageOrigin()}" from accessing a cross-origin frame.`, "SecurityError"); };
const targetOrigin = (target) => String((typeof target === "object" && target ? target.targetOrigin : target) ?? "/");

// What a window of another origin offers: messages, being sent elsewhere, and little else.
const crossWindows = new Map();
function crossWindow(id, self) {
  let w = crossWindows.get(id);
  if (w) return w;
  const place = new Proxy({}, {
    get(_, k) { if (k === "replace" || k === "assign") return (u) => $.navigateFrame(id, String(u)); blocked(k); },
    set(_, k, v) { if (k === "href") { $.navigateFrame(id, String(v)); return true; } blocked(k); },
  });
  const known = {
    postMessage(data, target, transfer) { $.postTo(id, $.wire(data, $.windowTransfer(target, transfer)), targetOrigin(target)); },
    focus() {}, blur() {}, close() {},
    closed: false,
  };
  w = new Proxy({}, {
    get(_, k) {
      if (k in known) return known[k];
      if (k === "self" || k === "window" || k === "frames") return self;
      if (k === "location") return place;
      if (k === "parent" || k === "top") return $.neighbor(id, k);
      if (k === "length") return $.framesCount(id);
      if (k === "opener") return null;
      if (k === Symbol.toStringTag) return "Window";
      if (typeof k === "symbol" || k === "then") return undefined;
      if (/^[0-9]+$/.test(k)) return $.framesOf(id)[Number(k) * 2];
      blocked(k);
    },
    set(_, k, v) { if (k === "location") { $.navigateFrame(id, String(v)); return true; } blocked(k); },
    has(_, k) { return k in known || k === "location" || k === "parent" || k === "top"; },
    ownKeys() { return []; },
    getOwnPropertyDescriptor(_, k) { blocked(k); },
    deleteProperty(_, k) { blocked(k); },
    getPrototypeOf() { return null; },
  });
  crossWindows.set(id, w);
  return w;
}

const gone = 0, cross = 2;
const remotes = new Map();
const eventStates = new WeakMap();
$.remoteEventState = (event) => eventStates.get(event)?.();
// A function read off a window, and this window's of that name: what it still does
// once the frame has gone. Sentry and others read clean natives from an iframe they
// remove straight away, and go on to bind and call them.
const localOf = new WeakMap();
$.hook("makeRemote", (peer, id, callable, array) => {
  const key = peer + ":" + id;
  let p = remotes.get(key);
  if (p) return p;
  const call = (op, a, b) => $.remote(op, peer, id, a, b);
  const isWindow = id === 0;
  const state = isWindow ? () => $.peerState(peer) : () => 1;
  const far = () => crossWindow(peer, p);
  const send = (data, target, transfer) => $.postTo(peer, $.wire(data, $.windowTransfer(target, transfer)), targetOrigin(target));
  const orphan = () => (callable && $.peerState(peer) === gone ? localOf.get(p) ?? Function.prototype : null);
  // An array must remain an array to Array.isArray and structuredClone.
  p = new Proxy(callable ? function () {} : array ? [] : {}, {
    get(_, k) {
      const s = state();
      if (s === cross) return far()[k];
      if (isWindow) {
        if (k === "postMessage") return s === gone ? () => {} : send;
        if (k === "closed" && s === gone) return true;
      }
      if (k === Symbol.iterator) return call(9, "iterator");
      if (typeof k === "symbol") return k === Symbol.toStringTag ? call(0, "constructor")?.name : undefined;
      const v = call(0, k);
      if (v === undefined && callable) {
        const left = orphan();
        if (left) return left[k];
      }
      if (isWindow && typeof v === "function" && typeof g[k] === "function") localOf.set(v, g[k]);
      return v;
    },
    set(_, k, v) {
      if (state() === cross) { far()[k] = v; return true; }
      if (typeof k !== "symbol") call(1, k, v);
      return true;
    },
    has(_, k) { return state() === cross ? k in far() : typeof k !== "symbol" && Boolean(call(2, k)); },
    deleteProperty(_, k) { return state() === cross ? delete far()[k] : typeof k === "symbol" || call(3, k) !== false; },
    ownKeys() { return state() === cross ? [] : Array.from(call(4) ?? []); },
    getOwnPropertyDescriptor(_, k) {
      if (state() === cross) return Reflect.getOwnPropertyDescriptor(far(), k);
      if (typeof k === "symbol") return undefined;
      const enumerable = call(5, k);
      if (enumerable === undefined) return undefined;
      // The local array target's length is non-configurable, as the remote's is.
      const length = array && k === "length";
      return { value: call(0, k), writable: true, enumerable, configurable: !length };
    },
    getPrototypeOf() { return state() === cross ? null : call(8) ?? null; },
    apply(_, self, args) {
      const left = orphan();
      return left ? Reflect.apply(left, self, args) : call(6, self, args);
    },
    construct(_, args) {
      const left = orphan();
      return left ? Reflect.construct(left, args) : call(7, args) ?? {};
    },
  });
  remotes.set(key, p);
  let eventState;
  eventStates.set(p, () => eventState ??= call(11));
  return p;
});
// Arguments already are a list. Iterating their remote proxy here would call
// another remote function to obtain its iterator, recursively marshalling args.
function argumentList(value) {
  const out = [];
  for (let i = 0; i < value.length; i++) out.push(value[i]);
  return out;
}
$.hook("remoteOp", (op, o, a, b) => {
  switch (op) {
    case 0: return o[a];
    case 1: o[a] = b; return true;
    case 2: return a in o;
    case 3: return delete o[a];
    case 4: return Reflect.ownKeys(o).filter((k) => typeof k === "string");
    // Preserve hidden properties, including Object.prototype.__proto__: for-in
    // must not turn an attributes copy across frames into prototype replacement.
    case 5: return Object.getOwnPropertyDescriptor(o, a)?.enumerable;
    case 6: return Reflect.apply(o, a, b);
    case 7: return Reflect.construct(o, a);
    case 8: return Object.getPrototypeOf(o);
    case 9: return o[Symbol[a]];
    case 10: return o instanceof g.MessagePort || $.remotePort(o);
    case 11: return $.eventState(o);
  }
});
})

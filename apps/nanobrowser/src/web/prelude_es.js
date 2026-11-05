// What Chromium's JavaScript has that the engine doesn't yet, written in JavaScript:
// found by listing every builtin's members there and asking for each here. Scripts
// that take `String.prototype.x` or `Set.prototype.y` at load stop if it's missing,
// so an obfuscated script dies on its first line over something it may never call.
(function ($, g) {
"use strict";

const method = (o, name, f) => { if (!(name in o)) Object.defineProperty(o, name, { value: f, writable: true, configurable: true, enumerable: false }); };
const methods = (o, list) => { for (const name of Object.keys(list)) method(o, name, list[name]); };

// Iterator helpers, on what every iterator already inherits.
const IteratorProto = Object.getPrototypeOf(Object.getPrototypeOf([][Symbol.iterator]()));
function Iterator() {
  if (new.target === undefined || new.target === Iterator) throw new TypeError("Abstract class Iterator not directly constructable");
}
Object.defineProperty(Iterator, "prototype", { value: IteratorProto, writable: false });
method(IteratorProto, "constructor", Iterator);
const callable = (f) => { if (typeof f !== "function") throw new TypeError(String(f) + " is not a function"); return f; };
const count = (n) => { const v = Math.trunc(Number(n)); if (Number.isNaN(v) || v < 0) throw new RangeError(String(n) + " must be positive"); return v; };
const each = (it) => ({ [Symbol.iterator]() { return { next: () => it.next(), return: () => (it.return ? it.return() : { done: true }) }; } });
methods(IteratorProto, {
  map(f) { callable(f); const it = this; return (function* () { let i = 0; for (const v of each(it)) yield f(v, i++); })(); },
  filter(f) { callable(f); const it = this; return (function* () { let i = 0; for (const v of each(it)) if (f(v, i++)) yield v; })(); },
  take(n) { const left = count(n); const it = this; return (function* () { let i = 0; if (left === 0) return; for (const v of each(it)) { yield v; if (++i >= left) return; } })(); },
  drop(n) { const skip = count(n); const it = this; return (function* () { let i = 0; for (const v of each(it)) if (i++ >= skip) yield v; })(); },
  flatMap(f) { callable(f); const it = this; return (function* () { let i = 0; for (const v of each(it)) yield* f(v, i++); })(); },
  reduce(f, ...start) { callable(f); let has = start.length > 0, out = start[0], i = 0; for (const v of each(this)) { out = has ? f(out, v, i) : v; has = true; i++; } if (!has) throw new TypeError("Reduce of a done iterator with no initial value"); return out; },
  toArray() { return Array.from(each(this)); },
  forEach(f) { callable(f); let i = 0; for (const v of each(this)) f(v, i++); },
  some(f) { callable(f); let i = 0; for (const v of each(this)) if (f(v, i++)) return true; return false; },
  every(f) { callable(f); let i = 0; for (const v of each(this)) if (!f(v, i++)) return false; return true; },
  find(f) { callable(f); let i = 0; for (const v of each(this)) if (f(v, i++)) return v; return undefined; },
});
Iterator.from = function from(o) {
  const get = o[Symbol.iterator];
  const it = typeof get === "function" ? get.call(o) : o;
  if (it instanceof Iterator) return it;
  return Object.create(IteratorProto, { next: { value: () => it.next(), configurable: true, writable: true }, return: { value: () => (it.return ? it.return() : { done: true }), configurable: true, writable: true } });
};
method(g, "Iterator", Iterator);

// One thread at a time here, so every one of these is already atomic.
const at = (a, i, op) => { const old = a[i]; a[i] = op(old); return old; };
method(g, "Atomics", Object.create(Object.prototype, Object.getOwnPropertyDescriptors({
  add: (a, i, v) => at(a, i, (x) => x + v), sub: (a, i, v) => at(a, i, (x) => x - v),
  and: (a, i, v) => at(a, i, (x) => x & v), or: (a, i, v) => at(a, i, (x) => x | v), xor: (a, i, v) => at(a, i, (x) => x ^ v),
  exchange: (a, i, v) => at(a, i, () => v), load: (a, i) => a[i], store: (a, i, v) => { a[i] = v; return v; },
  compareExchange: (a, i, want, v) => at(a, i, (x) => (x === want ? v : x)),
  isLockFree: (n) => n === 1 || n === 2 || n === 4 || n === 8, notify: () => 0, pause: () => {},
  wait: () => { throw new TypeError("Atomics.wait cannot be called in this context"); },
})));

method(Symbol, "dispose", Symbol.for("nodejs.dispose"));
method(Symbol, "asyncDispose", Symbol.for("nodejs.asyncDispose"));
method(Promise, "try", function (f, ...args) { return new this((ok) => ok(f(...args))); });
method(Error, "isError", (v) => v instanceof Error);
method(RegExp, "escape", (s) => String(s).replace(/[\\^$.*+?()[\]{}|\/-]/g, "\\$&").replace(/^[0-9a-zA-Z]/, (c) => "\\x" + c.charCodeAt(0).toString(16).padStart(2, "0")));
method(Array, "fromAsync", async function (from, f, self) {
  const out = [];
  let i = 0;
  for await (const v of from) out.push(f ? await f.call(self, v, i++) : v);
  return out;
});

// String's old markup methods.
const tagged = (tag, attr) => function (v) { return `<${tag}${attr ? ` ${attr}="${String(v).replace(/"/g, "&quot;")}"` : ""}>${this}</${tag}>`; };
methods(String.prototype, { anchor: tagged("a", "name"), big: tagged("big"), blink: tagged("blink"), bold: tagged("b"), fixed: tagged("tt"), fontcolor: tagged("font", "color"), fontsize: tagged("font", "size"), italics: tagged("i"), link: tagged("a", "href"), small: tagged("small"), strike: tagged("strike"), sub: tagged("sub"), sup: tagged("sup") });

// Sets.
const keysOf = (o) => (o && typeof o.keys === "function" ? o.keys() : []);
methods(Set.prototype, {
  union(o) { const out = new Set(this); for (const v of keysOf(o)) out.add(v); return out; },
  intersection(o) { const out = new Set(); for (const v of this) if (o.has(v)) out.add(v); return out; },
  difference(o) { const out = new Set(); for (const v of this) if (!o.has(v)) out.add(v); return out; },
  symmetricDifference(o) { const out = new Set(this); for (const v of keysOf(o)) { if (this.has(v)) out.delete(v); else out.add(v); } return out; },
  isSubsetOf(o) { for (const v of this) if (!o.has(v)) return false; return true; },
  isSupersetOf(o) { for (const v of keysOf(o)) if (!this.has(v)) return false; return true; },
  isDisjointFrom(o) { for (const v of this) if (o.has(v)) return false; return true; },
});
const orInsert = { getOrInsert(k, v) { if (!this.has(k)) this.set(k, v); return this.get(k); }, getOrInsertComputed(k, f) { if (!this.has(k)) this.set(k, f(k)); return this.get(k); } };
methods(Map.prototype, orInsert);
methods(WeakMap.prototype, orInsert);

// ArrayBuffer: copies for what would be a move; none here are resizable.
const AB = ArrayBuffer.prototype;
const moved = function (n = this.byteLength) { const out = new ArrayBuffer(n); new Uint8Array(out).set(new Uint8Array(this, 0, Math.min(n, this.byteLength))); return out; };
methods(AB, { transfer: moved, transferToFixedLength: moved, resize() { throw new TypeError("This ArrayBuffer is not resizable."); } });
for (const [name, get] of [["resizable", () => false], ["detached", () => false], ["maxByteLength", function () { return this.byteLength; }]]) {
  if (!(name in AB)) Object.defineProperty(AB, name, { get, configurable: true });
}

// Uint8Array's base64 and hex.
const b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const alphabet = (o) => (o && o.alphabet === "base64url" ? "-_" : "+/");
methods(Uint8Array.prototype, {
  toBase64(o) {
    const end = alphabet(o);
    let s = "";
    for (let i = 0; i < this.length; i += 3) {
      const n = (this[i] << 16) | ((this[i + 1] ?? 0) << 8) | (this[i + 2] ?? 0);
      s += b64[n >> 18] + b64[(n >> 12) & 63] + (i + 1 < this.length ? b64[(n >> 6) & 63] : "=") + (i + 2 < this.length ? b64[n & 63] : "=");
    }
    if (end !== "+/") s = s.replace(/\+/g, "-").replace(/\//g, "_");
    return o && o.omitPadding ? s.replace(/=+$/, "") : s;
  },
  toHex() { let s = ""; for (const v of this) s += v.toString(16).padStart(2, "0"); return s; },
});
method(Uint8Array, "fromBase64", function (text, o) {
  const clean = String(text).replace(/[\s=]/g, "").replace(/-/g, "+").replace(/_/g, "/");
  if (/[^A-Za-z0-9+/]/.test(clean)) throw new SyntaxError("The string is not valid base64");
  void o;
  const out = new Uint8Array(Math.floor((clean.length * 3) / 4));
  let bits = 0, have = 0, n = 0;
  for (const c of clean) {
    bits = (bits << 6) | b64.indexOf(c);
    have += 6;
    if (have >= 8) { have -= 8; out[n++] = (bits >> have) & 255; bits &= (1 << have) - 1; }
  }
  return out;
});
method(Uint8Array, "fromHex", function (text) {
  const s = String(text);
  if (s.length % 2 || /[^0-9a-fA-F]/.test(s)) throw new SyntaxError("The string is not valid hex");
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(s.slice(i * 2, i * 2 + 2), 16);
  return out;
});

// Intl: the shapes, with English's answers.
const I = g.Intl;
if (I) {
  class Segmenter {
    #granularity; #locale;
    constructor(locale, o) { this.#locale = Array.isArray(locale) ? locale[0] : locale || "en-US"; this.#granularity = (o && o.granularity) || "grapheme"; }
    resolvedOptions() { return { locale: this.#locale, granularity: this.#granularity }; }
    segment(text) {
      const s = String(text), kind = this.#granularity;
      const pattern = kind === "word" ? /[\p{L}\p{N}_'’]+|\s+|[^\p{L}\p{N}_'’\s]/gu : kind === "sentence" ? /[^.!?]+[.!?]*\s*|[.!?]+\s*/gu : /\P{M}\p{M}*(?:\u200d\P{M}\p{M}*)*/gu;
      const list = [];
      for (const m of s.matchAll(pattern)) {
        const one = { segment: m[0], index: m.index, input: s };
        if (kind === "word") one.isWordLike = /[\p{L}\p{N}]/u.test(m[0]);
        list.push(one);
      }
      return { [Symbol.iterator]() { return list[Symbol.iterator](); }, containing(i = 0) { return list.find((x) => i >= x.index && i < x.index + x.segment.length); } };
    }
    static supportedLocalesOf(l) { return [].concat(l || []); }
  }
  class Locale {
    constructor(tag, o) {
      const [language, ...rest] = String(tag).split("-");
      this.baseName = String(tag); this.language = language;
      this.region = rest.find((x) => /^([A-Z]{2}|\d{3})$/.test(x));
      this.script = rest.find((x) => /^[A-Z][a-z]{3}$/.test(x));
      Object.assign(this, o);
    }
    toString() { return this.baseName; }
    maximize() { return this; }
    minimize() { return this; }
  }
  class DisplayNames {
    #o;
    constructor(_l, o) { this.#o = o || {}; }
    of(code) { return String(code); }
    resolvedOptions() { return { locale: "en-US", style: "long", fallback: "code", ...this.#o }; }
    static supportedLocalesOf(l) { return [].concat(l || []); }
  }
  method(I, "Segmenter", Segmenter);
  method(I, "Locale", Locale);
  method(I, "DisplayNames", DisplayNames);
  method(I, "supportedValuesOf", () => []);
}
})

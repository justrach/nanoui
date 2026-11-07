// What talks to the network and what it talks in: fetch, XHR, Headers, Blob,
// FormData, AbortController, text encoding, structuredClone. Streaming isn't there:
// a response's body arrives whole, and `Response.body` is a stream of that one piece.
(function ($, g) {
"use strict";
const def = $.def;

// Abort.
class AbortSignal extends EventTarget {
  aborted = false;
  reason = undefined;
  onabort = null;
  throwIfAborted() { if (this.aborted) throw this.reason; }
  static abort(reason) { const s = new AbortSignal(); doAbort(s, reason); return s; }
  static timeout(ms) { const s = new AbortSignal(); g.setTimeout(() => doAbort(s, new DOMException("The operation timed out.", "TimeoutError")), ms); return s; }
  static any(list) {
    const s = new AbortSignal();
    for (const x of list) {
      if (x.aborted) { doAbort(s, x.reason); break; }
      x.addEventListener("abort", () => doAbort(s, x.reason));
    }
    return s;
  }
}
function doAbort(s, reason) {
  if (s.aborted) return;
  s.aborted = true;
  s.reason = reason === undefined ? new DOMException("signal is aborted without reason", "AbortError") : reason;
  const e = new Event("abort");
  if (typeof s.onabort === "function") { try { s.onabort(e); } catch (x) { $.reportError(x); } }
  s.dispatchEvent(e);
}
class AbortController {
  signal = new AbortSignal();
  abort(reason) { doAbort(this.signal, reason); }
}

// Text.
class TextEncoder {
  get encoding() { return "utf-8"; }
  encode(s = "") { return $.encode(String(s)); }
  encodeInto(s, into) {
    const b = $.encode(String(s));
    const n = Math.min(b.length, into.length);
    into.set(b.subarray(0, n));
    return { read: s.length, written: n };
  }
}
class TextDecoder {
  constructor(label = "utf-8", o) {
    const l = String(label).toLowerCase().trim();
    if (!/^(?:utf-?8|unicode-1-1-utf-8|ascii|us-ascii|iso-8859-1|latin1|windows-1252)$/.test(l)) throw new RangeError("The encoding label provided ('" + label + "') is invalid.");
    this.encoding = /utf/.test(l) ? "utf-8" : "windows-1252";
    this.fatal = !!(o && o.fatal);
    this.ignoreBOM = !!(o && o.ignoreBOM);
  }
  decode(v) {
    if (v === undefined) return "";
    if (this.encoding !== "utf-8") {
      const u = v instanceof ArrayBuffer ? new Uint8Array(v) : new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
      let out = "";
      for (let i = 0; i < u.length; i++) out += String.fromCharCode(u[i]);
      return out;
    }
    const s = $.decode(v, this.ignoreBOM);
    if (this.fatal && s.includes("\uFFFD")) throw new TypeError("The encoded data was not valid.");
    return s;
  }
}

// structuredClone.
function clone(v, seen) {
  if (v === null || typeof v !== "object") {
    if (typeof v === "function" || typeof v === "symbol") throw new DOMException(String(v) + " could not be cloned.", "DataCloneError");
    return v;
  }
  if (seen.has(v)) return seen.get(v);
  if ($.isNode(v)) throw new DOMException("A node could not be cloned.", "DataCloneError");
  let out;
  if (v instanceof Date) out = new Date(v.getTime());
  else if (v instanceof RegExp) out = new RegExp(v.source, v.flags);
  else if (v instanceof Boolean || v instanceof Number || v instanceof String) out = Object(v.valueOf());
  else if (v instanceof ArrayBuffer) out = v.slice(0);
  else if (ArrayBuffer.isView(v)) {
    const buf = clone(v.buffer, seen);
    out = v instanceof DataView ? new DataView(buf, v.byteOffset, v.byteLength) : new v.constructor(buf, v.byteOffset, v.length);
  } else if (v instanceof Error) {
    const C = { EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError }[v.name] || Error;
    out = new C(v.message);
    if ("stack" in v) out.stack = v.stack;
  } else if (v instanceof Blob) out = v;
  else if (v instanceof Map) { out = new Map(); seen.set(v, out); for (const [k, x] of v) out.set(clone(k, seen), clone(x, seen)); return out; }
  else if (v instanceof Set) { out = new Set(); seen.set(v, out); for (const x of v) out.add(clone(x, seen)); return out; }
  else if (Array.isArray(v)) { out = new Array(v.length); seen.set(v, out); for (const k of Object.keys(v)) out[k] = clone(v[k], seen); return out; }
  else if (v instanceof Promise || v instanceof WeakMap || v instanceof WeakSet) throw new DOMException("An object could not be cloned.", "DataCloneError");
  else { out = {}; seen.set(v, out); for (const k of Object.keys(v)) out[k] = clone(v[k], seen); return out; }
  seen.set(v, out);
  return out;
}
function structuredClone(v) { return clone(v, new Map()); }

// Blob, File, FormData.
const toBytes = (v) => {
  if (v instanceof Uint8Array) return v;
  if (v instanceof ArrayBuffer) return new Uint8Array(v);
  if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  if (v instanceof Blob) return v._bytes;
  return $.encode(String(v));
};
class Blob {
  #bytes; #type;
  constructor(parts = [], o) {
    const chunks = Array.from(parts).map(toBytes);
    let n = 0; for (const c of chunks) n += c.length;
    const all = new Uint8Array(n);
    let at = 0; for (const c of chunks) { all.set(c, at); at += c.length; }
    this.#bytes = all;
    this.#type = o && o.type ? String(o.type).toLowerCase() : "";
  }
  get _bytes() { return this.#bytes; }
  get size() { return this.#bytes.length; }
  get type() { return this.#type; }
  text() { return Promise.resolve($.decode(this.#bytes)); }
  arrayBuffer() { return Promise.resolve(this.#bytes.slice().buffer); }
  bytes() { return Promise.resolve(this.#bytes.slice()); }
  slice(a = 0, b = this.size, type = "") { return new Blob([this.#bytes.slice(a, b)], { type }); }
  stream() { return streamOf(this.#bytes); }
}
class File extends Blob {
  constructor(parts, name, o) { super(parts, o); this.name = String(name); this.lastModified = o && o.lastModified || Date.now(); this.webkitRelativePath = ""; }
}
class FileReader extends EventTarget {
  result = null; error = null; readyState = 0;
  onload = null; onloadend = null; onerror = null; onabort = null; onloadstart = null; onprogress = null;
  _read(blob, f) {
    this.readyState = 1;
    g.setTimeout(() => {
      this.result = f(blob);
      this.readyState = 2;
      for (const t of ["load", "loadend"]) { const e = new Event(t); if (typeof this["on" + t] === "function") this["on" + t](e); this.dispatchEvent(e); }
    }, 0);
  }
  readAsText(b) { this._read(b, (x) => $.decode(x._bytes)); }
  readAsArrayBuffer(b) { this._read(b, (x) => x._bytes.slice().buffer); }
  readAsDataURL(b) {
    this._read(b, (x) => {
      let s = ""; const u = x._bytes;
      for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]);
      return "data:" + (x.type || "application/octet-stream") + ";base64," + g.btoa(s);
    });
  }
  abort() { this.readyState = 2; }
}
for (const [k, v] of [["EMPTY", 0], ["LOADING", 1], ["DONE", 2]]) { FileReader[k] = v; FileReader.prototype[k] = v; }
class FormData {
  #list = [];
  constructor(form) {
    if (!form) return;
    for (const el of form.elements) {
      const name = el.getAttribute("name");
      if (!name || el.disabled) continue;
      const tag = el.tagName;
      if (tag === "INPUT") {
        const t = el.type;
        if (t === "checkbox" || t === "radio") { if (el.checked) this.append(name, el.value); }
        else if (t !== "submit" && t !== "button" && t !== "reset" && t !== "image" && t !== "file") this.append(name, el.value);
      } else if (tag === "TEXTAREA" || tag === "SELECT") this.append(name, el.value);
    }
  }
  append(k, v, fname) { this.#list.push([String(k), v instanceof Blob ? (v instanceof File && fname === undefined ? v : new File([v], fname === undefined ? "blob" : fname, { type: v.type })) : String(v)]); }
  delete(k) { k = String(k); this.#list = this.#list.filter((x) => x[0] !== k); }
  get(k) { k = String(k); const p = this.#list.find((x) => x[0] === k); return p ? p[1] : null; }
  getAll(k) { k = String(k); return this.#list.filter((x) => x[0] === k).map((x) => x[1]); }
  has(k) { k = String(k); return this.#list.some((x) => x[0] === k); }
  set(k, v, fname) { this.delete(k); this.append(k, v, fname); }
  forEach(f, t) { for (const [k, v] of this.#list) f.call(t, v, k, this); }
  *entries() { for (const p of this.#list) yield [p[0], p[1]]; }
  *keys() { for (const p of this.#list) yield p[0]; }
  *values() { for (const p of this.#list) yield p[1]; }
  [Symbol.iterator]() { return this.entries(); }
}

// Headers.
class Headers {
  #map = new Map();
  constructor(init) {
    if (!init) return;
    if (init instanceof Headers) init.forEach((v, k) => this.append(k, v));
    else if (typeof init[Symbol.iterator] === "function") for (const [k, v] of init) this.append(k, v);
    else for (const k of Object.keys(init)) this.append(k, init[k]);
  }
  append(k, v) {
    k = String(k).toLowerCase();
    if (!/^[!#$%&'*+.^_`|~0-9a-z-]+$/.test(k)) throw new TypeError("'" + k + "' is an invalid header name.");
    const o = this.#map.get(k);
    this.#map.set(k, o === undefined ? String(v) : o + ", " + v);
  }
  delete(k) { this.#map.delete(String(k).toLowerCase()); }
  get(k) { const v = this.#map.get(String(k).toLowerCase()); return v === undefined ? null : v; }
  has(k) { return this.#map.has(String(k).toLowerCase()); }
  set(k, v) { this.#map.set(String(k).toLowerCase(), String(v)); }
  getSetCookie() { const v = this.#map.get("set-cookie"); return v === undefined ? [] : [v]; }
  forEach(f, t) { for (const k of Array.from(this.#map.keys()).sort()) f.call(t, this.#map.get(k), k, this); }
  *entries() { for (const k of Array.from(this.#map.keys()).sort()) yield [k, this.#map.get(k)]; }
  *keys() { for (const k of Array.from(this.#map.keys()).sort()) yield k; }
  *values() { for (const k of Array.from(this.#map.keys()).sort()) yield this.#map.get(k); }
  [Symbol.iterator]() { return this.entries(); }
}
// A stream of one chunk.
function streamOf(bytes) {
  return new ReadableStream({ start(c) { if (bytes.length) c.enqueue(bytes); c.close(); } });
}
class ReadableStream {
  #queue = []; #closed = false; #err = null; #waiters = []; locked = false;
  constructor(source) {
    const self = this;
    const ctl = {
      enqueue(x) { self.#queue.push(x); self.#wake(); },
      close() { self.#closed = true; self.#wake(); },
      error(e) { self.#err = e || new Error("stream error"); self.#wake(); },
    };
    if (source && source.start) source.start(ctl);
  }
  #wake() { for (const f of this.#waiters.splice(0)) f(); }
  getReader() {
    const self = this; self.locked = true;
    return {
      async read() {
        for (;;) {
          if (self.#err) throw self.#err;
          if (self.#queue.length) return { value: self.#queue.shift(), done: false };
          if (self.#closed) return { value: undefined, done: true };
          await new Promise((r) => self.#waiters.push(r));
        }
      },
      releaseLock() { self.locked = false; },
      cancel() { self.#queue.length = 0; self.#closed = true; return Promise.resolve(); },
      closed: Promise.resolve(),
    };
  }
  cancel() { this.#queue.length = 0; this.#closed = true; return Promise.resolve(); }
  async *[Symbol.asyncIterator]() {
    const r = this.getReader();
    for (;;) { const { value, done } = await r.read(); if (done) return; yield value; }
  }
}

// What a body may be, as bytes or text, and the type it says it is.
function extractBody(b) {
  if (b === undefined || b === null) return { body: null, type: null };
  if (typeof b === "string") return { body: b, type: "text/plain;charset=UTF-8" };
  if (b instanceof g.URLSearchParams) return { body: b.toString(), type: "application/x-www-form-urlencoded;charset=UTF-8" };
  if (b instanceof Blob) return { body: b._bytes, type: b.type || null };
  if (b instanceof FormData) return formBody(b);
  if (b instanceof ArrayBuffer) return { body: new Uint8Array(b), type: null };
  if (ArrayBuffer.isView(b)) return { body: new Uint8Array(b.buffer, b.byteOffset, b.byteLength), type: null };
  return { body: String(b), type: "text/plain;charset=UTF-8" };
}
function formBody(fd) {
  const boundary = "----nanobrowser" + g.crypto.randomUUID().replace(/-/g, "");
  const parts = [];
  for (const [k, v] of fd) {
    if (typeof v === "string") parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="${k}"\r\n\r\n${v}\r\n`);
    else parts.push(`--${boundary}\r\nContent-Disposition: form-data; name="${k}"; filename="${v.name}"\r\nContent-Type: ${v.type || "application/octet-stream"}\r\n\r\n`, v, "\r\n");
  }
  parts.push(`--${boundary}--\r\n`);
  return { body: new Blob(parts)._bytes, type: "multipart/form-data; boundary=" + boundary };
}
function bodyMixin(C) {
  const P = C.prototype;
  P._take = function () {
    if (this.bodyUsed) return Promise.reject(new TypeError("Body has already been consumed."));
    this.bodyUsed = true;
    const b = this._body;
    return Promise.resolve(typeof b === "string" ? $.encode(b) : b === null ? new Uint8Array(0) : b);
  };
  P.text = function () { return this._take().then((b) => $.decode(b)); };
  P.json = function () { return this.text().then((t) => JSON.parse(t)); };
  P.arrayBuffer = function () { return this._take().then((b) => b.slice().buffer); };
  P.bytes = function () { return this._take().then((b) => b.slice()); };
  P.blob = function () { return this._take().then((b) => new Blob([b], { type: this.headers.get("content-type") || "" })); };
  P.formData = function () {
    return this.text().then((t) => { const f = new FormData(); for (const [k, v] of new g.URLSearchParams(t)) f.append(k, v); return f; });
  };
}
class Request {
  constructor(input, init = {}) {
    let base = input instanceof Request ? input : null;
    const url = base ? base.url : String(input);
    const resolved = $.resolveUrl(url);
    if (resolved === null) throw new TypeError("Failed to parse URL from " + url);
    this.url = resolved;
    const m = String(init.method || (base ? base.method : "GET"));
    this.method = /^(?:get|head|post|put|delete|options|patch)$/i.test(m) ? m.toUpperCase() : m;
    this.headers = new Headers(init.headers || (base ? base.headers : undefined));
    this.mode = init.mode || (base ? base.mode : "cors");
    this.credentials = init.credentials || (base ? base.credentials : "same-origin");
    this.cache = init.cache || (base ? base.cache : "default");
    this.redirect = init.redirect || (base ? base.redirect : "follow");
    this.referrer = init.referrer || "about:client";
    this.referrerPolicy = init.referrerPolicy || "";
    this.integrity = init.integrity || "";
    this.keepalive = !!init.keepalive;
    this.destination = "";
    this.signal = init.signal || (base ? base.signal : new AbortSignal());
    const e = extractBody(init.body !== undefined ? init.body : base ? base._body : null);
    if (e.body !== null && (this.method === "GET" || this.method === "HEAD")) throw new TypeError("Request with GET/HEAD method cannot have body.");
    this._body = e.body;
    this.bodyUsed = false;
    if (e.type && !this.headers.has("content-type")) this.headers.set("content-type", e.type);
  }
  get body() { return this._body === null ? null : streamOf(typeof this._body === "string" ? $.encode(this._body) : this._body); }
  clone() { if (this.bodyUsed) throw new TypeError("Request body is already used."); return new Request(this); }
}
bodyMixin(Request);
const statusText = { 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 301: "Moved Permanently", 302: "Found", 304: "Not Modified", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 422: "Unprocessable Entity", 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable", 504: "Gateway Timeout" };
class Response {
  constructor(body = null, init = {}) {
    this.status = init.status === undefined ? 200 : init.status | 0;
    if (this.status < 200 || this.status > 599) throw new RangeError("Failed to construct 'Response': The status provided (" + this.status + ") is outside the range [200, 599].");
    this.statusText = init.statusText === undefined ? (init._raw ? statusText[this.status] || "" : "") : String(init.statusText);
    this.headers = new Headers(init.headers);
    this.url = init.url || "";
    this.redirected = !!init.redirected;
    this.type = init.type || "default";
    const e = extractBody(body);
    this._body = e.body;
    this.bodyUsed = false;
    if (e.type && !this.headers.has("content-type")) this.headers.set("content-type", e.type);
  }
  get ok() { return this.status >= 200 && this.status < 300; }
  get body() { return this._body === null ? null : streamOf(typeof this._body === "string" ? $.encode(this._body) : this._body); }
  clone() {
    if (this.bodyUsed) throw new TypeError("Response body is already used.");
    const r = new Response(null, { status: this.status, statusText: this.statusText, headers: this.headers, url: this.url, redirected: this.redirected, type: this.type });
    r._body = this._body;
    return r;
  }
  static error() { const r = new Response(null, { status: 200 }); r.status = 0; r.type = "error"; return r; }
  static redirect(url, status = 302) { return new Response(null, { status, headers: { location: String(url) } }); }
  static json(v, init = {}) { const h = new Headers(init.headers); if (!h.has("content-type")) h.set("content-type", "application/json"); return new Response(JSON.stringify(v), Object.assign({}, init, { headers: h })); }
}
bodyMixin(Response);

function flatHeaders(h) {
  const out = [];
  h.forEach((v, k) => { out.push(k, v); });
  return out;
}
function fetch(input, init) {
  return new Promise((resolve, reject) => {
    const req = new Request(input, init);
    if (req.signal.aborted) return reject(req.signal.reason);
    let done = false;
    const onAbort = () => { if (!done) { done = true; reject(req.signal.reason); } };
    req.signal.addEventListener("abort", onAbort);
    const url = req.url;
    if (url.startsWith("blob:")) {
      const blob = $.blobUrls && $.blobUrls.get(url);
      if (!blob) return reject(new TypeError("Failed to fetch"));
      return resolve(new Response(blob, { url, _raw: true }));
    }
    const body = typeof req._body === "string" ? req._body : req._body;
    $.request(req.method, url, flatHeaders(req.headers), body === null ? undefined : body, (status, finalUrl, headers, bytes, err) => {
      req.signal.removeEventListener("abort", onAbort);
      if (done) return;
      done = true;
      if (status === 0) return reject(new TypeError("Failed to fetch" + (err ? ": " + err : "")));
      const h = new Headers();
      for (let i = 0; i + 1 < headers.length; i += 2) h.append(headers[i], headers[i + 1]);
      const r = new Response(null, { status: Math.max(status, 200), headers: h, url: finalUrl, redirected: finalUrl !== url, type: "basic", _raw: true });
      r.status = status;
      r.statusText = statusText[status] || "";
      r._body = bytes;
      resolve(r);
    }, req.credentials === "include");
  });
}

// XMLHttpRequest, asynchronous only.
class ProgressEvent extends Event {
  constructor(t, i) { super(t, i); this.lengthComputable = !!(i && i.lengthComputable); this.loaded = i && i.loaded || 0; this.total = i && i.total || 0; }
}
class XMLHttpRequestEventTarget extends EventTarget {}
class XMLHttpRequestUpload extends XMLHttpRequestEventTarget {}
class XMLHttpRequest extends XMLHttpRequestEventTarget {
  #method = "GET"; #url = ""; #headers = new Headers(); #gen = 0; #resHeaders = null; #bytes = null; #mime = null;
  readyState = 0; status = 0; statusText = ""; responseURL = ""; responseType = ""; timeout = 0; withCredentials = false;
  upload = new XMLHttpRequestUpload();
  onreadystatechange = null; onload = null; onerror = null; onabort = null; ontimeout = null; onloadstart = null; onloadend = null; onprogress = null;
  open(method, url, isAsync) {
    if (isAsync === false) throw new DOMException("Synchronous requests are not available.", "NotSupportedError");
    const m = String(method);
    this.#method = /^(?:get|head|post|put|delete|options|patch)$/i.test(m) ? m.toUpperCase() : m;
    const r = $.resolveUrl(String(url));
    if (r === null) throw new DOMException("The URL is invalid.", "SyntaxError");
    this.#url = r;
    this.#headers = new Headers(); this.#gen++; this.#resHeaders = null; this.#bytes = null;
    this.status = 0; this.statusText = ""; this.responseURL = "";
    this.#state(1);
  }
  #fire(type, target = this, o) {
    const e = new ProgressEvent(type, o);
    const f = target["on" + type];
    if (typeof f === "function") { try { f.call(target, e); } catch (x) { $.reportError(x); } }
    target.dispatchEvent(e);
  }
  #state(n) { this.readyState = n; this.#fire("readystatechange"); }
  setRequestHeader(k, v) {
    if (this.readyState !== 1) throw new DOMException("The object's state must be OPENED.", "InvalidStateError");
    this.#headers.append(k, v);
  }
  send(body) {
    if (this.readyState !== 1) throw new DOMException("The object's state must be OPENED.", "InvalidStateError");
    const gen = this.#gen;
    const noBody = this.#method === "GET" || this.#method === "HEAD";
    const e = noBody ? { body: null, type: null } : extractBody(body);
    if (e.type && !this.#headers.has("content-type")) this.#headers.set("content-type", e.type);
    this.#fire("loadstart", this, { loaded: 0, total: 0 });
    let timer = 0;
    if (this.timeout > 0) timer = g.setTimeout(() => {
      if (gen !== this.#gen) return;
      this.#gen++;
      this.status = 0;
      this.#state(4);
      this.#fire("timeout");
      this.#fire("loadend");
    }, this.timeout);
    $.request(this.#method, this.#url, flatHeaders(this.#headers), e.body === null ? undefined : e.body, (status, finalUrl, headers, bytes, err) => {
      if (timer) g.clearTimeout(timer);
      if (gen !== this.#gen) return;
      if (status === 0) {
        this.#state(4);
        this.#fire("error", this, { loaded: 0, total: 0 });
        this.#fire("loadend", this, { loaded: 0, total: 0 });
        return;
      }
      this.status = status;
      this.statusText = statusText[status] || "";
      this.responseURL = finalUrl;
      const h = new Headers();
      for (let i = 0; i + 1 < headers.length; i += 2) h.append(headers[i], headers[i + 1]);
      this.#resHeaders = h;
      this.#state(2);
      this.#bytes = bytes;
      this.#state(3);
      this.#fire("progress", this, { lengthComputable: true, loaded: bytes.length, total: bytes.length });
      this.#state(4);
      this.#fire("load", this, { lengthComputable: true, loaded: bytes.length, total: bytes.length });
      this.#fire("loadend", this, { lengthComputable: true, loaded: bytes.length, total: bytes.length });
    }, this.withCredentials);
  }
  abort() {
    this.#gen++;
    if (this.readyState === 1 || this.readyState === 2 || this.readyState === 3) {
      this.status = 0;
      this.readyState = 4;
      this.#fire("readystatechange");
      this.#fire("abort");
      this.#fire("loadend");
    }
    this.readyState = 0;
  }
  overrideMimeType(m) { this.#mime = m; }
  getResponseHeader(k) { return this.#resHeaders ? this.#resHeaders.get(k) : null; }
  getAllResponseHeaders() {
    if (!this.#resHeaders) return "";
    let out = "";
    this.#resHeaders.forEach((v, k) => { out += k + ": " + v + "\r\n"; });
    return out;
  }
  get responseText() {
    if (this.responseType !== "" && this.responseType !== "text") throw new DOMException("The value is only accessible if the object's 'responseType' is '' or 'text'.", "InvalidStateError");
    return this.#bytes ? $.decode(this.#bytes) : "";
  }
  get responseXML() { return null; }
  get response() {
    if (this.readyState !== 4 || !this.#bytes) return this.responseType === "" || this.responseType === "text" ? "" : null;
    switch (this.responseType) {
      case "": case "text": return $.decode(this.#bytes);
      case "json": try { return JSON.parse($.decode(this.#bytes)); } catch (e) { return null; }
      case "arraybuffer": return this.#bytes.slice().buffer;
      case "blob": return new Blob([this.#bytes], { type: this.getResponseHeader("content-type") || "" });
      case "document": return new g.DOMParser().parseFromString($.decode(this.#bytes), "text/html");
    }
    return null;
  }
}
for (const [k, v] of [["UNSENT", 0], ["OPENED", 1], ["HEADERS_RECEIVED", 2], ["LOADING", 3], ["DONE", 4]]) {
  Object.defineProperty(XMLHttpRequest, k, { value: v, enumerable: true });
  Object.defineProperty(XMLHttpRequest.prototype, k, { value: v, enumerable: true });
}

for (const c of [AbortSignal, AbortController, TextEncoder, TextDecoder, Blob, File, FileReader, FormData, Headers, ReadableStream, Request, Response, ProgressEvent, XMLHttpRequest]) def(g, c.name, c);
def(g, "XMLHttpRequestEventTarget", XMLHttpRequestEventTarget);
def(g, "XMLHttpRequestUpload", XMLHttpRequestUpload);
def(g, "structuredClone", structuredClone);
g.fetch = fetch;
})

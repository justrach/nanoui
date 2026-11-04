// URL and URLSearchParams. Parsing is by a pattern and Zig's resolver, enough for
// the URLs pages make: no IDNA, no opaque-path subtleties.
(function ($, g) {
"use strict";
const def = $.def;

function encodeForm(s) {
  return encodeURIComponent(s).replace(/%20/g, "+").replace(/[!'()~]/g, (c) => "%" + c.charCodeAt(0).toString(16).toUpperCase());
}
function decodeForm(s) {
  s = s.replace(/\+/g, " ");
  try { return decodeURIComponent(s); } catch (e) { return s.replace(/%[0-9a-fA-F]{2}/g, (m) => { try { return decodeURIComponent(m); } catch (x) { return m; } }); }
}
const OWNER = Symbol("owner");
class URLSearchParams {
  #list = [];
  constructor(init) {
    if (init === undefined || init === null) return;
    if (typeof init === "object") {
      if (typeof init[Symbol.iterator] === "function") {
        for (const p of init) { const a = Array.from(p); if (a.length !== 2) throw new TypeError("Each query pair must be an iterable [name, value] tuple"); this.#list.push([String(a[0]), String(a[1])]); }
      } else for (const k of Object.keys(init)) this.#list.push([k, String(init[k])]);
    } else this._parse(String(init));
  }
  _parse(s) {
    this.#list = [];
    if (s[0] === "?") s = s.slice(1);
    for (const part of s.split("&")) {
      if (!part) continue;
      const i = part.indexOf("=");
      this.#list.push(i < 0 ? [decodeForm(part), ""] : [decodeForm(part.slice(0, i)), decodeForm(part.slice(i + 1))]);
    }
  }
  _changed() { if (this[OWNER]) this[OWNER]._setQuery(this.toString()); }
  get size() { return this.#list.length; }
  append(k, v) { this.#list.push([String(k), String(v)]); this._changed(); }
  delete(k, v) { k = String(k); this.#list = this.#list.filter((p) => !(p[0] === k && (v === undefined || p[1] === String(v)))); this._changed(); }
  get(k) { k = String(k); const p = this.#list.find((x) => x[0] === k); return p ? p[1] : null; }
  getAll(k) { k = String(k); return this.#list.filter((x) => x[0] === k).map((x) => x[1]); }
  has(k, v) { k = String(k); return this.#list.some((x) => x[0] === k && (v === undefined || x[1] === String(v))); }
  set(k, v) {
    k = String(k); v = String(v);
    const i = this.#list.findIndex((x) => x[0] === k);
    if (i < 0) this.#list.push([k, v]);
    else { this.#list[i][1] = v; this.#list = this.#list.filter((x, j) => j <= i || x[0] !== k); }
    this._changed();
  }
  sort() { this.#list.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0)); this._changed(); }
  forEach(f, t) { for (const [k, v] of this.#list) f.call(t, v, k, this); }
  *entries() { for (const p of this.#list) yield [p[0], p[1]]; }
  *keys() { for (const p of this.#list) yield p[0]; }
  *values() { for (const p of this.#list) yield p[1]; }
  [Symbol.iterator]() { return this.entries(); }
  toString() { return this.#list.map(([k, v]) => encodeForm(k) + "=" + encodeForm(v)).join("&"); }
}

const special = { "http:": "80", "https:": "443", "ftp:": "21", "ws:": "80", "wss:": "443", "file:": "" };
const absolute = /^([a-z][a-z0-9+.-]*:)(.*)$/i;
const blobUrls = new Map();
$.blobUrls = blobUrls;

function dotSegments(path) {
  const out = [];
  const parts = path.split("/");
  for (let i = 0; i < parts.length; i++) {
    const p = parts[i];
    if (p === "." || p.toLowerCase() === "%2e") { if (i === parts.length - 1) out.push(""); continue; }
    if (p === ".." || /^(\.|%2e){2}$/i.test(p)) { if (out.length > 1) out.pop(); if (i === parts.length - 1) out.push(""); continue; }
    out.push(p);
  }
  return out.join("/");
}
function encodePart(s, re) { return s.replace(re, (c) => encodeURIComponent(c)); }
function parseAbsolute(s) {
  const m = absolute.exec(s);
  if (!m) return null;
  const u = { protocol: m[1].toLowerCase(), username: "", password: "", hostname: "", port: "", pathname: "", search: "", hash: "" };
  let rest = m[2];
  const h = rest.indexOf("#");
  if (h >= 0) { u.hash = rest.slice(h); rest = rest.slice(0, h); }
  const q = rest.indexOf("?");
  if (q >= 0) { u.search = rest.slice(q); rest = rest.slice(0, q); }
  const isSpecial = u.protocol in special;
  if (isSpecial) rest = rest.replace(/\\/g, "/");
  if (rest.startsWith("//") || (isSpecial && u.protocol !== "file:")) {
    rest = rest.replace(/^\/*/, "");
    const slash = rest.indexOf("/");
    let auth = slash < 0 ? rest : rest.slice(0, slash);
    u.pathname = slash < 0 ? "" : rest.slice(slash);
    const at = auth.lastIndexOf("@");
    if (at >= 0) {
      const cred = auth.slice(0, at);
      auth = auth.slice(at + 1);
      const c = cred.indexOf(":");
      u.username = c < 0 ? cred : cred.slice(0, c);
      u.password = c < 0 ? "" : cred.slice(c + 1);
    }
    const port = /:(\d*)$/.exec(auth);
    if (port) { auth = auth.slice(0, port.index); u.port = port[1]; }
    else if (/:[^\]]*$/.test(auth)) return null;
    if (isSpecial && !auth && u.protocol !== "file:") return null;
    u.hostname = isSpecial ? auth.toLowerCase() : auth;
    if (/[\s<>^|%]/.test(u.hostname)) return null;
    if (u.port === special[u.protocol]) u.port = "";
    if (isSpecial && !u.pathname) u.pathname = "/";
    u.hier = true;
  } else {
    u.pathname = rest;
    u.hier = rest.startsWith("/");
  }
  if (u.hier || isSpecial) u.pathname = dotSegments(u.pathname);
  u.pathname = encodePart(u.pathname, /[\s"<>`{}\u0080-\uFFFF]/g);
  u.search = encodePart(u.search, /[\s"<>\u0080-\uFFFF]/g);
  u.hash = encodePart(u.hash, /[\s"<>`\u0080-\uFFFF]/g);
  if (u.search === "?") u.search = "";
  if (u.hash === "#") u.hash = "";
  return u;
}
function resolveAgainst(ref, base) {
  ref = String(ref).trim();
  if (absolute.test(ref) && !/^[a-z][a-z0-9+.-]*:[^/]*$/i.test(ref.replace(/[?#].*$/, "") + "/")) return parseAbsolute(ref);
  const m = absolute.exec(ref);
  if (m && !(m[1].toLowerCase() in special && base.protocol === m[1].toLowerCase() && !m[2].startsWith("/"))) return parseAbsolute(ref);
  const u = Object.assign({}, base);
  u.hash = ""; u.search = "";
  if (m) ref = m[2];
  if (!ref) { u.search = base.search; return u; }
  if (ref[0] === "#") { u.search = base.search; u.hash = ref; return normalizeTail(u); }
  if (ref[0] === "?") { const h = ref.indexOf("#"); u.search = h < 0 ? ref : ref.slice(0, h); u.hash = h < 0 ? "" : ref.slice(h); return normalizeTail(u); }
  if (ref.startsWith("//")) return parseAbsolute(base.protocol + ref);
  const h = ref.indexOf("#"); if (h >= 0) { u.hash = ref.slice(h); ref = ref.slice(0, h); }
  const q = ref.indexOf("?"); if (q >= 0) { u.search = ref.slice(q); ref = ref.slice(0, q); }
  u.pathname = ref[0] === "/" ? ref : base.pathname.slice(0, base.pathname.lastIndexOf("/") + 1) + ref;
  u.pathname = encodePart(dotSegments(u.pathname.replace(/\\/g, "/")), /[\s"<>`{}\u0080-\uFFFF]/g);
  return normalizeTail(u);
}
function normalizeTail(u) {
  u.search = encodePart(u.search, /[\s"<>\u0080-\uFFFF]/g);
  u.hash = encodePart(u.hash, /[\s"<>`\u0080-\uFFFF]/g);
  if (u.search === "?") u.search = "";
  if (u.hash === "#") u.hash = "";
  return u;
}
const invalid = (s) => new TypeError("Failed to construct 'URL': Invalid URL: " + s);
class URL {
  #u; #params = null;
  constructor(url, base) {
    if (arguments.length === 0) throw new TypeError("Failed to construct 'URL': 1 argument required");
    url = String(url);
    if (base !== undefined) {
      const b = parseAbsolute(String(base));
      if (!b) throw invalid(base);
      this.#u = resolveAgainst(url, b);
    } else this.#u = parseAbsolute(url.trim());
    if (!this.#u) throw invalid(url);
  }
  _setQuery(q) { this.#u.search = q ? "?" + q : ""; }
  get href() {
    const u = this.#u;
    const cred = u.username ? u.username + (u.password ? ":" + u.password : "") + "@" : "";
    const authority = u.hier && (u.hostname || u.protocol === "file:" || u.protocol in special) ? "//" + cred + this.host : "";
    return u.protocol + authority + u.pathname + u.search + u.hash;
  }
  set href(v) { const n = parseAbsolute(String(v)); if (!n) throw invalid(v); this.#u = n; if (this.#params) this.#params._parse(n.search); }
  get origin() { const u = this.#u; return u.protocol in special && u.protocol !== "file:" ? u.protocol + "//" + this.host : "null"; }
  get protocol() { return this.#u.protocol; }
  set protocol(v) { v = String(v); this.#u.protocol = (v.endsWith(":") ? v : v + ":").toLowerCase(); }
  get username() { return this.#u.username; }
  set username(v) { this.#u.username = encodeURIComponent(String(v)); }
  get password() { return this.#u.password; }
  set password(v) { this.#u.password = encodeURIComponent(String(v)); }
  get host() { const u = this.#u; return u.hostname + (u.port ? ":" + u.port : ""); }
  set host(v) { const [h, p] = String(v).split(":"); this.#u.hostname = h.toLowerCase(); if (p !== undefined) this.port = p; }
  get hostname() { return this.#u.hostname; }
  set hostname(v) { this.#u.hostname = String(v).toLowerCase(); }
  get port() { return this.#u.port; }
  set port(v) { v = String(v); this.#u.port = v === special[this.#u.protocol] ? "" : v; }
  get pathname() { return this.#u.pathname; }
  set pathname(v) { v = String(v); this.#u.pathname = dotSegments(encodePart(v[0] === "/" ? v : "/" + v, /[\s"<>`{}\u0080-\uFFFF]/g)); }
  get search() { return this.#u.search; }
  set search(v) { v = String(v); this.#u.search = !v || v === "?" ? "" : encodePart(v[0] === "?" ? v : "?" + v, /[\s"<>\u0080-\uFFFF]/g); if (this.#params) this.#params._parse(this.#u.search); }
  get hash() { return this.#u.hash; }
  set hash(v) { v = String(v); this.#u.hash = !v || v === "#" ? "" : encodePart(v[0] === "#" ? v : "#" + v, /[\s"<>`\u0080-\uFFFF]/g); }
  get searchParams() {
    if (!this.#params) {
      this.#params = new URLSearchParams(this.#u.search);
      this.#params[OWNER] = this;
    }
    return this.#params;
  }
  toString() { return this.href; }
  toJSON() { return this.href; }
  static canParse(url, base) { try { new URL(url, base); return true; } catch (e) { return false; } }
  static parse(url, base) { try { return new URL(url, base); } catch (e) { return null; } }
  static createObjectURL(blob) {
    const id = "blob:" + g.location.origin + "/" + g.crypto.randomUUID();
    blobUrls.set(id, blob);
    return id;
  }
  static revokeObjectURL(id) { blobUrls.delete(String(id)); }
}
def(g, "URL", URL);
def(g, "webkitURL", URL);
def(g, "URLSearchParams", URLSearchParams);
})

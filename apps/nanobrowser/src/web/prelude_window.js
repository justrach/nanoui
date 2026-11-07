// The window: its names for itself, location, history, navigator, screen, console,
// performance, matchMedia, crypto, customElements, storage and the small functions.
(function ($, g) {
"use strict";
const def = $.def;
const accessor = (o, name, get, set) => Object.defineProperty(o, name, { get, set, configurable: true, enumerable: true });
const document = $.document;

Object.setPrototypeOf(g, Window.prototype);
// Elements by id, as globals: the "named properties object" of the window's
// prototype chain, so anything a script declares wins over them.
const names = Object.create(EventTarget.prototype);
Object.setPrototypeOf(Window.prototype, new Proxy(names, {
  get(t, k, r) {
    if (typeof k === "string" && !(k in t)) {
      const e = $.document.getElementById(k);
      if (e) return e;
    }
    return Reflect.get(t, k, r);
  },
  has(t, k) { return k in t || (typeof k === "string" && $.document.getElementById(k) !== null); },
}));
for (const name of ["window", "self"]) Object.defineProperty(g, name, { value: g, writable: true, configurable: true, enumerable: true });
// Above a frame are other windows (`api_frames.zig`); the top is its own parent.
const nearWindow = (name) => Object.defineProperty(g, name, { get() { return $.isFramed() ? $.relative(name) : g; }, set(v) { Object.defineProperty(g, name, { value: v, writable: true, configurable: true, enumerable: true }); }, configurable: true, enumerable: true });
nearWindow("top");
nearWindow("parent");
const framesList = () => {
  const list = $.framesOf();
  const out = { length: list.length / 2, window: g };
  for (let i = 0; i < list.length; i += 2) {
    out[i / 2] = list[i];
    if (list[i + 1]) out[list[i + 1]] = list[i];
  }
  return out;
};
Object.defineProperty(g, "frames", { get() { return $.framesCount() ? framesList() : g; }, set(v) { Object.defineProperty(g, "frames", { value: v, writable: true, configurable: true, enumerable: true }); }, configurable: true, enumerable: true });
Object.defineProperty(g, "document", { value: document, enumerable: true, configurable: true });
def(g, "event", undefined);
g.name = $.frameName();
Object.defineProperty(g, "length", { get() { return $.framesCount(); }, set(v) { Object.defineProperty(g, "length", { value: v, writable: true, configurable: true, enumerable: true }); }, configurable: true, enumerable: true });
g.opener = null;
Object.defineProperty(g, "frameElement", { get() { return $.frameElement(); }, configurable: true, enumerable: true });
g.closed = false;
g.isSecureContext = true;
g.origin = $.originOf($.splitUrl($.pageUrl()));
g.status = "";
g.external = {};

// Location.
const split = () => $.splitUrl($.pageUrl());
function goHash(to, push) {
  const from = $.pageUrl();
  if (to === from) return;
  if (push) histPush(to);
  $.setUrl(to, push);
  const h = $.splitUrl(to).hash;
  $.fragment(h ? decodeURIComponent(h.slice(1)) : "");
  g.setTimeout(() => {
    const pop = new PopStateEvent("popstate", { state: null });
    pop.isTrusted = true;
    $.dispatch(g, pop);
    const e = new HashChangeEvent("hashchange", { oldURL: from, newURL: to });
    e.isTrusted = true;
    $.dispatch(g, e);
  }, 0);
}
const samePage = (a, b) => a.split("#")[0] === b.split("#")[0];
function goTo(url, replace) {
  const to = $.resolveUrl(String(url));
  if (to === null) throw new DOMException("'" + url + "' is not a valid URL.", "SyntaxError");
  if (to.toLowerCase().startsWith("javascript:")) { (0, eval)(decodeURIComponent(to.slice(11))); return; }
  if (samePage(to, $.pageUrl()) && to.includes("#")) return goHash(to, !replace);
  $.navigate(to, false);
}
$.hook("hashChanged", (to) => goHash(to, true));
class Location {
  get href() { return $.pageUrl(); }
  set href(v) { goTo(v, false); }
  get protocol() { return split().protocol; }
  set protocol(v) { const u = split(); u.protocol = String(v).endsWith(":") ? String(v) : v + ":"; goTo($.joinUrl(u)); }
  get host() { const u = split(); return u.hostname + (u.port ? ":" + u.port : ""); }
  set host(v) { const u = split(); const [h, p] = String(v).split(":"); u.hostname = h; u.port = p || ""; goTo($.joinUrl(u)); }
  get hostname() { return split().hostname; }
  set hostname(v) { const u = split(); u.hostname = String(v); goTo($.joinUrl(u)); }
  get port() { return split().port; }
  set port(v) { const u = split(); u.port = String(v); goTo($.joinUrl(u)); }
  get pathname() { return split().pathname; }
  set pathname(v) { const u = split(); u.pathname = String(v).startsWith("/") ? String(v) : "/" + v; u.search = ""; u.hash = ""; goTo($.joinUrl(u)); }
  get search() { return split().search; }
  set search(v) { const u = split(); v = String(v); u.search = !v || v === "?" ? "" : v.startsWith("?") ? v : "?" + v; u.hash = ""; goTo($.joinUrl(u)); }
  get hash() { return split().hash; }
  set hash(v) { const u = split(); v = String(v); u.hash = !v || v === "#" ? "" : v.startsWith("#") ? v : "#" + v; goTo($.joinUrl(u)); }
  get origin() { return $.originOf(split()); }
  get ancestorOrigins() { return []; }
  assign(url) { goTo(url, false); }
  replace(url) { goTo(url, true); }
  reload() { $.navigate($.pageUrl(), false); }
  toString() { return $.pageUrl(); }
}
def(g, "Location", Location);
// What our user agent string claims, said the way Chromium says it.
const chromeMajor = /Chrome\/(\d+)/.exec($.userAgent)[1];
const userAgentData = {
  brands: [{ brand: "Chromium", version: chromeMajor }, { brand: "Not_A Brand", version: "99" }],
  mobile: false,
  platform: ({ MacIntel: "macOS", Win32: "Windows", iPhone: "iOS" })[$.platform] || "Linux",
  getHighEntropyValues(hints) {
    const known = { architecture: "arm", bitness: "64", model: "", platformVersion: "10.15.7", uaFullVersion: chromeMajor + ".0.0.0", fullVersionList: this.brands.map((b) => ({ brand: b.brand, version: b.version + ".0.0.0" })), wow64: false, formFactors: ["Desktop"] };
    const out = { brands: this.brands, mobile: this.mobile, platform: this.platform };
    for (const h of hints || []) if (h in known) out[h] = known[h];
    return Promise.resolve(out);
  },
  toJSON() { return { brands: this.brands, mobile: this.mobile, platform: this.platform }; },
};
if (!("chrome" in g)) g.chrome = { app: { isInstalled: false, InstallState: { DISABLED: "disabled", INSTALLED: "installed", NOT_INSTALLED: "not_installed" }, RunningState: { CANNOT_RUN: "cannot_run", READY_TO_RUN: "ready_to_run", RUNNING: "running" } }, runtime: {}, csi() { return {}; }, loadTimes() { return {}; } };
const location = new Location();
Object.defineProperty(g, "location", { get() { return location; }, set(v) { goTo(v, false); }, enumerable: true, configurable: true });
accessor(Document.prototype, "location", function () { return this === document ? location : null; }, function (v) { goTo(v, false); });

// History: same-document entries here, the tab's going back and forward past them.
const entries = [{ state: null, url: $.pageUrl() }];
let at = 0;
function histPush(url) {
  entries.length = at + 1;
  entries.push({ state: null, url });
  at++;
}
const cloneState = (s) => (s === undefined || s === null ? null : typeof s === "object" ? g.structuredClone(s) : s);
function historyUrl(url) {
  if (url === undefined || url === null) return $.pageUrl();
  const to = $.resolveUrl(String(url));
  if (to === null) throw new DOMException("The URL is invalid.", "SyntaxError");
  const here = split(), there = $.splitUrl(to);
  if (there.protocol !== here.protocol || there.hostname !== here.hostname || there.port !== here.port) throw new DOMException("A history state object with URL '" + to + "' cannot be created in a document with origin '" + location.origin + "'.", "SecurityError");
  return to;
}
class History {
  get length() { return entries.length; }
  get state() { return entries[at].state; }
  get scrollRestoration() { return "auto"; }
  set scrollRestoration(v) {}
  pushState(state, title, url) {
    const to = historyUrl(url);
    histPush(to);
    entries[at].state = cloneState(state);
    $.setUrl(to, true);
  }
  replaceState(state, title, url) {
    const to = historyUrl(url);
    entries[at] = { state: cloneState(state), url: to };
    $.setUrl(to, false);
  }
  go(n = 0) {
    n = n | 0;
    if (n === 0) return location.reload();
    // The tab holds the entries too: it goes, and steps this document's own
    // back through `historyStep`, or loads what is before it.
    $.historyGo(n);
  }
  back() { this.go(-1); }
  forward() { this.go(1); }
}
def(g, "History", History);
const history = new History();
Object.defineProperty(g, "history", { value: history, enumerable: true, configurable: true });

$.hook("historyStep", (by) => {
  const to = at + by;
  if (to < 0 || to >= entries.length) return;
  const from = $.pageUrl();
  at = to;
  $.setUrl(entries[at].url, false);
  const ev = new PopStateEvent("popstate", { state: entries[at].state });
  ev.isTrusted = true;
  $.dispatch(g, ev);
  if (samePage(from, entries[at].url) && from !== entries[at].url) {
    const h = new HashChangeEvent("hashchange", { oldURL: from, newURL: entries[at].url });
    h.isTrusted = true;
    $.dispatch(g, h);
  }
});

// Navigator, screen.
class Navigator {
  get userAgent() { return $.userAgent; }
  get appName() { return "Netscape"; }
  get appCodeName() { return "Mozilla"; }
  get appVersion() { return $.userAgent.slice(8); }
  get product() { return "Gecko"; }
  get productSub() { return "20030107"; }
  get vendor() { return ""; }
  get vendorSub() { return ""; }
  get language() { return "en-US"; }
  get languages() { return ["en-US", "en"]; }
  get platform() { return $.platform; }
  get onLine() { return true; }
  get cookieEnabled() { return true; }
  get hardwareConcurrency() { return 4; }
  get deviceMemory() { return 8; }
  get maxTouchPoints() { return 0; }
  get doNotTrack() { return null; }
  get webdriver() { return false; }
  get pdfViewerEnabled() { return false; }
  get plugins() { return []; }
  get mimeTypes() { return []; }
  get connection() { return { effectiveType: "4g", downlink: 10, rtt: 50, saveData: false, addEventListener() {}, removeEventListener() {} }; }
  get clipboard() { return clipboard; }
  get userActivation() { return { hasBeenActive: true, isActive: false }; }
  get userAgentData() { return userAgentData; }
  get vendor() { return "Google Inc."; }
  get mediaDevices() { return undefined; }
  sendBeacon(url, body) {
    try { g.fetch(url, { method: "POST", body, keepalive: true }).catch(() => {}); return true; } catch (e) { return false; }
  }
  javaEnabled() { return false; }
  vibrate() { return false; }
  share() { return Promise.reject(new DOMException("Sharing is not available.", "NotAllowedError")); }
  canShare() { return false; }
  // No battery backend: leave getBattery absent so feature detection can fall back.
  getGamepads() { return []; }
  registerProtocolHandler() {}
}
// The system's clipboard isn't a page's to read or write.
const clipboard = {
  readText() { return Promise.reject(new DOMException("The clipboard is not available to pages.", "NotAllowedError")); },
  writeText() { return Promise.reject(new DOMException("The clipboard is not available to pages.", "NotAllowedError")); },
  read() { return Promise.reject(new DOMException("The clipboard is not available to pages.", "NotAllowedError")); },
  write() { return Promise.reject(new DOMException("The clipboard is not available to pages.", "NotAllowedError")); },
  addEventListener() {}, removeEventListener() {},
};
def(g, "Navigator", Navigator);
Object.defineProperty(g, "navigator", { value: new Navigator(), enumerable: true, configurable: true });
g.clientInformation = g.navigator;
const screenObject = {
  get width() { return g.innerWidth; }, get height() { return g.innerHeight; },
  get availWidth() { return g.innerWidth; }, get availHeight() { return g.innerHeight; },
  availLeft: 0, availTop: 0, colorDepth: 24, pixelDepth: 24,
  orientation: { type: "landscape-primary", angle: 0, addEventListener() {}, removeEventListener() {}, lock() { return Promise.reject(new Error("not available")); }, unlock() {} },
};
Object.defineProperty(g, "screen", { value: screenObject, enumerable: true, configurable: true });
g.screenX = 0; g.screenY = 0; g.screenLeft = 0; g.screenTop = 0;
g.visualViewport = { get width() { return g.innerWidth; }, get height() { return g.innerHeight; }, offsetLeft: 0, offsetTop: 0, get pageLeft() { return g.scrollX; }, get pageTop() { return g.scrollY; }, scale: 1, addEventListener() {}, removeEventListener() {} };
g.locationbar = g.menubar = g.personalbar = g.scrollbars = g.statusbar = g.toolbar = { visible: true };

// The console: the text goes to the page's list, which `NANOBROWSER_LOG` also prints.
function inspect(v, depth = 0, seen = []) {
  if (typeof v === "string") return depth === 0 ? v : JSON.stringify(v);
  if (v === null || typeof v !== "object" && typeof v !== "function") return String(v);
  if (typeof v === "function") return "[Function: " + (v.name || "anonymous") + "]";
  if (v instanceof Error) return v.stack || `${v.name}: ${v.message}`;
  if ($.isNode(v)) return v.nodeType === 1 ? "<" + v.tagName.toLowerCase() + ">" : v.nodeName;
  if (seen.includes(v)) return "[Circular]";
  if (depth > 2) return Array.isArray(v) ? "[Array]" : "[Object]";
  seen = seen.concat([v]);
  try {
    if (Array.isArray(v)) return "[" + v.slice(0, 50).map((x) => inspect(x, depth + 1, seen)).join(", ") + "]";
    if (v instanceof Date) return v.toISOString();
    if (v instanceof RegExp) return String(v);
    if (v instanceof Map) return "Map(" + v.size + ")";
    if (v instanceof Set) return "Set(" + v.size + ")";
    const keys = Object.keys(v).slice(0, 30);
    const name = v.constructor && v.constructor.name && v.constructor !== Object ? v.constructor.name + " " : "";
    return name + "{" + keys.map((k) => k + ": " + inspect(v[k], depth + 1, seen)).join(", ") + "}";
  } catch (e) { return "[object]"; }
}
function formatArgs(args) {
  let out = "", i = 0;
  if (typeof args[0] === "string" && args[0].includes("%")) {
    i = 1;
    out = args[0].replace(/%[sdifoOc%]/g, (m) => {
      if (m === "%%") return "%";
      if (i >= args.length) return m;
      const a = args[i++];
      if (m === "%c") return "";
      if (m === "%d" || m === "%i") return String(parseInt(a, 10));
      if (m === "%f") return String(parseFloat(a));
      return inspect(a, m === "%s" ? 0 : 1);
    });
  }
  for (; i < args.length; i++) out += (out ? " " : "") + inspect(args[i]);
  return out;
}
let indent = "";
const line = (level, args) => $.log(level, indent + formatArgs(args));
const counts = new Map(), times = new Map();
const consoleObject = {
  log(...a) { line(1, a); }, info(...a) { line(1, a); }, debug(...a) { line(0, a); },
  warn(...a) { line(2, a); }, error(...a) { line(3, a); },
  trace(...a) { line(1, ["Trace", ...a]); },
  dir(a) { line(1, [a]); }, dirxml(...a) { line(1, a); },
  table(a) { line(1, [a]); },
  group(...a) { if (a.length) line(1, a); indent += "  "; },
  groupCollapsed(...a) { if (a.length) line(1, a); indent += "  "; },
  groupEnd() { indent = indent.slice(2); },
  time(l = "default") { times.set(l, $.now()); },
  timeLog(l = "default", ...a) { line(1, [l + ": " + ($.now() - (times.get(l) || 0)).toFixed(3) + "ms", ...a]); },
  timeEnd(l = "default") { line(1, [l + ": " + ($.now() - (times.get(l) || 0)).toFixed(3) + "ms"]); times.delete(l); },
  timeStamp() {},
  count(l = "default") { const n = (counts.get(l) || 0) + 1; counts.set(l, n); line(1, [l + ": " + n]); },
  countReset(l = "default") { counts.delete(l); },
  assert(c, ...a) { if (!c) line(3, ["Assertion failed:", ...a]); },
  clear() {},
  profile() {}, profileEnd() {},
};
def(g, "console", consoleObject);

// Performance.
const timeOrigin = Date.now() - $.now();
const perfEntries = [];
class PerformanceEntry { constructor(name, entryType, startTime, duration, detail) { this.name = name; this.entryType = entryType; this.startTime = startTime; this.duration = duration; this.detail = detail === undefined ? null : detail; } toJSON() { return Object.assign({}, this); } }
const performance = {
  now() { return $.now(); },
  timeOrigin,
  timing: { get navigationStart() { return timeOrigin; }, get loadEventEnd() { return timeOrigin; }, get domComplete() { return timeOrigin; }, get domContentLoadedEventEnd() { return timeOrigin; }, get responseStart() { return timeOrigin; }, get requestStart() { return timeOrigin; }, get domInteractive() { return timeOrigin; }, get fetchStart() { return timeOrigin; }, get connectEnd() { return timeOrigin; } },
  navigation: { type: 0, redirectCount: 0 },
  memory: { usedJSHeapSize: 0, totalJSHeapSize: 0, jsHeapSizeLimit: 0 },
  mark(name, o) { const e = new PerformanceEntry(String(name), "mark", o && o.startTime !== undefined ? o.startTime : $.now(), 0, o && o.detail); perfEntries.push(e); return e; },
  measure(name, a, b) {
    const time = (x, dflt) => { if (x === undefined) return dflt; if (typeof x === "number") return x; if (x in performance.timing) return 0; for (let i = perfEntries.length - 1; i >= 0; i--) if (perfEntries[i].name === x) return perfEntries[i].startTime; throw new DOMException("The mark '" + x + "' does not exist.", "SyntaxError"); };
    let start, end, detail;
    if (a && typeof a === "object") { start = time(a.start, 0); end = time(a.end, $.now()); detail = a.detail; } else { start = time(a, 0); end = time(b, $.now()); }
    const e = new PerformanceEntry(String(name), "measure", start, end - start, detail);
    perfEntries.push(e);
    return e;
  },
  getEntries() { return perfEntries.slice(); },
  getEntriesByType(t) { return perfEntries.filter((e) => e.entryType === t); },
  getEntriesByName(n, t) { return perfEntries.filter((e) => e.name === n && (!t || e.entryType === t)); },
  clearMarks(n) { for (let i = perfEntries.length - 1; i >= 0; i--) if (perfEntries[i].entryType === "mark" && (!n || perfEntries[i].name === n)) perfEntries.splice(i, 1); },
  clearMeasures(n) { for (let i = perfEntries.length - 1; i >= 0; i--) if (perfEntries[i].entryType === "measure" && (!n || perfEntries[i].name === n)) perfEntries.splice(i, 1); },
  clearResourceTimings() {}, setResourceTimingBufferSize() {},
  addEventListener() {}, removeEventListener() {},
  toJSON() { return { timeOrigin }; },
};
Object.defineProperty(g, "performance", { value: performance, enumerable: true, configurable: true });
def(g, "PerformanceEntry", PerformanceEntry);
class PerformanceNavigation { constructor() { this.type = 0; this.redirectCount = 0; } toJSON() { return { type: this.type, redirectCount: this.redirectCount }; } }
Object.assign(PerformanceNavigation, { TYPE_NAVIGATE: 0, TYPE_RELOAD: 1, TYPE_BACK_FORWARD: 2, TYPE_RESERVED: 255 });
Object.assign(PerformanceNavigation.prototype, { TYPE_NAVIGATE: 0, TYPE_RELOAD: 1, TYPE_BACK_FORWARD: 2, TYPE_RESERVED: 255 });
def(g, "PerformanceNavigation", PerformanceNavigation);
if (!performance.navigation) performance.navigation = new PerformanceNavigation();
class PerformanceObserver { constructor(cb) { this.cb = cb; } observe() {} disconnect() {} takeRecords() { return []; } static get supportedEntryTypes() { return []; } }
def(g, "PerformanceObserver", PerformanceObserver);
for (const c of [PerformanceEntry, PerformanceNavigation, class PerformanceTiming {}, class PerformanceResourceTiming extends PerformanceEntry {}, class PerformanceNavigationTiming extends PerformanceEntry {}, class PerformanceMark extends PerformanceEntry {}, class PerformanceMeasure extends PerformanceEntry {}, class PerformancePaintTiming extends PerformanceEntry {}]) def(g, c.name, c);

// matchMedia, its `change` events from a viewport or theme change.
const mediaLists = new Set();
class MediaQueryList extends EventTarget {
  #media; #matches; #onchange = null;
  constructor(media) { super(); this.#media = media; this.#matches = $.mediaMatches(media); }
  get media() { return this.#media; }
  get matches() { return $.mediaMatches(this.#media); }
  get onchange() { return this.#onchange; }
  set onchange(f) { if (this.#onchange) this.removeEventListener("change", this.#onchange); this.#onchange = f; if (f) { this.addEventListener("change", f); mediaLists.add(this); } }
  addListener(f) { this.addEventListener("change", f); mediaLists.add(this); }
  removeListener(f) { this.removeEventListener("change", f); }
  addEventListener(t, f, o) { super.addEventListener(t, f, o); mediaLists.add(this); }
  _check() {
    const now = $.mediaMatches(this.#media);
    if (now === this.#matches) return;
    this.#matches = now;
    this.dispatchEvent(new g.MediaQueryListEvent("change", { media: this.#media, matches: now }));
  }
}
def(g, "MediaQueryList", MediaQueryList);
def(g, "MediaQueryListEvent", class MediaQueryListEvent extends Event { constructor(t, i) { super(t, i); this.media = i && i.media || ""; this.matches = !!(i && i.matches); } });
g.matchMedia = function matchMedia(q) { return new MediaQueryList(String(q)); };
$.hook("viewportChanged", () => {
  for (const m of mediaLists) m._check();
  const e = new Event("resize"); e.isTrusted = true;
  $.dispatch(g, e);
});

// Crypto. Nothing subtle is offered: `crypto.subtle` is absent.
const hex = [];
for (let i = 0; i < 256; i++) hex.push((i + 256).toString(16).slice(1));
const crypto = {
  getRandomValues(a) { return $.randomFill(a); },
  randomUUID() {
    const b = $.randomFill(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    let s = "";
    for (let i = 0; i < 16; i++) { s += hex[b[i]]; if (i === 3 || i === 5 || i === 7 || i === 9) s += "-"; }
    return s;
  },
};
Object.defineProperty(g, "crypto", { value: crypto, enumerable: true, configurable: true });

// Custom elements.
const nameRe = /^[a-z][-.\d_a-z\u00B7\u00C0-\u{10FFFF}]*-[-.\d_a-z\u00B7\u00C0-\u{10FFFF}]*$/u;
const waiting = new Map(), ctors = new Map();
class CustomElementRegistry {
  define(name, ctor, opts) {
    name = String(name);
    if (typeof ctor !== "function") throw new TypeError("The element constructor is not a function.");
    if (!nameRe.test(name)) throw new DOMException("'" + name + "' is not a valid custom element name", "SyntaxError");
    const p = ctor.prototype;
    if (opts && opts.extends) { ctors.set(name, ctor); return; }
    const cb = (n) => { const f = p[n]; return typeof f === "function" ? f : undefined; };
    const attrs = ctor.observedAttributes;
    $.ceDefine(name, ctor, cb("connectedCallback"), cb("disconnectedCallback"), cb("attributeChangedCallback"), attrs ? Array.from(attrs) : []);
    ctors.set(name, ctor);
    const w = waiting.get(name);
    if (w) { waiting.delete(name); for (const r of w.res) r(ctor); }
  }
  get(name) { return ctors.get(String(name)); }
  getName(ctor) { for (const [k, v] of ctors) if (v === ctor) return k; return null; }
  whenDefined(name) {
    name = String(name);
    if (ctors.has(name)) return Promise.resolve(ctors.get(name));
    let w = waiting.get(name);
    if (!w) { w = { res: [], promise: null }; w.promise = new Promise((r) => w.res.push(r)); waiting.set(name, w); }
    return w.promise;
  }
  upgrade(root) { $.ceUpgrade(root); }
}
def(g, "CustomElementRegistry", CustomElementRegistry);
Object.defineProperty(g, "customElements", { value: new CustomElementRegistry(), enumerable: true, configurable: true });

// Storage for this origin.
const origin = g.origin;
let locals, sessions;
accessor(g, "localStorage", () => locals || (locals = $.storage("l", origin)));
accessor(g, "sessionStorage", () => sessions || (sessions = $.storage("s", origin)));

// Small functions.
g.requestIdleCallback = function requestIdleCallback(f, o) { const start = $.now(); return g.setTimeout(() => f({ didTimeout: false, timeRemaining() { return Math.max(0, 50 - ($.now() - start)); } }), 1); };
g.cancelIdleCallback = function cancelIdleCallback(id) { g.clearTimeout(id); };
g.alert = function alert() {};
g.confirm = function confirm() { return false; };
g.prompt = function prompt() { return null; };
g.print = function print() {};
g.stop = function stop() {};
g.focus = function focus() {};
g.blur = function blur() {};
g.close = function close() {};
g.moveTo = g.moveBy = g.resizeTo = g.resizeBy = function () {};
g.getMatchedCSSRules = undefined;
g.open = function open(url) {
  if (url !== undefined && url !== "") $.navigate(String(url), true);
  return null;
};
g.postMessage = function postMessage(data, target, transfer) {
  const from = $.callerPage();
  const want = typeof target === "object" && target ? target.targetOrigin : target;
  if (want !== undefined && want !== "*" && want !== "/" && String(want) !== ($.pageOrigin() === "null" ? "null" : new g.URL(String(want), location.href).origin)) { /* its own origin only */ }
  if (want !== undefined && want !== "*" && want !== "/" && $.pageOrigin() !== new g.URL(String(want), location.href).origin) return;
  // From a window of this origin in another world, whose objects come as proxies.
  const copy = from ? JSON.parse(JSON.stringify({ v: data })).v : g.structuredClone(data);
  const origin = from ? $.pageOrigin(from) : $.pageOrigin();
  const source = from ? $.windowOfPage(from) : g;
  g.setTimeout(() => {
    const e = new MessageEvent("message", { data: copy, origin, source, ports: $.transferred($.windowTransfer(target, transfer)) });
    e.isTrusted = true;
    $.dispatch(g, e);
  }, 0);
};
$.hook("deliverMessage", (text, origin, from) => {
  const m = $.unwire(text);
  const e = new MessageEvent("message", { data: m.data, ports: m.ports, origin, source: $.windowOfPage(from) });
  e.isTrusted = true;
  $.dispatch(g, e);
});
g.reportError = function reportError(e) { $.reportError(e); };
class BarProp {}
class Screen {}
for (const c of [BarProp, Screen]) def(g, c.name, c);

// What `instanceof` and `Object.prototype.toString` ask of interfaces. Libraries
// tell a DOM object from a plain one this way: Vue proxies only the plain.
for (const name of ["SVGAnimatedString", "SVGAnimatedLength", "SVGAnimatedRect", "DataTransfer", "Touch", "TouchList", "HTMLFormControlsCollection", "RadioNodeList", "HTMLOptionsCollection", "MimeType", "Plugin", "ImageData", "CanvasRenderingContext2D", "TextMetrics", "Path2D"]) {
  if (!(name in g)) def(g, name, { [name]: class {} }[name]);
}
for (const name of Object.getOwnPropertyNames(g)) {
  if (!/^(?:[A-Z][A-Za-z0-9]*(?:Element|Event|Observer|Entry|Record|List|Map|Collection|Declaration|Sheet|Rule|Registry)|Event|EventTarget|Node|Document|HTMLDocument|XMLDocument|DocumentFragment|ShadowRoot|DocumentType|CharacterData|Text|CDATASection|Comment|Attr|Window|Location|History|Navigator|Storage|DOMRect|DOMRectReadOnly|DOMPoint|DOMTokenList|DOMStringMap|DOMImplementation|DOMException)$/.test(name)) continue;
  const c = g[name];
  if (typeof c !== "function" || !c.prototype) continue;
  Object.defineProperty(c.prototype, Symbol.toStringTag, { value: name, configurable: true });
}
Object.defineProperty(document, Symbol.toStringTag, { value: "HTMLDocument", configurable: true });

// Speech recognition is an offer a page makes (Google's and YouTube's microphones
// are drawn if it's there); pressing it says what a browser with no permission says.
g.webkitSpeechRecognition = class webkitSpeechRecognition extends EventTarget {
  constructor() { super(); this.lang = ""; this.continuous = false; this.interimResults = false; this.maxAlternatives = 1; this.onerror = null; this.onend = null; this.onstart = null; this.onresult = null; }
  start() {
    setTimeout(() => {
      const fire = (name, props) => { const e = new Event(name); Object.assign(e, props); this.dispatchEvent(e); const f = this["on" + name]; if (typeof f === "function") f.call(this, e); };
      fire("error", { error: "not-allowed", message: "" });
      fire("end", {});
    }, 0);
  }
  stop() {}
  abort() {}
};
Object.defineProperty(g, "webkitSpeechRecognition", { enumerable: false });

// Audio is silent here, and offering it is what draws those same microphones: a
// context whose nodes connect and make no sound, never started.
class AudioNodeStub extends EventTarget {
  constructor(context) { super(); this.context = context; this.numberOfInputs = 1; this.numberOfOutputs = 1; this.channelCount = 2; }
  connect(to) { return to; }
  disconnect() {}
}
class AudioContext extends EventTarget {
  constructor() { super(); this.state = "suspended"; this.sampleRate = 44100; this.currentTime = 0; this.baseLatency = 0; this.onstatechange = null; this.destination = new AudioNodeStub(this); this.listener = {}; }
  resume() { return Promise.resolve(); }
  suspend() { return Promise.resolve(); }
  close() { this.state = "closed"; return Promise.resolve(); }
  decodeAudioData(bytes, ok, failed) { const e = new DOMException("Unable to decode audio data", "EncodingError"); if (failed) failed(e); return Promise.reject(e); }
}
for (const name of ["createGain", "createOscillator", "createBufferSource", "createAnalyser", "createBiquadFilter", "createDynamicsCompressor", "createScriptProcessor", "createMediaElementSource", "createMediaStreamSource", "createMediaStreamDestination", "createChannelSplitter", "createChannelMerger", "createDelay", "createPanner", "createStereoPanner", "createWaveShaper", "createConvolver"]) {
  def(AudioContext.prototype, name, function () {
    const param = { value: 0, defaultValue: 0, setValueAtTime() { return param; }, linearRampToValueAtTime() { return param; }, exponentialRampToValueAtTime() { return param; }, cancelScheduledValues() { return param; } };
    const n = new AudioNodeStub(this);
    return Object.assign(n, { gain: param, frequency: param, detune: param, Q: param, delayTime: param, pan: param, start() {}, stop() {}, frequencyBinCount: 1024, fftSize: 2048, getByteFrequencyData() {}, getByteTimeDomainData() {}, getFloatFrequencyData() {}, getFloatTimeDomainData() {} });
  });
}
def(AudioContext.prototype, "createBuffer", function (channels, length, rate) { return { numberOfChannels: channels, length, sampleRate: rate, duration: length / rate, getChannelData() { return new Float32Array(length); } }; });
def(g, "AudioContext", AudioContext);

// Things libraries feature-detect that aren't here on purpose stay undefined:
// WebSocket, Worker, ServiceWorker, IndexedDB, WebGL, WebRTC.
})

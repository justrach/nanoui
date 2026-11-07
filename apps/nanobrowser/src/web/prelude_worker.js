// `Worker`, and on a worker's own page what makes its global a worker's.
// See `api_worker.zig`; messages cross as `prelude_wire.js` writes them.
//
// What arrives from the worker is tagged by its first character: `!` an error,
// `.` it having run its first script, `#` it closing itself, the rest a message.
(function ($, g) {
"use strict";

// What a script names literally at its top: `importScripts` can't wait for the
// network here, so what it will ask for is loaded before the script runs.
function importsOf(text, base) {
  const out = [];
  const call = /importScripts\s*\(([^)]*)\)/g;
  for (let m; (m = call.exec(text));) {
    const literal = /(['"`])((?:(?!\1).)+)\1/g;
    for (let a; (a = literal.exec(m[1]));) {
      try { out.push(new g.URL(a[2], base).href); } catch (_) {}
    }
  }
  return [...new Set(out)];
}

const attr = (s) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");

class Worker extends g.EventTarget {
  #id; #held = []; #ran = false; #gone = false; #on = {};
  constructor(url, options) {
    super();
    if (arguments.length === 0) throw new TypeError("Failed to construct 'Worker': 1 argument required, but only 0 present.");
    const at = new g.URL(String(url), g.location.href);
    const local = at.protocol === "blob:" || at.protocol === "data:";
    if (!local && at.origin !== g.location.origin) throw new g.DOMException(`Script at '${at.href}' cannot be accessed from origin '${g.location.origin}'.`, "SecurityError");
    if (options && options.type === "module") throw new g.DOMException("Module workers are not available.", "NotSupportedError");
    // A worker made from text has the origin of the page that made it.
    const base = local ? g.location.href : at.href;
    this.#id = $.workerNew(base);
    live.set(this.#id, this);
    g.fetch(at.href).then((r) => {
      if (!r.ok) throw new Error(`${r.status}`);
      return r.text();
    }).then((text) => {
      if (this.#gone) return;
      const imports = importsOf(text, base);
      const scripts = imports.map((u) => `<script src="${attr(u)}"></script>`).join("");
      $.workerBoot(this.#id, `<!doctype html>${scripts}<script>__nanobrowserWorkerMain()</script>`, JSON.stringify({ text, imports, name: (options && options.name) || "" }));
    }).catch((e) => this.#fail(`Failed to load worker script: ${e && e.message}`));
  }
  #fail(message) {
    const e = new g.ErrorEvent("error", { message, cancelable: true });
    this.dispatchEvent(e);
  }
  #event(name, f) {
    if (this.#on[name]) this.removeEventListener(name, this.#on[name]);
    this.#on[name] = typeof f === "function" ? f : null;
    if (this.#on[name]) this.addEventListener(name, this.#on[name]);
  }
  get onmessage() { return this.#on.message || null; }
  set onmessage(f) { this.#event("message", f); }
  get onmessageerror() { return this.#on.messageerror || null; }
  set onmessageerror(f) { this.#event("messageerror", f); }
  get onerror() { return this.#on.error || null; }
  set onerror(f) { this.#event("error", f); }
  postMessage(data, transfer) {
    if (arguments.length === 0) throw new TypeError("Failed to execute 'postMessage' on 'Worker': 1 argument required, but only 0 present.");
    const text = $.wire(data, transfer);
    if (this.#gone) return;
    if (this.#ran) $.workerPost(this.#id, text);
    else this.#held.push(text);
  }
  terminate() {
    if (this.#gone) return;
    this.#gone = true;
    live.delete(this.#id);
    $.workerEnd(this.#id);
  }
  _arrived(text) {
    if (this.#gone) return;
    if (text === ".") {
      this.#ran = true;
      for (const t of this.#held) $.workerPost(this.#id, t);
      this.#held = [];
    } else if (text === "#") {
      this.terminate();
    } else if (text[0] === "!") {
      this.#fail(text.slice(1));
    } else {
      const m = $.unwire(text);
      this.dispatchEvent(new g.MessageEvent("message", { data: m.data, ports: m.ports }));
    }
  }
}
const live = new Map();
Object.defineProperty(Worker.prototype, "_arrived", { enumerable: false });

function installScope() {
  const parsed = JSON.parse($.workerSource());
  const loaded = new Set(parsed.imports);
  let handler = null;
  class WorkerGlobalScope { static [Symbol.hasInstance](o) { return o === g; } }
  class DedicatedWorkerGlobalScope extends WorkerGlobalScope {}
  for (const name of ["window", "document", "frames", "parent", "top", "opener", "frameElement", "alert", "confirm", "prompt", "open", "print", "history", "customElements", "localStorage", "sessionStorage", "screen", "getComputedStyle", "matchMedia"]) {
    try { delete g[name]; } catch (_) {}
    if (name in g) try { Object.defineProperty(g, name, { value: undefined, configurable: true, writable: true }); } catch (_) {}
  }
  const define = (name, value) => Object.defineProperty(g, name, { value, writable: true, configurable: true, enumerable: true });
  define("self", g);
  define("name", parsed.name);
  define("WorkerGlobalScope", WorkerGlobalScope);
  define("DedicatedWorkerGlobalScope", DedicatedWorkerGlobalScope);
  define("postMessage", function postMessage(data, transfer) {
    if (arguments.length === 0) throw new TypeError("Failed to execute 'postMessage' on 'DedicatedWorkerGlobalScope': 1 argument required, but only 0 present.");
    $.workerPost(0, $.wire(data, transfer));
  });
  define("close", function close() { $.workerEnd(0); });
  define("importScripts", function importScripts(...urls) {
    for (const u of urls) {
      const at = new g.URL(String(u), g.location.href).href;
      if (!loaded.has(at)) throw new g.DOMException(`The script at '${at}' failed to load: a worker here can only import what its script names literally.`, "NetworkError");
    }
  });
  Object.defineProperty(g, "onmessage", {
    configurable: true, enumerable: true,
    get() { return handler; },
    set(f) {
      if (handler) g.removeEventListener("message", handler);
      handler = typeof f === "function" ? f : null;
      if (handler) g.addEventListener("message", handler);
    },
  });
  g.addEventListener("error", (e) => $.workerPost(0, `!${e.message || "Script error."}`));
  $.hook("workerMessage", (_id, text) => {
    const m = $.unwire(text);
    const e = new g.MessageEvent("message", { data: m.data, ports: m.ports });
    e.isTrusted = true;
    $.dispatch(g, e);
  });
  define("__nanobrowserWorkerMain", function () {
    delete g.__nanobrowserWorkerMain;
    try {
      (0, eval)(parsed.text);
    } finally {
      // What's already sent reaches a script that has set its handler.
      $.workerPost(0, ".");
    }
  });
}

if ($.workerSelf()) installScope();
else $.hook("workerMessage", (id, text) => { const w = live.get(id); if (w) w._arrived(text); });
Object.defineProperty(g, "Worker", { value: Worker, writable: true, configurable: true, enumerable: false });
})

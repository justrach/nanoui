/// The page runtime, injected at document start into every page's main frame.
// It owns the wire protocol (see README): calls go out as JSON strings,
// replies and events come back batched through __nanoui.receive([...]).
(() => {
  if (window.nanoui) return;
  // The same page on each webview: WKWebView on macOS, WebView2 on Windows.
  // WebView2's `postMessage` takes the object and delivers it as JSON text to
  // the host (`get_WebMessageAsJson`), so the JSON goes out as an object.
  const webview2 = window.chrome && window.chrome.webview;
  const post = (m) =>
    webview2
      ? window.chrome.webview.postMessage(m)
      : window.webkit.messageHandlers.nanoui.postMessage(JSON.stringify(m));
  const pending = new Map();
  const listeners = new Map();
  let nextId = 1;

  const call = (method, ...args) =>
    new Promise((resolve, reject) => {
      const id = nextId++;
      pending.set(id, { resolve, reject });
      post({ t: "call", id, m: method, a: args });
    });

  const on = (name, fn) => {
    let set = listeners.get(name);
    if (!set) listeners.set(name, (set = new Set()));
    set.add(fn);
    return () => set.delete(fn);
  };
  const once = (name, fn) => {
    const off = on(name, (p) => {
      off();
      fn(p);
    });
    return off;
  };

  const receive = (messages) => {
    for (const m of messages) {
      if (m.t === "reply") {
        const p = pending.get(m.id);
        if (!p) continue;
        pending.delete(m.id);
        if (m.ok) p.resolve(m.v);
        else p.reject(new Error(m.e));
      } else if (m.t === "event") {
        const set = listeners.get(m.n);
        if (!set) continue;
        for (const fn of [...set]) {
          try {
            fn(m.p);
          } catch (e) {
            console.error(e);
          }
        }
      }
    }
  };

  // Prints to the app's stderr: for tests run with --nanoui-eval.
  const log = (...args) =>
    post({ t: "log", v: args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ") });

  const win = Object.freeze({
    close: () => post({ t: "win", op: "close" }),
    minimize: () => post({ t: "win", op: "minimize" }),
    toggleMaximize: () => post({ t: "win", op: "zoom" }),
    setTitle: (title) => post({ t: "win", op: "title", v: String(title) }),
    // Shows one of the app's pages (`window.__nanoui_pages`): 0 local, 1 remote.
    showPage: (id) => post({ t: "page", id: Number(id) }),
  });

  Object.defineProperty(window, "__nanoui", { value: Object.freeze({ receive }) });
  Object.defineProperty(window, "nanoui", {
    value: Object.freeze({ call, on, once, log, window: win, platform: "macos", version: "0.1.0" }),
  });

  const ready = () => post({ t: "dom-ready" });
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ready, { once: true });
  else ready();

  // The app's pages, as a switchable list: a bar in the corner of every
  // document, the app's own and every remote one. A page cannot navigate the
  // webview itself without losing the bridge that would bring it back, so
  // each entry asks the app (`win.showPage`) and the app navigates.
  const pages = () => window.__nanoui_pages || [];
  Object.defineProperty(window, "__nanoui_pages", { value: [], writable: true });

  const bar = () => {
    const list = pages();
    if (!list.length) return;
    const host = document.createElement("div");
    host.id = "__nanoui_bar";
    host.style.cssText = [
      "position:fixed", "bottom:12px", "right:12px", "z-index:2147483647",
      "display:flex", "gap:6px", "padding:6px", "border-radius:10px",
      "background:rgba(28,28,30,.86)", "backdrop-filter:blur(14px)",
      "box-shadow:0 6px 24px rgba(0,0,0,.28)", "font:13px -apple-system,'Segoe UI',system-ui,sans-serif",
    ].join(";");
    for (const p of list) {
      const b = document.createElement("button");
      b.textContent = p.title;
      b.style.cssText = [
        "font:inherit", "padding:5px 12px", "border-radius:7px", "cursor:pointer",
        p.current
          ? "background:#0071e3;border:1px solid #0071e3;color:#fff"
          : "background:transparent;border:1px solid rgba(255,255,255,.28);color:#f5f5f7",
      ].join(";");
      b.onclick = () => win.showPage(p.id);
      host.append(b);
    }
    document.documentElement.append(host);
  };

  // The app says which pages exist once the document is there.
  const setPages = (list) => {
    window.__nanoui_pages = list;
    document.getElementById("__nanoui_bar")?.remove();
    bar();
  };
  window.__nanoui_setPages = setPages;

  // Frameless windows: elements styled `--app-region: drag` move the window.
  document.addEventListener(
    "mousedown",
    (e) => {
      if (e.button !== 0) return;
      for (let el = e.target; el && el.nodeType === 1; el = el.parentElement) {
        const region = getComputedStyle(el).getPropertyValue("--app-region").trim();
        if (region === "no-drag") return;
        if (region === "drag") {
          post({ t: e.detail === 2 ? "dblclick" : "drag" });
          return;
        }
      }
    },
    true,
  );
})();

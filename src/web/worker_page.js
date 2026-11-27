// Page side of a Worker-hosted nanoui canvas. It transfers the canvas to
// worker.js, forwards DOM input and size, and supplies a fresh element when
// the Worker falls back to Canvas 2D after losing its GPU device.
import { bindInput } from "./input.js";

// Options: canvas (a visible element), worker (a module Worker running
// worker.js), url (the WASM command), cpuFallback, keyboard (as for start),
// canReplaceCanvas (returns or resolves false to decline a replacement) and
// onError. Returns { worker, canvas, ready, destroy }. ready rejects if the
// Worker fails to load or start, or is destroyed first.
export function startWorker({ canvas, worker, url, cpuFallback = false, keyboard, canReplaceCanvas = () => true, onError = console.error }) {
  let current = canvas, unbind, stopped = false;
  const scale = () => globalThis.devicePixelRatio ?? 1;
  const post = (message, transfer = []) => { if (!stopped) worker.postMessage(message, transfer); };
  const sink = {
    pointer: (...args) => post({ pointer: args }),
    pinch: (...args) => post({ pinch: args }),
    wheel: (...args) => post({ wheel: args }),
    key: (...args) => post({ key: args }),
    resize(width, height) {
      if (width === undefined) {
        const rect = current.getBoundingClientRect();
        width = Math.round(rect.width * scale());
        height = Math.round(rect.height * scale());
      }
      if (width > 0 && height > 0) post({ resize: [width, height, scale()] });
    },
  };
  const listen = () => {
    const element = current;
    const tabIndex = element.getAttribute("tabindex");
    if (keyboard && element.tabIndex < 0) element.tabIndex = 0;
    const off = bindInput(element, sink, { keyboard });
    unbind = () => {
      off();
      if (tabIndex === null) element.removeAttribute("tabindex");
      else element.setAttribute("tabindex", tabIndex);
    };
  };

  async function replace() {
    let offscreen = null;
    try {
      if (await canReplaceCanvas() !== false && !stopped) {
        // A canvas keeps its first context type, so Canvas 2D needs a new one.
        const next = current.cloneNode(false);
        const focused = current.ownerDocument.activeElement === current;
        offscreen = next.transferControlToOffscreen();
        unbind?.();
        // Copy the author's attributes after the input binding restores them.
        for (const name of ["style", "tabindex"]) {
          const value = current.getAttribute(name);
          if (value === null) next.removeAttribute(name);
          else next.setAttribute(name, value);
        }
        current.replaceWith(next);
        current = next;
        listen();
        if (focused) next.focus({ preventScroll: true });
      }
    } catch (error) {
      offscreen = null;
      onError(error);
    }
    post({ fallbackCanvas: offscreen }, offscreen ? [offscreen] : []);
  }

  let settle;
  const ready = new Promise((resolve, reject) => { settle = { resolve, reject }; });
  // Callers that never await ready still get errors through onError.
  ready.catch(() => {});
  let started = false;
  function fail(error) {
    if (!started) stop(error);
    onError(error);
  }
  const onMessage = ({ data }) => {
    if (data.ready) {
      started = true;
      settle.resolve();
    } else if (data.replaceCanvas) replace();
    else if (data.error) fail(new Error(data.error));
  };
  const onFailure = event => {
    event.preventDefault?.();
    fail(new Error(event.message || "The nanoui Worker failed to load"));
  };
  function stop(error) {
    stopped = true;
    unbind?.();
    settle.reject(error);
    worker.removeEventListener("message", onMessage);
    worker.removeEventListener("error", onFailure);
    worker.removeEventListener("messageerror", onFailure);
  }
  worker.addEventListener("message", onMessage);
  worker.addEventListener("error", onFailure);
  worker.addEventListener("messageerror", onFailure);
  try {
    const command = new URL(url, location.href).href;
    const rect = current.getBoundingClientRect();
    const offscreen = current.transferControlToOffscreen();
    post({
      canvas: offscreen, url: command, cpuFallback,
      width: Math.max(1, Math.round(rect.width * scale())), height: Math.max(1, Math.round(rect.height * scale())), scale: scale(),
    }, [offscreen]);
    listen();
  } catch (error) {
    stop(error);
    onError(error);
  }
  return {
    worker, ready,
    get canvas() { return current; },
    destroy() {
      if (stopped) return;
      try { worker.postMessage({ destroy: true }); }
      finally { stop(new Error("The Worker view was destroyed")); }
    },
  };
}

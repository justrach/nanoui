// Page side of a Worker-hosted nanoui canvas. It transfers the canvas to
// worker.js, forwards DOM input and size, and supplies a fresh element when
// the Worker falls back to Canvas 2D after losing its GPU device.
import { bindInput } from "./input.js";

// Options: canvas (a visible element), worker (a module Worker running
// worker.js), url (the WASM command), cpuFallback, keyboard (as for start),
// replaceCanvas (returns or resolves false to decline a replacement) and
// onError. Returns { worker, canvas, ready, destroy }.
export function startWorker({ canvas, worker, url, cpuFallback = false, keyboard, replaceCanvas = () => true, onError = console.error }) {
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
  const listen = () => { unbind = bindInput(current, sink, { keyboard }); };

  async function replace() {
    let offscreen = null;
    try {
      if (await replaceCanvas() !== false && !stopped) {
        // A canvas keeps its first context type, so Canvas 2D needs a new one.
        const next = current.cloneNode(false);
        const focused = current.ownerDocument.activeElement === current;
        offscreen = next.transferControlToOffscreen();
        unbind?.();
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
  worker.addEventListener("message", ({ data }) => {
    if (data.ready) settle.resolve();
    else if (data.replaceCanvas) replace();
    else if (data.error) {
      const error = new Error(data.error);
      settle.reject(error);
      onError(error);
    }
  });
  if (keyboard && current.tabIndex < 0) current.tabIndex = 0;
  const rect = current.getBoundingClientRect();
  const offscreen = current.transferControlToOffscreen();
  post({
    canvas: offscreen, url: new URL(url, location.href).href, cpuFallback,
    width: Math.max(1, Math.round(rect.width * scale())), height: Math.max(1, Math.round(rect.height * scale())), scale: scale(),
  }, [offscreen]);
  listen();
  return {
    worker, ready,
    get canvas() { return current; },
    destroy() {
      if (stopped) return;
      worker.postMessage({ destroy: true });
      stopped = true;
      unbind?.();
    },
  };
}

// File bytes come only from a browser picker opened by a user gesture.
export function createFilePicker(document) {
  let pending;
  let closed = false;
  return {
    pickFile({ accept = "", maxBytes = 16 * 1024 * 1024, signal } = {}) {
      if (closed) return Promise.reject(new Error("The nanoui host is closed"));
      if (pending) return Promise.reject(new DOMException("A file picker is already open", "InvalidStateError"));
      if (!Number.isSafeInteger(maxBytes) || maxBytes < 0)
        return Promise.reject(new RangeError("Invalid file size limit"));
      if (signal?.aborted) return Promise.reject(signal.reason);
      if (document.defaultView?.navigator.userActivation?.isActive === false)
        return Promise.reject(new DOMException("File picking needs a user gesture", "NotAllowedError"));
      return new Promise((resolve, reject) => {
        const input = document.createElement("input");
        input.type = "file";
        input.accept = accept;
        input.hidden = true;
        let settled = false;
        const finish = (value, error) => {
          if (settled) return;
          settled = true;
          pending = undefined;
          signal?.removeEventListener("abort", abort);
          input.remove();
          if (error) reject(error);
          else resolve(value);
        };
        const abort = () => finish(null, signal.reason ?? new DOMException("Aborted", "AbortError"));
        pending = () => finish(null);
        signal?.addEventListener("abort", abort, { once: true });
        input.addEventListener("cancel", () => finish(null), { once: true });
        input.addEventListener("change", async () => {
          const file = input.files?.[0];
          if (!file) return finish(null);
          if (file.size > maxBytes) return finish(null, new RangeError("The file exceeds the size limit"));
          try {
            const bytes = new Uint8Array(await file.arrayBuffer());
            finish({ name: file.name, type: file.type, bytes });
          } catch (error) {
            finish(null, error);
          }
        }, { once: true });
        document.body.append(input);
        // Programmatic click forwards the current trusted gesture to the
        // file input on engines where showPicker does not open it.
        try { input.click(); }
        catch (error) { finish(null, error); }
      });
    },
    destroy() {
      closed = true;
      pending?.();
    },
  };
}

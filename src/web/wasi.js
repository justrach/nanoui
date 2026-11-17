// Browser WASI preview1 subset. No preopened directories or filesystem.
export function createWASI(memory, log = message => console.log(message)) {
  const view = () => new DataView(memory().buffer);
  const bytes = (ptr, len) => new Uint8Array(memory().buffer, ptr, len);
  const empty = (count, size) => { view().setUint32(count, 0, true); view().setUint32(size, 0, true); return 0; };
  const decoder = new TextDecoder();
  const calls = {
    args_sizes_get: empty, environ_sizes_get: empty,
    args_get: () => 0, environ_get: () => 0,
    fd_prestat_get: () => 8, // EBADF: no preopens
    fd_write(fd, iovs, count, written) {
      if (fd !== 1 && fd !== 2) return 8;
      let total = 0, message = "";
      for (let i = 0; i < count; i++) {
        const ptr = view().getUint32(iovs + i * 8, true);
        const len = view().getUint32(iovs + i * 8 + 4, true);
        message += decoder.decode(bytes(ptr, len).slice()); total += len;
      }
      view().setUint32(written, total, true);
      log(message); return 0;
    },
    clock_time_get(clock, _precision, out) {
      const ms = clock === 0 ? Date.now() : performance.now();
      view().setBigUint64(out, BigInt(Math.floor(ms * 1e6)), true); return 0;
    },
    random_get(ptr, len) {
      for (let offset = 0; offset < len; offset += 65536) crypto.getRandomValues(bytes(ptr + offset, Math.min(65536, len - offset)));
      return 0;
    },
    proc_exit(code) { throw new Error(`WASI exited (${code})`); },
  };
  return new Proxy(calls, { get: (target, key) => target[key] ?? (() => 52) }); // ENOSYS
}

// Optional execution of the compile-only probe, without a browser or preopens.
// Run `zig build web-check` first, then `node tools/web/check.mjs` (Node 20+).
import { readFile } from "node:fs/promises";
import { WASI } from "node:wasi";

for (const mode of ["debug", "small"]) {
  const path = new URL(`../../zig-out/web/nanoui-web-check-${mode}.wasm`, import.meta.url);
  const bytes = await readFile(path);
  const wasi = new WASI({ version: "preview1", args: [], env: {}, preopens: {} });
  const { instance } = await WebAssembly.instantiate(bytes, {
    wasi_snapshot_preview1: wasi.wasiImport,
  });
  wasi.initialize(instance);
  const status = instance.exports.nanoui_web_check();
  if (status !== 0) throw new Error(`${mode}: UI probe failed (${status})`);
  console.log(`${mode}: UI probe passed (${bytes.length} bytes)`);
}

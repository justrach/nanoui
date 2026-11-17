// Loopback-only static host; WebGPU requires a secure context (localhost).
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { resolve, sep, extname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export async function serve(root = fileURLToPath(new URL("../../zig-out/web", import.meta.url)), port = 0) {
  root = resolve(root);
  const server = createServer(async (req, res) => {
    try {
      const pathname = decodeURIComponent(new URL(req.url, "http://localhost").pathname);
      if (pathname === "/favicon.ico") { res.writeHead(204); res.end(); return; }
      if (pathname === "/") {
        res.setHeader("Content-Type", "text/html");
        res.end("<!doctype html><title>nanoui WebGPU parity</title><body>nanoui WebGPU test host</body>");
        return;
      }
      const path = resolve(root, `.${pathname}`);
      if (!path.startsWith(root + sep)) { res.writeHead(403); res.end(); return; }
      const body = await readFile(path);
      res.setHeader("Content-Type", ({ ".wasm": "application/wasm", ".js": "text/javascript", ".html": "text/html" })[extname(path)] ?? "application/octet-stream");
      res.end(body);
    } catch { res.writeHead(404); res.end(); }
  });
  await new Promise(resolve => server.listen(port, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise(resolve => server.close(resolve)) };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const host = await serve(undefined, Number(process.argv[2] ?? 8080));
  console.log(host.url);
}

// Loopback-only static host; WebGPU requires a secure context (localhost).
import { createServer } from "node:http";
import { readFile, realpath } from "node:fs/promises";
import { resolve, sep, extname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const MIME = {
  ".wasm": "application/wasm",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".html": "text/html",
  ".css": "text/css",
  ".json": "application/json",
};

export async function serve(root = fileURLToPath(new URL("../../zig-out/web", import.meta.url)), port = 0) {
  const rootReal = await realpath(resolve(root));
  const server = createServer(async (req, res) => {
    try {
      const method = req.method ?? "GET";
      if (method !== "GET" && method !== "HEAD") {
        res.writeHead(405, { Allow: "GET, HEAD" });
        res.end();
        return;
      }
      const pathname = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
      if (pathname.includes("\0")) {
        res.writeHead(403);
        res.end();
        return;
      }
      if (pathname === "/favicon.ico") {
        res.writeHead(204);
        res.end();
        return;
      }
      if (pathname === "/") {
        res.setHeader("Content-Type", "text/html; charset=utf-8");
        res.setHeader("X-Content-Type-Options", "nosniff");
        res.setHeader("Cache-Control", "no-store");
        res.end(method === "HEAD" ? undefined : "<!doctype html><title>nanoui WebGPU parity</title><body>nanoui WebGPU test host</body>");
        return;
      }
      const candidate = resolve(rootReal, `.${pathname}`);
      if (!candidate.startsWith(rootReal + sep)) {
        res.writeHead(403);
        res.end();
        return;
      }
      const target = await realpath(candidate);
      if (!target.startsWith(rootReal + sep)) {
        res.writeHead(403);
        res.end();
        return;
      }
      const body = await readFile(target);
      res.setHeader("Content-Type", MIME[extname(target)] ?? "application/octet-stream");
      res.setHeader("X-Content-Type-Options", "nosniff");
      res.setHeader("Cache-Control", "no-store");
      res.end(method === "HEAD" ? undefined : body);
    } catch {
      res.writeHead(404);
      res.end();
    }
  });
  await new Promise(resolve => server.listen(port, "127.0.0.1", resolve));
  return { url: `http://127.0.0.1:${server.address().port}`, close: () => new Promise(resolve => server.close(resolve)) };
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const host = await serve(undefined, Number(process.argv[2] ?? 8080));
  console.log(host.url);
}

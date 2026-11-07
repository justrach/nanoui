#!/usr/bin/env python3
"""Runs WPT's testharness tests in nanobrowser, in the manner of wptrunner: a page
reports through our `testharnessreport.js`, then is sent to the next test.

    wpt_run.py --tests tests.json --bin nanobrowser --out results.jsonl [--jobs N] [--prefix /dom/]

Each worker is one browser process, without a window. A test that doesn't report in
time is a TIMEOUT, a process that dies a CRASH; either way the process is replaced
and the next test goes on. Results append to `--out`, and tests already there are
skipped, so a stopped run carries on.
"""
import argparse
import json
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

ORIGIN_HTTP = "http://web-platform.test:8000"
ORIGIN_HTTPS = "https://web-platform.test:8443"
ORIGIN_H2 = "https://web-platform.test:9000"
TESTS_PER_PROCESS = 100
# Past the harness's own timers (10 s, or 60 s for a long test), and what loading takes.
WATCHDOG = {"normal": 20.0, "long": 75.0}


def address(url):
    if ".h2." in url:
        return ORIGIN_H2 + url
    if ".https." in url or ".serviceworker." in url:
        return ORIGIN_HTTPS + url
    return ORIGIN_HTTP + url


def key(url):
    """A test's address as a page reports it may be escaped, its manifest's not."""
    return unquote(url)


class Run:
    def __init__(self, tests, out):
        self.lock = threading.Lock()
        self.queue = list(reversed(tests))
        self.total = len(tests)
        self.done = 0
        self.out = open(out, "a", buffering=1)
        self.by_url = {}
        self.started = time.time()

    def take(self, worker):
        with self.lock:
            if not self.queue or worker.spent >= TESTS_PER_PROCESS:
                return None
            test = self.queue.pop()
            worker.spent += 1
            worker.current = test
            worker.deadline = time.time() + WATCHDOG.get(test["timeout"], 20.0)
            self.by_url[key(test["url"])] = (worker, test["url"])
            return test

    def record(self, url, result):
        """Once per test: what comes first counts. Returns its worker."""
        with self.lock:
            found = self.by_url.pop(key(url), None)
            if found is None:
                return None
            worker, name = found
            worker.current = None
            worker.deadline = 0
            result["url"] = name
            self.out.write(json.dumps(result) + "\n")
            self.done += 1
            if self.done % 500 == 0:
                took = time.time() - self.started
                print(f"{self.done}/{self.total} {took:.0f}s", flush=True)
            return worker


class Worker:
    def __init__(self, index):
        self.index = index
        self.spent = 0
        self.current = None
        self.deadline = 0
        self.process = None


def serve(run, workers, port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            size = int(self.headers.get("content-length", 0))
            body = self.rfile.read(size)
            try:
                result = json.loads(body)
                run.record(result.pop("url"), result)
            except (ValueError, KeyError):
                pass
            self.send_response(204)
            self.send_header("access-control-allow-origin", "*")
            self.end_headers()

        def do_GET(self):
            q = parse_qs(urlparse(self.path).query)
            after = q.get("after", [None])[0]
            worker = None
            if after is not None:
                worker = next((w for w in workers if w.last_url == key(after)), None)
            elif "w" in q:
                worker = workers[int(q["w"][0])]
            test = run.take(worker) if worker else None
            if test is None:
                self.send_response(200)
                self.send_header("content-type", "text/plain")
                self.end_headers()
                self.wfile.write(b"idle")
                if worker:
                    worker.idle = True
                return
            worker.last_url = key(test["url"])
            self.send_response(302)
            self.send_header("location", address(test["url"]))
            self.send_header("cache-control", "no-store")
            self.end_headers()

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def drive(run, worker, binary, port):
    while True:
        with run.lock:
            if not run.queue and worker.current is None:
                return
        worker.spent = 0
        worker.idle = False
        worker.last_url = None
        start = f"http://web-platform.test:{port}/next?w={worker.index}"
        err_path = f"/tmp/nb-{worker.index}.err"
        with open(err_path, "wb") as err:
            worker.process = subprocess.Popen(
                [binary, f"--nanoui-snapshot=/tmp/nb-{worker.index}.png", "--nanoui-wait=86400", start],
                stdout=subprocess.DEVNULL,
                stderr=err,
            )
        quiet_since = time.time()
        while True:
            time.sleep(0.1)
            code = worker.process.poll()
            now = time.time()
            current = worker.current
            if current:
                quiet_since = now
            if code is not None:
                if current:
                    with open(err_path, "rb") as err:
                        err.seek(0, 2)
                        err.seek(max(0, err.tell() - 2500))
                        tail = err.read().decode("utf-8", "replace")
                    run.record(current["url"], {"harness": "CRASH", "code": code, "pass": 0, "total": 0, "stderr": tail})
                break
            if current and now > worker.deadline:
                run.record(current["url"], {"harness": "TIMEOUT", "pass": 0, "total": 0})
                break
            # Or a page that reported and never asked for the next, or never started.
            if worker.idle or now - quiet_since > 30:
                break
        if worker.process.poll() is None:
            worker.process.kill()
        worker.process.wait()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tests", required=True)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--port", type=int, default=9099)
    ap.add_argument("--prefix", action="append", default=[])
    a = ap.parse_args()
    tests = json.load(open(a.tests))
    if a.prefix:
        tests = [t for t in tests if any(t["url"].startswith(p) for p in a.prefix)]
    seen = set()
    try:
        for line in open(a.out):
            seen.add(json.loads(line)["url"])
    except FileNotFoundError:
        pass
    tests = [t for t in tests if t["url"] not in seen]
    print(f"{len(tests)} tests to run, {len(seen)} already done", flush=True)
    run = Run(tests, a.out)
    workers = [Worker(i) for i in range(a.jobs)]
    for w in workers:
        w.last_url = None
        w.idle = False
    serve(run, workers, a.port)
    threads = [threading.Thread(target=drive, args=(run, w, a.bin, a.port)) for w in workers]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    print(f"finished {run.done} in {time.time() - run.started:.0f}s", flush=True)


if __name__ == "__main__":
    main()

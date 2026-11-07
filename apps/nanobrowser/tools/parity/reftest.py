#!/usr/bin/env python3
"""WPT's reftests and crashtests in nanobrowser: a seeded sample, one process per page.

    reftest.py --manifest MANIFEST.json --ladybird SUMMARY.json --bin nanobrowser --out OUT.jsonl
               [--sample 3000] [--crash-sample 500] [--jobs 20]

A page is drawn with `--nanoui-snapshot` after a fixed wait, and only the page's part of
the window compared: the tab strip shows each page's own title. This is rougher than
wptrunner: it doesn't wait for `reftest-wait`, ignores `fuzzy`, doesn't follow a reference's
own references, and the page isn't 800x600. Two blank pictures match, so those are counted
apart: a browser that draws nothing would pass them too.
"""
import argparse
import hashlib
import json
import os
import random
import subprocess
import threading
import time
import zlib
from concurrent.futures import ThreadPoolExecutor

ORIGIN_HTTP = "http://web-platform.test:8000"
ORIGIN_HTTPS = "https://web-platform.test:8443"
WAIT = 1.5
# Points of the window above the page, at 2x.
CHROME_ROWS = 2 * 52


def address(url):
    return (ORIGIN_HTTPS if ".https." in url else ORIGIN_HTTP) + url


def walk(tree, prefix, out):
    for name, value in tree.items():
        if isinstance(value, dict):
            walk(value, prefix + "/" + name, out)
        else:
            for entry in value[1:]:
                url = entry[0] if entry and entry[0] else prefix + "/" + name
                out.append(("/" + url.lstrip("/"), entry))


def page_pixels(path):
    """The page's rows of a PNG as nanoui writes it: 8-bit, RGBA, unfiltered or filtered."""
    data = open(path, "rb").read()
    at = 8
    idat = []
    width = height = channels = 0
    while at < len(data):
        size = int.from_bytes(data[at : at + 4], "big")
        kind = data[at + 4 : at + 8]
        body = data[at + 8 : at + 8 + size]
        if kind == b"IHDR":
            width = int.from_bytes(body[0:4], "big")
            height = int.from_bytes(body[4:8], "big")
            channels = {2: 3, 6: 4, 0: 1, 4: 2}[body[9]]
        elif kind == b"IDAT":
            idat.append(body)
        at += 12 + size
    raw = zlib.decompress(b"".join(idat))
    stride = width * channels
    rows = []
    prev = bytearray(stride)
    pos = 0
    for _ in range(height):
        kind = raw[pos]
        row = bytearray(raw[pos + 1 : pos + 1 + stride])
        pos += 1 + stride
        if kind == 1:
            for i in range(channels, stride):
                row[i] = (row[i] + row[i - channels]) & 255
        elif kind == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 255
        elif kind == 3:
            for i in range(stride):
                left = row[i - channels] if i >= channels else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 255
        elif kind == 4:
            for i in range(stride):
                a = row[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(row))
        prev = row
    return rows[CHROME_ROWS:]


class Pages:
    """Each address drawn once: many tests share a reference."""

    def __init__(self, binary, work):
        self.binary = binary
        self.work = work
        self.lock = threading.Lock()
        self.done = {}

    def draw(self, url):
        with self.lock:
            cell = self.done.get(url)
            if cell is None:
                cell = self.done[url] = {"event": threading.Event(), "owner": True}
                mine = True
            else:
                mine = False
        if not mine:
            cell["event"].wait()
            return cell
        name = hashlib.sha1(url.encode()).hexdigest()
        path = os.path.join(self.work, name + ".png")
        try:
            p = subprocess.run(
                [self.binary, f"--nanoui-snapshot={path}", f"--nanoui-wait={WAIT}", address(url)],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                timeout=45,
            )
            cell["code"] = p.returncode
            if p.returncode != 0:
                cell["why"] = p.stderr[-1500:].decode("utf-8", "replace")
            else:
                rows = page_pixels(path)
                cell["hash"] = hashlib.sha1(b"".join(rows)).hexdigest()
                cell["blank"] = len(set(rows)) == 1 and len(set(rows[0][i : i + 4] for i in range(0, len(rows[0]), 4))) == 1
                os.unlink(path)
        except subprocess.TimeoutExpired:
            cell["code"] = "TIMEOUT"
        except Exception as e:  # A bad picture counts against this page alone.
            cell["code"] = "ERROR"
            cell["why"] = repr(e)[:300]
        cell["event"].set()
        return cell


def one_reftest(pages, url, refs):
    """Any one reference that holds passes, as the manifest's alternatives do."""
    test = pages.draw(url)
    if test.get("code") != 0:
        return {"url": url, "kind": "reftest", "status": str(test.get("code")), "why": test.get("why", "")[:300]}
    blank = False
    last = "NOREF"
    for ref_url, how in refs:
        ref = pages.draw(ref_url)
        if ref.get("code") != 0:
            last = "REF_" + str(ref.get("code"))
            continue
        same = test["hash"] == ref["hash"]
        if same == (how == "=="):
            blank = test["blank"] and ref["blank"] and how == "=="
            return {"url": url, "kind": "reftest", "status": "PASS", "blank": blank}
        last = "FAIL"
    return {"url": url, "kind": "reftest", "status": last}


def one_crashtest(pages, url):
    t = pages.draw(url)
    code = t.get("code")
    return {"url": url, "kind": "crashtest", "status": "PASS" if code == 0 else str(code), "why": t.get("why", "")[:300]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--ladybird", required=True)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--sample", type=int, default=3000)
    ap.add_argument("--crash-sample", type=int, default=500)
    ap.add_argument("--jobs", type=int, default=20)
    a = ap.parse_args()
    items = json.load(open(a.manifest))["items"]
    ref = []
    walk(items["reftest"], "", ref)
    crash = []
    walk(items["crashtest"], "", crash)
    pick = random.Random(262)
    ref.sort(key=lambda t: t[0])
    crash.sort(key=lambda t: t[0])
    ref = pick.sample(ref, min(a.sample, len(ref)))
    crash = pick.sample(crash, min(a.crash_sample, len(crash)))
    work = "/tmp/nb-ref"
    os.makedirs(work, exist_ok=True)
    pages = Pages(a.bin, work)
    started = time.time()
    finished = [0]
    lock = threading.Lock()
    out = open(a.out, "w", buffering=1)

    def run(fn, *args):
        r = fn(pages, *args)
        with lock:
            out.write(json.dumps(r) + "\n")
            finished[0] += 1
            if finished[0] % 500 == 0:
                print(f"{finished[0]} {time.time() - started:.0f}s", flush=True)

    with ThreadPoolExecutor(a.jobs) as ex:
        for url, entry in ref:
            ex.submit(run, one_reftest, url, entry[1])
        for url, _ in crash:
            ex.submit(run, one_crashtest, url)

    lady = json.load(open(a.ladybird))
    rows = [json.loads(line) for line in open(a.out)]
    for kind in ("reftest", "crashtest"):
        part = [r for r in rows if r["kind"] == kind]
        ok = [r for r in part if r["status"] == "PASS"]
        lady_ok = sum(lady.get(r["url"], {}).get("s") in ("P", "O") for r in part)
        blank = sum(bool(r.get("blank")) for r in ok)
        print(f"{kind}: {len(ok)} of {len(part)} pass ({blank} of those blank on both sides); Ladybird {lady_ok} on the same tests")
    print(f"finished in {time.time() - started:.0f}s")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""nanobrowser beside Ladybird's published results, test by test.

    report.py wpt RESULTS.jsonl LADYBIRD_SUMMARY.json
    report.py test262 RESULTS.json LADYBIRD_PER_FILE.json

For WPT a test that timed out early shows few subtests, so scores use the larger of
the two browsers' subtest counts: not reaching a subtest counts against it.
"""
import collections
import json
import sys


def wpt(results_path, ladybird_path):
    lady = json.load(open(ladybird_path))
    runs = [json.loads(line) for line in open(results_path)]
    by_dir = collections.defaultdict(lambda: [0, 0, 0, 0, 0])
    statuses = collections.Counter()
    all_tests = 0.0
    all_lady = 0.0
    only_nano = 0
    for r in runs:
        lp, lt = lady[r["url"]]["c"]
        total = max(r["total"], lt, 1)
        name = r["url"].split("/")[1]
        row = by_dir[name]
        row[0] += r["pass"]
        row[1] += lp
        row[2] += total
        row[3] += 1
        row[4] += r["harness"] in ("TIMEOUT", "CRASH")
        all_tests += r["pass"] / total
        all_lady += lp / max(lt, 1)
        only_nano += r["pass"] > lp
        h = r["harness"]
        statuses[{0: "OK", 1: "ERROR", 2: "TIMEOUT", 3: "PRECONDITION"}.get(h, h)] += 1
    n = sum(v[0] for v in by_dir.values())
    l = sum(v[1] for v in by_dir.values())
    t = sum(v[2] for v in by_dir.values())
    print(f"tests run {len(runs)}  statuses {dict(statuses)}")
    print(f"subtests: nanobrowser {n} ({100 * n / t:.1f}%)  Ladybird {l} ({100 * l / t:.1f}%)  of {t}")
    print(f"per test (each test counts once): nanobrowser {100 * all_tests / len(runs):.1f}%  Ladybird {100 * all_lady / len(runs):.1f}%")
    print(f"tests where nanobrowser passed more subtests than Ladybird: {only_nano}")
    print(f"{'directory':32s} {'tests':>6s} {'stuck':>6s} {'nano':>9s} {'ladybird':>9s} {'total':>9s}  nano%")
    for name, row in sorted(by_dir.items(), key=lambda x: -x[1][2])[:40]:
        print(f"{name:32s} {row[3]:6d} {row[4]:6d} {row[0]:9d} {row[1]:9d} {row[2]:9d}  {100 * row[0] / row[2]:.1f}")


def test262(results_path, ladybird_path):
    nano = json.load(open(results_path))["results"]
    lady = json.load(open(ladybird_path))["results"]
    n = sum(v == "PASSED" for v in nano.values())
    l = sum(lady.get(k) == "PASSED" for k in nano)
    print(f"test262: nanobrowser {n} ({100 * n / len(nano):.1f}%)  Ladybird {l} ({100 * l / len(nano):.1f}%)  of {len(nano)}")
    print(dict(collections.Counter(v.split(" ")[0] for v in nano.values())))


if __name__ == "__main__":
    {"wpt": wpt, "test262": test262}[sys.argv[1]](sys.argv[2], sys.argv[3])

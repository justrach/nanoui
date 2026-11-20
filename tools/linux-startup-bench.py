#!/usr/bin/env python3
"""Measure Linux launch-to-first-drawn-frame latency, idle CPU, and idle PSS.

Intended to run inside a single display session, e.g.:
    zig build counter -Doptimize=ReleaseFast --prefix zig-out/bench
    xvfb-run -a python3 tools/linux-startup-bench.py --bin zig-out/bench/bin/counter
"""
from __future__ import annotations

import argparse
import os
import pathlib
import select
import shutil
import statistics
import subprocess
import tempfile
import time


def read_proc_cpu_ticks(pid: int) -> int | None:
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
        # comm may contain spaces or parentheses; slice past final ')'.
        rparen = stat.rfind(")")
        if rparen < 0:
            return None
        fields = stat[rparen + 2 :].split()
        # field[11] = utime, field[12] = stime (0-based after state at [0]).
        return int(fields[11]) + int(fields[12])
    except OSError:
        return None


def read_proc_pss_mib(pid: int) -> float | None:
    for rel, single in (("smaps_rollup", True), ("smaps", False)):
        try:
            text = pathlib.Path(f"/proc/{pid}/{rel}").read_text()
        except OSError:
            continue
        total_kb = 0
        found = False
        for line in text.splitlines():
            if line.startswith("Pss:"):
                parts = line.split()
                if len(parts) >= 2:
                    total_kb += int(parts[1])
                    found = True
                    if single:
                        return total_kb / 1024.0
        if found:
            return total_kb / 1024.0
    return None


def measure_once(
    label: str,
    cmd: list[str],
    env: dict[str, str],
    timeout_s: float,
    idle_s: float,
) -> tuple[float, float | None, float | None, str]:
    clk_tck = os.sysconf("SC_CLK_TCK")
    t0 = time.monotonic_ns()
    proc = subprocess.Popen(
        cmd,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    first_frame_ms: float | None = None
    first_line = ""
    stderr_lines: list[str] = []
    assert proc.stderr is not None
    fd = proc.stderr.fileno()
    buf = b""
    deadline = time.monotonic() + timeout_s
    try:
        while time.monotonic() < deadline:
            rem = max(0.0, deadline - time.monotonic())
            rlist, _, _ = select.select([fd], [], [], rem)
            if not rlist:
                break
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                line = raw.decode(errors="replace").strip()
                stderr_lines.append(line)
                if "nanoui: first-frame" in line:
                    first_frame_ms = (time.monotonic_ns() - t0) / 1e6
                    first_line = line
                    break
            if first_frame_ms is not None:
                break
        if first_frame_ms is None:
            raise RuntimeError(
                f"[{label}] timed out waiting for first-frame ({cmd}); stderr={stderr_lines}"
            )
        cpu_before = read_proc_cpu_ticks(proc.pid)
        time.sleep(idle_s)
        cpu_after = read_proc_cpu_ticks(proc.pid)
        pss_mib = read_proc_pss_mib(proc.pid)
        idle_cpu_ms = (
            ((cpu_after - cpu_before) * 1000.0 / clk_tck)
            if cpu_before is not None and cpu_after is not None
            else None
        )
        return first_frame_ms, pss_mib, idle_cpu_ms, first_line
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def run_case(
    label: str,
    cmd: list[str],
    base_env: dict[str, str],
    runs: int,
    cold_cache: bool,
    extra_env: dict[str, str],
    idle_s: float,
) -> dict[str, object]:
    latencies: list[float] = []
    pss_samples: list[float] = []
    idle_cpus: list[float] = []
    sample_line = ""
    with tempfile.TemporaryDirectory(prefix="nanoui-bench-") as tmp:
        tmp_path = pathlib.Path(tmp)
        runtime_dir = tmp_path / "runtime"
        runtime_dir.mkdir(mode=0o700, exist_ok=True)
        warm_cache = tmp_path / "warm-cache"
        warm_mesa = tmp_path / "warm-mesa"
        warm_cache.mkdir()
        warm_mesa.mkdir()
        if not cold_cache:
            # One unrecorded warmup so font & Mesa caches match warm desktop runs.
            wenv = {
                **base_env,
                "XDG_RUNTIME_DIR": str(runtime_dir),
                **extra_env,
                "NANOUI_DEBUG": "1",
                "XDG_CACHE_HOME": str(warm_cache),
                "MESA_SHADER_CACHE_DIR": str(warm_mesa),
            }
            measure_once(label, cmd, wenv, timeout_s=20.0, idle_s=0.1)

        for i in range(runs):
            if cold_cache:
                cache_dir = tmp_path / f"cache-{i}"
                mesa_dir = tmp_path / f"mesa-{i}"
                cache_dir.mkdir()
                mesa_dir.mkdir()
            else:
                cache_dir = warm_cache
                mesa_dir = warm_mesa
            env = {
                **base_env,
                "XDG_RUNTIME_DIR": str(runtime_dir),
                **extra_env,
                "NANOUI_DEBUG": "1",
                "XDG_CACHE_HOME": str(cache_dir),
                "MESA_SHADER_CACHE_DIR": str(mesa_dir),
            }
            ms, pss, cpu_ms, line = measure_once(
                label, cmd, env, timeout_s=20.0, idle_s=idle_s
            )
            latencies.append(ms)
            if pss is not None:
                pss_samples.append(pss)
            if cpu_ms is not None:
                idle_cpus.append(cpu_ms)
            sample_line = line
            if cold_cache:
                shutil.rmtree(cache_dir, ignore_errors=True)
                shutil.rmtree(mesa_dir, ignore_errors=True)

    res = {
        "label": label,
        "median_ms": statistics.median(latencies),
        "min_ms": min(latencies),
        "max_ms": max(latencies),
        "pss_mib": statistics.median(pss_samples) if pss_samples else 0.0,
        "idle_cpu_ms": statistics.median(idle_cpus) if idle_cpus else 0.0,
        "renderer": sample_line,
    }
    print(
        f"[{label}] median={res['median_ms']:.1f}ms "
        f"({res['min_ms']:.1f}–{res['max_ms']:.1f}ms) "
        f"pss={res['pss_mib']:.1f}MiB idle_cpu={res['idle_cpu_ms']:.1f}ms",
        flush=True,
    )
    return res


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--bin", default="zig-out/bench/bin/counter")
    ap.add_argument("--runs", type=int, default=9)
    ap.add_argument("--idle-s", type=float, default=0.5)
    args = ap.parse_args()

    binary = pathlib.Path(args.bin).resolve()
    if not binary.exists():
        raise SystemExit(f"binary not found: {binary}")
    if not os.environ.get("DISPLAY") and not os.environ.get("WAYLAND_DISPLAY"):
        raise SystemExit("set DISPLAY (or run under xvfb-run -a)")

    base_env = os.environ.copy()
    for k in (
        "NANOUI_RENDERER",
        "GSK_RENDERER",
        "GDK_DISABLE",
        "GTK_THEME",
        "LIBGL_ALWAYS_SOFTWARE",
        "GALLIUM_DRIVER",
        "DBUS_SESSION_BUS_ADDRESS",
    ):
        base_env.pop(k, None)

    cases: list[tuple[str, list[str], bool, dict[str, str]]] = [
        ("default (no-GPU warm)", [str(binary)], False, {}),
        ("default (no-GPU cold cache)", [str(binary)], True, {}),
    ]
    if dbus_run := shutil.which("dbus-run-session"):
        cases.append(
            ("default (headless bus, no portal)", [dbus_run, "--", str(binary)], False, {})
        )
    cases.extend(
        [
            ("forced software GL (warm)", [str(binary)], False, {"NANOUI_RENDERER": "gl"}),
            ("forced software GL (cold cache)", [str(binary)], True, {"NANOUI_RENDERER": "gl"}),
        ]
    )

    results = [
        run_case(name, cmd, base_env, args.runs, cold, extra, args.idle_s)
        for name, cmd, cold, extra in cases
    ]

    size_mb = binary.stat().st_size / (1024 * 1024)
    print(
        f"\nLinux startup & idle PSS benchmark ({binary.name}, {size_mb:.2f} MiB, runs={args.runs}):"
    )
    print("| scenario | median first-frame | range | idle PSS | idle CPU | trace |")
    print("|---|---:|---:|---:|---:|---|")
    for r in results:
        print(
            f"| {r['label']} | {r['median_ms']:.1f} ms | "
            f"{r['min_ms']:.1f}–{r['max_ms']:.1f} ms | "
            f"{r['pss_mib']:.1f} MiB | {r['idle_cpu_ms']:.1f} ms | `{r['renderer']}` |"
        )


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""zhor collector — prints one JSON line per tick to stdout, kills nothing.

Everything that decides *what* is wrong lives here; shell.qml only draws it and
sends signals a human clicked. Two things this does that `ps`/`top -bn1` can't:

  * CPU% comes from the delta of utime+stime between ticks. `ps -o pcpu` is the
    average over the whole process lifetime, which for a long-lived hog reads
    low exactly when it starts thrashing.
  * PSI (/proc/pressure) is sampled alongside, because on a 2-core/8G laptop the
    freeze is almost never "someone is at 100% CPU" — it's memory stall. A CPU
    number alone points at the wrong process.
"""
import argparse, json, os, sys, time

CLK = os.sysconf("SC_CLK_TCK")
PAGE_KB = os.sysconf("SC_PAGE_SIZE") // 1024
ME = os.getuid()


# ── /proc readers ──────────────────────────────────────────────────────────
def read_pressure(kind):
    """-> {'some10': float, 'full10': float}. cpu has no 'full' line on most kernels."""
    out = {"some10": 0.0, "full10": 0.0}
    try:
        with open(f"/proc/pressure/{kind}") as f:
            for line in f:
                w = line.split()
                if w and w[0] in ("some", "full"):
                    out[w[0] + "10"] = float(w[1].split("=")[1])
    except OSError:
        pass
    return out


def read_meminfo():
    want = {"MemTotal": 0, "MemAvailable": 0, "SwapTotal": 0, "SwapFree": 0}
    with open("/proc/meminfo") as f:
        for line in f:
            k, _, rest = line.partition(":")
            if k in want:
                want[k] = int(rest.split()[0])  # kB
    return want


def read_procs():
    """-> {pid: {'name','ticks','rss_kb','uid','state'}}. Dead pids just vanish."""
    procs = {}
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        pid = int(entry.name)
        try:
            with open(f"/proc/{pid}/stat") as f:
                stat = f.read()
            # comm is parenthesised and may itself contain ') ' — split on the LAST ')'
            head, _, tail = stat.rpartition(")")
            name = head[head.index("(") + 1:]
            fields = tail.split()
            # tail[0] is field 3 (state), so utime=13 stime=14 rss=21 (0-based here)
            ticks = int(fields[11]) + int(fields[12])
            rss_kb = int(fields[21]) * PAGE_KB
            procs[pid] = {"name": name, "ticks": ticks, "rss_kb": rss_kb,
                          "uid": entry.stat().st_uid, "state": fields[0]}
        except (OSError, ValueError, IndexError):
            continue  # process died mid-read, or a kernel thread with no stat
    return procs


def read_swap_kb(pid):
    """Only called for the shortlist: this parses ~60 lines of text per process."""
    try:
        with open(f"/proc/{pid}/status") as f:
            for line in f:
                if line.startswith("VmSwap:"):
                    return int(line.split()[1])
    except OSError:
        pass
    return 0


# ── pure logic (see test_zhor.py) ──────────────────────────────────────────
def diff_procs(prev, cur, dt, mem_total_kb):
    """CPU% as percent of ONE core, the way top reports it: 247% == 2.5 cores busy."""
    out = []
    for pid, p in cur.items():
        was = prev.get(pid)
        cpu = 0.0
        if was and dt > 0:
            cpu = max(0.0, (p["ticks"] - was["ticks"]) / CLK / dt * 100.0)
        out.append({"pid": pid, "name": p["name"], "cpu": round(cpu, 1),
                    "rss_mb": p["rss_kb"] // 1024, "state": p["state"],
                    "rss_pct": round(p["rss_kb"] / mem_total_kb * 100, 1) if mem_total_kb else 0.0,
                    "mine": p["uid"] == ME})
    return out


def bump_hot(hot, procs, dt, cfg):
    """Seconds a pid has been continuously over threshold. Cooling off resets to 0,
    so a build that pauses between crates never accumulates its way to an alert."""
    new = {}
    for p in procs:
        if p["cpu"] >= cfg["cpu_hot"] or p["rss_pct"] >= cfg["rss_hot"]:
            new[p["pid"]] = round(hot.get(p["pid"], 0.0) + dt, 1)
    return new


def make_alerts(procs, hot, psi, cfg):
    alerts = []
    by_pid = {p["pid"]: p for p in procs}
    for pid, secs in hot.items():
        if secs >= cfg["sustain"] and pid in by_pid:
            p = by_pid[pid]
            alerts.append({"kind": "sustained", "pid": pid, "name": p["name"],
                           "why": f"{p['cpu']:.0f}% CPU, {p['rss_mb']}M RSS for {int(secs)}s"})
    if psi["memory"]["full10"] >= cfg["stall_psi"]:
        # Memory stall: the machine is *waiting*, so blame footprint, not CPU.
        worst = max(procs, key=lambda p: p["rss_mb"] + p.get("swap_mb", 0), default=None)
        alerts.append({"kind": "stall",
                       "pid": worst["pid"] if worst else 0,
                       "name": worst["name"] if worst else "?",
                       "why": f"memory stall {psi['memory']['full10']:.0f}%"})
    return alerts


def shortlist(procs, n):
    """Top n by CPU plus top n by RSS. A union, not a blended score: a single
    ranking always hides one of the two failure modes we're here to catch."""
    top_cpu = sorted(procs, key=lambda p: -p["cpu"])[:n]
    top_rss = sorted(procs, key=lambda p: -p["rss_mb"])[:n]
    seen, out = set(), []
    for p in top_cpu + top_rss:
        if p["pid"] not in seen:
            seen.add(p["pid"])
            out.append(p)
    return out


# ── main loop ──────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="zhor process/pressure collector")
    ap.add_argument("--interval", type=float, default=3.0)
    ap.add_argument("--top", type=int, default=10, help="top N by CPU and by RSS each")
    ap.add_argument("--cpu-hot", type=float, default=90.0, help="%% of one core")
    ap.add_argument("--rss-hot", type=float, default=25.0, help="%% of total RAM")
    ap.add_argument("--sustain", type=float, default=60.0, help="seconds before alerting")
    ap.add_argument("--stall-psi", type=float, default=10.0, help="memory full avg10")
    ap.add_argument("--once", action="store_true", help="two ticks, print one line, exit")
    a = ap.parse_args()
    cfg = {"cpu_hot": a.cpu_hot, "rss_hot": a.rss_hot,
           "sustain": a.sustain, "stall_psi": a.stall_psi}

    prev, hot, t_prev = read_procs(), {}, time.monotonic()
    while True:
        time.sleep(a.interval)
        now = time.monotonic()
        dt, t_prev = now - t_prev, now
        cur = read_procs()
        mem = read_meminfo()
        psi = {k: read_pressure(k) for k in ("cpu", "memory", "io")}

        procs = diff_procs(prev, cur, dt, mem["MemTotal"])
        hot = bump_hot(hot, procs, dt, cfg)
        listed = shortlist(procs, a.top)
        for p in listed:
            p["swap_mb"] = read_swap_kb(p["pid"]) // 1024
            p["hot_s"] = hot.get(p["pid"], 0.0)

        swap_total = mem["SwapTotal"]
        print(json.dumps({
            "psi": {"cpu10": psi["cpu"]["some10"],
                    "mem_full10": psi["memory"]["full10"],
                    "io_full10": psi["io"]["full10"]},
            "mem": {"avail_mb": mem["MemAvailable"] // 1024,
                    "total_mb": mem["MemTotal"] // 1024,
                    "swap_pct": round((swap_total - mem["SwapFree"]) / swap_total * 100)
                                if swap_total else 0},
            "procs": listed,
            "alerts": make_alerts(listed, hot, psi, cfg),
        }, separators=(",", ":")), flush=True)

        prev = cur
        if a.once:
            return


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, BrokenPipeError):
        sys.exit(0)

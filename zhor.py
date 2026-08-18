#!/usr/bin/env python3
"""zhor — what is eating this machine, in a form a human or an agent can read.

    zhor              one-shot report + verdict (exit 1 if under pressure)
    zhor --json       the same, machine-readable
    zhor recent       alerts the daemon recorded while nobody was looking
    zhor watch        the daemon: one JSON line per tick, for shell.qml

Kills nothing and offers no kill command: `kill`/`renice` already exist and the
report prints the pids. What does not already exist is the *judgement* — which
of CPU, memory or io is actually stalling this box, and who to blame for it.

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


# ── event log ──────────────────────────────────────────────────────────────
# A freeze is reported minutes after it ends ("why did it hang earlier?"), and a
# one-shot sample at that point shows a calm machine. The daemon is already
# running, so it writes the alerts down as they happen.
STATE = os.path.expanduser("~/.local/state/zhor")
EVENTS = os.path.join(STATE, "events.jsonl")
MAX_EVENTS = 2000


def log_events(alerts, seen):
    """Append alerts that are newly raised. `seen` is the set of (kind,pid) still
    active, so a process flapping over the line doesn't write a line every tick."""
    live = {(a["kind"], a["pid"]) for a in alerts}
    fresh = [a for a in alerts if (a["kind"], a["pid"]) not in seen]
    if fresh:
        try:
            os.makedirs(STATE, exist_ok=True)
            with open(EVENTS, "a") as f:
                for a in fresh:
                    f.write(json.dumps({"t": time.time(), **a}, separators=(",", ":")) + "\n")
            trim_events()
        except OSError:
            pass  # a monitor that dies because it can't write its log is worse than one that doesn't log
    return live


def trim_events():
    with open(EVENTS) as f:
        lines = f.readlines()
    if len(lines) > MAX_EVENTS:
        with open(EVENTS, "w") as f:
            f.writelines(lines[-MAX_EVENTS:])


def read_events(since_s):
    cutoff = time.time() - since_s
    out = []
    try:
        with open(EVENTS) as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("t", 0) >= cutoff:
                    out.append(e)
    except OSError:
        pass
    return out


# ── sampling ───────────────────────────────────────────────────────────────
def sample(interval, top, cfg, prev=None, hot=None, dt=None):
    """One measurement window. CPU needs two reads, so this always costs `interval`
    seconds unless the caller already holds a previous snapshot."""
    if prev is None:
        prev = read_procs()
        time.sleep(interval)
        dt = interval
    cur = read_procs()
    mem = read_meminfo()
    psi = {k: read_pressure(k) for k in ("cpu", "memory", "io")}
    procs = diff_procs(prev, cur, dt, mem["MemTotal"])
    hot = bump_hot(hot or {}, procs, dt, cfg)
    listed = shortlist(procs, top)
    for p in listed:
        p["swap_mb"] = read_swap_kb(p["pid"]) // 1024
        p["hot_s"] = hot.get(p["pid"], 0.0)
    swap_total = mem["SwapTotal"]
    snap = {
        "psi": {"cpu10": psi["cpu"]["some10"],
                "mem_full10": psi["memory"]["full10"],
                "io_full10": psi["io"]["full10"]},
        "mem": {"avail_mb": mem["MemAvailable"] // 1024,
                "total_mb": mem["MemTotal"] // 1024,
                "swap_pct": round((swap_total - mem["SwapFree"]) / swap_total * 100)
                            if swap_total else 0},
        "procs": listed,
        "alerts": make_alerts(listed, hot, psi, cfg),
    }
    return snap, cur, hot


def verdict(snap, cfg):
    """One line naming the bottleneck, because that is the whole question.
    Order matters: memory stall makes everything else look busy, so it wins."""
    psi, mem = snap["psi"], snap["mem"]
    fat = max(snap["procs"], key=lambda p: p["rss_mb"] + p.get("swap_mb", 0), default=None)
    busy = max(snap["procs"], key=lambda p: p["cpu"], default=None)
    if psi["mem_full10"] >= cfg["stall_psi"]:
        who = f" — biggest footprint: {fat['name']}({fat['pid']})" if fat else ""
        return 1, f"MEMORY STALL: {psi['mem_full10']:.0f}% of time blocked on memory{who}"
    if mem["swap_pct"] >= 90 and mem["avail_mb"] < mem["total_mb"] * 0.20:
        who = f", biggest footprint {fat['name']}({fat['pid']})" if fat else ""
        return 1, (f"MEMORY TIGHT: {mem['avail_mb']}M free, swap {mem['swap_pct']}% full{who}"
                   f" — a stall is one heavy tab away")
    if psi["io_full10"] >= cfg["stall_psi"]:
        return 1, f"IO STALL: {psi['io_full10']:.0f}% of time blocked on disk"
    if psi["cpu10"] >= 60:
        who = f" — heaviest: {busy['name']}({busy['pid']}) at {busy['cpu']:.0f}%" if busy else ""
        return 1, f"CPU CONTENTION: {psi['cpu10']:.0f}% of time waiting for a core{who}"
    return 0, "OK: no pressure right now"


def fmt_mb(mb):
    return f"{mb / 1024:.1f}G" if mb >= 1024 else f"{mb}M"


def report(snap, cfg, events):
    v_code, v_text = verdict(snap, cfg)
    psi, mem = snap["psi"], snap["mem"]
    by_cpu = sorted(snap["procs"], key=lambda p: -p["cpu"])[:5]
    by_mem = sorted(snap["procs"], key=lambda p: -(p["rss_mb"] + p.get("swap_mb", 0)))[:5]
    out = [
        f"VERDICT  {v_text}",
        f"PSI      cpu {psi['cpu10']:.1f}%  mem {psi['mem_full10']:.1f}%  io {psi['io_full10']:.1f}%"
        f"   (avg10 = share of the last 10s spent stalled)",
        f"MEM      {fmt_mb(mem['avail_mb'])} free of {fmt_mb(mem['total_mb'])}"
        f"   swap {mem['swap_pct']}% used",
        "TOP CPU  " + "  ".join(f"{p['name']}({p['pid']}) {p['cpu']:.0f}%" for p in by_cpu),
        "TOP MEM  " + "  ".join(
            f"{p['name']}({p['pid']}) {fmt_mb(p['rss_mb'])}"
            + (f"+{fmt_mb(p['swap_mb'])}sw" if p.get("swap_mb") else "") for p in by_mem),
    ]
    flagged = [p for p in snap["procs"] if p.get("hot_s", 0) >= cfg["sustain"]]
    if flagged:
        out.append("FLAGGED  " + "  ".join(
            f"{p['name']}({p['pid']}) {int(p['hot_s'])}s over threshold" for p in flagged))
    if events:
        kinds = {}
        for e in events:
            kinds[(e["kind"], e.get("name", "?"))] = kinds.get((e["kind"], e.get("name", "?")), 0) + 1
        out.append(f"RECENT   {len(events)} alert(s) logged: " + ", ".join(
            f"{n}x {k} {who}" for (k, who), n in sorted(kinds.items(), key=lambda x: -x[1])))
    else:
        out.append("RECENT   nothing logged (daemon running? `zhor watch` feeds this)")
    return v_code, "\n".join(out)


# ── main loop ──────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(
        description="zhor — who is eating this machine",
        epilog="exit 0 = no pressure, 1 = under pressure, so `zhor >/dev/null || ...` works")
    ap.add_argument("cmd", nargs="?", default="report", choices=["report", "watch", "recent"],
                    help="report (default): one-shot verdict; watch: JSON stream for the widget; "
                         "recent: alerts logged earlier")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--interval", type=float, default=None,
                    help="sampling window in seconds (default 1 for report, 3 for watch)")
    ap.add_argument("--since", type=float, default=60, help="recent: minutes to look back")
    ap.add_argument("--top", type=int, default=10, help="top N by CPU and by RSS each")
    ap.add_argument("--cpu-hot", type=float, default=90.0, help="%% of one core")
    ap.add_argument("--rss-hot", type=float, default=25.0, help="%% of total RAM")
    ap.add_argument("--sustain", type=float, default=60.0, help="seconds before alerting")
    ap.add_argument("--stall-psi", type=float, default=10.0, help="memory full avg10")
    a = ap.parse_args()
    cfg = {"cpu_hot": a.cpu_hot, "rss_hot": a.rss_hot,
           "sustain": a.sustain, "stall_psi": a.stall_psi}

    if a.cmd == "recent":
        events = read_events(a.since * 60)
        if a.json:
            print(json.dumps(events, separators=(",", ":")))
        elif not events:
            print(f"no alerts in the last {a.since:.0f} min "
                  f"(is the daemon running? `zhor watch` records them)")
        else:
            for e in events:
                when = time.strftime("%H:%M:%S", time.localtime(e["t"]))
                print(f"{when}  {e['kind']:<9} {e.get('name','?')}({e.get('pid','?')})  {e.get('why','')}")
        return 0

    if a.cmd == "report":
        snap, _, _ = sample(a.interval or 1.0, a.top, cfg)
        if a.json:
            code, text = verdict(snap, cfg)
            print(json.dumps({**snap, "verdict": text,
                              "recent": read_events(a.since * 60)}, separators=(",", ":")))
            return code
        code, text = report(snap, cfg, read_events(a.since * 60))
        print(text)
        return code

    # watch: the daemon behind shell.qml. Holds the previous snapshot so each tick
    # costs one read, not two, and carries `hot` across ticks.
    interval = a.interval or 3.0
    prev, hot, seen, t_prev = read_procs(), {}, set(), time.monotonic()
    while True:
        time.sleep(interval)
        now = time.monotonic()
        dt, t_prev = now - t_prev, now
        snap, prev, hot = sample(interval, a.top, cfg, prev=prev, hot=hot, dt=dt)
        seen = log_events(snap["alerts"], seen)
        print(json.dumps(snap, separators=(",", ":")), flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except (KeyboardInterrupt, BrokenPipeError):
        sys.exit(0)

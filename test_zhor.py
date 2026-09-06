#!/usr/bin/env python3
"""Self-check for the parts that can be wrong silently: the CPU delta, the
sustained-hot counter, and alert triggering. Run: ./test_zhor.py"""
import zhor

CFG = {"cpu_hot": 90.0, "rss_hot": 25.0, "sustain": 60.0, "stall_psi": 10.0}
CALM = {"cpu": {"some10": 0.0, "full10": 0.0},
        "memory": {"some10": 0.0, "full10": 0.0},
        "io": {"some10": 0.0, "full10": 0.0}}

import os, tempfile


def _w(root, rel, value):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(str(value) + "\n")


def fake_sys():
    """A /sys with everything the laptop has, plus the corner cases seen in review:
    a hwmon without `name`, a hwmon input without a label, a negative SMC sensor,
    idle cores reporting their requested P-state."""
    root = tempfile.mkdtemp(prefix="zhor-sys-")
    hw = "class/hwmon/"
    _w(root, hw + "hwmon1/name", "coretemp")
    _w(root, hw + "hwmon1/temp1_label", "Package id 0")
    _w(root, hw + "hwmon1/temp1_input", 65000)
    _w(root, hw + "hwmon1/temp1_crit", 105000)
    _w(root, hw + "hwmon1/temp2_label", "Core 0")
    _w(root, hw + "hwmon1/temp2_input", 65000)
    _w(root, hw + "hwmon1/temp3_label", "Core 1")
    _w(root, hw + "hwmon1/temp3_input", 64000)
    _w(root, hw + "hwmon2/name", "pch_wildcat_point")
    _w(root, hw + "hwmon2/temp1_input", 52000)          # no label → named after the hwmon
    _w(root, hw + "hwmon3/name", "BAT0")
    _w(root, hw + "hwmon3/temp1_input", 35000)
    os.makedirs(os.path.join(root, hw + "hwmon4"))        # applesmc's hwmon: no name, no sensors
    smc = "devices/platform/applesmc.768/"
    _w(root, smc + "fan1_input", 1185)
    _w(root, smc + "fan1_max", 6500)
    _w(root, smc + "temp1_label", "TCXC")
    _w(root, smc + "temp1_input", 52750)                  # not a multiple of 1000
    _w(root, smc + "temp2_label", "TH0F")
    _w(root, smc + "temp2_input", -43250)                 # garbage sensor
    cpu = "devices/system/cpu/"
    _w(root, cpu + "cpu0/cpufreq/scaling_cur_freq", 1774494)
    _w(root, cpu + "cpu1/cpufreq/scaling_cur_freq", 500000)   # idle: requested P-state
    _w(root, cpu + "cpu0/cpufreq/cpuinfo_max_freq", 1800000)
    _w(root, cpu + "intel_pstate/no_turbo", 1)
    _w(root, cpu + "cpu0/thermal_throttle/package_throttle_count", 863)
    _w(root, cpu + "cpu0/thermal_throttle/package_throttle_total_time_ms", 3512)
    return root


def test_thermal_reads_the_laptop_layout():
    root = fake_sys()
    therm = zhor.discover_thermal(root)
    t = zhor.read_thermal(therm)
    assert t["cpu_c"] == 65 and t["cores_c"] == [65, 64] and t["crit_c"] == 105
    assert t["freq_mhz"] == 1774 and t["freq_pct"] == 99      # max over cores, not the idle average
    assert t["turbo"] is False
    assert t["throttle_pkg"] == 863 and t["throttle_ms"] == 3512
    assert t["d_pkg"] == 0 and t["throttled"] is False        # first tick: nothing to diff against
    assert t["fan_rpm"] == 1185 and t["fan_max"] == 6500
    assert t["bat_c"] == 35
    names = [e["name"] for e in t["extra"]]
    assert names == ["TCXC", "pch_wildcat_point"]             # sorted by temp; TH0F filtered; BAT0/coretemp not duplicated
    assert t["extra"][0]["c"] == 53                            # 52750 rounds, not truncates


def test_thermal_survives_an_empty_sys():
    therm = zhor.discover_thermal(tempfile.mkdtemp(prefix="zhor-empty-"))
    t = zhor.read_thermal(therm)
    assert t["cpu_c"] is None and t["freq_mhz"] is None and t["fan_rpm"] is None
    assert t["extra"] == [] and t["throttled"] is False


def p(ticks, rss_kb=1024, uid=0, state="R", name="hog"):
    return {"name": name, "ticks": ticks, "rss_kb": rss_kb, "uid": uid, "state": state}


def test_cpu_delta_is_percent_of_one_core():
    # One full core for 2s == CLK ticks per second, twice -> 100%
    prev, cur = {1: p(0)}, {1: p(2 * zhor.CLK)}
    assert zhor.diff_procs(prev, cur, 2.0, 8_000_000)[0]["cpu"] == 100.0
    # 2.5 cores busy reads as 250%, like top — not clamped to 100
    cur = {1: p(int(2.5 * 2 * zhor.CLK))}
    assert zhor.diff_procs(prev, cur, 2.0, 8_000_000)[0]["cpu"] == 250.0


def test_unseen_process_is_not_charged_its_whole_lifetime():
    # A process that already burned CPU before we first saw it must read 0,
    # otherwise every freshly-spawned pid instantly looks like a hog.
    assert zhor.diff_procs({}, {7: p(999_999)}, 2.0, 8_000_000)[0]["cpu"] == 0.0


def test_counter_rewound_after_stat_reset_never_goes_negative():
    assert zhor.diff_procs({1: p(500)}, {1: p(100)}, 2.0, 8_000_000)[0]["cpu"] == 0.0


def test_rss_pct_is_share_of_total_ram():
    got = zhor.diff_procs({}, {1: p(0, rss_kb=2_000_000)}, 1.0, 8_000_000)[0]
    assert got["rss_pct"] == 25.0 and got["rss_mb"] == 1953


def test_hot_accumulates_only_while_over_threshold():
    hot = {}
    hot = zhor.bump_hot(hot, [{"pid": 1, "cpu": 95.0, "rss_pct": 1.0}], 3.0, CFG)
    hot = zhor.bump_hot(hot, [{"pid": 1, "cpu": 95.0, "rss_pct": 1.0}], 3.0, CFG)
    assert hot[1] == 6.0
    # cooling off resets: a build that pauses between crates must not creep up
    hot = zhor.bump_hot(hot, [{"pid": 1, "cpu": 10.0, "rss_pct": 1.0}], 3.0, CFG)
    assert 1 not in hot
    hot = zhor.bump_hot(hot, [{"pid": 1, "cpu": 95.0, "rss_pct": 1.0}], 3.0, CFG)
    assert hot[1] == 3.0


def test_memory_alone_makes_a_process_hot():
    hot = zhor.bump_hot({}, [{"pid": 1, "cpu": 0.0, "rss_pct": 30.0}], 3.0, CFG)
    assert hot[1] == 3.0


def test_alert_waits_for_the_full_sustain_window():
    procs = [{"pid": 1, "name": "rustc", "cpu": 95.0, "rss_mb": 700, "rss_pct": 9.0}]
    assert zhor.make_alerts(procs, {1: 59.0}, CALM, CFG) == []
    a = zhor.make_alerts(procs, {1: 60.0}, CALM, CFG)
    assert len(a) == 1 and a[0]["kind"] == "sustained" and a[0]["pid"] == 1


def test_stall_alert_blames_footprint_not_cpu():
    # The CPU hog is not the culprit when the machine is stalling on memory.
    procs = [{"pid": 1, "name": "rustc", "cpu": 250.0, "rss_mb": 100, "rss_pct": 1.0, "swap_mb": 0},
             {"pid": 2, "name": "Telegram", "cpu": 0.1, "rss_mb": 300, "rss_pct": 4.0, "swap_mb": 440}]
    psi = dict(CALM, memory={"some10": 40.0, "full10": 22.0})
    a = zhor.make_alerts(procs, {}, psi, CFG)
    assert len(a) == 1 and a[0]["kind"] == "stall" and a[0]["name"] == "Telegram"


def test_throttle_alert_needs_two_consecutive_ticks_or_near_crit():
    root = fake_sys()
    therm = zhor.discover_thermal(root)
    cnt = "devices/system/cpu/cpu0/thermal_throttle/package_throttle_count"
    ms = "devices/system/cpu/cpu0/thermal_throttle/package_throttle_total_time_ms"
    t0 = zhor.read_thermal(therm)                     # baseline
    _w(root, cnt, 865); _w(root, ms, 3520)
    t1 = zhor.read_thermal(therm)                     # first tick with movement
    assert t1["d_pkg"] == 2 and t1["d_ms"] == 8 and t1["throttled"] and therm["streak"] == 1
    assert zhor.make_alerts([], {}, CALM, CFG, thermal=(t1, therm)) == []   # one blip is not an alert
    _w(root, cnt, 870)
    t2 = zhor.read_thermal(therm)
    assert therm["streak"] == 2
    a = zhor.make_alerts([], {}, CALM, CFG, thermal=(t2, therm))
    assert len(a) == 1 and a[0]["kind"] == "throttle" and a[0]["pid"] == 0 and a[0]["name"] == "cpu"
    assert "+5 events" in a[0]["why"] and "65°C" in a[0]["why"]
    t3 = zhor.read_thermal(therm)                     # counter still: streak resets
    assert therm["streak"] == 0 and zhor.make_alerts([], {}, CALM, CFG, thermal=(t3, therm)) == []
    # near Tjmax alerts even without counter movement
    _w(root, "class/hwmon/hwmon1/temp1_input", 96000)
    t4 = zhor.read_thermal(therm)
    a = zhor.make_alerts([], {}, CALM, CFG, thermal=(t4, therm))
    assert len(a) == 1 and "crit 105°C" in a[0]["why"]


def test_make_alerts_without_thermal_is_unchanged():
    assert zhor.make_alerts([], {}, CALM, CFG) == []


def test_report_prints_thermal_line_when_present():
    snap = _snap()
    snap["thermal"] = {"cpu_c": 65, "cores_c": [65, 64], "crit_c": 105, "freq_mhz": 1800, "freq_pct": 100,
                       "turbo": False, "throttle_pkg": 863, "throttle_ms": 3512, "d_pkg": 0, "d_ms": 0,
                       "throttled": False, "fan_rpm": 1185, "fan_max": 6500, "bat_c": 35, "extra": []}
    _, text = zhor.report(snap, CFG, [])
    assert "THERMAL  65°C" in text and "1.8 GHz (100%)" in text and "fan 1185 rpm" in text and "863 total" in text
    _, text = zhor.report(_snap(), CFG, [])           # old snapshots without the block still render
    assert "THERMAL" not in text


def test_shortlist_keeps_both_failure_modes():
    # A pure-CPU ranking would drop the fat process and vice versa.
    procs = ([{"pid": i, "cpu": 100.0 - i, "rss_mb": 1} for i in range(5)]
             + [{"pid": 99, "cpu": 0.0, "rss_mb": 4000}])
    got = zhor.shortlist(procs, 2)
    pids = [x["pid"] for x in got]
    assert 99 in pids and 0 in pids and len(pids) == len(set(pids))


def _snap(cpu10=0.0, mem_full=0.0, io_full=0.0, avail=4000, total=8000, swap=0, procs=None):
    return {"psi": {"cpu10": cpu10, "mem_full10": mem_full, "io_full10": io_full},
            "mem": {"avail_mb": avail, "total_mb": total, "swap_pct": swap},
            "procs": procs or [{"pid": 1, "name": "hog", "cpu": 300.0, "rss_mb": 50, "swap_mb": 0},
                               {"pid": 2, "name": "fat", "cpu": 0.0, "rss_mb": 900, "swap_mb": 400}],
            "alerts": []}


def test_verdict_is_quiet_when_nothing_is_wrong():
    assert zhor.verdict(_snap(), CFG)[0] == 0


def test_memory_stall_outranks_a_busy_cpu_and_blames_footprint():
    # A 300% process is present in every case below; it must not be the answer
    # when the machine is blocked on memory.
    code, text = zhor.verdict(_snap(cpu10=90.0, mem_full=25.0), CFG)
    assert code == 1 and "MEMORY STALL" in text and "fat(2)" in text and "hog" not in text


def test_full_swap_with_little_free_is_flagged_before_it_stalls():
    code, text = zhor.verdict(_snap(avail=1300, total=7835, swap=100), CFG)
    assert code == 1 and "MEMORY TIGHT" in text
    # ...but a full swap alone, with room to breathe, is not an emergency
    assert zhor.verdict(_snap(avail=4000, total=7835, swap=100), CFG)[0] == 0


def test_cpu_contention_names_the_busiest():
    code, text = zhor.verdict(_snap(cpu10=75.0), CFG)
    assert code == 1 and "CPU CONTENTION" in text and "hog(1)" in text


def test_report_survives_an_empty_process_list():
    # /proc can come back empty under extreme pressure; the reporter must not
    # be the thing that crashes when the machine is at its worst.
    code, text = zhor.report(_snap(procs=[]), CFG, [])
    assert "VERDICT" in text and "TOP CPU" in text


if __name__ == "__main__":
    ran = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
            ran += 1
    print(f"ok — {ran} checks passed")

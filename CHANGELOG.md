# Changelog

All notable changes to zhor are documented in this file.

## [0.2.0] - 2026-09-07

### Added
- `Zhor.qml`: zhor as an embeddable component. Drop `Z.Zhor {}` into your own
  Quickshell bar; `shell.qml` is now a thin standalone wrapper around it.
  `fsActive` is an input (the host bar knows when a fullscreen window is up).

### Changed
- Click-away closes the list through `HyprlandFocusGrab` instead of a
  full-screen transparent catcher window. The catcher lived on the `top` layer
  and would also cover a host bar there, eating its clicks.
- Fullscreen detection reads `HyprlandWorkspace.hasFullscreen` and refreshes via
  the IPC socket instead of forking `hyprctl` on every window event.

### Unchanged
- Standalone usage, `install.sh`, the `popup` IPC target and the keybind.

## [0.1.0] - 2026-08-19

First release.

### Added

- **Collector (`zhor.py`)** reading `/proc` and `/proc/pressure`. CPU is a
  tick-to-tick delta rather than `ps -o pcpu`'s lifetime average — the
  difference is not cosmetic: the HyprPanel process this was written next to
  reads 22% in `ps` and 57% in reality.
- **PSI-based verdict.** The check order puts memory stall above CPU
  contention, because during a stall every process looks busy and the CPU
  ranking names the wrong one.
- **Widget (`shell.qml`)** for quickshell + Hyprland: a pill in the bar showing
  pressure, free memory and swap, and a process list on click or
  `SUPER+SHIFT+ESC`. Top by CPU and top by RSS merged, so neither failure mode
  hides the other.
- **Per-process buttons**: `SIGSTOP`/`SIGCONT`, `renice -n 19`, and
  `SIGTERM` escalating to `SIGKILL` on a second click within five seconds.
  Disabled for processes the user does not own, where `kill` would only return
  EPERM.
- **CLI**: `zhor` prints a verdict and exits 1 under pressure, `--json` for
  machines, `zhor recent` reads alerts the daemon logged to
  `~/.local/state/zhor/events.jsonl`. A freeze is asked about after it ends,
  when a fresh sample is calm — so the daemon writes them down as they happen.
- **Alerts** via `notify-send`: a process over the line for a minute, or the
  machine genuinely blocked on memory.
- `install.sh` / `uninstall.sh`. Idempotent; the uninstall returns
  `hyprland.conf` byte for byte.
- Self-checks in `test_zhor.py`: CPU delta arithmetic, the stuck counter, alert
  triggering, shortlist selection, verdict ordering.

### Notes

Nothing is killed automatically, by design: `rustc` at 250% CPU is a correct
`rustc`, and an autokiller would eat exactly that.

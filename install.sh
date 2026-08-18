#!/usr/bin/env bash
# zhor installer. Idempotent: safe to re-run, and uninstall.sh undoes exactly this.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK="$HOME/.config/quickshell/zhor"
CONF="$HOME/.config/hypr/hyprland.conf"
BIND='SUPER SHIFT, ESCAPE'
EXEC_LINE="exec-once = qs -n -p $LINK"
BIND_LINE="bind = $BIND, exec, qs -p $LINK ipc call popup toggle"

command -v qs >/dev/null || { echo "quickshell (qs) not found — pacman -S quickshell"; exit 1; }
command -v python3 >/dev/null || { echo "python3 not found"; exit 1; }

mkdir -p "$(dirname "$LINK")"
ln -sfn "$SRC" "$LINK"
echo "linked $LINK -> $SRC"

mkdir -p "$HOME/.local/bin"
ln -sfn "$SRC/zhor.py" "$HOME/.local/bin/zhor"
echo "linked $HOME/.local/bin/zhor -> $SRC/zhor.py"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "  note: $HOME/.local/bin is not on PATH" ;; esac

if [[ -f $CONF ]]; then
    # Grep on the literal lines, so re-running never stacks duplicates. Anything
    # already present is left exactly as the user has it — including a keybind
    # they moved somewhere else.
    added=0
    if ! grep -qF "qs -p $LINK ipc call popup toggle" "$CONF"; then added=1; fi
    if ! grep -qF "$EXEC_LINE" "$CONF"; then added=1; fi
    if (( added )); then
        cp "$CONF" "$CONF.zhor.bak"
        echo "backed up $CONF -> $CONF.zhor.bak"
        {
            echo "# --- zhor (added by $SRC/install.sh) ---"
            grep -qF "$EXEC_LINE" "$CONF" || echo "$EXEC_LINE"
            grep -qF "qs -p $LINK ipc call popup toggle" "$CONF" || echo "$BIND_LINE"
            echo "# --- end zhor ---"
        } >> "$CONF"
        echo "added exec-once + bind ($BIND) to $CONF"
    else
        echo "hyprland.conf already wired, left alone"
    fi
    hyprctl reload >/dev/null 2>&1 && echo "hyprctl reload ok" || echo "hyprctl reload skipped (no session?)"
else
    echo "no $CONF — add these yourself:"
    printf '  %s\n  %s\n' "$EXEC_LINE" "$BIND_LINE"
fi

# Restart rather than start: re-running the installer after an edit should leave
# one live instance, not two drawing the same pill on top of each other.
# `qs kill` and not `pkill -f`: a -f pattern this generic also matches any editor,
# shell or terminal that happens to have the path in its command line.
qs kill -p "$LINK" >/dev/null 2>&1 || true
if [[ -n ${WAYLAND_DISPLAY:-} ]]; then
    qs -d -p "$LINK" >/dev/null 2>&1 || true
    echo "zhor running — pill is next to your clock, $BIND opens the list"
else
    echo "not in a wayland session; zhor starts on next Hyprland launch"
fi

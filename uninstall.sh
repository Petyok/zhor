#!/usr/bin/env bash
# Undoes install.sh: stops zhor, removes the symlink and the config block.
set -euo pipefail
LINK="$HOME/.config/quickshell/zhor"
CONF="$HOME/.config/hypr/hyprland.conf"

qs kill -p "$LINK" >/dev/null 2>&1 && echo "stopped zhor" || echo "zhor not running"
[[ -L $LINK ]] && rm "$LINK" && echo "removed $LINK"

if [[ -f $CONF ]] && grep -q '^# --- zhor' "$CONF"; then
    cp "$CONF" "$CONF.zhor.bak"
    # Drop only our own fenced block; hand-moved lines outside it stay, on purpose.
    sed -i '/^# --- zhor (added by/,/^# --- end zhor ---$/d' "$CONF"
    echo "removed zhor block from $CONF (backup: $CONF.zhor.bak)"
    hyprctl reload >/dev/null 2>&1 || true
fi
echo "done. ~/zhor itself is untouched — rm -rf it if you want it gone."

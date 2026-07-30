#!/usr/bin/env bash
# Free space on the root volume, colored when it runs low. Reads `df -H /` (no deps).
# shellcheck source=/dev/null
source "$HOME/.config/sketchybar/colors.sh"

# df -H columns: Filesystem Size Used Avail Capacity ... -> $4 = available, $5 = used %.
read -r AVAIL USEDPCT < <(df -H / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $4, $5}')
if [ -z "${AVAIL:-}" ]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

# Disk stays neutral (fg) until it runs low — unlike cpu/memory it is NOT green when
# healthy (PARITY.md threshold table: disk <80% used = fg; Zebar uses c-fg to match).
if [ "${USEDPCT:-0}" -lt 80 ]; then
  COLOR="$FG"
elif [ "${USEDPCT:-0}" -lt 90 ]; then
  COLOR="$YELLOW"
else
  COLOR="$RED"
fi

sketchybar --set "$NAME" drawing=on icon="󰋊" icon.color="$COLOR" label="$AVAIL" label.color="$COLOR"

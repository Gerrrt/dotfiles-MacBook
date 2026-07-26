#!/usr/bin/env bash
# Center clock — date + time in the shared "EEE d MMM t" format (e.g. "Mon 13 Jul 2:45 PM"),
# matching the Zebar date provider (formatting: "EEE d MMM t"). Blue clock glyph + fg text.
# Battery + this clock also live in the tmux status bar; they are shown here too for cross-host
# parity with Zebar (see PARITY.md). Dependency-free (`date`).
# shellcheck source=/dev/null
source "$HOME/.config/sketchybar/colors.sh"

# %a=abbrev weekday, %-d=day (no pad), %b=abbrev month, %-l:%M=12h time (no pad), %p=AM/PM.
sketchybar --set "$NAME" icon="󰅐" icon.color="$MAGENTA" \
  label="$(date '+%a %-d %b %-l:%M %p')" label.color="$MAGENTA"

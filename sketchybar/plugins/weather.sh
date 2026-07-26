#!/usr/bin/env bash
# Current conditions — temperature in °C + a day/night weather glyph, mirroring Zebar's weather
# provider + getWeatherIcon map (clear / cloudy / light-rain / heavy-rain / snow / thunder, each
# with a day and night variant). Location is auto-detected by IP via wttr.in. Dependency-free
# (`curl`, built into macOS). Glyphs are emitted as UTF-8 octal escapes so they render under the
# stock bash 3.2 (no \u printf).
# shellcheck source=/dev/null
source "$HOME/.config/sketchybar/colors.sh"

# "+18°C|Partly cloudy" — temperature then condition text (metric).
RESP="$(curl -sf --max-time 10 'https://wttr.in/?format=%t|%C' 2>/dev/null)"
if [ -z "$RESP" ]; then
  sketchybar --set "$NAME" drawing=off
  exit 0
fi

TEMP="$(printf '%s' "$RESP" | cut -d'|' -f1 | tr -d '+°C ')"
COND="$(printf '%s' "$RESP" | cut -d'|' -f2 | tr '[:upper:]' '[:lower:]')"
[ -z "$TEMP" ] && {
  sketchybar --set "$NAME" drawing=off
  exit 0
}

# Day 06:00–17:59, else night — same day/night split Zebar's provider uses.
HOUR="$(date +%-H)"
if [ "$HOUR" -ge 6 ] && [ "$HOUR" -lt 18 ]; then DAY=1; else DAY=0; fi

# nerd-font weather glyphs, emitted as UTF-8 octal so they render under stock bash 3.2 (no \u).
# Codepoints are the day/night pairs of Zebar's getWeatherIcon map (see PARITY.md glyph table).
case "$COND" in
*thunder* | *storm*) [ "$DAY" -eq 1 ] && ICON="$(printf '\356\214\205')" || ICON="$(printf '\356\214\242')" ;;
*snow* | *sleet* | *blizzard* | *ice*) [ "$DAY" -eq 1 ] && ICON="$(printf '\356\214\212')" || ICON="$(printf '\356\214\247')" ;;
*heavy*rain* | *torrential* | *"heavy shower"*) [ "$DAY" -eq 1 ] && ICON="$(printf '\356\214\210')" || ICON="$(printf '\356\214\245')" ;;
*rain* | *drizzle* | *shower*) [ "$DAY" -eq 1 ] && ICON="$(printf '\356\214\213')" || ICON="$(printf '\356\214\250')" ;;
*cloud* | *overcast* | *fog* | *mist*) [ "$DAY" -eq 1 ] && ICON="$(printf '\356\214\202')" || ICON="$(printf '\356\215\276')" ;;
*) [ "$DAY" -eq 1 ] && ICON="$(printf '\356\214\215')" || ICON="$(printf '\356\214\253')" ;; # clear/sunny
esac

sketchybar --set "$NAME" drawing=on icon="$ICON" icon.color="$ORANGE" label="${TEMP}°C" label.color="$ORANGE"

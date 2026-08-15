#!/usr/bin/env bash
# test/check-configs.sh — parse-gate the repo-owned structured configs.
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS: shellcheck/shfmt/`bash -n`/`zsh -n` cover the shell, and actionlint
# covers the workflows — but the macOS desktop layer is JSON and TOML, which NOTHING
# looked at. A malformed karabiner.json or aerospace.toml passed every gate green and
# only failed on the next fresh install, silently taking out the keyboard remap or the
# tiling WM. Core's own audit parses ITS configs; this is the repo-owned counterpart.
#
# Three dialects, three parsers:
#   *.json   strict JSON            (karabiner/karabiner.json, renovate.json)
#   *.jsonc  JSON + // line comments (fastfetch/config.jsonc, .markdownlint.jsonc)
#   *.toml   TOML                   (aerospace/aerospace.toml)
#
# JSONC handling strips only lines whose FIRST non-whitespace characters are `//`.
# That is deliberate and safe: JSON has no multi-line strings, so a line-leading `//`
# can never be inside a string value — whereas a naive substring strip would corrupt
# any "https://…" URL. Trailing commas (also legal JSONC) are tolerated the same way
# json5 would, by stripping them before the parse.
#
# core/ is excluded — it is vendored and gated by core/scripts/audit-core.sh upstream.
#
#   ./test/check-configs.sh          # parse everything, report per file
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

# Palette from the VENDORED shared bash UX lib, like verify-core.sh — one colour rule
# instead of a hand-rolled TTY/NO_COLOR block. Degrade gracefully if core/ is absent.
if [[ -r "$REPO/core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/core/lib/ux.sh"
  c_g=$UX_GRN c_r=$UX_RED c_y=$UX_YEL c_0=$UX_RST
else
  c_g='' c_r='' c_y='' c_0=''
fi
ok() { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$*"; }
no() { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; }
skip() { printf '  %s–%s %s\n' "$c_y" "$c_0" "$*"; }

command -v python3 >/dev/null 2>&1 || {
  skip "check-configs: python3 not available — skipped"
  exit 0
}

fail=0
checked=0

# parse <file> <kind> — dispatch one file to the right parser. Kept in ONE python3 -c so
# a file costs one interpreter start, and so the JSONC normalisation has exactly one
# definition rather than being re-implemented per call site.
parse() {
  python3 - "$1" "$2" <<'PY'
import json, re, sys, pathlib

path, kind = sys.argv[1], sys.argv[2]
raw = pathlib.Path(path).read_text(encoding="utf-8")

if kind == "toml":
    try:
        import tomllib
    except ModuleNotFoundError:                 # python < 3.11
        sys.exit(3)
    tomllib.loads(raw)
else:
    if kind == "jsonc":
        # Drop whole-line // comments only (see the header: JSON has no multi-line
        # strings, so a line-leading // is never inside a value), then trailing commas.
        raw = "\n".join(l for l in raw.split("\n") if not l.lstrip().startswith("//"))
        raw = re.sub(r",(\s*[}\]])", r"\1", raw)
    json.loads(raw)
PY
}

while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  case "$f" in
  *.jsonc) kind=jsonc ;;
  *.json) kind=json ;;
  *.toml) kind=toml ;;
  *) continue ;;
  esac
  checked=$((checked + 1))
  if err="$(parse "$f" "$kind" 2>&1)"; then
    ok "$f ($kind)"
  elif [[ $? -eq 3 ]]; then
    skip "$f (toml — python3 < 3.11 has no tomllib)"
  else
    no "$f ($kind) — $(printf '%s' "$err" | tail -n1)"
    fail=1
  fi
done < <(git ls-files '*.json' '*.jsonc' '*.toml' 2>/dev/null | grep -v '^core/')

if ((fail)); then
  printf '%s✗%s structured config parse FAILED\n' "$c_r" "$c_0" >&2
  exit 1
fi
printf '%sconfig parse ok:%s %d file(s)\n' "$c_g" "$c_0" "$checked"

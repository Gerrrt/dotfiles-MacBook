#!/usr/bin/env bash
# test/check-pins.sh — assert the reusable-workflow SHA pins equal the vendored Core.
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS: this repo carries THREE references to a dotfiles-core commit, and
# until now only two were gated:
#
#   core/ subtree        gated by core-integrity (tree object) + verify-core (byte-for-byte)
#   core.lock core_sha   gated by verify-core (must equal the subtree-split marker)
#   the workflow pins    ← gated by NOTHING
#
# The pins decide which reusable workflow actually RUNS. They are not inert: the
# auto-tag caller holds `contents: write` and pushes tags, and the notify-web caller is
# handed two secrets. Running a different Core's version of those than the tree you
# vendored and reviewed is precisely the drift core.lock exists to prevent, one layer up.
#
# The drift is silent by construction: a sync fan-out updates core/ AND core.lock
# together, so both existing gates stay green while the pins keep pointing at the
# PREVIOUS Core. Renovate bumps the pins on its own cadence via the trailing `# vX.Y.Z`
# comment, so the two can be out of step for an arbitrary window with nothing saying so.
#
# The invariant: THE REUSABLE YOU CALL AND THE TREE YOU VENDOR ARE THE SAME CORE COMMIT.
#
# Deliberately a separate script rather than a section of verify-core.sh: that one needs
# the network and SKIPS (exit 0) when upstream is unreachable, which is right for a
# byte-for-byte diff and wrong for this. This check is offline, deterministic, and has no
# reason to ever skip.
#
#   ./test/check-pins.sh          # or: make pins-check
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

# Palette from the VENDORED shared bash UX lib, like verify-core.sh and check-configs.sh.
if [[ -r "$REPO/core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/core/lib/ux.sh"
  c_g=$UX_GRN c_r=$UX_RED c_0=$UX_RST
else
  c_g='' c_r='' c_0=''
fi
ok() { printf '  %s✓%s %s\n' "$c_g" "$c_0" "$*"; }
no() { printf '  %s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; }

[[ -r core.lock ]] || {
  no "core.lock is missing — nothing to verify the pins against"
  exit 1
}
lock_sha="$(sed -n 's/^core_sha=//p' core.lock | head -n1)"
lock_tag="$(sed -n 's/^core_tag=//p' core.lock | head -n1)"
[[ "$lock_sha" =~ ^[0-9a-f]{40}$ ]] || {
  no "core.lock core_sha is missing or malformed: '${lock_sha:-<empty>}'"
  exit 1
}

# The pattern accepts a NON-sha ref (e.g. @v4) on purpose, so a tag-pinned caller is
# REPORTED rather than silently skipped — that is the state #132 fixed and this guards.
PIN_RE='dotgibson/dotfiles-core/\.github/workflows/[^@[:space:]]*@[^[:space:]]*'

fail=0
found=0
for f in .github/workflows/*.yml; do
  [[ -f "$f" ]] || continue
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    found=$((found + 1))
    wf="${ref%@*}"
    wf="${wf##*/}" # bare caller filename, e.g. auto-tag-call.yml
    sha="${ref#*@}"
    # The trailing "# vX.Y.Z" is what Renovate reads; grab it from the source line.
    comment="$(grep -F "$ref" "$f" | sed -n 's/.*# \(v[0-9][^[:space:]]*\).*/\1/p' | head -n1)"

    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      no "$f: $wf is pinned to '$sha', not a 40-char commit SHA"
      fail=1
    elif [[ "$sha" != "$lock_sha" ]]; then
      no "$f: $wf pins ${sha:0:12}, but core.lock vendors ${lock_sha:0:12}"
      fail=1
    elif [[ -n "$lock_tag" && -n "$comment" && "$comment" != "$lock_tag" ]]; then
      no "$f: $wf comment says '$comment', but core.lock records '$lock_tag'"
      fail=1
    else
      ok "${f##*/}: $wf → ${sha:0:12}${comment:+ ($comment)}"
    fi
  done < <(grep -ho "$PIN_RE" "$f" 2>/dev/null)
done

if ((found == 0)); then
  no "no dotfiles-core reusable references found — did the callers move or get renamed?"
  exit 1
fi
if ((fail)); then
  printf '%s✗%s workflow pins DIVERGE from the vendored Core (core.lock %s)\n' \
    "$c_r" "$c_0" "${lock_sha:0:12}" >&2
  printf '   fix: repoint each caller at %s, or re-sync Core so the tree matches the pins\n' \
    "${lock_sha:0:12}" >&2
  exit 1
fi
printf '%spins ok:%s %d reusable(s) → %s%s\n' \
  "$c_g" "$c_0" "$found" "${lock_sha:0:12}" "${lock_tag:+ ($lock_tag)}"

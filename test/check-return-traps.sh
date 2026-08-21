#!/usr/bin/env bash
# test/check-return-traps.sh — refuse a RETURN trap that does not disarm itself.
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS: a bash RETURN trap is a GLOBAL slot, not a function-scoped one. Arm one
# inside a function and it stays armed in the CALLER's frame, firing a SECOND time when the
# caller returns — where the local it was cleaning up is out of scope and `set -u` makes
# that fatal:
#
#     f()     { local tmp; tmp="$(mktemp -d)"; trap CLEANUP RETURN; ...; }
#     outer() { f; ...; }        # ← aborts HERE, on outer's return, not on f's
#
# In dotfiles-Debian that aborted provision() AFTER every package had installed but BEFORE
# wire_links ran — a box carrying the whole stack and not one symlink, wearing the costume
# of a near-complete run (dotgibson/dotfiles-Debian#2). This repo's bootstrap.sh is exactly
# the kind of code that arms cleanup traps.
#
# NOTHING ELSE HERE CAN SEE IT. The broken line is valid bash, so `make shellcheck` and
# `make syntax` both pass it. A textual scan is the only thing that catches this class.
#
# WHY THIS REPO NEEDS ITS OWN COPY OF THE GATE. Core v4.14.0 added this rule as a blocking
# leg of the reusable lint-call.yml, which the other eight vendoring repos inherit. This one
# does not call lint-call.yml — its gate is its own ci.yml + Makefile, and a fuller one
# (gitleaks, markdownlint, config parsing, pin checks, all of which the reusable workflow
# lacks). So the rule has to be ported rather than inherited: dotgibson/dotfiles-MacBook#154,
# and dotgibson/dotfiles-core#564 for the general problem of the two gates drifting.
#
# THE RULE ITSELF IS NOT REIMPLEMENTED HERE. It is _core_return_trap_hits from the VENDORED
# core/scripts/lib/common.sh — the same function Core's audit §5e runs over its own tree,
# covered by ten fixtures in Core's test-core.sh. Copying the regex instead would recreate
# precisely the duplication dotfiles-core#558 was opened to remove. If the rule is wrong,
# it is wrong upstream, and a subtree pull fixes it here.
#
# SCOPE: the same $(SH_FILES) the other shell gates use — every repo-owned *.sh plus
# sketchybar/sketchybarrc, the extensionless bash entry point a '*.sh' glob cannot see.
# core/ is excluded (gated upstream). zsh is out of scope permanently: it has no RETURN
# signal at all (`trap ... RETURN` → "undefined signal"), so the bug cannot exist there.
#
# Exit codes:
#   0  clean, or a graceful skip (the vendored helper is missing — a partial checkout)
#   1  a leaked RETURN trap
#
#   ./test/check-return-traps.sh          # or: make trap-guard
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

LIB="core/scripts/lib/common.sh"

# Palette from the VENDORED shared bash UX lib, like check-configs.sh — one colour rule
# across the repo's gates rather than three hand-rolled copies.
if [[ -r "core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "core/lib/ux.sh"
fi
ok() { printf '%s%s%s %s\n' "${UX_GRN:-}" "${UX_OK:-+}" "${UX_RST:-}" "$*"; }
skip() {
  printf '%s%s%s %s\n' "${UX_YEL:-}" "${UX_INFO:--}" "${UX_RST:-}" "$*"
  exit 0
}
bad() { printf '%s%s%s %s\n' "${UX_RED:-}" "${UX_ERR:-x}" "${UX_RST:-}" "$*" >&2; }

# A missing helper means a partial checkout, not a finding — skip rather than invent a pass
# or a failure. It arrives with the vendored subtree from Core v4.14.0 onward.
[[ -r "$LIB" ]] || skip "check-return-traps: $LIB not present (vendored Core older than v4.14.0?) — skipping"
# shellcheck source=/dev/null
source "$LIB"
command -v _core_return_trap_hits >/dev/null 2>&1 ||
  skip "check-return-traps: the vendored Core has no _core_return_trap_hits — skipping"

# Same file set as the other shell gates. Kept in step with the Makefile's SH_FILES by
# construction: it is passed in when invoked through `make trap-guard`, and derived the
# same way when the script is run directly.
files=()
if (($#)); then
  files=("$@")
else
  while IFS= read -r f; do files+=("$f"); done < <(
    find . -name '*.sh' -not -path './core/*' -not -path './.git/*' | sort
  )
  [[ -f sketchybar/sketchybarrc ]] && files+=("sketchybar/sketchybarrc")
fi
((${#files[@]})) || skip "check-return-traps: no repo-owned shell to scan."

rc=0
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    # Print the offending text, not just the line number: this is what makes a CI finding
    # actionable without a checkout.
    printf '    %s:%s:%s\n' "$f" "$hit" "$(sed -n "${hit}p" "$f")" >&2
    rc=1
  done < <(_core_return_trap_hits "$f")
done

if ((rc)); then
  bad "check-return-traps: a RETURN trap is armed without disarming itself"
  # shellcheck disable=SC2016  # the backticks and the $tmp below are literal PROSE in the
  # advice text — `set -u` is being named, and the reader must see $tmp verbatim to copy
  # the fix. Single quotes are deliberate; expanding any of it would corrupt the message.
  {
    printf '\n    A RETURN trap is a GLOBAL slot: it survives into the CALLER frame and\n'
    printf '    fires again on ITS return, where the local it cleans up is gone and\n'
    printf '    `set -u` makes that fatal. Disarm first, and keep the disarm first:\n\n'
    printf "        trap 'trap - RETURN; rm -rf \"\$tmp\"' RETURN\n\n"
    printf '    Background: dotgibson/dotfiles-Debian#2, dotgibson/dotfiles-core#512.\n'
  } >&2
  exit 1
fi

ok "check-return-traps: ${#files[@]} repo-owned scripts — every RETURN trap disarms itself"

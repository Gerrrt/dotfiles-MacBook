#!/usr/bin/env bash
# test/check-skip-guards.sh — do the "skips if not installed" targets actually skip?
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS: three Makefile targets documented as degrading gracefully did not.
# `secrets`, `zsh-syntax` and `markdownlint` each printed their skip notice and then ran the
# missing tool anyway, so `make lint` could not pass on a box without gitleaks, zsh or npx —
# the exact boxes the guards were written for (#156).
#
# THE MECHANISM, because it is not obvious and will be re-introduced by anyone "tidying" the
# recipes: every line of a make recipe runs in its OWN shell. A guard ending in `exit 0`
# therefore exits only ITS line; make reads that as a successful line and proceeds to the
# next one, which calls the tool just reported missing:
#
#     target:
#     	@command -v tool >/dev/null 2>&1 || { echo "  skip …"; exit 0; }   # exits THIS line
#     	@tool --run                                                        # still runs
#
# The fix is to make the guard and the work ONE recipe line. `brew-check` was never affected
# because its guard uses `exit 1`: the line FAILS, so make aborts the target — the guard is
# broken only when it is trying to succeed, which is why reading the code does not reveal it.
#
# WHY IT NEEDS A TEST AT ALL: CI installs gitleaks and zsh and ships npx, so in CI the `||`
# branch never fires and all three guards are dead code. The bug is invisible to every gate
# and only appears on a developer box. So the test has to CREATE the missing-tool state.
#
# HOW: run each target with a PATH containing only the handful of binaries the Makefile
# needs — and NOT the guarded tool. Symlinks are built from absolute /usr/bin,/bin paths
# rather than `command -v`, which in an interactive shell can resolve to a function or alias
# (this repo's own shells alias several) and would silently produce a broken shim.
#
# Exit codes:
#   0  every guarded target skipped cleanly (or a graceful skip of this test itself)
#   1  a guarded target failed instead of skipping — #156 has regressed
#
#   ./test/check-skip-guards.sh          # or: make skip-guards
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

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

command -v mktemp >/dev/null 2>&1 || skip "check-skip-guards: mktemp unavailable — skipping"
TMP="$(mktemp -d)" || {
  bad "check-skip-guards: mktemp -d failed"
  exit 1
}
trap 'rm -rf "$TMP"' EXIT

# The shim: everything the Makefile itself needs, and nothing that the guards probe for.
# `make` reads SH_FILES via $(shell find … | sort) at PARSE time, so find and sort must be
# present or every target breaks for an unrelated reason and the test proves nothing.
BIN="$TMP/bin"
mkdir -p "$BIN"
for t in bash make find sort sed head cat grep rm; do
  for d in /usr/bin /bin /usr/local/bin; do
    [[ -x "$d/$t" ]] && {
      ln -sf "$d/$t" "$BIN/$t"
      break
    }
  done
done
[[ -x "$BIN/make" && -x "$BIN/bash" && -x "$BIN/find" ]] ||
  skip "check-skip-guards: could not build a shim PATH (make/bash/find not in /usr/bin) — skipping"

# target:tool — the guarded targets and the binary each one probes for.
fail=0
for spec in "zsh-syntax:zsh" "markdownlint:npx" "secrets:gitleaks"; do
  target="${spec%%:*}"
  tool="${spec##*:}"
  # Assert the shim really hides it, or the case below would pass for the wrong reason.
  if PATH="$BIN" command -v "$tool" >/dev/null 2>&1; then
    bad "check-skip-guards: $tool is still on the shim PATH — the $target case would prove nothing"
    fail=1
    continue
  fi
  out="$(PATH="$BIN" make "$target" 2>&1)"
  rc=$?
  if ((rc != 0)); then
    bad "check-skip-guards: 'make $target' exited $rc with $tool absent — it must SKIP, not fail (#156)"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    fail=1
  elif ! printf '%s' "$out" | grep -q "skip $target"; then
    bad "check-skip-guards: 'make $target' exited 0 with $tool absent but printed no skip notice"
    fail=1
  else
    ok "skip-guard: 'make $target' skips cleanly when $tool is absent"
  fi
done

if ((fail)); then
  # shellcheck disable=SC2016  # the backticks are literal PROSE — `exit 0` is being NAMED
  # in the advice text, not run. Single quotes are deliberate so it reaches the reader as
  # written.
  {
    printf '\n    Every line of a make recipe runs in its OWN shell, so a guard ending in\n'
    printf '    `exit 0` exits only THAT line and make runs the next one anyway. Keep the\n'
    printf '    guard and the work on ONE recipe line. See this file'"'"'s header and #156.\n'
  } >&2
  exit 1
fi
ok "check-skip-guards: every guarded target degrades as documented"

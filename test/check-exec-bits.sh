#!/usr/bin/env bash
# test/check-exec-bits.sh — a shebang and the exec bit must agree, both ways.
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS: macos/defaults.sh sat tracked as mode 100644 with a
# `#!/usr/bin/env bash` shebang and a full CLI (-h, --dry-run), the ONE file in the
# repo-owned tree out of step with every other script. Nothing noticed, and the reason
# is the interesting part.
#
# .pre-commit-config.yaml DOES carry the rule, as the upstream pair
# check-executables-have-shebangs + check-shebang-scripts-are-executable. But CI does not
# run pre-commit AT ALL — ci.yml drives the make targets directly — so those two hooks
# only ever fire on a contributor's box, only over the files that commit CHANGES. A file
# that was already wrong when the hooks landed is invisible to both halves: CI never looks,
# and locally it is never in the changed set until someone happens to edit it. At which
# point it blocks THEIR commit, for a defect they did not introduce.
#
# `pre-commit run --all-files` does catch it. Nothing runs that either.
#
# So the rule needs a home CI actually reaches. Core's own audit already gates exec-bit
# drift for core/ (see `make core-audit`); this is the same rule for the half of the tree
# that audit deliberately does not cover.
#
# THE RULE, in both directions:
#   a file starting with `#!`     MUST be mode 100755 — or `./script` dies with
#                                 "permission denied" while `bash script` works, which is
#                                 a confusing way to learn about a mode bit.
#   a file that is mode 100755   MUST start with `#!` — an exec bit on a file the kernel
#                                 cannot launch is a lie about how the file is used, and
#                                 on a `defaults write` script it is a lie with teeth.
#
# Read from the INDEX (`git ls-files -s`), not the filesystem: the mode git records is the
# one that ships, and a umask or a copy onto exFAT can make a working tree disagree with it.
#
# SCOPE: every tracked file outside core/ (gated upstream, and read-only here). Symlinks
# (mode 120000) are skipped — they carry no mode of their own. Deliberately NOT limited to
# $(SH_FILES) like the other shell gates: the whole point is to catch a script this repo
# has not thought to name yet, including one with no extension at all.
#
# Exit codes:
#   0  every tracked file agrees with its own shebang
#   1  at least one disagreement
#
#   ./test/check-exec-bits.sh             # or: make exec-bits
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

# Palette from the VENDORED shared bash UX lib, like the sibling gates — one colour rule
# across the repo's checks rather than another hand-rolled copy.
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

git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  skip "check-exec-bits: not a git working tree (the index is the source of truth) — skipping"

rc=0
n=0
while read -r mode _ _ path; do
  [[ -n "$path" ]] || continue
  [[ "$path" == core/* ]] && continue # gated upstream by Core's own audit
  [[ "$mode" == "120000" ]] && continue
  [[ -f "$path" ]] || continue # staged-for-deletion, or a sparse checkout
  n=$((n + 1))
  # Two bytes is the whole test, and `head -c` on a binary is safe — grep -q just says no.
  local_sh=no
  head -c2 -- "$path" 2>/dev/null | grep -q '^#!' && local_sh=yes
  if [[ "$local_sh" == yes && "$mode" != "100755" ]]; then
    printf '    %s: mode %s but starts with a shebang — run: git add --chmod=+x %s\n' \
      "$path" "$mode" "$path" >&2
    rc=1
  elif [[ "$local_sh" == no && "$mode" == "100755" ]]; then
    printf '    %s: mode %s but has no shebang — run: git add --chmod=-x %s\n' \
      "$path" "$mode" "$path" >&2
    rc=1
  fi
done < <(git ls-files -s)

((n)) || skip "check-exec-bits: no tracked files outside core/ to scan."

if ((rc)); then
  bad "check-exec-bits: a shebang and an exec bit disagree (above)"
  exit 1
fi
ok "check-exec-bits: $n repo-owned file(s) — every shebang matches its exec bit"

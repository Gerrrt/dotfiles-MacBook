#!/usr/bin/env bash
# test/verify-core.sh — assert the vendored core/ subtree is BYTE-FOR-BYTE the upstream
# dotfiles-core commit it was vendored from.
# ──────────────────────────────────────────────────────────────────────────────
# WHY THIS EXISTS: core/scripts/audit-core.sh proves the vendored tree is internally
# consistent, but it canNOT prove it equals upstream — its manifest lists some entries at
# DIRECTORY granularity (e.g. `tmux/scripts/`), so a file ADDED or a tracked file EDITED
# inside such a dir passes the audit while silently diverging from Core. Two real drifts of
# exactly that shape were found here: an orphaned tmux-sessionizer.sh (added, removed
# upstream) and an in-place edit of mise/config.toml. This is the backstop: diff the
# vendored core/ against upstream AT THE RECORDED SUBTREE-SPLIT COMMIT, so ANY difference is
# a genuine local modification — a `git subtree pull` conflict or a hand-edit — not just
# "we're behind upstream" (which comparing against HEAD would noisily flag).
#
# Best-effort + graceful, like the other gates: when upstream is unreachable (offline, a
# restricted runner) or no subtree marker exists, it SKIPS (exit 0) rather than failing —
# it can only verify what it can fetch. Override the upstream with CORE_UPSTREAM (a git URL
# or a local path); the default is the public dotfiles-core.
#
#   ./test/verify-core.sh                              # verify against the public upstream
#   CORE_UPSTREAM=/path/to/dotfiles-core ./test/verify-core.sh   # verify against a local clone
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

# Palette from the VENDORED shared bash UX lib (core/lib/ux.sh) — ONE colour rule instead
# of a hand-rolled TTY/NO_COLOR block that drifts (B4). Guarded: this script must still be
# able to SKIP gracefully when core/ is absent, so fall back to no colour rather than fail.
if [[ -r "$REPO/core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/core/lib/ux.sh"
  c_g=$UX_GRN c_r=$UX_RED c_y=$UX_YEL c_0=$UX_RST
else
  c_g='' c_r='' c_y='' c_0=''
fi
skip() {
  printf '%s–%s %s\n' "$c_y" "$c_0" "$*"
  exit 0
}
ok() { printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
# Non-fatal notice. Distinct from skip(): the run CONTINUES and still verifies.
warn() { printf '%s!%s %s\n' "$c_y" "$c_0" "$*" >&2; }
fail() { printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; }

command -v git >/dev/null 2>&1 || skip "verify-core: git not available"
[[ -d core ]] || skip "verify-core: no vendored core/ here"

# The upstream commit core/ was last vendored from — the subtree squash records it in the
# commit body as `git-subtree-split: <sha>` under `git-subtree-dir: core`.
SPLIT="$(git log --grep='git-subtree-dir: core' -n1 --format='%b' 2>/dev/null |
  sed -n 's/^[[:space:]]*git-subtree-split:[[:space:]]*//p' | head -n1)"
# B1: core.lock is the O(1) offline provenance stamp (core_sha=<full subtree-split>), and
# it OUTRANKS the marker whenever both exist. That used to be the other way round — a
# mismatch hard-failed as "stale lock" — until main sat red for three commits proving the
# assumption backwards: this repo is squash-only (CONTRIBUTING.md), git subtree records
# provenance in COMMIT TRAILERS, and a squash keeps those only if the squash body happens
# to carry the original message. v4.14.3 (#175) lost them; v4.14.2 (#171) kept them. So the
# marker is structurally unreliable here, while core.lock is generated, guarded against
# hand-edits, and independently checked by core-integrity.
#
# Preferring the lock costs no detection power, because the byte-for-byte diff below is the
# real test — the marker/lock comparison only ever picked WHICH commit to diff against:
#   - manual subtree pull, no `make core-lock` → core/ new, lock old → diff FAILS (caught)
#   - a hand-edit of core/                     → core/ edited, lock right → diff FAILS (caught)
#   - a squash ate the marker (this case)      → core/ and lock agree → diff passes (correct)
# so a mismatch is worth saying out loud, but not worth refusing to verify over.
#
# The marker remains the fallback when there is no core.lock at all.
LOCK_SHA=""
if [[ -r core.lock ]]; then
  LOCK_SHA="$(sed -n 's/^core_sha=//p' core.lock | head -n1)"
  # A PRESENT-but-malformed lock (empty / partial / short / non-hex) is an ERROR, not a
  # reason to silently skip: an invalid SHA would make the fetch below fail and the script
  # `skip` (exit 0), quietly disabling verification. Fail loudly instead.
  if [[ ! "$LOCK_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    fail "core.lock has an invalid core_sha ('${LOCK_SHA:-empty}') — expected a 40-char hex SHA; run 'make core-lock' and commit it"
    exit 1
  fi
fi
if [[ -n "$SPLIT" && -n "$LOCK_SHA" && "$SPLIT" != "$LOCK_SHA" ]]; then
  warn "core.lock (${LOCK_SHA:0:12}) != newest subtree-split marker (${SPLIT:0:12}) — verifying against core.lock"
  warn "  usually a squashed sync whose commit body dropped the git-subtree-split trailer, not a bad lock"
  warn "  do NOT 'make core-lock' to silence this: it rebuilds core_sha FROM the stale marker"
fi
# core.lock wins when present; the marker is the fallback for a lock-less checkout.
[[ -z "$LOCK_SHA" ]] || SPLIT="$LOCK_SHA"
[[ -n "$SPLIT" ]] || skip "verify-core: no git-subtree-split marker or core.lock (not a subtree checkout?)"

UPSTREAM="${CORE_UPSTREAM:-https://github.com/dotgibson/dotfiles-core}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/verify-core.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fetch EXACTLY the recorded commit (shallow, like 45-plugins.zsh does for pinned plugins) —
# GitHub serves arbitrary SHAs via fetch. A local-path CORE_UPSTREAM works the same way.
git -C "$TMP" init -q 2>/dev/null || skip "verify-core: cannot init a temp git workspace"
git -C "$TMP" remote add origin "$UPSTREAM" 2>/dev/null
if ! git -C "$TMP" fetch -q --depth 1 origin "$SPLIT" 2>/dev/null; then
  skip "verify-core: upstream commit ${SPLIT:0:12} not fetchable from $UPSTREAM (offline/restricted) — cannot verify"
fi
git -C "$TMP" checkout -q FETCH_HEAD 2>/dev/null || skip "verify-core: could not check out ${SPLIT:0:12}"
rm -rf "$TMP/.git" # compare working trees only

# Byte-for-byte diff: upstream tree (files at its root) vs the vendored core/. `diff -rq`
# reports both content differences AND files present on only one side (orphans / omissions).
#
# EXCEPT nvim/lazy-lock.json: lazy.nvim REWRITES it in place whenever plugins are
# installed/updated, and ~/.config/nvim is bootstrap-symlinked into the vendored core/nvim/
# — so on any machine that actually runs nvim it legitimately drifts from Core's seed
# lockfile. Core still ships a lockfile (the canonical/seed pins), but enforcing it
# byte-for-byte here would make normal editor use break every `core/` sync. So skip it;
# `-x` matches the basename (there's only the one lazy-lock.json, under nvim/).
#
# We tolerate its CONTENT drifting, NOT its ABSENCE: Core ships it as the seed pins, so a
# deletion/omission on either side is a real defect `-x` would otherwise hide. Assert it
# exists in both trees first, then run the content-excluded diff for everything else.
#
# ALSO excluded: .DS_Store. Finder drops one into any directory a user browses, so on a real
# Mac — this repo's entire audience — a stray core/.DS_Store made this gate report
# `Only in core: .DS_Store` and fail. It never surfaced in CI because runners have no Finder.
# It's macOS turd, never Core content, and os/macos.gitignore already excludes it from git;
# excluding it here can't mask a genuine drift.
if [[ ! -f "$TMP/nvim/lazy-lock.json" ]]; then
  fail "upstream @ ${SPLIT:0:12} is missing nvim/lazy-lock.json — Core must ship the seed lockfile"
  exit 1
fi
if [[ ! -f core/nvim/lazy-lock.json ]]; then
  fail "vendored core/nvim/lazy-lock.json is missing — restore it (Core ships the seed pins)"
  exit 1
fi
echo ":: vendored core/ vs upstream dotfiles-core @ ${SPLIT:0:12} (lazy-lock.json: presence-checked, content excluded — machine-mutable; .DS_Store ignored)"
if diff -rq -x lazy-lock.json -x .DS_Store "$TMP" core >"$TMP.diff" 2>&1; then
  ok "vendored core/ is byte-for-byte upstream @ ${SPLIT:0:12} (lazy-lock.json excluded)"
  exit 0
fi
fail "vendored core/ DIFFERS from upstream @ ${SPLIT:0:12} — a subtree conflict or a hand-edit:"
# Re-point diff's temp-dir paths at the friendlier 'upstream'/'core' labels for the report.
sed -e "s#${TMP}#upstream#g" "$TMP.diff" | sed 's/^/    /' >&2
fail "fix: revert the local change (edit upstream + re-sync), or re-run the subtree pull cleanly"
exit 1

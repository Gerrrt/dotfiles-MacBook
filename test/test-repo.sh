#!/usr/bin/env bash
# test/test-repo.sh — behavioral regression harness for THIS repo's own code.
# ──────────────────────────────────────────────────────────────────────────────
# `make test` runs the VENDORED Core harness (core/scripts/test-core.sh). That never
# touches the repo-owned surface: bootstrap.sh (symlink/backup/seed/dry-run/arg-parse),
# the zsh loader in zsh/zshrc, the macOS interactive layer, or macos/defaults.sh. Those
# are the highest-risk, hardest-to-reverse scripts here and were previously gated only
# by `bash -n`/`zsh -n` (syntax, not behaviour). This harness closes that gap.
#
# It is HERMETIC and runs anywhere (Linux CI included): bootstrap.sh is macOS-only, so
# we set BOOTSTRAP_ALLOW_NON_DARWIN=1 and only ever exercise its --dry-run / arg-parse /
# output paths — never a real provision. Every mutation is sandboxed under a temp HOME.
# zsh-dependent checks self-skip when zsh is absent (matching test-core.sh's contract).
#
#   ./test/test-repo.sh            # run everything
#   ./test/test-repo.sh --quiet    # only print failures + the summary
# ──────────────────────────────────────────────────────────────────────────────
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

# ── tiny assert framework ─────────────────────────────────────────────────────
# Palette from the VENDORED shared bash UX lib (core/lib/ux.sh) — ONE colour rule across
# the repo's bash instead of a hand-rolled TTY/NO_COLOR block that drifts (B4). Maps UX_*
# onto the c_* names this harness already uses. Guarded so the harness still runs if core/
# is somehow absent (degrades to no colour, never an unbound-var error under set -u).
if [[ -r "$REPO/core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/core/lib/ux.sh"
  c_g=$UX_GRN c_r=$UX_RED c_d=$UX_DIM c_0=$UX_RST
else
  c_g='' c_r='' c_d='' c_0=''
fi
pass=0 fail=0 skip=0
ok() {
  pass=$((pass + 1))
  ((QUIET)) || printf '  %s✓%s %s\n' "$c_g" "$c_0" "$1"
}
no() {
  fail=$((fail + 1))
  printf '  %s✗%s %s\n' "$c_r" "$c_0" "$1" >&2
  [[ -n "${2:-}" ]] && printf '      %s%s%s\n' "$c_d" "$2" "$c_0" >&2
}
skipt() {
  skip=$((skip + 1))
  ((QUIET)) || printf '  %s· skip%s %s\n' "$c_d" "$c_0" "$1"
}
section() { ((QUIET)) || printf '\n%s== %s ==%s\n' "$c_d" "$1" "$c_0"; }

# assert_eq <desc> <expected> <actual>
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }
# assert_contains <desc> <haystack> <needle>
assert_contains() { if [[ "$2" == *"$3"* ]]; then ok "$1"; else no "$1" "missing '$3' in: $2"; fi; }
# assert_not_contains <desc> <haystack> <needle>
assert_not_contains() { if [[ "$2" != *"$3"* ]]; then ok "$1"; else no "$1" "unexpected '$3' present"; fi; }

# Run bootstrap.sh in a throwaway HOME, capturing stdout+stderr and the exit code.
# Sets globals OUT (combined output) and RC (exit status). Never provisions.
SANDBOX=""
run_bootstrap() { # run_bootstrap <piped|tty-irrelevant> <args...>
  shift
  local home
  home="$(mktemp -d)"
  SANDBOX="$home"
  OUT="$(HOME="$home" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR='' bash "$REPO/bootstrap.sh" "$@" 2>&1)"
  RC=$?
}

# ── A. bootstrap.sh: help + arg parsing ───────────────────────────────────────
section "bootstrap.sh — help & argument parsing"

OUT="$(bash "$REPO/bootstrap.sh" --help 2>&1)"
RC=$?
assert_eq "--help exits 0" 0 "$RC"
assert_contains "--help prints the banner" "$OUT" "bootstrap.sh — idempotent"

OUT="$(bash "$REPO/bootstrap.sh" --bogus 2>&1)"
RC=$?
assert_eq "unknown flag exits 2 (usage-error convention)" 2 "$RC"
assert_contains "unknown flag names the offender" "$OUT" "unknown flag: --bogus"

# did-you-mean (U4): hyphen-slip typos should suggest the real flag.
for pair in "--dryrun:--dry-run" "--link-only:--links-only" "--nobrew:--no-brew" "--setshell:--set-shell"; do
  typo="${pair%%:*}" want="${pair##*:}"
  OUT="$(bash "$REPO/bootstrap.sh" "$typo" 2>&1)"
  assert_contains "typo '$typo' suggests '$want'" "$OUT" "did you mean $want?"
done
# An unrelated token must NOT produce a bogus suggestion.
OUT="$(bash "$REPO/bootstrap.sh" --zzzzzz 2>&1)"
assert_not_contains "unrelated typo gives no false suggestion" "$OUT" "did you mean"

# ── B. bootstrap.sh: dry-run is a true no-op + scannable output ────────────────
section "bootstrap.sh — dry-run plan (hermetic, no mutations)"

run_bootstrap piped --links-only --dry-run
assert_eq "dry-run exits 0" 0 "$RC"
assert_contains "dry-run announces itself" "$OUT" "DRY RUN"
assert_contains "dry-run prints a run summary" "$OUT" "linked ·"
assert_contains "dry-run closes with the safe-to-rerun note" "$OUT" "re-run without --dry-run"

# Output piped (not a TTY) must be free of raw ANSI escapes (U1).
esc=$(printf '%s' "$OUT" | grep -c $'\e' || true)
assert_eq "piped output carries no ANSI escape bytes" 0 "$esc"

# A dry run must not create ANYTHING in the sandbox HOME (no symlinks, no backups).
created=$(find "$SANDBOX" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "dry-run creates zero files in HOME" 0 "$created"
[[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"

# ── B1b. bootstrap.sh: a REAL apply creates the links + is idempotent (B8) ─────
# The CI macOS job only ever ran `--links-only --dry-run` (the PLAN), so a regression in
# the actual link/seed step — a renamed source, a broken wire_links edit — could ship
# green. This exercises a real apply against a sandboxed HOME and asserts the links land
# (pointing INTO the repo), seeds are real files, a re-apply is idempotent, and the
# apply→uninstall round-trip is clean. Hermetic: pre-seed tpm so wire_links skips the
# network clone (and so the #133 tpm check below finds it), and stub `mise` — belt and
# braces, since --links-only no longer runs `mise install` at all. Note the stub alone was
# never enough on macOS: brew_shellenv PREPENDS /opt/homebrew/bin, shadowing it.
# Runs on Linux CI too (BOOTSTRAP_ALLOW_NON_DARWIN).
section "bootstrap.sh — real apply creates links, idempotent, round-trips (B8)"

ahome="$(mktemp -d)"
abin="$(mktemp -d)"
mkdir -p "$ahome/.config/tmux/plugins/tpm"
printf '#!/bin/sh\nexit 0\n' >"$abin/mise"
chmod +x "$abin/mise"
OUT="$(HOME="$ahome" PATH="$abin:$PATH" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" --no-brew --links-only 2>&1)"
arc=$?
((arc == 0)) || printf '%s\n' "$OUT" | sed 's/^/    [apply diag] /' >&2 # surface where it stopped
assert_eq "apply (--no-brew --links-only) exits 0" 0 "$arc"
for l in .zshenv .config/zsh/.zshrc .config/starship.toml .config/nvim .local/bin/clip; do
  tgt="$(readlink "$ahome/$l" 2>/dev/null || true)"
  case "$tgt" in
  "$REPO"/*) ok "apply linked $l → repo" ;;
  *) no "apply linked $l → repo" "got: ${tgt:-<missing>}" ;;
  esac
done
if [[ -f "$ahome/.config/git/local.gitconfig" && ! -L "$ahome/.config/git/local.gitconfig" ]]; then
  ok "apply seeded local.gitconfig as a real file (editable, not a symlink)"
else
  no "apply seeded local.gitconfig as a real file" "missing or a symlink"
fi
OUT="$(HOME="$ahome" PATH="$abin:$PATH" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" --no-brew --links-only 2>&1)"
arc=$?
((arc == 0)) || printf '%s\n' "$OUT" | sed 's/^/    [re-apply diag] /' >&2
assert_eq "re-apply exits 0 (idempotent)" 0 "$arc"
assert_contains "re-apply reports an already-linked file" "$OUT" "already linked"
HOME="$ahome" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" --uninstall >/dev/null 2>&1
if [[ -L "$ahome/.zshenv" ]]; then no "apply→uninstall round-trip removes the links" "still a link"; else ok "apply→uninstall round-trip removes the links"; fi
rm -rf "$ahome" "$abin"

# ── B1b2. bootstrap.sh: a brew ALREADY on PATH is success, not failure ─────────
# `brew shellenv` opens with an idempotence guard and prints NOTHING (exit 0) when its own
# bin:sbin already lead PATH. brew_shellenv used to read that empty output as breakage, so
# a full run on a perfectly healthy box closed with a red "produced no output" — and, now
# that the error is ledgered, would exit 3. bootstrap.sh calls brew_shellenv TWICE and the
# first call's eval creates exactly that PATH, so the second call always trips the guard;
# leading PATH with brew's bin:sbin reproduces it in single-call --links-only mode.
# Needs a REAL brew — the guard lives in Homebrew, and brew_shellenv hardcodes absolute
# prefixes, so nothing here can be stubbed. Self-skips where there is no Homebrew.
section "bootstrap.sh — brew already on PATH is success, not failure"

realbrew=""
for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
  [[ -x "$b" ]] && {
    realbrew="$b"
    break
  }
done
if [[ -z "$realbrew" ]]; then
  skipt "brew already on PATH is not a failure (no Homebrew on this box)"
else
  leadpath="${realbrew%/brew}:${realbrew%/bin/brew}/sbin"
  # Assert the PREMISE first, so a future Homebrew that drops the guard retires this test
  # loudly instead of passing vacuously.
  guard_out="$(PATH="$leadpath:/usr/bin:/bin" "$realbrew" shellenv 2>/dev/null || true)"
  if [[ -n "$guard_out" ]]; then
    skipt "brew already on PATH is not a failure (this Homebrew has no idempotence guard)"
  else
    ahome="$(mktemp -d)"
    abin="$(mktemp -d)"
    mkdir -p "$ahome/.config/tmux/plugins/tpm"
    printf '#!/bin/sh\nexit 0\n' >"$abin/mise"
    chmod +x "$abin/mise"
    OUT="$(HOME="$ahome" PATH="$leadpath:$abin:$PATH" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" --no-brew --links-only 2>&1)"
    arc=$?
    ((arc == 0)) || printf '%s\n' "$OUT" | sed 's/^/    [brew-on-PATH diag] /' >&2
    assert_eq "brew-leading PATH: --links-only exits 0" 0 "$arc"
    assert_not_contains "brew-leading PATH: no 'produced no output' error" "$OUT" "produced no output"
    assert_not_contains "brew-leading PATH: no 'did not put ... on PATH' error" "$OUT" "did not put"
    rm -rf "$ahome" "$abin"
  fi
fi

# ── B1b3. bootstrap.sh: a CRASHING brew degrades the run, it does not silence it ─
# Regression, and the nastiest failure this script has had. A broken vendored gem stack
# makes every `brew bundle` subcommand crash while plain `brew list` still works, so
# provision() reached:
#     n_pkgs="$(brew bundle list … 2>/dev/null | wc -l | tr -d ' ')"
# `set -o pipefail` propagated the crash through the pipeline, and a STANDALONE assignment
# IS the command — so `set -e` killed the whole run right there. The traceback was already
# discarded by `2>/dev/null`, and provision() is the FIRST thing a full run does, so the
# user saw absolutely ZERO output and a non-zero exit, with not one symlink wired.
# A stub on PATH cannot reproduce this (brew_shellenv's path_helper prepends
# /opt/homebrew/bin and shadows it) — hence the BOOTSTRAP_BREW seam, which also keeps this
# full-provision run from ever touching the real Homebrew installer.
# Self-skips where provisioning cannot run at all (no Command Line Tools → Linux CI).
section "bootstrap.sh — a crashing brew degrades the run, it does not silence it"

if ! command -v xcode-select >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
  skipt "crashing brew degrades the run (no Command Line Tools — provisioning cannot run here)"
else
  ahome="$(mktemp -d)"
  abin="$(mktemp -d)"
  mkdir -p "$ahome/.config/tmux/plugins/tpm"
  printf '#!/bin/sh\nexit 0\n' >"$abin/mise"
  printf '#!/bin/sh\nexit 1\n' >"$abin/brew" # every subcommand crashes, as the real one did
  chmod +x "$abin/mise" "$abin/brew"
  # A FULL run (no --links-only/--no-brew): the provision path is the whole point.
  OUT="$(HOME="$ahome" PATH="$abin:$PATH" BOOTSTRAP_BREW="$abin/brew" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" 2>&1)"
  brc=$?
  # The headline symptom, asserted on its own: silence is the bug.
  if [[ -n "$OUT" ]]; then ok "crashing brew: the run still PRINTS"; else no "crashing brew: the run still PRINTS" "zero bytes of output"; fi
  assert_eq "crashing brew: exits 3 (degraded), not 1 (aborted)" 3 "$brc"
  # Only reachable if the count assignment survived the crash — the precise pin for the bug.
  assert_contains "crashing brew: the '?' package-count fallback is reachable" "$OUT" "(? formulae/casks"
  assert_contains "crashing brew: the bundle failure is ledgered" "$OUT" "brew bundle failed"
  assert_contains "crashing brew: the summary still prints" "$OUT" "linked ·"
  if [[ -L "$ahome/.zshenv" ]]; then ok "crashing brew: symlinks were still wired"; else no "crashing brew: symlinks were still wired" "the sandbox .zshenv is not a link"; fi
  rm -rf "$ahome" "$abin"
fi

# ── B1c. bootstrap.sh: a degraded run REPORTS itself (#133) ───────────────────
# Steps that must not abort the run (mise, defaults.sh, chsh, tpm) were each written
# `|| info "…"` and forgotten: the run still closed with "bootstrap complete" and exit 0,
# so a box that got none of its runtimes looked exactly like a clean one — to the operator
# and to anything parsing --json. These assert the three halves of the fix: the ledger
# reaches --json, a failure changes the exit code, and warnings do NOT.
section "bootstrap.sh — degraded runs report themselves (#133)"

# run_bootstrap merges 2>&1, which cannot express the fd-3 discipline (`exec 3>&1 1>&2`):
# under --json the ONLY thing on real stdout is the summary object. Keep them separate.
JSON_OUT="" ERR_OUT=""
run_bootstrap_json() { # run_bootstrap_json <args...> → JSON_OUT, ERR_OUT, RC
  local home errf
  home="$(mktemp -d)"
  errf="$(mktemp)"
  SANDBOX="$home"
  JSON_OUT="$(HOME="$home" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" "$@" 2>"$errf")"
  RC=$?
  ERR_OUT="$(cat "$errf")"
  rm -f "$errf"
}

run_bootstrap_json --links-only --dry-run --json
assert_eq "clean --json run exits 0" 0 "$RC"
assert_eq "--json puts exactly ONE line on real stdout" 1 "$(printf '%s\n' "$JSON_OUT" | wc -l | tr -d ' ')"
assert_contains "--json reports ok:true on a clean run" "$JSON_OUT" '"ok":true'
assert_contains "--json carries an errors[] channel" "$JSON_OUT" '"errors":[]'
assert_contains "--json carries a warnings[] channel" "$JSON_OUT" '"warnings":'
# The human body must be on stderr, never mixed into the object automation parses.
assert_not_contains "--json keeps the human summary off stdout" "$JSON_OUT" "linked ·"
assert_contains "--json still prints the human summary on stderr" "$ERR_OUT" "linked ·"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "--json emits parseable JSON"
  else
    no "--json emits parseable JSON" "$JSON_OUT"
  fi
else
  skipt "--json emits parseable JSON (no python3)"
fi
# A warning (a tool not on PATH yet — the norm on Linux CI, where nothing is installed)
# must NOT degrade the run. On a fully-provisioned Mac there are no warnings and this is
# vacuously true, so assert the implication rather than the presence.
case "$JSON_OUT" in
*'"warnings":[]'*) skipt "warnings do not change the exit code (none raised here)" ;;
*) assert_eq "a run with warnings but no errors still exits 0" 0 "$RC" ;;
esac
[[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"

# A FAILED step must exit 3 and say so. Injected via the issue's own scenario: tpm is
# cloned over https by wire_links, so GIT_ALLOW_PROTOCOL=file makes that clone fail the
# way a proxy does — deterministic, offline, and no stub can be shadowed by brew_shellenv.
# The sandbox HOME deliberately does NOT pre-seed tpm, so the clone is actually attempted.
run_bootstrap_json_nogit() {
  local home errf
  home="$(mktemp -d)"
  errf="$(mktemp)"
  SANDBOX="$home"
  JSON_OUT="$(HOME="$home" GIT_ALLOW_PROTOCOL=file BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 \
    bash "$REPO/bootstrap.sh" "$@" 2>"$errf")"
  RC=$?
  ERR_OUT="$(cat "$errf")"
  rm -f "$errf"
}
run_bootstrap_json_nogit --no-brew --links-only --json
assert_eq "a failed step exits 3 (partial success), not 0" 3 "$RC"
assert_contains "the failure names tpm" "$ERR_OUT" "tpm"
assert_contains "a degraded run does NOT claim to be complete" "$ERR_OUT" "failed step(s)"
assert_not_contains "a degraded run does NOT print the clean closing line" "$ERR_OUT" "bootstrap complete"
assert_contains "--json reports ok:false when a step failed" "$JSON_OUT" '"ok":false'
assert_contains "--json lists the failure in errors[]" "$JSON_OUT" "tpm"
# The object must STILL be emitted on a degraded run — reading why is the whole point.
assert_eq "--json still emits exactly one line when degraded" 1 "$(printf '%s\n' "$JSON_OUT" | wc -l | tr -d ' ')"
[[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"

# --links-only promises "no installs" in both usage() and the README, but the mise step
# sat outside the provision branch and ran anyway — which also meant `make test-repo`
# drove a real `mise install` of every pinned runtime on any dev box with mise on PATH.
run_bootstrap piped --links-only --dry-run
assert_not_contains "--links-only does not run mise install" "$OUT" "installing mise-managed tools"
[[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"

assert_contains "--help documents the exit codes" "$(bash "$REPO/bootstrap.sh" --help 2>&1)" "3  ran, but one or more steps FAILED"

# ── B2. bootstrap.sh --uninstall: reverse links + restore backups (B4) ─────────
section "bootstrap.sh — uninstall (reverse symlinks, restore backups, skip foreign)"

# dry-run uninstall is a true no-op + scannable.
run_bootstrap piped --uninstall --dry-run
assert_eq "uninstall --dry-run exits 0" 0 "$RC"
assert_contains "uninstall --dry-run announces itself" "$OUT" "DRY RUN"
assert_contains "uninstall prints its summary" "$OUT" "uninstall summary"
created=$(find "$SANDBOX" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
assert_eq "uninstall --dry-run creates nothing" 0 "$created"
[[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"

# functional: a Core symlink + its backup is reversed; a FOREIGN symlink is left alone.
uhome="$(mktemp -d)"
ucfg="$uhome/.config/zsh"
mkdir -p "$ucfg"
ln -s "$REPO/zsh/zshrc" "$ucfg/.zshrc"                           # ours (points into the repo)
printf 'ORIGINAL\n' >"$ucfg/.zshrc.pre-dotfiles.20250101-120000" # a prior backup
# v4: uninstall visits the NUMBERED fragment dests (core/zsh/NN-name.zsh → $CFG/zsh/NN-name.zsh),
# so plant the foreign link at a numbered slot it actually inspects (20-aliases.zsh).
ln -s /etc/hostname "$ucfg/20-aliases.zsh" # foreign (not into the repo)
OUT="$(HOME="$uhome" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" --uninstall 2>&1)"
assert_eq "uninstall exits 0" 0 "$?"
if [[ -L "$ucfg/.zshrc" ]]; then no "uninstall removed our symlink" "still a link"; else ok "uninstall removed our symlink"; fi
assert_eq "uninstall restored the backup over it" "ORIGINAL" "$(cat "$ucfg/.zshrc" 2>/dev/null)"
if [[ -L "$ucfg/20-aliases.zsh" ]]; then ok "uninstall left a FOREIGN symlink untouched"; else no "uninstall left a foreign symlink untouched" "it was removed"; fi
assert_contains "uninstall flags the foreign link as not-ours" "$OUT" "not ours"
rm -rf "$uhome"

# safety: if the user replaced our symlink with a REAL file, uninstall must NOT clobber it
# with a stale backup (it must leave real files untouched). Regression for the data-loss
# path Copilot flagged: a real file at $dest + a .pre-dotfiles.* backup present.
shome="$(mktemp -d)"
scfg="$shome/.config/zsh"
mkdir -p "$scfg"
printf 'USER REAL FILE\n' >"$scfg/.zshrc"                            # a real file the user put there
printf 'STALE BACKUP\n' >"$scfg/.zshrc.pre-dotfiles.20240101-000000" # an old backup also present
OUT="$(HOME="$shome" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" --uninstall 2>&1)"
assert_eq "uninstall does NOT overwrite a real file with a stale backup" "USER REAL FILE" "$(cat "$scfg/.zshrc" 2>/dev/null)"
assert_contains "uninstall reports it skipped the real file" "$OUT" "real file present"
rm -rf "$shome"

# --uninstall --json must emit the object too. It did not: uninstall() is reached from a
# short-circuit whose `exit 0` sat ABOVE the emitter at the foot of bootstrap.sh, so the
# one path that fills `removed`/`restored` was the one path that printed nothing. Fixed by
# factoring the emitter into emit_json() and calling it from BOTH exits — these assertions
# pin that down, so re-inlining it (or adding a third early exit) fails here.
jhome="$(mktemp -d)"
jcfg="$jhome/.config/zsh"
mkdir -p "$jcfg"
ln -s "$REPO/zsh/zshrc" "$jcfg/.zshrc"                           # ours — makes removed >= 1
printf 'ORIGINAL\n' >"$jcfg/.zshrc.pre-dotfiles.20250101-120000" # a backup — makes restored >= 1
jerr="$(mktemp)"
JSON_OUT="$(HOME="$jhome" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 \
  bash "$REPO/bootstrap.sh" --uninstall --json 2>"$jerr")"
RC=$?
ERR_OUT="$(cat "$jerr")"
rm -f "$jerr"
assert_eq "uninstall --json exits 0" 0 "$RC"
assert_eq "uninstall --json puts exactly ONE line on real stdout" 1 "$(printf '%s\n' "$JSON_OUT" | wc -l | tr -d ' ')"
# The two counters that ONLY an uninstall fills — the reason the object has to exist here.
assert_contains "uninstall --json reports what it removed" "$JSON_OUT" '"removed":1'
assert_contains "uninstall --json reports what it restored" "$JSON_OUT" '"restored":1'
assert_contains "uninstall --json carries the same ok verdict key" "$JSON_OUT" '"ok":true'
# The fd discipline (`exec 3>&1 1>&2`) must hold on this path too: human body on stderr.
assert_not_contains "uninstall --json keeps the human summary off stdout" "$JSON_OUT" "removed ·"
assert_contains "uninstall --json still prints the human summary on stderr" "$ERR_OUT" "removed ·"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$JSON_OUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    ok "uninstall --json emits parseable JSON"
  else
    no "uninstall --json emits parseable JSON" "$JSON_OUT"
  fi
else
  skipt "uninstall --json emits parseable JSON (no python3)"
fi
# --dry-run must preview, not mutate: same object, dry_run:true, and the link still there.
JSON_OUT="$(HOME="$jhome" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 \
  bash "$REPO/bootstrap.sh" --uninstall --dry-run --json 2>/dev/null)"
assert_contains "uninstall --dry-run --json marks itself dry_run:true" "$JSON_OUT" '"dry_run":true'
rm -rf "$jhome"

# A dest that will NOT unlink must be recorded and stepped over, not fatal. `rm -f` and
# `mv` were bare under `set -euo pipefail`, so an unwritable parent aborted the script
# mid-uninstall: no summary, no --json object, a half-reversed HOME and no record of which
# half. Now it's a fail_note — the other ~40 dests still come out, errors[] names the one
# that didn't, and the run exits 3 like any other degraded run.
#
# Injected with a read-only parent dir (chmod a-w), which makes `rm` fail with EACCES for
# real rather than via a stub. root ignores the write bit, so skip there.
if [[ "$(id -u)" -eq 0 ]]; then
  skipt "uninstall records an unremovable dest instead of aborting (running as root)"
else
  fhome="$(mktemp -d)"
  fcfg="$fhome/.config/zsh"
  mkdir -p "$fcfg" "$fhome/.config/git"
  ln -s "$REPO/zsh/zshrc" "$fcfg/.zshrc"               # ours, but about to be unremovable
  ln -s "$REPO/os/macos.gitconfig" "$fhome/.gitconfig" # ours, in a WRITABLE dir → must still come out
  chmod a-w "$fcfg"                                    # rm -f "$fcfg/.zshrc" now fails
  ferr="$(mktemp)"
  JSON_OUT="$(HOME="$fhome" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 \
    bash "$REPO/bootstrap.sh" --uninstall --json 2>"$ferr")"
  RC=$?
  ERR_OUT="$(cat "$ferr")"
  rm -f "$ferr"
  chmod u+w "$fcfg" # restore before cleanup, or rm -rf can't recurse
  assert_eq "an unremovable dest exits 3 (partial reversal), not 0" 3 "$RC"
  assert_contains "the failure names the dest that would not unlink" "$ERR_OUT" ".zshrc"
  assert_contains "a partial uninstall does NOT claim to be clean" "$ERR_OUT" "failed step(s)"
  assert_contains "uninstall --json reports ok:false when a dest resisted" "$JSON_OUT" '"ok":false'
  assert_contains "uninstall --json lists the stuck dest in errors[]" "$JSON_OUT" "still wired to this repo"
  # The whole point of continuing: the run must not abort at the stuck dest.
  assert_eq "the object is still emitted on a partial uninstall" 1 "$(printf '%s\n' "$JSON_OUT" | wc -l | tr -d ' ')"
  if [[ -L "$fhome/.gitconfig" ]]; then
    no "uninstall keeps going past a stuck dest" ".gitconfig in the writable dir was never unlinked"
  else
    ok "uninstall keeps going past a stuck dest"
  fi
  assert_contains "the stuck dest is NOT counted as removed" "$JSON_OUT" '"removed":1'
  rm -rf "$fhome"
fi

# ── C. zsh loader (zsh/zshrc) actually executes ───────────────────────────────
# `make zsh-syntax` only parses (zsh -n). This sources the real loader against a
# hermetic ZDOTDIR of numbered stub fragments and asserts it runs clean AND sources
# them in numeric order.
section "zsh/zshrc — loader executes (not just parses)"
if command -v zsh >/dev/null 2>&1; then
  zhome="$(mktemp -d)"
  zcfg="$zhome/zsh"
  mkdir -p "$zcfg"
  # v4: Core modules are NUMBERED fragments (NN-name.zsh); the vendored loader globs
  # $ZSH_CFG/[0-9][0-9]-*.zsh and sorts by the NN prefix. One stub per fragment appends its
  # NN-name to an order log so we can prove the numeric load order. (05-ui is intentionally
  # omitted — the glob simply never matches it, exercising the real missing-fragment path.)
  frags=(00-tools 10-options 15-history 20-aliases 25-git 30-functions 35-fzf 40-bindings 45-plugins 50-op 55-maint 60-update 80-os 99-local)
  for m in "${frags[@]}"; do
    # The $ZSH_ORDER_LOG ref is meant to expand inside the stub at zsh runtime, not here.
    # shellcheck disable=SC2016
    printf 'print -r -- %s >> "$ZSH_ORDER_LOG"\n' "$m" >"$zcfg/$m.zsh"
  done
  # zshrc sources the VENDORED loader (v4) rather than an inline loop, so the sandbox needs
  # loader.zsh present (bootstrap symlinks it from core/zsh/ in a real install). The loader
  # itself has no NN- prefix, so the glob never picks it up.
  ln -s "$REPO/core/zsh/loader.zsh" "$zcfg/loader.zsh"
  order_log="$zhome/order.log"
  # A global /etc/zshenv can force ZDOTDIR (overriding an env-passed one), so set ZDOTDIR
  # INSIDE -c after /etc/zshenv has run — the hermetic pattern core/scripts/test-core.sh uses.
  zerr="$(ZSH_ORDER_LOG="$order_log" zsh -f -c "ZDOTDIR='$zcfg'; source '$REPO/zsh/zshrc'" 2>&1)"
  zrc=$?
  assert_eq "loader sources cleanly (exit 0)" 0 "$zrc"
  assert_eq "loader produced no errors" "" "$zerr"
  got_order="$(tr '\n' ' ' <"$order_log" 2>/dev/null | sed 's/ $//')"
  assert_eq "fragments sourced in numeric order" "${frags[*]}" "$got_order"
  # zcompile self-heal: a .zwc should appear next to a sourced stub.
  if compgen -G "$zcfg"/*.zwc >/dev/null; then
    ok "loader byte-compiles fragments (.zwc written beside the symlink)"
  else
    skipt "zcompile produced no .zwc (acceptable on this zsh build)"
  fi
  rm -rf "$zhome"
else
  skipt "zsh absent — skipping loader execution checks"
  skipt "zsh absent — skipping loader order check"
fi

# ── D. macOS interactive layer + repo-owned completion ────────────────────────
# Source the REAL os/macos.zsh (not a re-implementation) so its actual fpath/compdef
# wiring — including the ${…:A:h:h}/completions path resolution — is what's under test.
# The script is single-quoted and the temp dump path + repo root are passed as
# positional args ($1/$2), so there is no nested bash/zsh substitution to get wrong.
# compinit must run first (80-os.zsh guards on compdef); the auto-tmux exec at os.zsh's
# tail self-skips here because stdout isn't a TTY (its `-t 1` guard is false).
section "os/macos.zsh — sources clean & registers the bootstrap completion"
if command -v zsh >/dev/null 2>&1; then
  oshome="$(mktemp -d)"
  merr="$(ZDOTDIR="$oshome" zsh -f -c '
    autoload -Uz compinit && compinit -u -d "$1" >/dev/null 2>&1
    source "$2/os/macos.zsh"
    (( $+functions[_bootstrap] )) || { print "_bootstrap not autoloaded by os/macos.zsh" >&2; exit 1; }
    [[ -n ${_comps[bootstrap.sh]:-} ]] || { print "bootstrap.sh completion not registered" >&2; exit 1; }
  ' zsh-test "$oshome/.zcompdump" "$REPO" 2>&1)"
  mrc=$?
  assert_eq "os/macos.zsh sources clean & registers _bootstrap completion" 0 "$mrc"
  [[ -n "$merr" ]] && no "sourcing os/macos.zsh produced unexpected output" "$merr"
  rm -rf "$oshome"
else
  skipt "zsh absent — skipping completion registration check"
fi

# ── E. macos/defaults.sh: arg parsing + dry-run summary ───────────────────────
section "macos/defaults.sh — arg parsing & dry-run"
OUT="$(bash "$REPO/macos/defaults.sh" -h 2>&1)"
RC=$?
assert_eq "defaults.sh -h exits 0" 0 "$RC"
OUT="$(bash "$REPO/macos/defaults.sh" --bogus 2>&1)"
RC=$?
assert_eq "defaults.sh rejects unknown arg (exit 2)" 2 "$RC"
assert_contains "defaults.sh names the bad arg" "$OUT" "unknown argument: --bogus"
# Dry-run shadows every mutator, so it is safe to execute even off-macOS.
OUT="$(bash "$REPO/macos/defaults.sh" --dry-run 2>&1)"
RC=$?
assert_eq "defaults.sh --dry-run exits 0" 0 "$RC"
assert_contains "defaults.sh --dry-run prints a summary" "$OUT" "nothing changed"
esc=$(printf '%s' "$OUT" | grep -c $'\e' || true)
assert_eq "defaults.sh piped output carries no ANSI escapes" 0 "$esc"

# ── F. ghostty/config — seeded but otherwise un-validated ─────────────────────
# ghostty has no headless config-lint, so we can't truly parse it; but a smoke check
# catches gross corruption a symlink would happily wire up — a merge-conflict marker,
# a stray paste, a truncated file. ghostty's format is `key = value` (or `#` comments),
# so every non-blank, non-comment line must contain '='. Cheap; catches the real breakage.
section "ghostty/config — no obvious corruption (key = value lines)"
if [[ -s "$REPO/ghostty/config" ]]; then
  bad="$(grep -vE '^[[:space:]]*(#|$)' "$REPO/ghostty/config" | grep -vE '=' || true)"
  if [[ -z "$bad" ]]; then
    ok "ghostty/config: every directive is a key = value line"
  else
    no "ghostty/config has non-comment line(s) without '='" "$(printf '%s' "$bad" | head -3)"
  fi
else
  no "ghostty/config is missing or empty" "expected a seeded config at ghostty/config"
fi

# ── summary ───────────────────────────────────────────────────────────────────
printf '\n%s──────── repo test summary ────────%s\n' "$c_d" "$c_0"
printf '  %spass %d%s   %sskip %d%s   ' "$c_g" "$pass" "$c_0" "$c_d" "$skip" "$c_0"
if ((fail)); then
  printf '%sfail %d%s\n' "$c_r" "$fail" "$c_0"
  printf '%srepo tests FAILED%s\n' "$c_r" "$c_0" >&2
  exit 1
fi
printf 'fail 0\n'
printf '%srepo tests OK%s\n' "$c_g" "$c_0"

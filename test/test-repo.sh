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
# we set BOOTSTRAP_ALLOW_NON_DARWIN=1. Every mutation is sandboxed under a temp HOME, and
# zsh-dependent checks self-skip when zsh is absent (matching test-core.sh's contract).
#
# PROVISION IS EXERCISED HERE, and this file is where that fact lives (#178). Sections
# B1b3/B1b4 run a FULL bootstrap — no --links-only — so provision() actually executes.
# They reach it only through the BOOTSTRAP_BREW seam and a PATH shim dir, never the real
# Homebrew, and they self-skip where the Command Line Tools are absent (so Linux CI runs
# everything except them). The macOS CI leg sets REPO_TESTS_GATE_PROVISION=1 and section
# G2 turns "they all skipped" into a FAILURE there — this repo's provision() gate is that
# leg, and Core's reusable bootstrap-test.yml cannot be it.
#
# HONEST LIMIT, so a green run is not over-read: these sections prove provision() RAN,
# BRANCHED, and returned/exited as designed. Nothing is installed. They say nothing about
# whether the Brewfile's formulae exist, whether a cask name is right, or whether a real
# Homebrew install would succeed — only `make brew-check` on a provisioned machine, or a
# periodic real bootstrap, covers that.
#
# HOW MANY ASSERTIONS: it depends on the box, which is why README.md and CONTRIBUTING.md
# quote "~150" rather than a figure. Whole sections self-skip where they cannot run — the
# provision cases need the Command Line Tools, the zsh ones need zsh — so the same tree
# reports 109 pass / 4 skip on Linux CI and 151 pass / 0 skip on the macOS runner (a
# contributor's Mac lands elsewhere again — an already-present pre-commit hook skips one).
# There is no single true number, and the exact one those docs used to carry (48) was
# stale by more than half before anyone noticed. Do not put a precise count back.
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
# Did any section actually ENTER provision()? Section G2 turns a run where every
# provision section self-skipped into a FAILURE on the CI leg that claims to gate it (#178).
prov_ran=0
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
  prov_ran=1 # this section really enters provision() — see section G2
  ahome="$(mktemp -d)"
  abin="$(mktemp -d)"
  mkdir -p "$ahome/.config/tmux/plugins/tpm"
  printf '#!/bin/sh\nexit 0\n' >"$abin/mise"
  printf '#!/bin/sh\nexit 1\n' >"$abin/brew" # every subcommand crashes, as the real one did
  # A full run installs the repo's local pre-commit hook, and $REPO is the REAL working
  # tree (it comes from bootstrap.sh's own location and cannot be sandboxed like $HOME).
  # Stub it via the BOOTSTRAP_PRE_COMMIT seam so the tests cannot rewrite the
  # contributor's .git/hooks/pre-commit — `make test-repo` is itself a pre-commit hook, so
  # that would be a hook rewriting itself mid-commit. The stub records that it was called,
  # which is what lets the install path still be asserted below.
  # shellcheck disable=SC2016  # $0 must expand when the STUB runs, not when it is written
  printf '#!/bin/sh\ntouch "$0.called"\nexit 0\n' >"$abin/pre-commit"
  chmod +x "$abin/mise" "$abin/brew" "$abin/pre-commit"
  hook_before="$(cat "$REPO/.git/hooks/pre-commit" 2>/dev/null || true)"
  # A FULL run (no --links-only/--no-brew): the provision path is the whole point.
  OUT="$(HOME="$ahome" PATH="$abin:$PATH" BOOTSTRAP_BREW="$abin/brew" BOOTSTRAP_PRE_COMMIT="$abin/pre-commit" BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 bash "$REPO/bootstrap.sh" 2>&1)"
  brc=$?
  # The headline symptom, asserted on its own: silence is the bug.
  if [[ -n "$OUT" ]]; then ok "crashing brew: the run still PRINTS"; else no "crashing brew: the run still PRINTS" "zero bytes of output"; fi
  assert_eq "crashing brew: exits 3 (degraded), not 1 (aborted)" 3 "$brc"
  # Only reachable if the count assignment survived the crash — the precise pin for the bug.
  assert_contains "crashing brew: the '?' package-count fallback is reachable" "$OUT" "(? formulae/casks"
  assert_contains "crashing brew: the bundle failure is ledgered" "$OUT" "brew bundle failed"
  assert_contains "crashing brew: the summary still prints" "$OUT" "linked ·"
  if [[ -L "$ahome/.zshenv" ]]; then ok "crashing brew: symlinks were still wired"; else no "crashing brew: symlinks were still wired" "the sandbox .zshenv is not a link"; fi
  # A full run reaches the pre-commit install (#135) — unless this box already has the
  # framework hook, in which case the run correctly reports it instead of reinstalling.
  if [[ -f "$abin/pre-commit.called" ]]; then
    ok "full run: the local pre-commit hook is installed"
  elif grep -q '# start templated' "$REPO/.git/hooks/pre-commit" 2>/dev/null; then
    skipt "full run: the local pre-commit hook is installed (already present on this box)"
  else
    no "full run: the local pre-commit hook is installed" "the stub was never invoked"
  fi
  # And, whichever branch it took, it did NOT touch the real repo's hook.
  assert_eq "full run leaves the contributor's .git/hooks/pre-commit byte-identical" \
    "$hook_before" "$(cat "$REPO/.git/hooks/pre-commit" 2>/dev/null || true)"
  rm -rf "$ahome" "$abin"
fi

# ── B1b4. bootstrap.sh: provision()'s Homebrew-installer branches (#178) ──────
# B1b3 above covers a brew BINARY THAT EXISTS AND CRASHES. That means `command -v "$BREW"`
# SUCCEEDS, so the entire installer block (bootstrap.sh:677-702) — the only code in this
# repo that downloads and then EXECUTES a script — is skipped, along with the satisfied-
# Brewfile fast path and the --no-brew gate. One of provision()'s ~11 branches was gated;
# these cases take the rest. Pointing BOOTSTRAP_BREW at a path that does NOT exist is what
# flips `command -v` and makes the installer block reachable at all.
#
# SAFETY, and it is why this section is shaped the way it is: inside that block the run
# really invokes curl and really runs whatever came back. TWO INDEPENDENT layers stop that
# from ever being the real Homebrew installer on a contributor's Mac:
#   1. a `curl` shim first on PATH — proven per-run by shim_wins(), not assumed;
#   2. an unroutable proxy in the environment of EVERY run below (prov_run), so even a shim
#      that somehow lost the PATH race gets a curl that fails in milliseconds having
#      touched no network. The worst case is then a case landing in the download-failure
#      branch and failing its OWN assertion loudly — never a real install.
#
# WHY A PATH SHIM WORKS HERE WHEN B1b3 NEEDED THE BOOTSTRAP_BREW SEAM. brew_shellenv evals
# `brew shellenv`, which on macOS re-runs path_helper and REWRITES PATH: it hoists
# /opt/homebrew/{bin,sbin} to the front but PRESERVES the relative order of everything
# else, so a prepended shim dir stays ahead of /usr/bin. A `brew` stub still loses, because
# Homebrew links a real `brew` into the dir that just got hoisted above it — hence the env
# seam. Homebrew links no curl (keg-only, :provided_by_macos), no mktemp (it ships gmktemp)
# and no xcode-select, so those stubs survive. That is a property of today's Homebrew, not
# a law, so PROVE it with the same mechanism bootstrap.sh uses and skip rather than run
# blind if it ever stops holding.
section "bootstrap.sh — provision()'s installer branches (#178)"

# shim_wins <bindir> <tool> — <bindir>/<tool> must ALREADY exist. True when it still wins
# after a real `brew shellenv` eval, exactly as provision() will have run one.
shim_wins() {
  local got
  got="$(PATH="$1:$PATH" bash -c '
    for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      [ -x "$b" ] || continue
      out="$("$b" shellenv 2>/dev/null)" || exit 1
      eval "$out"
      break
    done
    command -v "$1"' _ "$2" 2>/dev/null)"
  [[ "$got" == "$1/$2" ]]
}

# The B1b3 sandbox idiom, factored out because seven cases share it. Never touches the real
# $HOME, the real .git/hooks (BOOTSTRAP_PRE_COMMIT) or the real Homebrew (BOOTSTRAP_BREW).
PHOME="" PBIN=""
prov_sandbox() {
  PHOME="$(mktemp -d)"
  PBIN="$(mktemp -d)"
  mkdir -p "$PHOME/.config/tmux/plugins/tpm" # skip tpm's first-run network clone
  printf '#!/bin/sh\nexit 0\n' >"$PBIN/mise"
  # shellcheck disable=SC2016  # $0 must expand when the STUB runs, not when it is written
  printf '#!/bin/sh\ntouch "$0.called"\nexit 0\n' >"$PBIN/pre-commit"
  chmod +x "$PBIN/mise" "$PBIN/pre-commit"
}
prov_run() { # prov_run <BOOTSTRAP_BREW value> [bootstrap args...] → OUT, RC
  local brewpath="$1"
  shift
  OUT="$(HOME="$PHOME" PATH="$PBIN:$PATH" \
    BOOTSTRAP_BREW="$brewpath" BOOTSTRAP_PRE_COMMIT="$PBIN/pre-commit" \
    BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 \
    https_proxy=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1 ALL_PROXY=http://127.0.0.1:1 \
    bash "$REPO/bootstrap.sh" "$@" 2>&1)"
  RC=$?
}
prov_clean() {
  [[ -n "$PHOME" ]] && rm -rf "$PHOME"
  [[ -n "$PBIN" ]] && rm -rf "$PBIN"
  PHOME="" PBIN=""
}

prov_hook_before="$(cat "$REPO/.git/hooks/pre-commit" 2>/dev/null || true)"

# ── case 1: the Command Line Tools are missing → STOP (bootstrap.sh:667-673) ──
# The ONE case that gains coverage on Linux too: there `xcode-select` genuinely does not
# exist, so the branch is reachable with no shim at all. This guard is therefore INVERTED
# relative to every other provision case in this file.
prov_sandbox
prov_skip=0
if command -v xcode-select >/dev/null 2>&1; then
  # shellcheck disable=SC2016  # $0/$1 must expand when the STUB runs, not when it is written
  printf '#!/bin/sh\n[ "$1" = --install ] && { touch "$0.install-called"; exit 0; }\nexit 1\n' >"$PBIN/xcode-select"
  chmod +x "$PBIN/xcode-select"
  shim_wins "$PBIN" xcode-select || prov_skip=1
fi
if ((prov_skip)); then
  skipt "missing CLT stops the run (an xcode-select stub cannot win the PATH race here)"
else
  # Deliberately NOT prov_ran: this case runs on every box (on Linux `xcode-select` is
  # genuinely absent, on macOS the shim supplies the failure), so counting it would make
  # section G2's enforcement vacuously true. G2 asks whether the leg reached the HOMEBREW
  # paths, and only the CLT-dependent cases below answer that.
  prov_run /nonexistent/brew
  assert_eq "missing CLT: exits 1 (STOP, do not carry on brewless)" 1 "$RC"
  assert_contains "missing CLT: says the CLT are required" "$OUT" "Xcode Command Line Tools are required"
  assert_contains "missing CLT: tells you to re-run after the installer" "$OUT" "then re-run: ./bootstrap.sh"
  # The regression this branch exists for: the old code printed "then re-run" and carried
  # straight on into the Homebrew install and a tpm clone that popped a SECOND dialog.
  assert_not_contains "missing CLT: never reaches the Homebrew installer" "$OUT" "Installing Homebrew"
  if [[ -L "$PHOME/.zshenv" ]]; then
    no "missing CLT: stops before wire_links" "it wired links anyway"
  else
    ok "missing CLT: stops before wire_links"
  fi
  if [[ -x "$PBIN/xcode-select" ]]; then
    if [[ -f "$PBIN/xcode-select.install-called" ]]; then
      ok "missing CLT: the GUI installer was spawned"
    else
      no "missing CLT: the GUI installer was spawned" "--install never ran"
    fi
  fi
fi
prov_clean

# Cases 2-7 all need provisioning to be reachable, i.e. real Command Line Tools.
if ! command -v xcode-select >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
  skipt "provision() installer branches (no Command Line Tools — provisioning cannot run here)"
else
  # ── case 2: mktemp fails → exit 1 (bootstrap.sh:686-689) ───────────────────
  # Reachable only via a PATH shim: BSD `mktemp -t` uses the Darwin confstr temp dir and
  # ignores TMPDIR, so a bogus TMPDIR does NOT force the failure.
  prov_sandbox
  printf '#!/bin/sh\nexit 1\n' >"$PBIN/mktemp"
  chmod +x "$PBIN/mktemp"
  if shim_wins "$PBIN" mktemp; then
    prov_ran=1
    prov_run /nonexistent/brew
    assert_eq "mktemp failure: exits 1" 1 "$RC"
    assert_contains "mktemp failure: names the temp file" "$OUT" "could not create a temp file"
    assert_not_contains "mktemp failure: does not misreport it as a download error" "$OUT" "could not download"
  else
    skipt "mktemp failure exits 1 (an mktemp stub cannot win the PATH race here)"
  fi
  prov_clean

  # ── case 3: the installer download fails → exit 1 (bootstrap.sh:690-695) ───
  # The highest-risk branch in the file. The stub writes NOTHING (unlike Core's shim, which
  # honours -o): a failed download must not leave a file behind for /bin/bash to run.
  prov_sandbox
  # shellcheck disable=SC2016  # $0 must expand when the STUB runs, not when it is written
  printf '#!/bin/sh\necho "curl $*" >>"$0.log"\nexit 1\n' >"$PBIN/curl"
  chmod +x "$PBIN/curl"
  if shim_wins "$PBIN" curl; then
    prov_ran=1
    prov_run /nonexistent/brew
    assert_eq "curl failure: exits 1" 1 "$RC"
    assert_contains "curl failure: blames the network" "$OUT" "could not download the Homebrew installer"
    assert_contains "curl failure: offers the manual route" "$OUT" "install it by hand from https://brew.sh"
    # The bug this branch exists for: the upstream one-liner ran /bin/bash on an EMPTY
    # string and exited 0. Prove the shim really intercepted — without this, a shim that
    # never engaged looks identical to one that did.
    assert_contains "curl failure: the shim really intercepted the download" \
      "$(cat "$PBIN/curl.log" 2>/dev/null || true)" "raw.githubusercontent.com"
    assert_not_contains "curl failure: does not misreport it as an install failure" "$OUT" "Homebrew installation failed"
  else
    skipt "curl failure exits 1 (a curl stub cannot win the PATH race here)"
  fi
  prov_clean

  # ── case 4: the installer itself fails → exit 1 (bootstrap.sh:696-700) ─────
  prov_sandbox
  cat >"$PBIN/curl" <<'CURLSTUB'
#!/bin/sh
out=
while [ $# -gt 0 ]; do
  case $1 in
  -o) out=$2; shift 2 ;;
  --output=*) out=${1#--output=}; shift ;;
  *) shift ;;
  esac
done
[ -n "$out" ] && printf '#!/bin/sh\nexit 1\n' >"$out"
exit 0
CURLSTUB
  chmod +x "$PBIN/curl"
  if shim_wins "$PBIN" curl; then
    prov_ran=1
    prov_run /nonexistent/brew
    assert_eq "failing installer: exits 1" 1 "$RC"
    assert_contains "failing installer: blames the install" "$OUT" "Homebrew installation failed"
    assert_not_contains "failing installer: does not misreport a download error" "$OUT" "could not download"
    assert_not_contains "failing installer: never reaches brew bundle" "$OUT" "formulae/casks"
  else
    skipt "a failing installer exits 1 (a curl stub cannot win the PATH race here)"
  fi
  prov_clean

  # ── case 5: installer "succeeds" but brew is STILL absent (bootstrap.sh:714-720) ──
  # The guard that stops `brew bundle` dying at a bare exit 127 with no explanation.
  prov_sandbox
  cat >"$PBIN/curl" <<'CURLSTUB2'
#!/bin/sh
out=
while [ $# -gt 0 ]; do
  case $1 in
  -o) out=$2; shift 2 ;;
  --output=*) out=${1#--output=}; shift ;;
  *) shift ;;
  esac
done
[ -n "$out" ] && printf '#!/bin/sh\nexit 0\n' >"$out"
exit 0
CURLSTUB2
  chmod +x "$PBIN/curl"
  if shim_wins "$PBIN" curl; then
    prov_ran=1
    prov_run /nonexistent/brew
    assert_eq "brew still absent after install: exits 1" 1 "$RC"
    assert_contains "brew still absent: names PATH as the problem" "$OUT" "Homebrew is not on PATH"
    assert_contains "brew still absent: prints the paste-able shellenv remedy" "$OUT" "brew shellenv"
    assert_not_contains "brew still absent: no bare command-not-found death" "$OUT" "command not found"
  else
    skipt "a still-absent brew exits 1 (a curl stub cannot win the PATH race here)"
  fi
  prov_clean

  # ── case 6: the Brewfile is already satisfied → skip (bootstrap.sh:724-725) ──
  # The common real-world RE-RUN path, and previously uncovered. No shims needed: the brew
  # stub exists, so `command -v "$BREW"` succeeds and the installer block is never entered.
  # Asserting on the intercept log, not just the message, is what proves the EXPENSIVE path
  # was skipped rather than merely that a string printed.
  prov_sandbox
  prov_ran=1
  # shellcheck disable=SC2016  # $0/$* must expand when the STUB runs, not when written
  printf '#!/bin/sh\necho "$*" >>"$0.log"\nexit 0\n' >"$PBIN/brew"
  chmod +x "$PBIN/brew"
  prov_run "$PBIN/brew"
  # NOT an exact exit-code assertion, deliberately. A full run also reaches `mise install`,
  # which is gated on `command -v mise` AFTER brew_shellenv has prepended /opt/homebrew/bin
  # — so on a box with a real mise it runs the REAL one (the PATH stub cannot win there,
  # the same shadowing B1b3 documents) and ledgers a failure against the blocked network,
  # closing at 3; on a runner without mise the stub wins and it closes at 0. Both are
  # correct, and neither is what this case is about. What provision() OWES here is that it
  # did not ABORT the run (exit 1/2) and contributed no failure of its own.
  if ((RC == 1 || RC == 2)); then
    no "satisfied Brewfile: provision() did not abort the run" "exit $RC"
  else
    ok "satisfied Brewfile: provision() did not abort the run"
  fi
  assert_contains "satisfied Brewfile: the run still reaches its summary" "$OUT" "linked ·"
  assert_contains "satisfied Brewfile: says it skipped" "$OUT" "brew bundle already satisfied"
  assert_not_contains "satisfied Brewfile: the expensive path was not announced" "$OUT" "formulae/casks"
  assert_not_contains "satisfied Brewfile: nothing was ledgered" "$OUT" "brew bundle failed"
  prov_blog="$(cat "$PBIN/brew.log" 2>/dev/null || true)"
  assert_contains "satisfied Brewfile: the cheap check really ran" "$prov_blog" "bundle check --file="
  if printf '%s\n' "$prov_blog" | grep -qx "bundle --file=$REPO/Brewfile"; then
    no "satisfied Brewfile: the full bundle was skipped" "brew bundle ran anyway"
  else
    ok "satisfied Brewfile: the full bundle was skipped"
  fi
  if [[ -L "$PHOME/.zshenv" ]]; then
    ok "satisfied Brewfile: wire_links still ran"
  else
    no "satisfied Brewfile: wire_links still ran" "no link in the sandbox"
  fi
  prov_clean

  # ── case 7: --no-brew gates the INSTALLER too (bootstrap.sh:677, 753-754) ──
  # Pins a real past bug: --no-brew promised "skip Homebrew/brew bundle" but gated only the
  # bundle, so on a fresh Mac the flag still downloaded and ran the Homebrew installer.
  prov_sandbox
  prov_ran=1
  prov_run /nonexistent/brew --no-brew
  # Same reasoning as case 6: the exit code depends on whether this box has a real mise.
  if ((RC == 1 || RC == 2)); then
    no "--no-brew: provision() did not abort the run" "exit $RC"
  else
    ok "--no-brew: provision() did not abort the run"
  fi
  assert_contains "--no-brew: the run still reaches its summary" "$OUT" "linked ·"
  assert_contains "--no-brew: says it skipped the bundle" "$OUT" "skipping brew bundle"
  assert_not_contains "--no-brew: never runs the Homebrew installer" "$OUT" "Installing Homebrew"
  assert_not_contains "--no-brew: never touches the network" "$OUT" "could not download"
  prov_clean
fi

# Whatever the branches did, none of it may touch the contributor's real hook (B1b3's rule).
assert_eq "B1b4 left the contributor's .git/hooks/pre-commit byte-identical" \
  "$prov_hook_before" "$(cat "$REPO/.git/hooks/pre-commit" 2>/dev/null || true)"

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

# ── B1d. bootstrap.sh: the closing checklist (#135) ───────────────────────────
# A clean exit was never the same as a finished machine: GUI permissions, tmux plugins,
# the pre-commit hook and the git identity were all left undone and unmentioned, so the
# run closed with "complete" over a box whose hotkeys and tiling did nothing. The list has
# to be PROBED — a hardcoded one would be wrong the moment a step is actually done — so
# these drive the probes against a sandbox HOME rather than asserting fixed text.
#
# Hermetic, and deliberately so: tpm is pre-seeded WITHOUT bin/install_plugins, so
# install_tmux_plugins returns before it can reach the network, and a dummy plugin
# directory stands in for an installed plugin. The two desktop probes read REAL machine
# state (/Applications, systemextensionsctl, aerospace) which is absent on Linux CI, so
# nothing here asserts on them.
section "bootstrap.sh — closing checklist (#135)"

# A dry run probes nothing — every item would read as outstanding, and a plan that lies is
# worse than no plan — but it must still say where the list went.
run_bootstrap piped --links-only --dry-run
assert_not_contains "dry-run prints no checklist" "$OUT" "==> next steps"
assert_contains "dry-run says the checklist follows a real run" "$OUT" "reported after a real run"
[[ -n "$SANDBOX" ]] && rm -rf "$SANDBOX"

chome="$(mktemp -d)"
cbin="$(mktemp -d)"
mkdir -p "$chome/.config/tmux/plugins/tpm" "$chome/.config/tmux/plugins/tmux-sensible"
printf '#!/bin/sh\nexit 0\n' >"$cbin/mise"
# Stubbed for the same reason as B1b3 above, and here it also makes the assertion
# deterministic: the pre-commit item is reported whether or not the contributor's box has
# the real binary installed.
# shellcheck disable=SC2016  # $0 must expand when the STUB runs, not when it is written
printf '#!/bin/sh\ntouch "$0.called"\nexit 0\n' >"$cbin/pre-commit"
chmod +x "$cbin/mise" "$cbin/pre-commit"
# Baseline for the "--links-only installs nothing" check further down. Taken before any
# apply, because these runs drive bootstrap against the REAL working tree.
ck_hook_before="$(cat "$REPO/.git/hooks/pre-commit" 2>/dev/null || true)"
run_checklist() { # → OUT, RC   (same sandbox each time, so state carries between calls)
  OUT="$(HOME="$chome" PATH="$cbin:$PATH" BOOTSTRAP_PRE_COMMIT="$cbin/pre-commit" \
    BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 \
    bash "$REPO/bootstrap.sh" --no-brew --links-only 2>&1)"
  RC=$?
}

run_checklist
assert_eq "a real apply that prints a checklist still exits 0" 0 "$RC"
assert_contains "a real apply prints the checklist" "$OUT" "==> next steps"
# blib_seed has just copied core/git/local.gitconfig.example, so the identity is the
# placeholder `you@example.com`. NB it is NOT the string "FILL IN your name & email" —
# that never reaches the file, it is only blib_seed's one-line note at seed time.
assert_contains "the seeded placeholder git identity is reported" "$OUT" "git identity is still the seeded placeholder"
# tpm present with a plugin already beside it ⇒ reported done, with no network clone.
assert_contains "already-installed tmux plugins are reported, not reinstalled" "$OUT" "tmux plugins installed (1)"

# PROBED, not hardcoded: fill the identity in and the item must disappear on the next run.
git config -f "$chome/.config/git/local.gitconfig" user.name "A Real Person"
git config -f "$chome/.config/git/local.gitconfig" user.email "real@example.org"
run_checklist
assert_not_contains "a filled-in identity drops off the checklist" "$OUT" "git identity is still the seeded placeholder"
assert_contains "a filled-in identity is confirmed instead" "$OUT" "git identity set (real@example.org)"

# --links-only promises "no installs" in both usage() and the README, and writing a git
# hook is an install. This matters beyond tidiness: the suite runs REAL --links-only
# applies against the actual working tree, so a slip here would rewrite the contributor's
# own .git/hooks/pre-commit out from under them.
# Asserted as "unchanged", not as "absent": a contributor who has run `pre-commit install`
# (which SECURITY.md tells them to, and which a full ./bootstrap.sh now does for them) has
# pre-commit's hook there legitimately, and an absolute assertion would fail on their box
# for no reason. What must hold is that the run above did not MOVE it either way.
hookf="$REPO/.git/hooks/pre-commit"
hook_after="$(cat "$hookf" 2>/dev/null || true)"
assert_eq "--links-only leaves .git/hooks/pre-commit byte-identical" "$ck_hook_before" "$hook_after"
# What it reports still depends on the contributor's own hook, so assert the right thing
# for each state rather than one line that only holds on one of them.
if grep -q '# start templated' "$hookf" 2>/dev/null; then
  assert_contains "an already-installed pre-commit hook is confirmed" "$OUT" "pre-commit hook installed"
else
  assert_contains "--links-only reports the pre-commit gate as outstanding" "$OUT" "run: pre-commit install"
fi

# The outstanding half must reach automation as well: `ok` alone would call a box finished
# while its keyboard remapper is still inert. Same sandbox, so still no network.
cjson="$(HOME="$chome" PATH="$cbin:$PATH" BOOTSTRAP_PRE_COMMIT="$cbin/pre-commit" \
  BOOTSTRAP_ALLOW_NON_DARWIN=1 NO_COLOR=1 \
  bash "$REPO/bootstrap.sh" --no-brew --links-only --json 2>/dev/null)"
assert_contains "--json carries a next_steps[] channel" "$cjson" '"next_steps":'
assert_eq "--json with a checklist is still ONE line on stdout" 1 "$(printf '%s\n' "$cjson" | wc -l | tr -d ' ')"
assert_not_contains "the human checklist stays off the JSON stdout" "$cjson" "==> next steps"
if command -v python3 >/dev/null 2>&1; then
  if printf '%s' "$cjson" | python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(sys.stdin)["next_steps"], list) else 1)' 2>/dev/null; then
    ok "--json next_steps parses as an array"
  else
    no "--json next_steps parses as an array" "$cjson"
  fi
else
  skipt "--json next_steps parses as an array (no python3)"
fi
rm -rf "$chome" "$cbin"

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

# ── G. verify-core.sh: VERIFY_CORE_STRICT flips skip into failure (#136) ──────
# verify-core is the strongest Core-drift gate, and it exits 0 when it cannot reach
# upstream. That is right on a laptop and wrong in CI, where a skip is indistinguishable
# from a pass — so CI sets VERIFY_CORE_STRICT=1. Both halves of that contract are asserted
# here, and the DEFAULT half is the one that matters most: it is what stops a later edit
# from making strict unconditional and failing every offline `make lint`.
#
# CORE_UPSTREAM=/nonexistent makes the fetch fail immediately with no network at all, so
# this is deterministic and costs nothing — no flake, no upstream dependency.
section "verify-core.sh — strict mode (#136)"
VC_OUT="$(CORE_UPSTREAM=/nonexistent "$REPO/test/verify-core.sh" 2>&1)"
VC_RC=$?
assert_eq "unverifiable upstream SKIPS by default (exit 0)" 0 "$VC_RC"
assert_contains "the skip says why it could not verify" "$VC_OUT" "cannot verify"

VC_OUT="$(CORE_UPSTREAM=/nonexistent VERIFY_CORE_STRICT=1 "$REPO/test/verify-core.sh" 2>&1)"
VC_RC=$?
assert_eq "unverifiable upstream FAILS under VERIFY_CORE_STRICT (exit 1)" 1 "$VC_RC"
assert_contains "the failure names the strict switch that caused it" "$VC_OUT" "VERIFY_CORE_STRICT"

# The CI job must actually SET it — otherwise the strict path above is dead code in the
# one place it exists for. Grepping the workflow is crude but catches a silent drop.
if grep -q 'VERIFY_CORE_STRICT: 1' "$REPO/.github/workflows/ci.yml"; then
  ok "ci.yml arms VERIFY_CORE_STRICT for the verify-core job"
else
  no "ci.yml no longer sets VERIFY_CORE_STRICT" "strict mode exists but CI never enables it"
fi

# ── G2. the macOS leg really is provision()'s gate (#178) ─────────────────────
# #178 was filed on the belief that provision() is executed by no CI job here. It is — by
# the `macos smoke` leg's `make test-repo`, through the BOOTSTRAP_BREW seam, since B1b3.
# The defect was that the fact was INVISIBLE: nothing named it, and nothing would notice if
# it stopped being true. That is the same shape as #154/#155, where a fleet gate this repo
# does not call had to be ported by hand and the divergence was discoverable only by
# noticing this repo's absence from a rollout.
#
# Two halves, and the SECOND is the one a comment cannot do.
section "the macOS CI leg is provision()'s gate (#178)"

if grep -q 'REPO_TESTS_GATE_PROVISION: 1' "$REPO/.github/workflows/ci.yml"; then
  ok "ci.yml marks the macOS leg as provision()'s gate"
else
  no "ci.yml no longer marks a provision() gate" "the provision sections would gate nothing"
fi

# The half a grep cannot do: the marked leg must actually REACH provision(). A guard that
# silently starts skipping — a runner image without the Command Line Tools, a reordered
# guard, a renamed seam — is exactly the invisible gap #178 is about, so on that leg a
# total skip is a FAILURE rather than a quiet pass. Off that leg this is inert, which is
# what keeps Linux CI and a contributor laptop honest about what they did not run.
if [[ "${REPO_TESTS_GATE_PROVISION:-}" == 1 ]]; then
  if ((prov_ran)); then
    ok "the CI leg that claims to gate provision() actually executed it"
  else
    no "the provision() gate leg never entered provision()" \
      "REPO_TESTS_GATE_PROVISION=1 but every provision section self-skipped"
  fi
else
  skipt "provision() sections actually ran (only enforced on the CI leg that claims to gate them)"
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

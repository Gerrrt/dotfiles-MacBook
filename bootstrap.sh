#!/usr/bin/env bash
# dotfiles-MacBook/bootstrap.sh
# ──────────────────────────────────────────────────────────────────────────────
# Idempotent macOS provision + symlink wiring. Safe to re-run.
#
#   ./bootstrap.sh                  # full: Homebrew + brew bundle + symlinks
#   ./bootstrap.sh --links-only     # just (re)create symlinks, no installs
#   ./bootstrap.sh --no-brew        # symlinks + mise, skip Homebrew/brew bundle
#   ./bootstrap.sh --macos-defaults # also run macos/defaults.sh (system prefs)
#   ./bootstrap.sh --set-shell      # make Homebrew zsh the login shell (chsh)
#   ./bootstrap.sh --dry-run        # print every planned action; change nothing
#
# This repo vendors Core under core/ (git subtree). bootstrap symlinks the Core
# files + the macOS os/ layer into ~/.config and ~. Your identity lives in
# ~/.config/git/local.gitconfig (never tracked); machine-only shell tweaks in
# ~/.config/zsh/99-local.zsh (never tracked).
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINKS_ONLY=0
NO_BREW=0
RUN_DEFAULTS=0
SET_SHELL=0
UNINSTALL=0
DRY=0
QUIET=0
JSON=0
# --only/--skip module selection: captured here, validated by the shared lib
# (blib_select) once core/lib/bootstrap-lib.sh is sourced below.
ONLY_RAW="" SKIP_RAW="" ONLY_SEEN=0 SKIP_SEEN=0
# BREW — which brew binary provision() drives. The BOOTSTRAP_BREW override exists so the
# provision path is TESTABLE at all: a stub earlier on PATH cannot shadow the real brew,
# because brew_shellenv's `path_helper` puts /opt/homebrew/bin at the FRONT of PATH before
# provision() ever runs. Every provision call site goes through this — INCLUDING the
# `command -v` gates, so a test with a stub can never fall into the real Homebrew
# installer. brew_shellenv deliberately keeps its own hardcoded absolute prefixes: its job
# is to FIND Homebrew, which is exactly what an override must not fake.
BREW="${BOOTSTRAP_BREW:-brew}"
# PRE_COMMIT — which pre-commit binary installs the repo's local commit-time hook. Same
# seam, same reasoning as BREW above. This one is unavoidable rather than merely
# convenient: the hook goes into $REPO, and $REPO is derived from this script's own
# location, so unlike $HOME it CANNOT be pointed at a sandbox. Without the override,
# test/test-repo.sh's full-run case would rewrite the contributor's own
# .git/hooks/pre-commit as a side effect of running the tests — and since `make test-repo`
# is itself one of the pre-commit hooks, that means rewriting the hook mid-commit. Aimed
# at a stub the install path still runs and is still asserted on; it just does not touch git.
PRE_COMMIT="${BOOTSTRAP_PRE_COMMIT:-pre-commit}"

# usage() is a real function (heredoc) rather than `sed -n '2,18p' "$0"`: the old
# form was coupled to header line numbers, so editing the banner silently drifted
# `--help`. This stays correct no matter how the file above moves.
usage() {
  cat <<'EOF'
bootstrap.sh — idempotent macOS provision + symlink wiring. Safe to re-run.

  ./bootstrap.sh                  full: Homebrew + brew bundle + symlinks
  ./bootstrap.sh --links-only     just (re)create symlinks, no installs
  ./bootstrap.sh --no-brew        symlinks + mise, skip Homebrew/brew bundle
  ./bootstrap.sh --macos-defaults also run macos/defaults.sh (system prefs)
  ./bootstrap.sh --set-shell      make Homebrew zsh the login shell (chsh)
  ./bootstrap.sh --only zsh,nvim  link ONLY these module groups (zsh nvim tmux git prompt tools desktop)
  ./bootstrap.sh --skip desktop   link everything EXCEPT these module groups
  ./bootstrap.sh --uninstall      remove Core symlinks + restore backed-up files
  ./bootstrap.sh --dry-run, -n    print every planned action; change nothing
  ./bootstrap.sh --quiet, -q      show only CHANGES + the summary (quiet re-runs)
  ./bootstrap.sh --json           emit a machine-readable summary on stdout (for automation)
  ./bootstrap.sh -h, --help       show this help

Flags combine: `./bootstrap.sh --links-only --dry-run` previews the symlink
plan without touching your home directory. `--quiet` suppresses section headers
and the per-file "already linked" lines, so a re-run prints only what actually
changed — handy once you're set up and just re-syncing. `--uninstall --dry-run`
previews exactly what an uninstall would remove and restore, changing nothing.

Exit codes:
    0  clean run
    1  could not run (not macOS, missing core/, no Command Line Tools)
    2  usage error (unknown flag, bad --only/--skip selector)
    3  ran, but one or more steps FAILED — the box is degraded; see the summary
       (under --uninstall: a dest would not unlink, so it is still wired to the repo)
  130  interrupted (Ctrl-C); bootstrap is idempotent, just re-run
EOF
}

# suggest <bad-flag> — print the nearest known flag as a "did you mean" hint, so a
# typo (`--dryrun`, `--link-only`) gets the same contextual nudge Core's verbs give
# via _core_suggest, instead of a bare usage dump. Heuristic, no external deps:
# compare HYPHEN-NORMALISED forms (so `--dryrun` ≈ `--dry-run`) and accept an exact
# match, a prefix either way, or a shared 4+ char stem. Silent when nothing's close.
KNOWN_FLAGS=(--links-only --no-brew --macos-defaults --set-shell --only --skip --uninstall --dry-run -n --quiet -q --json -h --help)
suggest() {
  local in="${1#--}" f cand n=0
  [[ -z "$in" || "$in" == "$1" ]] && return 0 # only guess for --long typos
  in="${in//-/}"                              # normalise away hyphen placement (the usual slip)
  for f in "${KNOWN_FLAGS[@]}"; do
    [[ "$f" == --* ]] || continue
    cand="${f#--}"
    cand="${cand//-/}"
    # shared leading-char count between the two normalised stems
    n=0
    while [[ "${in:n:1}" == "${cand:n:1}" && -n "${in:n:1}" ]]; do n=$((n + 1)); done
    if [[ "$in" == "$cand" || "$in" == "$cand"* || "$cand" == "$in"* ]] || ((n >= 4)); then
      printf '%s' "$f"
      return 0
    fi
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
  --links-only) LINKS_ONLY=1 ;;
  --no-brew) NO_BREW=1 ;;
  --macos-defaults) RUN_DEFAULTS=1 ;;
  --set-shell) SET_SHELL=1 ;;
  --uninstall) UNINSTALL=1 ;;
  --dry-run | -n) DRY=1 ;;
  --quiet | -q) QUIET=1 ;;
  --json) JSON=1 QUIET=1 ;; # machine-readable summary on stdout; implies quiet for the body
  # --only/--skip take a value (the lib's blib_select validates it after sourcing).
  --only)
    [[ $# -ge 2 ]] || {
      echo "--only requires module names, e.g. --only zsh,nvim" >&2
      exit 2
    }
    ONLY_RAW="$2"
    ONLY_SEEN=1
    shift
    ;;
  --only=*)
    ONLY_RAW="${1#*=}"
    ONLY_SEEN=1
    ;;
  --skip)
    [[ $# -ge 2 ]] || {
      echo "--skip requires module names, e.g. --skip tmux" >&2
      exit 2
    }
    SKIP_RAW="$2"
    SKIP_SEEN=1
    shift
    ;;
  --skip=*)
    SKIP_RAW="${1#*=}"
    SKIP_SEEN=1
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "unknown flag: $1" >&2
    s="$(suggest "$1")"
    [[ -n "$s" ]] && echo "did you mean $s?" >&2
    usage >&2
    exit 2 # usage error (the convention the lint scripts use; 1 stays for real failures)
    ;;
  esac
  shift
done

# Palette + glyphs come from the VENDORED shared bash UX lib (core/lib/ux.sh) — ONE
# definition across Core's bash layer (B5). A normal clone ALWAYS contains core/ (it's a
# tracked subtree, and the core/ guard below hard-requires it), so this is REQUIRED, not
# best-effort: the old inline fallback was unreachable dead weight that could silently
# drift from the canonical rule. If ux.sh is missing the tree is incomplete — say so
# plainly and stop, rather than limping on a hand-rolled copy. ux.sh handles colour
# (TTY + NO_COLOR) and the UTF-8→ASCII glyph degradation itself.
if [[ -r "$REPO/core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO/core/lib/ux.sh"
else
  printf 'bootstrap: core/lib/ux.sh is missing — the core/ subtree is incomplete.\n' >&2
  printf '  a clone always contains core/; if building fresh, take the RELEASED tag\n' >&2
  printf '  (never main, or core-integrity reports the fresh subtree as TAMPERED):\n' >&2
  printf '    git subtree add --prefix=core <dotfiles-core-url> refs/tags/v4 --squash\n' >&2
  printf '    make core-lock\n' >&2
  exit 1
fi
c_b=$UX_BLU c_g=$UX_GRN c_y=$UX_YEL c_r=$UX_RED c_0=$UX_RST
G_OK=$UX_OK G_INFO=$UX_INFO G_ERR=$UX_ERR SPIN_FRAMES=$UX_SPIN_FRAMES

# Shared bash PROVISIONING scaffold (vendored core/lib/bootstrap-lib.sh) — the ONE
# definition of the Core→destination symlink MAP. wire_links delegates the Core surface
# to blib_link_core so this repo stops re-listing it by hand (the exact drift that left
# core/lazygit/config.yml + core/vim/vimrc unlinked here). Sourced after ux.sh so the
# blib_* messages share the palette; REQUIRED like ux.sh (a clone always has core/).
if [[ -r "$REPO/core/lib/bootstrap-lib.sh" ]]; then
  # source=/dev/null (not the real path): `make shellcheck` here runs without -x, so a
  # real-path directive would only yield SC1091 "not following"; /dev/null silences it,
  # matching how ux.sh is sourced above.
  # shellcheck source=/dev/null
  source "$REPO/core/lib/bootstrap-lib.sh"
else
  printf 'bootstrap: core/lib/bootstrap-lib.sh is missing — the core/ subtree is incomplete.\n' >&2
  exit 1
fi

# Register the macOS-only module group BEFORE validating a selector. Core's BLIB_MODULES
# ("zsh nvim tmux git prompt tools") knows nothing about a tiling WM, a menu bar, or a
# keyboard remapper — those are this layer's own, so this repo extends the list rather than
# editing the vendored default (which a subtree pull would overwrite).
#
# Without this, `--skip desktop` was rejected as an unknown group and `--only zsh` still
# wired ghostty/fastfetch/aerospace/sketchybar/karabiner — six configs the operator had
# just said they didn't want.
BLIB_MODULES="$BLIB_MODULES desktop"

# Apply any --only/--skip module selection now the validator (blib_select) exists;
# it aborts (exit 1) on a malformed selector or an unknown group.
if ((ONLY_SEEN)); then blib_select --only "$ONLY_RAW"; fi
if ((SKIP_SEEN)); then blib_select --skip "$SKIP_RAW"; fi

# B7: in --json mode the ONLY thing on stdout must be the final summary object, so route
# the entire human body (section headers, per-file lines, AND any subprocess output like
# brew bundle) to stderr by pointing fd 1 there, saving the real stdout on fd 3. The JSON
# is printed to >&3 by emit_json() on whichever exit path the run takes (normal end of
# run, or the --uninstall short-circuit). No effect outside --json.
if ((JSON)); then exec 3>&1 1>&2; fi
# Under --quiet, say() (section headers) and noop() (idempotent "already linked / present"
# confirmations) fall silent, so a re-run prints only the CHANGES (info: linked/backed
# up/seeded) + the summary. ok()/info()/err() — actual results, changes, and errors —
# always print. The summary (print_summary) prints unconditionally regardless of --quiet.
say() { ((QUIET)) || printf '%s==>%s %s\n' "$c_b" "$c_0" "$*"; }
ok() { printf '  %s%s%s %s\n' "$c_g" "$G_OK" "$c_0" "$*"; }
noop() { ((QUIET)) || ok "$@"; }
info() { printf '  %s%s%s %s\n' "$c_y" "$G_INFO" "$c_0" "$*"; }
err() { printf '  %s%s%s %s\n' "$c_r" "$G_ERR" "$c_0" "$*" >&2; }

# U3: step() is say() with an ordinal `[k/N]` prefix, so a long link phase reads as
# BOUNDED progress ("where am I in this?") rather than an undifferentiated wall of
# section headers. WIRE_TOTAL is the count of step() sections in wire_links; bump it if
# you add/remove one (a wrong total is cosmetic — it never affects what gets linked).
WIRE_STEP=0
# Count of step() sections in wire_links, COMPUTED from the active selection rather than
# hand-maintained — the old `WIRE_TOTAL=8` + "bump it if you add/remove one" was the same
# manual-mirror pattern that let the uninstall list drift. Sections:
#   1  Core + macOS overlay (shared scaffold)        — always
#   +1 zsh entry layer                               — blib_want zsh
#   +1 git ignore (macOS)                            — blib_want git
#   +6 ghostty, fastfetch, aerospace, sketchybar, borders, karabiner — blib_want desktop
# (Selection is already applied above via blib_select.)
WIRE_TOTAL=1
blib_want zsh && WIRE_TOTAL=$((WIRE_TOTAL + 1))
blib_want git && WIRE_TOTAL=$((WIRE_TOTAL + 1))
blib_want desktop && WIRE_TOTAL=$((WIRE_TOTAL + 6))
true # keep the last conditional from setting a non-zero status under `set -e`
step() {
  WIRE_STEP=$((WIRE_STEP + 1))
  ((QUIET)) || printf '%s==>%s %s[%d/%d]%s %s\n' "$c_b" "$c_0" "$c_y" "$WIRE_STEP" "$WIRE_TOTAL" "$c_0" "$*"
}

# U4: confirm a destructive, system-mutating opt-in before doing it. The --set-shell /
# --macos-defaults FLAGS are the consent in automation, so a non-interactive run (CI,
# piped, no TTY) PROCEEDS without prompting — but an interactive operator gets a [y/N]
# safety net (default no) before chsh / system `defaults` actually change anything. gum
# confirm when it's on PATH (it may be, post-brew-bundle), else a plain read.
confirm() {                      # confirm <prompt>  → 0 = proceed, non-zero = decline
  [[ -t 0 && -t 2 ]] || return 0 # non-TTY → the flag already gave consent; don't block
  if command -v gum >/dev/null 2>&1; then
    gum confirm --default=false "$1"
    return
  fi
  local reply
  # `|| true`: a bare EOF (Ctrl-D) makes read exit non-zero. Treat that as a safe DECLINE
  # (empty reply → the test below is false) rather than risk aborting under set -e. (Every
  # caller already invokes confirm in a tested `||`/`if` context, where set -e is suspended
  # inside the function, but this makes the EOF→decline contract explicit and call-safe.)
  read -r -p "$1 [y/N] " reply || true
  [[ "$reply" == [yY]* ]]
}

# Run-summary counters. NB: bump with `n=$((n+1))`, never `((n++))` — under
# `set -e`, a standalone `((n++))` evaluates to the OLD value and, when that's 0,
# returns exit 1 and ABORTS the whole script. The assignment form is always 0.
n_linked=0
n_backed=0
n_skipped=0
n_seeded=0
n_removed=0  # --uninstall: Core symlinks removed
n_restored=0 # --uninstall: backups restored over the removed link

# Failure/warning ledger (#133). A bootstrap is full of steps that must NOT abort the
# run — a rate-limited registry, a runtime that won't build — so each was written
# `|| info "…"` and then FORGOTTEN: the run still closed with "bootstrap complete" and
# exit 0, leaving a box that got none of its runtimes indistinguishable from a good one,
# to the operator and to anything parsing --json alike. These two arrays are the record.
#
# ERROR   = a step that was supposed to do something and didn't (mise, defaults.sh,
#           chsh, tpm). Non-empty ⇒ the closing line says so and we exit 3.
# WARNING = a notice that does NOT make the run degraded (a tool not on PATH *yet*
#           because you need a new shell). Never affects the exit code.
#
# This implements the intent documented upstream at core/lib/bootstrap-lib.sh:939-967
# (blib_note_fail / blib_failures_report) in bootstrap's own idiom: that API models
# failures only — there is no warnings channel — and prints in the blib_* palette
# rather than err()'s glyph, which mid-run reads as two different programs. Same
# shape as the n_* counters folding in BLIB_* tallies below.
#
# Both recorders must END on a zero status (err/info return 0) or a call in statement
# position would trip `set -e`.
FAILURES=()
WARNINGS=()
fail_note() { # fail_note <message>  → record a degraded step; makes the run exit 3
  FAILURES+=("$1")
  err "$1"
}
warn_note() { # warn_note <message>  → record a non-fatal notice; exit code unchanged
  WARNINGS+=("$1")
  info "$1"
}

# Closing checklist (#135). A bootstrap can finish cleanly and still leave a machine that
# does not work: Karabiner and AeroSpace do nothing until macOS grants them GUI
# permissions, and git refuses to commit while the seeded identity is still a placeholder.
# None of that is a FAILURE — nothing bootstrap ran went wrong — so it belongs in neither
# ledger above, and it must not touch the exit code. It is a third category: what is left
# for a HUMAN to do, PROBED at the end of the run rather than hardcoded, so a re-run on a
# finished box says nothing and the list never cries wolf.
#
# Two lists, because "you still have to do this" and "this is already done" answer
# different questions: the first is the actionable checklist, the second is the evidence
# that the steps bootstrap DID take (tmux plugins, the pre-commit hook) actually landed.
NEXT_TODO=() # outstanding — printed with info()'s glyph, and exported in --json
NEXT_DONE=() # verified done — printed with ok()'s glyph; human reassurance only
todo_step() { NEXT_TODO+=("$1"); }
done_step() { NEXT_DONE+=("$1"); }

# JSON string/array serialisers for the --json ledger. Pure parameter expansion (bash
# 3.2-safe, no subprocess) — there is deliberately no jq dependency on a fresh box.
# The messages are ours, but they interpolate PATHS (`chsh -s $brew_zsh`), so escaping
# is what keeps a `\` or `"` in a path from emitting invalid JSON.
json_escape() { # json_escape <string>  → the string, safe inside a JSON "…" literal
  local s=$1
  s=${s//\\/\\\\} # backslash FIRST, or it would re-escape the escapes added below
  s=${s//\"/\\\"}
  printf '%s' "$s"
}
json_array() { # json_array <item...>  → ["a","b"], or [] when given nothing
  local out="" item
  for item in "$@"; do out="${out:+$out,}\"$(json_escape "$item")\""; done
  printf '[%s]' "$out"
}

# emit_json — B7: the machine-readable run summary on the REAL stdout (fd 3, saved by the
# `exec 3>&1 1>&2` above before the body redirect). Provisioning automation parses what
# changed, which headline tools landed on PATH, and — since #133 — whether anything
# actually FAILED, instead of scraping human output. Hand-built (no jq dependency on a
# fresh box); the string/array values go through json_escape so a `"` or `\` in a path
# can't emit a broken object.
#
# `ok` is the one-key verdict: true iff `errors` is empty. `warnings` are notices that do
# NOT degrade the run (a tool that just needs a new shell), so they never clear `ok`.
#
# `next_steps` (#135) is the third channel: work left for a HUMAN — a GUI permission macOS
# will only take from a person, a git identity only its owner can fill in. It never clears
# `ok` either, because nothing failed; without it a fleet-provisioning script reading `ok`
# alone would call a box finished while its keyboard remapper is still inert. Only the
# OUTSTANDING items ship — the ✓ half of the checklist is human reassurance, not data.
#
# A FUNCTION, not the trailing block it used to be, because this script has more than one
# way to end: --uninstall short-circuits the install path with its own `exit 0`, which sat
# ABOVE the old inline emitter and so produced no object at all — even though n_removed /
# n_restored are the two keys only an uninstall ever fills. Every exit path that has run
# far enough to have a tally now calls this first; keep it that way when adding another.
#
# The --json test lives HERE rather than at the call sites for the same reason: the defect
# was a caller forgetting the emitter, so a new exit path should only have to remember one
# word. Outside --json this is a no-op (and fd 3 doesn't even exist).
emit_json() {
  ((JSON)) || return 0
  # Leading underscores: `ok` is also a function name in this file (the green-glyph
  # printer), and a local shadowing it would read as a bug to the next person even
  # though bash keeps variables and functions in separate namespaces.
  local _dry=false _ok=true
  ((DRY)) && _dry=true
  ((${#FAILURES[@]})) && _ok=false
  # TOOLS_JSON is empty until verify_tools runs, which the uninstall path never does —
  # `"tools":{}` there is correct and means "no probe was taken", not "nothing present".
  printf '{"dry_run":%s,"ok":%s,"linked":%d,"backed_up":%d,"seeded":%d,"skipped":%d,"removed":%d,"restored":%d,"tools":{%s},"errors":%s,"warnings":%s,"next_steps":%s}\n' \
    "$_dry" "$_ok" "$n_linked" "$n_backed" "$n_seeded" "$n_skipped" "$n_removed" "$n_restored" \
    "$TOOLS_JSON" \
    "$(json_array "${FAILURES[@]+"${FAILURES[@]}"}")" \
    "$(json_array "${WARNINGS[@]+"${WARNINGS[@]}"}")" \
    "$(json_array "${NEXT_TODO[@]+"${NEXT_TODO[@]}"}")" >&3
}

# print_summary — the run tally, factored out so the INT/TERM trap can show what was
# already done if you Ctrl-C mid-run (a long brew bundle, say). Without this, an
# interrupt left you with no record of the partial state and no reminder that re-running
# is safe. `$1` is an optional headline (e.g. "interrupted").

# print_ledger — re-list the WARNINGS/FAILURES ledger under a tally so the failures aren't
# scrolled off above a long brew bundle (or above 40 lines of uninstall). Shared by
# print_summary and uninstall's own summary: both close a run, so both owe the same recap.
#
# `"${a[@]+"${a[@]}"}"`: on bash 3.2 under `set -u`, expanding an EMPTY array is an
# "unbound variable" error — the count guard makes it non-empty here, but keep the idiom
# so a later edit that moves these lines can't reintroduce the crash.
print_ledger() {
  if ((${#WARNINGS[@]})); then
    printf '  %s%s%s %d warning(s):\n' "$c_y" "$G_INFO" "$c_0" "${#WARNINGS[@]}"
    printf '      - %s\n' "${WARNINGS[@]+"${WARNINGS[@]}"}"
  fi
  if ((${#FAILURES[@]})); then
    printf '  %s%s%s %d step(s) did not complete:\n' "$c_r" "$G_ERR" "$c_0" "${#FAILURES[@]}" >&2
    printf '      - %s\n' "${FAILURES[@]+"${FAILURES[@]}"}" >&2
  fi
}

print_summary() {
  # Always prints (bypasses the --quiet say() gate via a direct printf) — the tally is
  # the whole point of a quiet run, so it must never be suppressed.
  printf '%s==>%s %s\n' "$c_b" "$c_0" "${1:-summary}"
  ok "$n_linked linked · $n_backed backed up · $n_seeded seeded · $n_skipped skipped"
  print_ledger
}

# print_next_steps — the #135 closing checklist. TODOs first (what a human must still do),
# the ✓ items after (what bootstrap handled for you), so the eye lands on the actionable
# half rather than scrolling past it. Bypasses the --quiet say() gate with a direct printf
# for the same reason print_summary does: a quiet run is exactly the case where "your
# keyboard remapper still needs a permission" is the one line worth printing.
#
# Silent when BOTH lists are empty — on a box that deselected the desktop and git groups
# there is no checklist to give, and a bare header would be noise.
print_next_steps() {
  ((${#NEXT_TODO[@]} + ${#NEXT_DONE[@]})) || return 0
  printf '%s==>%s %s\n' "$c_b" "$c_0" "next steps"
  local m
  for m in "${NEXT_TODO[@]+"${NEXT_TODO[@]}"}"; do info "$m"; done
  for m in "${NEXT_DONE[@]+"${NEXT_DONE[@]}"}"; do ok "$m"; done
  return 0 # a for-loop over an empty list yields the PREVIOUS status; be explicit
}

# Graceful interrupt: report the partial run + reassure that bootstrap is idempotent
# (so the fix is simply to re-run), then exit 130 (128+SIGINT) — the conventional code.
on_interrupt() {
  printf '\n' >&2
  err "interrupted"
  print_summary "partial summary (interrupted)" >&2
  info "bootstrap is idempotent — re-run to finish where it left off" >&2
  exit 130
}
trap on_interrupt INT TERM

# run <cmd...> — execute, or (in --dry-run) just announce the mutation. For plain
# commands only; pipes/redirections are guarded inline at their call site instead.
run() {
  if ((DRY)); then
    info "would run: $*"
  else
    "$@"
  fi
}

# spin <label> <cmd...> — run an OPAQUE long step with a live spinner so the terminal
# reads as progress, not a hang. Output is captured and shown ONLY on failure (a clean
# run stays quiet; a broken one prints what went wrong). On a non-TTY (CI, piped) or in
# --dry-run there's no animation: it just runs the command with output passing through,
# so logs and the dry-run plan are unchanged. Returns the command's own exit status.
spin() {
  local label="$1"
  shift
  if ((DRY)); then
    info "would run: $*"
    return 0
  fi
  # No TTY (CI, piped) → run plainly, output passes through; then emit a scannable
  # done/failed marker so a log reads as discrete steps with outcomes, not a bare
  # "label…" with no resolution (the TTY path below ends each step with ✓/✗ too).
  if [[ ! -t 1 ]]; then
    # ${label} braced, NOT "$label…": bash 3.2 (macOS /bin/bash) slurps the trailing
    # multibyte … into the variable NAME, looks up the unset `label…`, and under `set -u`
    # aborts the whole run. This non-TTY spin path is only reached on a real apply (the mise
    # install step), so it stayed hidden until the apply round-trip test exercised it.
    info "${label}…"
    # Run inside `||` so a non-zero exit can't trip `set -e` before we capture rc and emit
    # the marker — spin() may be called without an `|| handler` guard at the call site.
    local rc=0
    "$@" || rc=$?
    if ((rc == 0)); then ok "$label"; else err "$label — failed (exit $rc)"; fi
    return "$rc"
  fi
  local out rc
  out="$(mktemp -t bootstrap-spin.XXXXXX)" || {
    "$@"
    return $?
  }
  "$@" >"$out" 2>&1 &
  local pid=$! frames="$SPIN_FRAMES" i=0
  # A signal during a spin: FORWARD it to the child (so a child that only traps ^C actually
  # stops) and REAP with `wait` before handing off, so the work really halts instead of
  # lingering; then restore the cursor and hand off to the global handler (partial summary
  # + exit 130). We trap BOTH INT and TERM: the global trap handles TERM too, but it knows
  # nothing about $pid and never restores the cursor — so a SIGTERM mid-spin (e.g. CI
  # cancellation) would otherwise orphan the child and leave the cursor hidden. Mirrors
  # Core's 05-ui.zsh _core_spin (SIGINT-forward + wait).
  trap 'kill -INT  "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; printf "\e[?25h"; on_interrupt' INT
  trap 'kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; printf "\e[?25h"; on_interrupt' TERM
  printf '\e[?25l' # hide cursor while spinning
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s' "$c_y" "${frames:i++%${#frames}:1}" "$c_0" "$label"
    sleep 0.1
  done
  printf '\e[?25h\r\033[K'   # restore cursor, return to col 0, clear the line
  trap on_interrupt INT TERM # re-arm the normal interrupt handlers
  if wait "$pid"; then
    rc=0
    ok "$label"
  else
    rc=$?
    err "$label — failed (exit $rc)"
    sed 's/^/    /' "$out" >&2 # indent the captured output under the failure
  fi
  rm -f "$out"
  return "$rc"
}

# brew_shellenv runs TWICE per run (the unconditional call below and again in provision()),
# so a genuinely broken brew trips both calls. Ledger it once — a second FAILURES entry for
# the same broken step would inflate the "N step(s) did not complete" tally — and just say
# it plainly the second time. Ends on a zero status (both fail_note and err do) so a call in
# statement position cannot trip `set -e`.
BREW_SHELLENV_NOTED=0
brew_shellenv_fail() { # brew_shellenv_fail <message>  → ledger the first, err the rest
  if ((BREW_SHELLENV_NOTED)); then
    err "$1"
  else
    BREW_SHELLENV_NOTED=1
    fail_note "$1"
  fi
}

# brew_shellenv — put Homebrew on PATH for the rest of this run (Apple Silicon first, then
# Intel). Factored out of provision() because it is needed in TWO places:
#
#   1. UNCONDITIONALLY, right after the guards below — provision() is the only thing that
#      used to run it, and --links-only skips provision() entirely. From a fresh /bin/bash
#      (the first Terminal on a new machine, or CI) /opt/homebrew/bin isn't on PATH yet, so
#      `command -v mise` further down failed and the whole `mise install` step silently
#      no-op'd with no message — a green "bootstrap complete" and no runtimes.
#   2. Again inside provision() after a FRESH Homebrew install, when call (1) ran before
#      brew existed and therefore found nothing.
#
# Idempotent and safe to call twice: `typeset -U`-style dedup isn't available in bash, but
# `brew shellenv` emits absolute assignments, so the second call just rewrites the same
# values.
#
# CAPTURE-then-CHECK-then-eval, never `eval "$(brew shellenv)"` directly: a non-zero
# shellenv (corrupt install, unreadable prefix, a brew whose Ruby is broken) expands to an
# EMPTY string, and `eval ""` exits 0 — so `set -e` never fires and PATH is silently never
# set. That is the identical failure shape this commit series removes from the Homebrew
# installer one-liner, and it matters MORE here now that the early call is the only thing
# putting brew on PATH in --links-only mode.
#
# What is checked is the EXIT STATUS and then the resulting PATH — never the shape of the
# output. Empty output is a documented SUCCESS (see the guard note in the body).
#
# Returns non-zero (after saying so) when a brew binary exists but shellenv fails, so a
# caller that genuinely needs brew can escalate. Not fatal on its own — the symlink-only
# modes work fine without Homebrew, so a broken brew must not stop them. A box with no
# Homebrew at all is NOT an error: that's a fresh machine, and provision() installs it.
brew_shellenv() {
  local brew out bindir
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$brew" ]] || continue
    bindir="${brew%/brew}"
    if ! out="$("$brew" shellenv)"; then
      brew_shellenv_fail "$brew shellenv failed — Homebrew tools will not be on PATH"
      return 1
    fi
    # EMPTY OUTPUT IS SUCCESS, not failure. `brew shellenv` opens with an idempotence guard
    # and returns having printed NOTHING when its own bin:sbin already lead PATH:
    #   [[ "${HOMEBREW_PATH%%:"${HOMEBREW_PREFIX}"/sbin*}" == "${HOMEBREW_PREFIX}/bin" ]]
    # We call this function TWICE, and the first call's eval is exactly what puts brew at
    # the front of PATH — so on a working box the second call ALWAYS takes that branch.
    # Testing `[[ -z "$out" ]]` therefore reported success as a failure on every full run.
    # Test the OUTCOME instead: eval whatever came back (an empty eval is a correct no-op),
    # then assert the thing we actually care about — brew's bin dir really is on PATH.
    eval "$out"
    [[ ":$PATH:" == *":$bindir:"* ]] && return 0
    brew_shellenv_fail "$brew shellenv did not put $bindir on PATH"
    return 1
  done
  return 0 # no Homebrew on this box (yet) — normal on a fresh machine
}

[[ "$(uname -s)" == "Darwin" || -n "${BOOTSTRAP_ALLOW_NON_DARWIN:-}" ]] || {
  err "this bootstrap is macOS-only"
  info "set BOOTSTRAP_ALLOW_NON_DARWIN=1 to preview the plan elsewhere (with --dry-run)"
  exit 1
}
# A normal clone already CONTAINS core/ (it's a tracked subtree), so this only fires
# when building the repo from scratch — say exactly what to run, don't just abort.
[[ -d "$REPO/core" ]] || {
  err "core/ subtree missing — this should be present in a clone; if building fresh, take"
  err "the RELEASED tag (never main), or core-integrity reports the subtree as TAMPERED:"
  info "git subtree add --prefix=core <dotfiles-core-url> refs/tags/v4 --squash"
  info "make core-lock"
  exit 1
}

# Homebrew on PATH for EVERY mode (see brew_shellenv above) — not just the provisioning
# path, so --links-only can still find mise/nvim/tmux. A no-op on a box without Homebrew;
# provision() calls it again after a fresh install.
#
# `|| true` is deliberate: brew_shellenv reports a BROKEN brew and returns non-zero, which
# under `set -e` would otherwise abort the whole run here — before the guards have even
# decided whether this mode needs Homebrew at all. Symlink-only runs must survive a broken
# brew; the run that actually needs it (provision, below) escalates on its own.
#
# Discarding the status does NOT hide the failure: brew_shellenv has already recorded it
# through fail_note, so the ledger, the summary and the --json "ok" field still report it
# and the run still exits 3.
brew_shellenv || true

((DRY)) && say "DRY RUN — no changes will be made; printing the plan only"

# ── link helper: back up a real file once, then symlink ──────────────────────
link() { # link <src> <dest>
  local src="$1" dest="$2"
  [[ -e "$src" ]] || {
    info "skip (missing): ${src#"$REPO"/}"
    n_skipped=$((n_skipped + 1))
    return 0
  }
  # Idempotent fast path: already the correct symlink → report and move on. Makes
  # a re-run (and a --dry-run) honest about what's actually already wired.
  if [[ -L "$dest" && "$(readlink "$dest")" == "$src" ]]; then
    noop "${dest/#"$HOME"/\~} (already linked)"
    n_linked=$((n_linked + 1))
    return 0
  fi
  if ((DRY)); then
    if [[ -L "$dest" ]]; then
      info "would relink: ${dest/#"$HOME"/\~} → ${src#"$REPO"/}"
    elif [[ -e "$dest" ]]; then
      info "would back up real file, then link: ${dest/#"$HOME"/\~}"
      n_backed=$((n_backed + 1))
    else
      info "would link: ${dest/#"$HOME"/\~} → ${src#"$REPO"/}"
    fi
    n_linked=$((n_linked + 1))
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  elif [[ -e "$dest" ]]; then
    mv "$dest" "$dest.pre-dotfiles.$(date +%Y%m%d-%H%M%S)"
    info "backed up existing $dest"
    n_backed=$((n_backed + 1))
  fi
  ln -s "$src" "$dest"
  ok "${dest/#"$HOME"/\~}"
  n_linked=$((n_linked + 1))
}

# ── provision (Homebrew + packages) ──────────────────────────────────────────
provision() {
  # STOP when the Command Line Tools are missing. `xcode-select --install` only SPAWNS a GUI
  # installer and returns immediately — it does not wait, and any failure was swallowed by
  # `|| true`. The old code printed "then re-run" and then carried straight on into the
  # Homebrew install and a `git clone` (tpm) that pops a SECOND blocking dialog against a
  # /usr/bin/git stub. Exiting here is what actually makes "then re-run" true.
  if ! xcode-select -p >/dev/null 2>&1; then
    say "Xcode Command Line Tools"
    xcode-select --install 2>/dev/null || true
    err "Xcode Command Line Tools are required before provisioning"
    info "finish the CLT installer window that just opened, then re-run: ./bootstrap.sh"
    exit 1
  fi
  # `--no-brew` promises "skip Homebrew/brew bundle", but NO_BREW previously gated only the
  # bundle below — so on a fresh Mac the flag still downloaded and ran the Homebrew
  # installer (sudo prompt, several minutes, hundreds of MB). Gate the installer too.
  if ((!NO_BREW)) && ! command -v "$BREW" >/dev/null 2>&1; then
    say "Installing Homebrew"
    # Download FIRST, check the status, THEN execute. The upstream one-liner
    # `/bin/bash -c "$(curl -fsSL …)"` cannot fail safely: a failed curl (no network, DNS,
    # captive portal, proxy, GitHub outage) yields an EMPTY string, and `/bin/bash -c ""` is
    # a valid program that exits 0. `set -e` never fires — the failing command is inside
    # $(…) and the outer command succeeded — so the run continued brewless and died minutes
    # later at `brew: command not found` with NOT ONE symlink wired and no diagnosis.
    local installer
    installer="$(mktemp -t brew-install.XXXXXX)" || {
      err "could not create a temp file for the Homebrew installer"
      exit 1
    }
    if ! curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$installer"; then
      rm -f "$installer"
      err "could not download the Homebrew installer — check your network/proxy"
      info "or install it by hand from https://brew.sh, then re-run: ./bootstrap.sh"
      exit 1
    fi
    if ! /bin/bash "$installer"; then
      rm -f "$installer"
      err "Homebrew installation failed — see its output above"
      exit 1
    fi
    rm -f "$installer"
  fi
  # brew now exists (or never will) — re-run the PATH setup, since the unconditional call
  # near the top ran before this install. Same `|| true` reasoning as there: brew_shellenv
  # has already SAID what went wrong (and ledgered it once), and the guard just below turns
  # that into a clean exit with a remedy rather than letting `brew bundle` die at 127 with
  # no explanation.
  brew_shellenv || true
  if ((!NO_BREW)) && [[ -f "$REPO/Brewfile" ]]; then
    # Escalate here, where Homebrew is genuinely required. Without this, a brew that exists
    # but whose shellenv failed reaches `brew bundle` as a bare `brew: command not found`
    # (exit 127) — the same misleading death this commit series removes from the installer
    # path, just one step later.
    if ! command -v "$BREW" >/dev/null 2>&1; then
      err "Homebrew is not on PATH — cannot run brew bundle"
      info "see the shellenv error above; or put it on PATH by hand and re-run:"
      # shellcheck disable=SC2016  # a command for the USER to paste — must NOT expand here
      info '  eval "$(/opt/homebrew/bin/brew shellenv)"   # Intel: /usr/local/bin/brew'
      exit 1
    fi
    # B13: skip the expensive resolve+install when the Brewfile is already satisfied.
    # `brew bundle check` is a fast read-only "is everything here installed?" probe, so a
    # re-run on a provisioned box no longer pays for a full `brew bundle` pass.
    if "$BREW" bundle check --file="$REPO/Brewfile" >/dev/null 2>&1; then
      ok "brew bundle already satisfied — skipping (every formula/cask is installed)"
    else
      # Up-front scope so the longest, mostly-opaque step reads as BOUNDED work, not an
      # open-ended hang: count the Brewfile entries (best-effort; falls back to "?" if the
      # list query fails) and name the number before handing off to brew's own streaming
      # output. `brew bundle list --all` enumerates every tap/brew/cask/mas line.
      #
      # `|| n_pkgs=""` is what makes "best-effort" TRUE. `set -o pipefail` plus a STANDALONE
      # assignment is a silent-kill combo: the assignment IS the command, so when `brew
      # bundle list` died (a broken vendored gem stack makes every `brew bundle` subcommand
      # crash, while plain `brew list` still works) the non-zero pipeline aborted the entire
      # run under `set -e` — with the traceback already discarded by `2>/dev/null`, and
      # before provision(), the FIRST thing a full run does, had printed one byte. The
      # symptom was a bootstrap that emitted absolutely nothing and exited non-zero. An
      # AND-OR list is exempt from errexit, which is the only reason the `${n_pkgs:-?}`
      # fallback on the next line is reachable at all.
      local n_pkgs
      n_pkgs="$("$BREW" bundle list --file="$REPO/Brewfile" --all 2>/dev/null | wc -l | tr -d ' ')" || n_pkgs=""
      say "brew bundle (${n_pkgs:-?} formulae/casks — this can take a while)"
      # LEDGER a failed bundle instead of dying on it (#133). As a bare command under
      # `set -e` this aborted the run at exit 1 — mid-provision, before wire_links, so a
      # sick Homebrew cost you every symlink and printed no summary. The packages are the
      # one part of a bootstrap you can retry by hand; the wiring is not. Record it, keep
      # going, and let the run close as DEGRADED (exit 3) with the reason named.
      if ! "$BREW" bundle --file="$REPO/Brewfile"; then
        fail_note "brew bundle failed — some formulae/casks are missing; re-run: brew bundle --file=$REPO/Brewfile"
      fi
    fi
  else
    info "skipping brew bundle (--no-brew or no Brewfile yet)"
  fi
}

# verify_tools — confirm the headline tools actually landed on PATH, so a half-finished
# bundle is reported instead of silently assumed-good. Read-only (`command -v` probes).
#
# Called at the END of the run (#133). It used to run immediately after provision() —
# BEFORE wire_links and before `mise install` — so on every fresh box it reported
# everything mise provides as "not yet on PATH". A hint that always cries wolf is a hint
# you learn to ignore, which is why it moved to just before the summary.
#
# Publishes TOOLS_JSON so the --json emitter serialises THIS probe instead of repeating
# the loop; the human line and the machine object then cannot drift apart.
TOOLS_JSON=""
verify_tools() {
  local missing=() t present
  TOOLS_JSON=""
  for t in zsh starship mise fzf nvim tmux git; do
    if command -v "$t" >/dev/null 2>&1; then
      present=true
    else
      present=false
      missing+=("$t")
    fi
    TOOLS_JSON="${TOOLS_JSON:+$TOOLS_JSON,}\"$t\":$present"
  done
  if ((${#missing[@]})); then
    # A WARNING, not a failure: the usual cause is that this shell simply predates the
    # install, so it must not make an otherwise-clean bootstrap exit 3.
    warn_note "not yet on PATH: ${missing[*]} — open a new shell, or re-run after brew bundle finishes"
  else
    ok "core tools present (zsh starship mise fzf nvim tmux git)"
  fi
}

# ── closing-checklist probes (#135) ───────────────────────────────────────────
# What these can and cannot know: macOS keeps Accessibility and Input Monitoring grants in
# the SYSTEM TCC database, which is unreadable without Full Disk Access — so there is no
# honest way to ask "was this permission granted?" from a shell. Everything below is a
# BEHAVIOURAL proxy, and each ✓ is therefore worded as the observation it actually made,
# never as the conclusion you would like to draw from it. A checklist that overstates is
# the same defect as a bootstrap that closes with "complete" over a machine that is dead.
#
# All read-only, all guarded on their tool existing, and all end on status 0: they are
# called in statement position under `set -euo pipefail`, where a falsy last command in a
# function aborts the whole run.

# karabiner_ready — true when Karabiner's DriverKit extension is approved AND its per-user
# server is alive. The extension approval is the half macOS will actually tell us about
# (`systemextensionsctl list` reads fine unprivileged); a running console_user_server is
# evidence the app has been opened and got far enough to launch its helpers.
#
# Input Monitoring is proven by NEITHER, which is why the ✓ that consumes this says
# "driver extension approved and running" and stops there. Deliberately not `pgrep -x
# karabiner_grabber`: the grabber is a root daemon that does not show up for a user pgrep
# even on a fully working box, so keying off it would report every Mac as broken.
karabiner_ready() {
  command -v systemextensionsctl >/dev/null 2>&1 || return 1
  systemextensionsctl list 2>/dev/null |
    grep -q 'org.pqrs.Karabiner-DriverKit-VirtualHIDDevice.*activated enabled' || return 1
  pgrep -x karabiner_console_user_server >/dev/null 2>&1
}

# check_desktop_permissions — the two GUI apps that are INERT until macOS grants them a
# permission, and that report nothing when it hasn't been: hotkeys and tiling simply do
# not happen, with no error to search for. Gated on the desktop group and on the app being
# installed — a `--skip desktop` box has nothing to grant, and a box where the cask never
# landed has a `brew bundle` failure already in the ledger saying so.
check_desktop_permissions() {
  blib_want desktop || return 0
  if [[ -d /Applications/Karabiner-Elements.app ]]; then
    if karabiner_ready; then
      done_step "Karabiner driver extension approved and its user server is running"
    else
      todo_step "Karabiner-Elements — open it once, approve its driver extension, then grant it Input Monitoring (System Settings → Privacy & Security)"
    fi
  fi
  if [[ -d /Applications/AeroSpace.app ]]; then
    # Ask AeroSpace itself rather than pgrep for it: the CLI reaches the running server
    # over a socket, so an answer proves the server is up AND responding. A process that
    # launched and then stalled on a permission dialog does not answer.
    if command -v aerospace >/dev/null 2>&1 && aerospace list-monitors >/dev/null 2>&1; then
      done_step "AeroSpace is running and responding"
    else
      todo_step "AeroSpace is not responding — launch it and grant it Accessibility (System Settings → Privacy & Security → Accessibility)"
    fi
  fi
  return 0
}

# check_git_identity — blib_seed copies core/git/local.gitconfig.example to
# ~/.config/git/local.gitconfig on a fresh box, and the run then declares success. What is
# left is a git that refuses to commit ("Please tell me who you are") with nothing in the
# bootstrap log connecting the two (#135).
#
# Reads the SEEDED FILE, not the effective value: core/git/gitconfig carries `includeIf
# gitdir:` blocks for ~/work and ~/clients, so `git config --get user.email` answers
# differently depending on where it is run — from this repo it would miss a work identity,
# and from ~/work it would mask an unset personal one.
#
# NB the placeholder is `Your Name` / `you@example.com`, the literal content of the example
# file. It is NOT the string "FILL IN your name & email", which exists only as blib_seed's
# one-line note at seed time and never reaches the file.
check_git_identity() {
  blib_want git || return 0
  command -v git >/dev/null 2>&1 || return 0
  local f="$HOME/.config/git/local.gitconfig" name="" email="" shown
  shown="${f/#"$HOME"/\~}"
  if [[ -f "$f" ]]; then
    # `|| var=""`: a standalone assignment from a command substitution IS the command under
    # `set -e`, and `git config` exits 1 on a missing key — so an unset user.email would
    # abort the run one line before the checklist that exists to report it.
    name="$(git config -f "$f" user.name 2>/dev/null)" || name=""
    email="$(git config -f "$f" user.email 2>/dev/null)" || email=""
  else
    # Never seeded (--skip git, or a box predating the seed): the global config is then the
    # only place an identity could live, and an empty answer there is the real problem.
    name="$(git config --global user.name 2>/dev/null)" || name=""
    email="$(git config --global user.email 2>/dev/null)" || email=""
  fi
  if [[ -z "$email" || "$email" == "you@example.com" || "$name" == "Your Name" ]]; then
    if [[ -f "$f" ]]; then
      todo_step "git identity is still the seeded placeholder — edit $shown, or: git config -f $shown user.email 'you@your.domain'"
    else
      todo_step "git identity is unset — git will refuse to commit; set it: git config --global user.email 'you@your.domain'"
    fi
  else
    done_step "git identity set ($email)"
  fi
  return 0
}

# _tmux_plugin_count <plugins-dir> — how many plugins are installed, i.e. any directory in
# there other than tpm itself. Cheap, and true of a hand-installed box too. Used twice: to
# decide whether there is anything to do, and to VERIFY that doing it worked.
_tmux_plugin_count() {
  local n=""
  n="$(find "$1" -mindepth 1 -maxdepth 1 -type d ! -name tpm 2>/dev/null | wc -l | tr -d ' ')" || n=""
  printf '%s' "${n:-0}"
}

# install_tmux_plugins — tpm is cloned by the shared scaffold, but its plugins need a
# manual `prefix + I` and nothing ever said so, so a fresh box came up with tmux and none
# of the seven plugins tmux.conf declares (#135). tpm ships a headless entry point, so
# bootstrap can simply do it.
#
# It CANNOT be called bare, and getting this wrong is silent. tpm resolves its install
# directory from the TMUX_PLUGIN_MANAGER_PATH set on a tmux SERVER; core/tmux/tmux.conf
# only ever sets that asynchronously, from its trailing `run '…/tpm/tpm'`. Reach tpm before
# that fires and the value is empty, tpm does `cd "/"`, and every clone fails. `-f
# /dev/null` is not a way out either: the @plugin LIST is read off the same config, so a
# config-less server installs nothing at all.
#
# So: start a THROWAWAY server on a private socket (TMUX_TMPDIR), load the real config on
# it so the @plugin list is present, and set the path explicitly. The operator's own tmux —
# quite possibly the one they are running this from — is never touched, and the throwaway
# server is killed on the way out.
#
# XDG_CONFIG_HOME is pinned for the same reason, and it is not paranoia: tpm derives its
# own path from `${XDG_CONFIG_HOME:-$HOME/.config}/tmux` and re-sets it on the server as
# the config loads, LATER than — and therefore over the top of — the set-environment below.
# wire_links hardcodes $HOME/.config as the destination, so an inherited XDG_CONFIG_HOME
# pointing at another tree would quietly aim the clones somewhere bootstrap never wired.
install_tmux_plugins() {
  local dir="$HOME/.config/tmux/plugins" tpm="$HOME/.config/tmux/plugins/tpm"

  # Count FIRST, before requiring tpm's installer. Whether the plugins are there is a
  # question about the plugins, not about tpm — gate the report on the installer and a box
  # with working plugins but a half-cloned tpm silently drops off the checklist entirely.
  local n
  n="$(_tmux_plugin_count "$dir")"
  if ((n > 0)); then
    done_step "tmux plugins installed ($n)"
    return 0
  fi
  # Nothing installed and no headless installer to run: a FAILED tpm clone is already
  # ledgered by the shared scaffold (blib_note_fail → FAILURES), so stay quiet rather than
  # say the same thing twice in two different voices.
  [[ -x "$tpm/bin/install_plugins" ]] || return 0
  if ! command -v tmux >/dev/null 2>&1; then
    todo_step "tmux plugins are not installed — once tmux is on PATH, open it and press prefix + I"
    return 0
  fi

  local sock=""
  sock="$(mktemp -d)" || sock=""
  if [[ -z "$sock" ]]; then
    todo_step "tmux plugins are not installed — open tmux and press prefix + I"
    return 0
  fi
  # local -x, not a `VAR=x cmd` prefix: bash keeps an assignment prefixed to a SHELL
  # FUNCTION call (spin is one) in effect after that function returns, which would leak the
  # throwaway socket into every later tmux command in this run. Scoped and exported here.
  local -x TMUX_TMPDIR="$sock"
  local -x XDG_CONFIG_HOME="$HOME/.config"
  say "tmux plugins (tpm)"
  # Neither call decides the outcome — the directory listing below does — so both are
  # allowed to fail without aborting under `set -e`. spin already prints its captured log
  # when the command fails, so a real breakage is on screen either way.
  tmux -f "$HOME/.config/tmux/tmux.conf" start-server \; \
    set-environment -g TMUX_PLUGIN_MANAGER_PATH "$dir/" 2>/dev/null || true
  spin "installing tmux plugins" "$tpm/bin/install_plugins" || true
  tmux kill-server 2>/dev/null || true
  rm -rf "$sock"

  # VERIFY rather than trust the exit code. tpm exits 0 having installed nothing whenever
  # its idea of the plugin path differs from ours — and a ✓ printed over an empty directory
  # is precisely the defect this checklist exists to stop. The listing is the ground truth.
  n="$(_tmux_plugin_count "$dir")"
  if ((n > 0)); then
    done_step "tmux plugins installed ($n)"
  else
    # A WARNING, not a fail_note: tmux is perfectly usable without its plugins and the
    # recovery is two keystrokes. Contrast the MISSING-tpm check in the run body, which is
    # ledgered as a failure precisely because it leaves no plugin manager to press them in.
    warn_note "tpm installed no tmux plugins — tmux still starts, just without them"
    todo_step "tmux plugins are not installed — open tmux and press prefix + I"
  fi
  return 0
}

# install_pre_commit_hook — the Brewfile installs pre-commit and .pre-commit-config.yaml
# defines the gate, but nothing ever ran `pre-commit install`, so the local commit-time
# check — gitleaks included — did not exist until someone remembered (#135). That is also
# what made SECURITY.md's "locally at commit time" caveat load-bearing.
#
# ORDER MATTERS, and it is why this is called from the run body AFTER wire_links rather
# than from inside it. wire_links installs the core/ guard directly into
# .git/hooks/pre-commit; pre-commit then moves that aside to pre-commit.legacy and goes on
# executing it (its hook-impl runs an executable <hook>.legacy first), so both gates
# survive. Reverse the order and blib_install_core_guard finds a foreign hook, declines to
# overwrite it, and the clone ends up with no core/ guard at all.
install_pre_commit_hook() {
  command -v "$PRE_COMMIT" >/dev/null 2>&1 || return 0
  [[ -f "$REPO/.pre-commit-config.yaml" ]] || return 0
  git -C "$REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  # --git-path resolves the real hooks dir through worktrees and submodules, where it lives
  # in the common git dir rather than under $REPO/.git — the same reasoning as the shared
  # scaffold's blib_install_core_guard. The path comes back relative to $REPO.
  local hooks="" hook legacy
  hooks="$(git -C "$REPO" rev-parse --git-path hooks 2>/dev/null)" || hooks=""
  [[ -n "$hooks" ]] || return 0
  [[ "$hooks" == /* ]] || hooks="$REPO/$hooks"
  hook="$hooks/pre-commit"
  legacy="$hooks/pre-commit.legacy"

  # pre-commit's generated hook carries this marker; the core/ guard has no such line, so
  # it distinguishes "the framework hook is installed" from "some hook exists".
  if grep -q '# start templated' "$hook" 2>/dev/null; then
    done_step "pre-commit hook installed"
  elif ((LINKS_ONLY)); then
    # --links-only is promised as "just (re)create symlinks, no installs" by both usage()
    # and the README, and writing a git hook is an install. Report the gap instead of
    # closing it — the probe is still honest, a full run is what acts on it. This is also
    # what keeps `make test-repo`, which does real --links-only applies against the actual
    # working tree, from rewriting the contributor's own .git/hooks/pre-commit.
    todo_step "the local lint + secret-scan gate is not active — run: pre-commit install"
    return 0
  elif (cd "$REPO" && "$PRE_COMMIT" install >/dev/null 2>&1); then
    done_step "pre-commit hook installed — the local lint + gitleaks gate is now live"
  else
    warn_note "pre-commit install failed — the local commit-time gate (gitleaks included) is not active"
    todo_step "the local lint + secret-scan gate is not active — run: pre-commit install"
    return 0
  fi
  # Answers the now-stale blib_install_core_guard line printed back in wire_links ("already
  # has a custom pre-commit hook — left as-is"). Once pre-commit owns the hook path the
  # guard is still enforced, just from .legacy — say so, or the warning reads as a hole.
  if grep -q 'dotfiles-core-guard' "$legacy" 2>/dev/null; then
    info "core/ guard preserved as ${legacy/#"$REPO"/.} — pre-commit runs it first"
  fi
  return 0
}

# set_login_shell — opt-in (--set-shell). Make the Homebrew zsh the login shell,
# idempotently: skip if it's already $SHELL, and only append to /etc/shells if the
# path isn't already listed (chsh refuses a shell that isn't in there).
set_login_shell() {
  local brew_zsh=""
  if [[ -x /opt/homebrew/bin/zsh ]]; then
    brew_zsh=/opt/homebrew/bin/zsh
  elif [[ -x /usr/local/bin/zsh ]]; then
    brew_zsh=/usr/local/bin/zsh
  fi
  [[ -n "$brew_zsh" ]] || {
    info "Homebrew zsh not found — skipping login-shell change (run brew bundle first)"
    return 0
  }
  if [[ "${SHELL:-}" == "$brew_zsh" ]]; then
    ok "login shell already $brew_zsh"
    return 0
  fi
  say "login shell → $brew_zsh"
  if ((DRY)); then
    info "would add $brew_zsh to /etc/shells (if absent), then: chsh -s $brew_zsh"
    return 0
  fi
  confirm "Change your login shell to $brew_zsh now (chsh)?" || {
    info "login shell unchanged (declined)"
    return 0
  }
  grep -qxF "$brew_zsh" /etc/shells 2>/dev/null || echo "$brew_zsh" | sudo tee -a /etc/shells >/dev/null
  if chsh -s "$brew_zsh"; then
    ok "login shell set — open a new terminal to use it"
  else
    fail_note "chsh failed — login shell unchanged; set it manually: chsh -s $brew_zsh"
  fi
}

# ── symlinks ──────────────────────────────────────────────────────────────────
wire_links() {
  local CFG="$HOME/.config"
  WIRE_STEP=0 # reset so the [k/N] counter is fresh even if wire_links is called twice

  # The Core surface (clip helpers, zsh modules, tmux + tpm, starship, lazygit, nvim, vim,
  # mise, git config + seeded identity, sesh seed, ssh) + the macOS os/ overlay
  # (macos.zsh/.conf/.gitconfig) are wired by the SHARED scaffold core/lib/bootstrap-lib.sh
  # — ONE definition the whole fleet uses, so a new Core file links here automatically
  # instead of being re-listed by hand (the exact drift that left lazygit + vimrc unlinked
  # in this repo). Map --dry-run onto BLIB_DRY so the scaffold previews and mutates nothing.
  step "Core + macOS overlay (shared scaffold)"
  # shellcheck disable=SC2034  # read by the sourced bootstrap-lib.sh (blib_* honor BLIB_DRY)
  BLIB_DRY="$DRY"
  BLIB_LINKED=0 BLIB_SEEDED=0 BLIB_BACKED=0 BLIB_SKIPPED=0
  # Reset the failure ledger too, so a second blib_link_* call in one run can't double-count.
  BLIB_FAILED=()
  # blib_* are not --quiet-aware and conflate section headers with actionable messages
  # (seeded-file notes, ssh wiring) on the same stream — so we do NOT redirect them away
  # under --quiet: a /dev/null there would hide those changes too, not just headers. We
  # accept the scaffold's couple of header lines leaking into a quiet run as the lesser
  # evil. Failures are no longer part of that trade-off — blib_note_fail puts them on
  # stderr — but the seeded/ssh notes still are. (In --json mode fd1 already points at
  # stderr, so this output never reaches the JSON object on fd3 regardless.)
  blib_link_core "$REPO" "$CFG"
  blib_link_os_layer "$REPO" "$CFG" macos
  # fold the scaffold's tallies into this run's summary so --json / print_summary stay accurate
  n_linked=$((n_linked + BLIB_LINKED))
  n_backed=$((n_backed + BLIB_BACKED))
  n_seeded=$((n_seeded + BLIB_SEEDED))
  n_skipped=$((n_skipped + BLIB_SKIPPED))
  # ...and the scaffold's FAILURES, so a lib-internal failure (a tpm clone behind a proxy)
  # makes this run exit 3 like any other degraded step. An array, not a counter, so it
  # appends. `"${arr[@]+"${arr[@]}"}"` because bash 3.2 under `set -u` treats an empty array
  # expansion as unset — the happy path leaves it empty. Appended DIRECTLY rather than via
  # fail_note: blib_note_fail already printed it to stderr, and print_ledger re-lists it at
  # the end; routing through fail_note would print the same line a third time.
  FAILURES+=("${BLIB_FAILED[@]+"${BLIB_FAILED[@]}"}")

  # ── macOS-only links the shared scaffold does NOT own ──────────────────────
  # zsh entry layer (ZDOTDIR model): ~/.zshenv sets ZDOTDIR; .zprofile/.zshrc live in
  # $ZDOTDIR. This repo symlinks its own entry files rather than using the scaffold's
  # generated-heredoc loader (blib_write_zshrc_loader) — a deliberate macOS difference.
  # The zsh entry layer rides with the zsh module group — skip it under --only/--skip
  # when zsh isn't selected (there'd be no Core zsh modules for it to load).
  if blib_want zsh; then
    step "zsh entry layer (ZDOTDIR model)"
    link "$REPO/zsh/zshenv" "$HOME/.zshenv"
    link "$REPO/zsh/zprofile" "$CFG/zsh/.zprofile"
    link "$REPO/zsh/zshrc" "$CFG/zsh/.zshrc"
  fi

  # Rides with the git group, matching how blib_link_os_layer already gates
  # os/macos.gitconfig on `blib_want git`. Previously ungated, so `--only zsh` wrote a
  # global gitignore while explicitly excluding git — internally inconsistent.
  if blib_want git; then
    step "git ignore (macOS)"
    # global gitignore; macos.zsh/.conf/.gitconfig are wired by blib_link_os_layer above.
    link "$REPO/os/macos.gitignore" "$CFG/git/ignore"
  fi

  # ── macOS desktop layer: terminal + banner + tiling WM + menu bar + keyboard ──
  # All read their config from ~/.config; the apps themselves come from the Brewfile.
  # Gated as ONE group (`desktop`, registered near the top of this file) — these are GUI
  # app configs with no Core counterpart, and `--only zsh` has no business writing them.
  if blib_want desktop; then
    step "ghostty"
    link "$REPO/ghostty/config" "$CFG/ghostty/config"

    step "fastfetch (system banner)"
    link "$REPO/fastfetch/config.jsonc" "$CFG/fastfetch/config.jsonc"

    step "aerospace (tiling WM)"
    link "$REPO/aerospace/aerospace.toml" "$CFG/aerospace/aerospace.toml"

    step "sketchybar (menu bar)"
    link "$REPO/sketchybar" "$CFG/sketchybar" # sketchybarrc + colors.sh + plugins/
    # `|| true` + 2>/dev/null so a non-expanding glob (plugins removed) can't abort the run
    # under `set -e` after links are already wired — matches the scaffold's guarded chmods.
    run chmod +x "$REPO"/sketchybar/sketchybarrc "$REPO"/sketchybar/plugins/*.sh 2>/dev/null || true

    step "borders (focused-window ring)"
    # bordersrc is the config AND the launcher: started bare — which is how the brew service
    # starts it — `borders` executes ~/.config/borders/bordersrc on launch. Linked as a
    # directory to mirror sketchybar/ above, so a second file here needs no bootstrap change.
    link "$REPO/borders" "$CFG/borders"
    run chmod +x "$REPO"/borders/bordersrc 2>/dev/null || true

    step "karabiner (keyboard)"
    link "$REPO/karabiner/karabiner.json" "$CFG/karabiner/karabiner.json"
  fi

  # ── local core/ guard (L6) ────────────────────────────────────────────────────
  # Install the pre-commit hook that REJECTS a hand-edit of the vendored core/ subtree.
  # It shipped in the shared scaffold but was only ever called by upstream sync-core.sh —
  # so anyone who clones this repo and merges sync PRs through the GitHub UI never got it,
  # and could drift core/ from day one with no local signal. CI's core-integrity still
  # catches it, but at PR time rather than commit time.
  #
  # Not DRY-aware in the lib (it writes the hook unconditionally), so gate it here.
  #
  # The lib returns 0 on every BENIGN skip (not a git tree, core.hooksPath set, a custom
  # pre-commit hook already present) and non-zero ONLY on a real failure — it can't
  # resolve the hooks dir, or mkdir failed. So the old `|| true` swallowed precisely the
  # two cases worth hearing about. A WARNING rather than an error: the guard is a
  # commit-time convenience, and CI's core-integrity job still catches core/ edits at PR
  # time, so its absence doesn't make the install itself degraded.
  if ((DRY)); then
    info "would install the core/ pre-commit guard (rejects hand-edits to the vendored subtree)"
  else
    blib_install_core_guard "$REPO" ||
      warn_note "core/ pre-commit guard not installed — hand-edits to core/ won't be caught locally (CI's core-integrity still will)"
  fi
}

# ── desktop services: sketchybar + borders under launchd (#134) ───────────────
# Installing them was never enough. Nothing here registered or started either one, and the
# only thing that ever launched them — aerospace.toml's after-startup-command — is itself a
# launchd-started GUI app with no /opt/homebrew/bin on PATH, so the bare command names
# resolved to nothing and exec-and-forget swallowed it. A fresh box came up with no menu bar,
# no focus ring, and not one error anywhere.
#
# `brew services` is the right owner, and not merely a second launcher: both formulae ship a
# `service` block with keep_alive (start at login, restart on crash, independent of whether
# AeroSpace is running) and PATH=std_service_path_env. That PATH is the load-bearing part —
# every plugin under sketchybar/plugins/ calls bare `sketchybar`, and they inherit it from
# the service. AeroSpace keeps its own PATH-prefixed commands as a fallback for a box where
# these were never registered; both binaries self-detect a running instance, so the overlap
# is harmless.
#
# Idempotent BY INSPECTION, not by retry: `brew services start` against a live service is a
# restart in all but name, and a re-run of bootstrap must not blink the operator's menu bar
# mid-session. So ask first and start only what is not already up.
start_desktop_services() {
  say "desktop services (launchd via brew services)"
  # ONE `brew services list` for both lookups — it stats every plist and is easily the
  # slowest thing in this function. On failure it stays empty, which reads as "neither is
  # started" and earns each a start attempt: the safe direction to be wrong in, since
  # starting an already-started service is redundant rather than destructive.
  #
  # Queried in --dry-run TOO. It is a read-only probe, and skipping it would make the plan
  # lie in the common case: a provisioned box would be told bootstrap "would start" a bar
  # that has been running for weeks.
  local listing=""
  listing="$("$BREW" services list 2>/dev/null)" || listing=""
  local svc status hint=0
  for svc in sketchybar borders; do
    # Column 2 of the row whose column 1 is the service name: none|started|stopped|error|…
    # `|| status=""` because a standalone assignment from a pipeline IS the command under
    # `set -euo pipefail` — a non-zero awk would abort the whole run here (see the same trap
    # documented at the `brew bundle list` call in provision).
    status="$(printf '%s\n' "$listing" | awk -v s="$svc" '$1 == s { print $2; exit }')" || status=""
    if [[ "$status" == "started" ]]; then
      noop "$svc service already started"
      hint=1
      continue
    fi
    if ((DRY)); then
      info "would run: $BREW services start $svc"
      continue
    fi
    if "$BREW" services start "$svc" >/dev/null 2>&1; then
      ok "$svc registered with launchd — starts at login, restarts on crash"
    else
      # A WARNING, not a fail_note: the AeroSpace fallback still launches it in this
      # session, so a service that would not register must not turn an otherwise-clean
      # install into a degraded run (exit 3).
      #
      # Name the STRAY when there is one, because "try by hand: brew services start" is
      # useless advice in that case — it is the command that just failed, and it will keep
      # failing. Every box that predates this change hits it: the old aerospace.toml
      # launched these bare, so a copy is already holding the singleton (sketchybar's
      # lock file, borders' running-instance check) and `launchctl bootstrap` dies with
      # EIO. The stray must go first, and killing a process the operator can see is their
      # call to make, not something bootstrap should do behind their back.
      local stray
      stray="$(pgrep -x "$svc" | tr '\n' ' ')" || stray=""
      if [[ -n "${stray// /}" ]]; then
        warn_note "could not start the $svc service — a running $svc (pid ${stray% }) is already holding it; stop that first, then retry: pkill -x $svc && brew services start $svc"
      else
        warn_note "could not start the $svc service — AeroSpace still launches it, but it won't come up on login; try by hand: brew services start $svc"
      fi
    fi
  done
  # Only worth saying when something was already up: a service reads its config exactly once,
  # at launch, so a freshly-relinked sketchybarrc/bordersrc is NOT live until it is bounced.
  ((hint)) && info "config is read only at launch — after a config change: brew services restart sketchybar borders"
  return 0 # the `((hint))` above is the last command; a zero hint must not fail the step
}

# ── uninstall: reverse the symlink wiring + restore backups (B4) ──────────────
# bootstrap backs a real file up to <dest>.pre-dotfiles.<ts> before linking, but there was
# no way BACK. This reverses it, idempotently and safely: it removes a dest ONLY when it's a
# symlink pointing INTO this repo (never a real file or a foreign link), then restores the
# most recent .pre-dotfiles.* backup if one exists. --dry-run previews every action. It does
# NOT uninstall Homebrew/packages or revert the login shell — just the symlinks this script
# created (the destructive, hard-to-remember half).
unlink_dest() { # unlink_dest <dest>
  local dest="$1"
  if [[ -L "$dest" ]]; then
    local tgt
    tgt="$(readlink "$dest")"
    if [[ "$tgt" == "$REPO"/* ]]; then
      if ((DRY)); then
        info "would remove symlink: ${dest/#"$HOME"/\~}"
      else
        # An unwritable parent dir (or an immutable flag) makes this fail. Under `set -e`
        # a bare `rm` would abort the script HERE — mid-uninstall, with no summary and no
        # --json object, leaving a half-reversed HOME and no record of which half. Record
        # it and carry on instead: the remaining ~40 dests are independent of this one.
        #
        # `|| { …; return 0; }` and not `|| fail_note …`: the caller is a bare
        # `unlink_dest "$d"` inside a for-loop, so a non-zero return would abort the run
        # anyway. Returning 0 is what "continue" means here.
        rm -f "$dest" || {
          fail_note "could not remove symlink ${dest/#"$HOME"/\~} — it is still wired to this repo; remove it by hand: rm '$dest'"
          # Bail on THIS dest, don't fall through to the restore below: the symlink is
          # still there, so the "is a real file present?" guard would wave us through and
          # we'd mv a backup on top of a link we just failed to remove.
          return 0
        }
        ok "removed ${dest/#"$HOME"/\~}"
      fi
      n_removed=$((n_removed + 1))
    else
      noop "skip (not ours): ${dest/#"$HOME"/\~}"
      return 0
    fi
  fi
  # Never restore a backup OVER an existing real file/dir. We only restore into a slot we
  # just emptied (our symlink was removed above) or one that's now absent — if a REAL file
  # sits at $dest, it's the user's own (they may have replaced our link with it), so leave
  # it untouched rather than clobber it with a stale backup. (In --dry-run our symlink isn't
  # actually removed, so $dest is still a symlink here and this guard correctly lets the
  # restore PREVIEW through.)
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    noop "skip restore (real file present, not ours): ${dest/#"$HOME"/\~}"
    return 0
  fi
  # Restore the most recent backup, if any — chosen by MTIME, not by sorting the name.
  #
  # This used to claim "the suffix is a zero-padded YYYYMMDD-HHMMSS stamp, so a lexical
  # sort IS chronological". That is false across the fleet: link() (this file) stamps
  # %Y%m%d-%H%M%S while Core's blib_link stamps a bare epoch (%s), and both write into
  # this same `.pre-dotfiles.*` namespace. "20…" always sorts after "17…", so a lexical
  # pick returns the datestamped file regardless of age. Comparing mtimes is correct for
  # either format and stays correct whatever Core does next (dotfiles-core#464).
  #
  # nullglob makes a no-match expand to nothing rather than the literal pattern.
  local newest="" b
  shopt -s nullglob
  for b in "$dest".pre-dotfiles.*; do
    [[ -z "$newest" || "$b" -nt "$newest" ]] && newest="$b"
  done
  shopt -u nullglob
  if [[ -n "$newest" && -e "$newest" ]]; then
    if ((DRY)); then
      info "would restore backup: ${newest/#"$HOME"/\~} → ${dest/#"$HOME"/\~}"
    else
      # Same reasoning as the rm above. Note what this failure does NOT cost you: mv
      # either moves the file or leaves it where it was, so the backup is intact at
      # $newest — say where, because that is the one thing the operator needs to know.
      mv "$newest" "$dest" || {
        fail_note "could not restore ${dest/#"$HOME"/\~} from backup — your original is still at ${newest/#"$HOME"/\~}; move it back by hand: mv '$newest' '$dest'"
        return 0
      }
      info "restored ${dest/#"$HOME"/\~} from backup"
    fi
    n_restored=$((n_restored + 1))
  fi
}
uninstall() {
  local CFG="$HOME/.config"
  say "Uninstall — removing Core symlinks + restoring backups (Homebrew/packages untouched)"
  ((DRY)) && say "DRY RUN — nothing will be changed; printing the plan only"
  # The same destinations wire_links creates — the per-module Core zsh links plus the
  # fixed set. Kept in one list here so an uninstall mirrors the install exactly.
  local -a dests=(
    "$HOME/.local/bin/clip" "$HOME/.local/bin/clip-paste"
    "$CFG/zsh/80-os.zsh" "$HOME/.zshenv" "$CFG/zsh/.zprofile" "$CFG/zsh/.zshrc"
    # The OS capability declaration (os/macos.capabilities). NOT a numbered fragment and
    # not a .zsh, so the `core/zsh/*.zsh` loop below cannot pick it up — it has to be
    # named here or an uninstall strands it as a dangling symlink. test/test-repo.sh's
    # "dests covers every link blib_link_core/os_layer creates" assertion is what caught
    # the omission, which is exactly the drift that check exists for.
    "$CFG/zsh/os.capabilities"
    "$CFG/starship.toml" "$CFG/lazygit/config.yml"
    "$CFG/tmux/tmux.conf" "$CFG/tmux/tmux.reset.conf" "$CFG/tmux/scripts" "$CFG/tmux/os.conf"
    "$CFG/nvim" "$HOME/.vimrc"
    "$HOME/.gitconfig" "$CFG/git/os.gitconfig" "$CFG/git/ignore"
    "$CFG/mise/config.toml" "$CFG/jj/config.toml" "$CFG/atuin/config.toml"
    "$CFG/tealdeer/config.toml"
    "$CFG/ghostty/config" "$CFG/fastfetch/config.jsonc" "$HOME/.ssh/config"
    "$HOME/.ssh/config.d/50-os.conf"
    "$CFG/aerospace/aerospace.toml" "$CFG/sketchybar" "$CFG/borders"
    "$CFG/karabiner/karabiner.json"
  )
  local f
  for f in "$REPO"/core/zsh/*.zsh; do dests+=("$CFG/zsh/$(basename "$f")"); done
  local d
  for d in "${dests[@]}"; do unlink_dest "$d"; done
  printf '%s==>%s %s\n' "$c_b" "$c_0" "uninstall summary"
  ok "$n_removed removed · $n_restored restored"
  print_ledger
  ((DRY)) && info "dry run — nothing was changed; re-run without --dry-run to apply"
  info "left in place: Homebrew + packages, your login shell, and ~/.config/{zsh/99-local.zsh,git/local.gitconfig}"
  # The launchd agents start_desktop_services registered are NOT torn down here, and that is
  # deliberate: `brew services` is USER-global and ignores $HOME, so an uninstall aimed at a
  # sandbox HOME (test/test-repo.sh does exactly that) would stop the real operator's menu bar.
  # Name the command instead and let them decide.
  info "still running: the sketchybar + borders launchd agents — stop them with: brew services stop sketchybar borders"
  # Same contract as the install path: a partial reversal must not read like a clean one.
  # The dests that DID come out are listed above; these are the ones still wired.
  if ((${#FAILURES[@]})); then
    err "uninstall finished with ${#FAILURES[@]} failed step(s) — see above; those paths are still linked (exit 3)"
  fi
}

# --uninstall short-circuits the whole install path (it's the reverse operation). The
# emit_json here is not decoration: n_removed / n_restored are the two keys that ONLY an
# uninstall ever fills, and this `exit 0` used to jump clean over the emitter at the foot
# of the file, so `--uninstall --json` printed no object at all.
if ((UNINSTALL)); then
  uninstall
  emit_json
  # Exit 3 on a partial reversal, matching the install path's meaning of the code: the
  # run happened, but the machine is in a state you did not ask for. `exit 0` here was
  # unconditional, so a dest that would not unlink reported success.
  if ((${#FAILURES[@]})); then exit 3; fi
  exit 0
fi

# ── provision (unless --links-only); dry-run announces but installs nothing ──
if ((LINKS_ONLY)); then
  : # symlinks only
elif ((DRY)); then
  say "would provision: Homebrew + brew bundle (skipped in dry-run)"
else
  provision
fi

wire_links

# tpm being present is not the same as the plugins being installed — that still needed a
# manual `prefix + I`, which nothing told you about (#135). Do it headlessly instead; see
# install_tmux_plugins for why it needs a tmux server of its very own. Read-only when the
# plugins are already there, so a re-run just reports ✓.
if ((DRY == 0)) && blib_want tmux; then
  install_tmux_plugins
fi

# The local commit-time gate (#135). AFTER wire_links, and the order is load-bearing —
# see install_pre_commit_hook: wire_links must plant the core/ guard FIRST so pre-commit
# inherits it as pre-commit.legacy instead of locking it out.
((DRY == 0)) && install_pre_commit_hook

# Desktop services (sketchybar, borders) — see start_desktop_services above. Held out of
# --links-only, which usage() and the README both promise is "just (re)create symlinks, no
# installs"; skipped when the desktop group is deselected, since those are its binaries. Needs
# Homebrew on PATH to ask about or register anything — a --no-brew box never got the formulae.
# Runs AFTER wire_links on purpose: borders reads ~/.config/borders/bordersrc at launch, so the
# symlink has to exist before the service starts or the ring comes up with stock defaults.
if ((LINKS_ONLY == 0)) && blib_want desktop && command -v "$BREW" >/dev/null 2>&1; then
  start_desktop_services
fi

# mise tools — install behind a spinner: it can churn for a while pulling runtimes,
# and its raw output is noise unless it fails (spin shows the captured log only then).
#
# NOT under --links-only, which usage() and the README both promise is "just (re)create
# symlinks, no installs" — this block sat outside the provision branch and installed
# anyway. --no-brew still runs it, per its documented "symlinks + mise" contract.
if ((LINKS_ONLY == 0)) && command -v mise >/dev/null 2>&1; then
  say "mise install"
  # spin already prints `err "<label> — failed (exit N)"` plus the captured log, so this
  # records the step and says what was lost — it does not re-report the failure itself.
  spin "installing mise-managed tools" mise install ||
    fail_note "mise install failed — node/python/ruby/go/rust/java/lua may be missing or stale; re-run: mise install"
fi

# login shell (opt-in: changes your default shell)
((SET_SHELL)) && set_login_shell

# macOS system defaults (opt-in: changes system prefs, may need logout)
if ((RUN_DEFAULTS)) && [[ -f "$REPO/macos/defaults.sh" ]]; then
  say "macos/defaults.sh"
  if ((DRY)); then
    info "would run: bash macos/defaults.sh (pass --dry-run to preview its keys)"
  elif confirm "Apply macOS system defaults now (changes system prefs)?"; then
    bash "$REPO/macos/defaults.sh" ||
      fail_note "macos/defaults.sh failed — system preferences were not (fully) applied; re-run: bash macos/defaults.sh"
  else
    info "macOS defaults skipped (declined)"
  fi
elif [[ -f "$REPO/macos/defaults.sh" ]]; then
  info "system defaults available — apply with: ./bootstrap.sh --macos-defaults  (or: bash macos/defaults.sh)"
fi

# ── run summary ───────────────────────────────────────────────────────────────
# Last, so its "not yet on PATH" verdict accounts for everything wire_links and
# `mise install` just did. It also populates TOOLS_JSON for the --json object below.
verify_tools

# ── closing checklist (#135) ──────────────────────────────────────────────────
# The read-only PROBES run here, at the very end, for the same reason verify_tools does:
# they describe the FINISHED machine, and one taken earlier would cry wolf about a
# permission the operator granted thirty seconds ago. The two steps bootstrap performs
# itself — tmux plugins, the pre-commit hook — recorded their own outcome as they happened.
#
# Skipped wholesale in --dry-run: nothing ran, so every probe would report every step as
# outstanding, and a plan that lies is worse than no plan. It also keeps this block
# provably side-effect-free in the one mode that promises to touch nothing at all.
if ((DRY == 0)); then
  check_desktop_permissions
  check_git_identity
fi

print_summary "summary"
# Between the tally and the verdict: the checklist is part of the run REPORT, while the
# closing line is the #133 verdict and has to stay the last word (its "see above" points
# at the failure list print_summary just printed).
print_next_steps
if ((DRY)); then
  info "dry run — nothing above was actually changed; re-run without --dry-run to apply"
  info "next steps (GUI permissions, git identity) are probed and reported after a real run"
elif ((${#FAILURES[@]})); then
  # NOT ok "…complete" — the whole point of #133 is that a degraded run must not look
  # like a clean one. The failing steps are listed by print_summary just above.
  err "macOS bootstrap finished with ${#FAILURES[@]} failed step(s) — see above (exit 3)"
else
  ok "macOS bootstrap complete — open a new shell or: exec zsh"
fi

# The machine-readable summary on the REAL stdout — see emit_json above. No-op without
# --json. This is the normal end-of-run path; --uninstall emits from its own exit.
emit_json

# Exit 3 when any step failed — the run happened, but the box is DEGRADED. Distinct from
# 1 (bootstrap could not run at all: not macOS, no core/, no CLT) and 2 (usage error), so
# automation can tell "never started" from "ran but the runtimes never installed".
#
# AFTER the --json block on purpose: a degraded run is exactly when a provisioning script
# most needs to read WHY, so the object must still be emitted.
#
# Deliberately CONDITIONAL, with no `exit 0` after it: a clean run still falls off the end
# (a taken-no-branch `if` yields status 0). With an unconditional trailing `exit`, the
# reachability pass in shellcheck declares on_interrupt — reached only via the INT/TERM
# trap, which it cannot see — uninvoked, tripping SC2329 on code that was already there.
if ((${#FAILURES[@]})); then exit 3; fi

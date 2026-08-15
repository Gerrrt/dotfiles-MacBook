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
  printf '  a clone always contains core/; if building fresh, run:\n' >&2
  printf '    git subtree add --prefix=core <dotfiles-core-url> main --squash\n' >&2
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
# is printed to >&3 at the very end. No effect outside --json.
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
#   +5 ghostty, fastfetch, aerospace, sketchybar, karabiner — blib_want desktop
# (Selection is already applied above via blib_select.)
WIRE_TOTAL=1
blib_want zsh && WIRE_TOTAL=$((WIRE_TOTAL + 1))
blib_want git && WIRE_TOTAL=$((WIRE_TOTAL + 1))
blib_want desktop && WIRE_TOTAL=$((WIRE_TOTAL + 5))
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

# print_summary — the run tally, factored out so the INT/TERM trap can show what was
# already done if you Ctrl-C mid-run (a long brew bundle, say). Without this, an
# interrupt left you with no record of the partial state and no reminder that re-running
# is safe. `$1` is an optional headline (e.g. "interrupted").
print_summary() {
  # Always prints (bypasses the --quiet say() gate via a direct printf) — the tally is
  # the whole point of a quiet run, so it must never be suppressed.
  printf '%s==>%s %s\n' "$c_b" "$c_0" "${1:-summary}"
  ok "$n_linked linked · $n_backed backed up · $n_seeded seeded · $n_skipped skipped"
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
# Returns non-zero (after saying so) when a brew binary exists but shellenv fails, so a
# caller that genuinely needs brew can escalate. Not fatal on its own — the symlink-only
# modes work fine without Homebrew, so a broken brew must not stop them. A box with no
# Homebrew at all is NOT an error: that's a fresh machine, and provision() installs it.
brew_shellenv() {
  local brew out
  for brew in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$brew" ]] || continue
    if ! out="$("$brew" shellenv)"; then
      err "$brew shellenv failed — Homebrew tools will not be on PATH"
      return 1
    fi
    if [[ -z "$out" ]]; then
      err "$brew shellenv produced no output — Homebrew tools will not be on PATH"
      return 1
    fi
    eval "$out"
    return 0
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
  err "core/ subtree missing — this should be present in a clone; if building fresh, run:"
  info "git subtree add --prefix=core <dotfiles-core-url> main --squash"
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

# seed <src> <dest> <note> — copy (don't symlink) a starter file when the dest is
# absent. Used for files the user is meant to EDIT locally (git identity, sesh).
seed() {
  local src="$1" dest="$2" note="$3"
  [[ -f "$src" && ! -e "$dest" ]] || {
    noop "${dest/#"$HOME"/\~} present (or example missing) — left as-is"
    return 0
  }
  if ((DRY)); then
    info "would seed: ${dest/#"$HOME"/\~}  ($note)"
    n_seeded=$((n_seeded + 1))
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  info "seeded ${dest/#"$HOME"/\~} — $note"
  n_seeded=$((n_seeded + 1))
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
  if ((!NO_BREW)) && ! command -v brew >/dev/null 2>&1; then
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
  # has already SAID what went wrong, and the guard just below turns that into a clean exit
  # with a remedy rather than letting `brew bundle` die at 127 with no explanation.
  brew_shellenv || true
  if ((!NO_BREW)) && [[ -f "$REPO/Brewfile" ]]; then
    # Escalate here, where Homebrew is genuinely required. Without this, a brew that exists
    # but whose shellenv failed reaches `brew bundle` as a bare `brew: command not found`
    # (exit 127) — the same misleading death this commit series removes from the installer
    # path, just one step later.
    if ! command -v brew >/dev/null 2>&1; then
      err "Homebrew is not on PATH — cannot run brew bundle"
      info "see the shellenv error above; or put it on PATH by hand and re-run:"
      # shellcheck disable=SC2016  # a command for the USER to paste — must NOT expand here
      info '  eval "$(/opt/homebrew/bin/brew shellenv)"   # Intel: /usr/local/bin/brew'
      exit 1
    fi
    # B13: skip the expensive resolve+install when the Brewfile is already satisfied.
    # `brew bundle check` is a fast read-only "is everything here installed?" probe, so a
    # re-run on a provisioned box no longer pays for a full `brew bundle` pass.
    if brew bundle check --file="$REPO/Brewfile" >/dev/null 2>&1; then
      ok "brew bundle already satisfied — skipping (every formula/cask is installed)"
    else
      # Up-front scope so the longest, mostly-opaque step reads as BOUNDED work, not an
      # open-ended hang: count the Brewfile entries (best-effort; falls back to "?" if the
      # list query fails) and name the number before handing off to brew's own streaming
      # output. `brew bundle list --all` enumerates every tap/brew/cask/mas line.
      local n_pkgs
      n_pkgs="$(brew bundle list --file="$REPO/Brewfile" --all 2>/dev/null | wc -l | tr -d ' ')"
      say "brew bundle (${n_pkgs:-?} formulae/casks — this can take a while)"
      brew bundle --file="$REPO/Brewfile"
    fi
  else
    info "skipping brew bundle (--no-brew or no Brewfile yet)"
  fi
}

# verify_tools — after a provision, confirm the headline tools actually landed on
# PATH so a half-finished bundle is reported, not silently assumed-good. Read-only.
verify_tools() {
  local missing=() t
  for t in zsh starship mise fzf nvim tmux git; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if ((${#missing[@]})); then
    info "not yet on PATH: ${missing[*]} — open a new shell, or re-run after brew bundle finishes"
  else
    ok "core tools present (zsh starship mise fzf nvim tmux git)"
  fi
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
    info "chsh failed — set it manually: chsh -s $brew_zsh"
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
  # blib_* are not --quiet-aware and conflate section headers with actionable messages
  # (tpm clone failure, seeded-file notes, ssh wiring) on the same stream — so we do NOT
  # redirect them away under --quiet: a /dev/null there would hide failures/changes too,
  # not just headers. We accept the scaffold's couple of header lines leaking into a quiet
  # run as the lesser evil. (In --json mode fd1 already points at stderr, so this output
  # never reaches the JSON object on fd3 regardless.)
  blib_link_core "$REPO" "$CFG"
  blib_link_os_layer "$REPO" "$CFG" macos
  # fold the scaffold's tallies into this run's summary so --json / print_summary stay accurate
  n_linked=$((n_linked + BLIB_LINKED))
  n_backed=$((n_backed + BLIB_BACKED))
  n_seeded=$((n_seeded + BLIB_SEEDED))
  n_skipped=$((n_skipped + BLIB_SKIPPED))

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
  # Not DRY-aware in the lib (it writes the hook unconditionally), so gate it here. `||
  # true` because it returns non-zero on the benign "you already have a custom pre-commit
  # hook" path, which must not abort a bootstrap under `set -e`.
  if ((DRY)); then
    info "would install the core/ pre-commit guard (rejects hand-edits to the vendored subtree)"
  else
    blib_install_core_guard "$REPO" || true
  fi
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
        rm -f "$dest"
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
      mv "$newest" "$dest"
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
    "$CFG/starship.toml" "$CFG/lazygit/config.yml"
    "$CFG/tmux/tmux.conf" "$CFG/tmux/tmux.reset.conf" "$CFG/tmux/scripts" "$CFG/tmux/os.conf"
    "$CFG/nvim" "$HOME/.vimrc"
    "$HOME/.gitconfig" "$CFG/git/os.gitconfig" "$CFG/git/ignore"
    "$CFG/mise/config.toml" "$CFG/jj/config.toml" "$CFG/atuin/config.toml"
    "$CFG/ghostty/config" "$CFG/fastfetch/config.jsonc" "$HOME/.ssh/config"
    "$CFG/aerospace/aerospace.toml" "$CFG/sketchybar" "$CFG/karabiner/karabiner.json"
  )
  local f
  for f in "$REPO"/core/zsh/*.zsh; do dests+=("$CFG/zsh/$(basename "$f")"); done
  local d
  for d in "${dests[@]}"; do unlink_dest "$d"; done
  printf '%s==>%s %s\n' "$c_b" "$c_0" "uninstall summary"
  ok "$n_removed removed · $n_restored restored"
  ((DRY)) && info "dry run — nothing was changed; re-run without --dry-run to apply"
  info "left in place: Homebrew + packages, your login shell, and ~/.config/{zsh/99-local.zsh,git/local.gitconfig}"
}

# --uninstall short-circuits the whole install path (it's the reverse operation).
if ((UNINSTALL)); then
  uninstall
  exit 0
fi

# ── provision (unless --links-only); dry-run announces but installs nothing ──
if ((LINKS_ONLY)); then
  : # symlinks only
elif ((DRY)); then
  say "would provision: Homebrew + brew bundle (skipped in dry-run)"
else
  provision
  verify_tools
fi

wire_links

# mise tools — install behind a spinner: it can churn for a while pulling runtimes,
# and its raw output is noise unless it fails (spin shows the captured log only then).
if command -v mise >/dev/null 2>&1; then
  say "mise install"
  spin "installing mise-managed tools" mise install ||
    info "mise install hit an issue — run it manually later"
fi

# login shell (opt-in: changes your default shell)
((SET_SHELL)) && set_login_shell

# macOS system defaults (opt-in: changes system prefs, may need logout)
if ((RUN_DEFAULTS)) && [[ -f "$REPO/macos/defaults.sh" ]]; then
  say "macos/defaults.sh"
  if ((DRY)); then
    info "would run: bash macos/defaults.sh (pass --dry-run to preview its keys)"
  elif confirm "Apply macOS system defaults now (changes system prefs)?"; then
    bash "$REPO/macos/defaults.sh" || info "defaults.sh hit an issue"
  else
    info "macOS defaults skipped (declined)"
  fi
elif [[ -f "$REPO/macos/defaults.sh" ]]; then
  info "system defaults available — apply with: ./bootstrap.sh --macos-defaults  (or: bash macos/defaults.sh)"
fi

# ── run summary ───────────────────────────────────────────────────────────────
print_summary "summary"
if ((DRY)); then
  info "dry run — nothing above was actually changed; re-run without --dry-run to apply"
else
  ok "macOS bootstrap complete — open a new shell or: exec zsh"
fi

# B7: machine-readable summary on the REAL stdout (fd 3, saved before the body redirect).
# Provisioning automation can parse what changed + which headline tools landed on PATH,
# instead of scraping human output. Hand-built JSON (no jq dependency on a fresh box).
if ((JSON)); then
  _dry=false
  ((DRY)) && _dry=true
  _tools_json=""
  for _t in zsh starship mise fzf nvim tmux git; do
    if command -v "$_t" >/dev/null 2>&1; then _present=true; else _present=false; fi
    _tools_json+="${_tools_json:+,}\"$_t\":$_present"
  done
  printf '{"dry_run":%s,"linked":%d,"backed_up":%d,"seeded":%d,"skipped":%d,"removed":%d,"restored":%d,"tools":{%s}}\n' \
    "$_dry" "$n_linked" "$n_backed" "$n_seeded" "$n_skipped" "$n_removed" "$n_restored" \
    "$_tools_json" >&3
fi

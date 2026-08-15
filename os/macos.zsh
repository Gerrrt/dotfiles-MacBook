# dotfiles-MacBook/os/macos.zsh  →  ~/.config/zsh/80-os.zsh  (v4: numbered OS-layer fragment)
# ──────────────────────────────────────────────────────────────────────────────
# macOS-only INTERACTIVE shell extras. Sourced near the end of .zshrc (after the
# Core modules), so it can override Core. PATH/env that must exist in every shell
# lives in .zprofile/.zshenv, not here. Nothing offensive here — that's Kali.
# ──────────────────────────────────────────────────────────────────────────────

# Native clipboard already works: Core's `clip`/`clip-paste` detect Darwin and
# shell out to pbcopy/pbpaste, so no aliases are needed here.

# ── tool completions (Homebrew-installed CLIs that ship zsh completions) ─────
# direnv/gh/uv/ty all emit DETERMINISTIC scripts: `direnv hook zsh` installs a precmd
# whose per-directory behavior runs at RUNTIME, but the generated hook TEXT is static
# for a given binary — exactly like mise/zoxide in 00-tools.zsh, which Core already caches.
# So route all four through Core's _cache_eval (from 00-tools.zsh) — one cheap `source`
# instead of spawning each generator every shell. _cache_eval self-guards on the binary
# being present and regenerates only when the binary is newer than the cache.
if (( $+functions[_cache_eval] )); then
  _cache_eval direnv direnv hook zsh
  _cache_eval gh gh completion -s zsh
  _cache_eval uv uv generate-shell-completion zsh
  _cache_eval ty ty generate-shell-completion zsh
else  # bare fallback if 80-os.zsh is sourced without Core's 00-tools.zsh
  command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh 2>/dev/null)"
  command -v gh >/dev/null 2>&1 && eval "$(gh completion -s zsh 2>/dev/null)"
  command -v uv >/dev/null 2>&1 && eval "$(uv generate-shell-completion zsh 2>/dev/null)"
  command -v ty >/dev/null 2>&1 && eval "$(ty generate-shell-completion zsh 2>/dev/null)"
fi

# ── where this repo lives (DERIVED, never hardcoded) ─────────────────────────
# %x = the path of THIS sourced file, :A follows the bootstrap symlink back to
# <repo>/os/macos.zsh, :h:h climbs to the repo root. The same technique Core's
# 10-options.zsh uses, and the one this file already relied on for its completions dir.
#
# It is derived rather than written down because the clone location is the operator's
# choice: the README says ~/dotfiles-MacBook, but a real checkout of this very repo lives
# at ~/code/dotgibson/dotfiles-MacBook, where every hardcoded "$HOME/dotfiles-MacBook"
# silently pointed at a directory that does not exist. `.zprofile` sets this too (login
# shells need it before .zshrc runs); `:=` means whichever runs first wins and the other
# is a no-op, and a non-login interactive shell still gets it here.
: "${DOTFILES_MACBOOK_ROOT:=${${(%):-%x}:A:h:h}}"
export DOTFILES_MACBOOK_ROOT

# ── repo-owned completions (bootstrap.sh) ─────────────────────────────────────
# Core adds its completions dir to fpath BEFORE compinit (10-options.zsh), so compinit
# auto-registers them. This macOS layer loads AFTER compinit, so add the repo's
# completions dir to fpath and then explicitly autoload + compdef — compinit won't
# re-scan fpath on its own.
_macos_compdir="$DOTFILES_MACBOOK_ROOT/completions"
if [[ -d "$_macos_compdir" ]] && (($+functions[compdef])); then
  fpath=("$_macos_compdir" $fpath)
  autoload -Uz _bootstrap 2>/dev/null && compdef _bootstrap bootstrap.sh ./bootstrap.sh
fi
unset _macos_compdir

# ── macOS conveniences ────────────────────────────────────────────────────────
alias localip='ipconfig getifaddr en0'                 # LAN IP on the primary interface
alias flushdns='sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder'
alias showfiles='defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder'
alias hidefiles='defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder'
alias o='open'                                          # `o .` to open in Finder

# trash(1): send files to macOS Trash instead of permanently deleting them.
# Overrides the Core `rm='rm -i'` safety net with something even safer.
# `rm -f` / `command rm` still bypass this when you need the real thing.
command -v trash >/dev/null 2>&1 && alias rm='trash'

# navi: interactive, fzf-driven cheatsheets. Complements tealdeer (`help`, static
# man-style) with runnable, arg-templated snippets. Bound to its OWN verb `cheats`
# (plural) so it does NOT shadow Core's `cheat` alias → `core-help`: the first-run
# welcome banner and `core-doctor` both point users at `core-help`, so keeping
# `cheat` resolving there avoids a confusing collision. `cheats` launches navi.
# (No Ctrl-G widget — that key is owned by sesh in Core's 40-bindings.zsh.)
command -v navi >/dev/null 2>&1 && alias cheats='navi'

# croc / onefetch are invoked directly (no alias): `croc send <file>` to ship a
# file e2e-encrypted to another box; `onefetch` in a repo for an at-a-glance summary.

# fastfetch: system/host banner (config: fastfetch/config.jsonc, themed to match
# the rice). Short `ff` verb — the host-info twin of `onefetch`'s repo summary.
command -v fastfetch >/dev/null 2>&1 && alias ff='fastfetch'

# mas: Mac App Store CLI convenience helpers
command -v mas >/dev/null 2>&1 && {
  alias masup='mas upgrade'                            # upgrade all App Store apps
  alias masls='mas list'                               # list installed App Store apps
}

# ── dotfiles maintenance: jump to this repo ──────────────────────────────────
# Single-quoted so $DOTFILES_MACBOOK_ROOT is resolved at RUN time, not alias-definition
# time — the var is exported above from this file's own resolved path.
alias dotsync='cd "$DOTFILES_MACBOOK_ROOT"'

# ── 1Password CLI sign-in convenience (50-op.zsh in Core has the helpers) ───────
command -v op >/dev/null 2>&1 && alias opsignin='eval "$(op signin)"'

# ── auto-start tmux: moved to the TAIL of zsh/zshrc ──────────────────────────
# It must run AFTER 99-local.zsh (the last module) so DOTFILES_NO_AUTOTMUX /
# DOTFILES_TMUX_SESSION set there are honored. The `os` module loads BEFORE
# `local`, so reading those knobs here silently ignored a user's 99-local.zsh. See
# the auto-tmux block at the end of zsh/zshrc.

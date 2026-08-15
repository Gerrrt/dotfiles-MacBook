# bash completion for dotfiles-MacBook's bootstrap.sh.
# ──────────────────────────────────────────────────────────────────────────────
# The repo ships ZSH completions for Core's verbs (core/zsh/completions/_*) and for
# bootstrap.sh (completions/_bootstrap), but nothing for BASH — yet bootstrap.sh is run
# from bash (the macOS default login shell before the Homebrew-zsh switch, and many CI /
# rescue contexts). Core's interactive verbs are zsh FUNCTIONS with no bash equivalent, so
# the one thing worth completing in bash is the installer itself. Source this from
# ~/.bashrc (or ~/.bash_profile):
#
#     source /path/to/dotfiles-MacBook/completions/bootstrap.bash
#
# (Use your actual clone path — the repo does not assume one. The zsh side derives it;
# bash has no equivalent of zsh's %x, so this line is yours to fill in.)
#
# Flags mirror bootstrap.sh's parser (KNOWN_FLAGS) — keep them in step.
_bootstrap_sh_complete() {
  local cur="${COMP_WORDS[COMP_CWORD]}"
  local flags='--links-only --no-brew --macos-defaults --set-shell --only --skip --uninstall --dry-run -n --quiet -q --json -h --help'
  # shellcheck disable=SC2207  # word-split is intentional for compgen output
  COMPREPLY=($(compgen -W "$flags" -- "$cur"))
}
complete -F _bootstrap_sh_complete bootstrap.sh ./bootstrap.sh

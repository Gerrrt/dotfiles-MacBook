# Security Policy

`dotfiles-MacBook` ships **configuration and an installer** — no running service, no
credentials, no machine state. Secrets are deliberately kept out of the tree: git identity
lives in an untracked `~/.config/git/local.gitconfig`, machine-local shell tweaks in an
untracked `~/.config/zsh/99-local.zsh`, and real secrets in 1Password (`core/zsh/50-op.zsh`
provides `opsecret`/`openv`/`optoken`). `.gitignore` tracks `ssh/config` but never key
material, and `gitleaks` runs over the repo-owned tree in CI and at commit time.

Even so, two classes of issue are worth a **security** report rather than a normal issue:

- a tracked file that leaks a secret, token, key, or other sensitive value, and
- a path where `bootstrap.sh`, `macos/defaults.sh`, or a `sketchybar/plugins/*.sh` script
  can be coerced into executing untrusted input, or into writing outside the paths it
  documents.

`bootstrap.sh` warrants particular attention: it symlinks into `$HOME`, moves existing
files aside, can invoke `sudo` (for `/etc/shells` under `--set-shell`), and downloads and
executes the official Homebrew installer. Anything that subverts one of those is in scope.

## Reporting a vulnerability

**Please do not open a public issue for a security report.** Use GitHub's private
vulnerability reporting: the **Security** tab → **Report a vulnerability**. That keeps
details private until a fix has landed.

Include, where you can:

- the file and line, and whether it is repo-owned or vendored under `core/`,
- how it is reached at runtime (a bootstrap flag, a sourced zsh fragment, a sketchybar
  plugin, a `defaults write`), and
- a minimal reproduction.

Expect an acknowledgement within a few days.

## Scope

**In scope** — anything in this repo outside `core/`: `bootstrap.sh`, `Brewfile`, `os/`,
`zsh/`, `macos/defaults.sh`, `aerospace/`, `sketchybar/`, `karabiner/`, `ghostty/`,
`fastfetch/`, `ssh/config`, `completions/`, `test/`, and the workflows in `.github/`.

**Out of scope — report upstream.** `core/` is a vendored `git subtree` copy of
[dotfiles-core](https://github.com/dotgibson/dotfiles-core) and is overwritten on the next
sync; a fix applied here would be silently reverted. Report it against `dotfiles-core`
instead, where it can be fixed once and fanned out to every OS repo.

Also out of scope: vulnerabilities in the third-party tools this repo *installs*
(Homebrew, Neovim, tmux, aerospace, sketchybar, karabiner-elements, …) — report those to
their own maintainers. The `Brewfile` only names them.

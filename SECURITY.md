# Security Policy

`dotfiles-MacBook` ships **configuration and an installer**. It is not a running service,
and the *tracked tree* holds no credentials and no machine state: git identity lives in an
untracked `~/.config/git/local.gitconfig`, machine-local shell tweaks in an untracked
`~/.config/zsh/99-local.zsh`, and real secrets in 1Password (`core/zsh/50-op.zsh` provides
`opsecret`/`openv`/`optoken`). Under `ssh/`, `.gitignore` excludes everything (`ssh/*`)
and re-includes only the client config (`!ssh/config`), so a private key dropped in that
directory is untracked by default.

Treat that as a guard against **accident, not an absolute barrier**: ignore rules apply
only to files git is not already tracking, and `git add -f` overrides them outright. The
backstops for the deliberate or already-tracked case are `gitleaks`, which scans the
repo-owned tree on every PR in CI and locally at commit time **once you have run
`pre-commit install`** (the local hook is opt-in, CI is not), and GitHub's push protection,
which is enabled on this repo.

The **installer is a different matter**, and it is the main reason this file exists.
`bootstrap.sh` writes symlinks throughout `$HOME`, moves existing files aside, downloads
and executes the official Homebrew installer, and — behind explicit opt-in flags — invokes
`sudo` to append to `/etc/shells` (`--set-shell`) and runs `macos/defaults.sh` to change
system preferences (`--macos-defaults`). Those are genuine system changes; a defect that
subverts one of them is in scope below.

Two classes of issue are therefore worth a **security** report rather than a normal issue:

- a tracked file that leaks a secret, token, key, or other sensitive value, and
- a path where `bootstrap.sh`, `macos/defaults.sh`, or a `sketchybar/plugins/*.sh` script
  can be coerced into executing untrusted input, or into writing outside the paths it
  documents.

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

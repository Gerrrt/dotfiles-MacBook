# CLAUDE.md — dotfiles-MacBook

Project memory for Claude Code, auto-loaded every session. For the shared Core
rules (the load order, the "is it Core?" test, the manifest contract) see
`core/README.md` and `core/CONTRIBUTING.md`.

## What this repo is

`dotfiles-MacBook` is the **OS-native layer for macOS** in a **eleven-repo dotfiles system** built on a three-layer
model (Core → OS-native → Role). Its own lineage — built directly on **Homebrew**, not stamped from the Fedora template — and it also owns the macOS desktop tooling (aerospace, sketchybar, karabiner, ghostty). Packages live in the **`Brewfile`** (`brew bundle`), not `install/packages.txt`; Core targets macOS's stock **bash 3.2** in places.

## The rule that bites

`core/` is a **vendored `git subtree` copy of [dotfiles-core](https://github.com/dotgibson/dotfiles-core)** — it
is *not* editable here. Anything you change under `core/` is overwritten on the
next sync, and a local pre-commit guard plus the `core-integrity` CI job both
reject a hand-edit before it can land.

To change shared Core config, edit it **in dotfiles-core**. From there it reaches
this repo on its own: a Core *release* fans out a `sync/core-vX.Y.Z` PR to every
OS repo, which you merge. Nothing here needs running by hand — `make sync-core`
is a reminder, not an action. After merging a sync PR:

```bash
./bootstrap.sh --links-only   # re-wire any new/changed Core files
make test-repo                # prove the new Core still loads (exercises the loader)
```

A **manual** `git subtree pull` is the exception, not the norm; take the released
tag (never `main`) and regenerate the lock with `make core-lock`, or
`core-integrity` reports the fresh subtree as tampered.

What belongs **here** is only the OS-native layer: the `Brewfile`, OS overlays, desktop tooling, and the bootstrap.

## Where things are

- `Brewfile` — Homebrew package list
- `zsh/zshenv`, `zsh/zprofile`, `zsh/zshrc` — the loader entry points (symlinked to `~/.zshenv`/`~/.config/zsh/`)
- `os/macos.zsh`, `os/macos.conf`, `os/macos.gitconfig` — OS overlays
- `macos/defaults.sh` — `defaults write` system-preferences script (`bootstrap.sh --macos-defaults`)
- `aerospace/`, `sketchybar/`, `karabiner/`, `ghostty/` — macOS desktop tooling
- `fastfetch/config.jsonc` — system/host info banner, Tokyo Night Storm (matches `sketchybar/colors.sh`); `ff` alias
- `completions/` — shell completion files
- `ssh/config` — ssh client config (only this file is tracked; keys never are)
- `bootstrap.sh`, `Makefile` — install + dev entry points
- `test/` — `test-repo.sh` (behavioral), `verify-core.sh` + `check-configs.sh` (gates)
- `core/` — vendored Core (read-only here; edit upstream in dotfiles-core)
- `core.lock` — vendored-Core provenance: `core_version`, `core_sha`, `core_branch`
  (may hold a SHA — the fan-out records what was vendored, not a moving branch),
  and `core_tag`. Written by the fan-out; `make core-lock` reproduces it exactly.

## Docs

- `README.md` — install, layer overview, the gate list
- `TERMINAL_WORKFLOW_GUIDE.md` — the real reference (~870 lines) for the daily workflow
- `aliases.md` — the alias/verb table
- `MIGRATION.md` — **archived**: a one-time `~/.config`-as-repo migration, long done

# CLAUDE.md — dotfiles-MacBook

Project memory for Claude Code, auto-loaded every session. For the shared Core
rules (the load order, the "is it Core?" test, the manifest contract) see
dotfiles-core's [`README.md`](https://github.com/dotgibson/dotfiles-core/blob/main/README.md) and
[`CONTRIBUTING.md`](https://github.com/dotgibson/dotfiles-core/blob/main/CONTRIBUTING.md) — upstream, not in `core/`, which
vendors only what a machine actually runs.

## What this repo is

`dotfiles-MacBook` is the **OS-native layer for macOS** in an **eleven-repo dotfiles system** built on a three-layer
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

A **manual** `git subtree pull` is not supported: it moves `core/` but not `core.lock`,
and `core-integrity` then reports the fresh subtree as tampered. There is no local fix —
`core.lock` is written by `sync-core.sh` in `dotfiles-core`, in the same commit as the
pull. Re-run the fan-out (`make sync` in a Core checkout) instead
(dotgibson/dotfiles-core#593).

What belongs **here** is only the OS-native layer: the `Brewfile`, OS overlays, desktop tooling, and the bootstrap.

## Where things are

- `Brewfile` — Homebrew package list
- `zsh/zshenv`, `zsh/zprofile`, `zsh/zshrc` — the loader entry points (symlinked to `~/.zshenv`/`~/.config/zsh/`)
- `os/macos.zsh`, `os/macos.conf`, `os/macos.gitconfig` — OS overlays
- `macos/defaults.sh` — `defaults write` system-preferences script (`bootstrap.sh --macos-defaults`)
- `aerospace/`, `sketchybar/`, `borders/`, `karabiner/`, `ghostty/` — macOS desktop tooling
- `fastfetch/config.jsonc` — system/host info banner, Tokyo Night Storm (matches `sketchybar/colors.sh`); `ff` alias
- `completions/` — shell completion files
- `ssh/os.conf` — this host's ssh overlay, linked to `~/.ssh/config.d/50-os.conf`. The
  portable client config is Core's (`core/ssh/config`); only this overlay is tracked here,
  and keys never are (dotgibson/dotfiles-core#450)
- `bootstrap.sh`, `Makefile` — install + dev entry points
- `test/` — `test-repo.sh` (behavioral), `verify-core.sh` + `check-configs.sh` (gates)
- `core/` — vendored Core (read-only here; edit upstream in dotfiles-core)
- `core.lock` — vendored-Core provenance: `core_version`, `core_sha`, `core_branch`
  (may hold a SHA — the fan-out records what was vendored, not a moving branch) and
  `core_tag`. Written by the fan-out, and **only** by the fan-out — `make core-lock`
  explains this rather than reproducing it (dotgibson/dotfiles-core#593).
  `core_branch` becomes `core_ref` on the next Core sync: the name was wrong precisely
  because the value is often a commit (dotgibson/dotfiles-core#453).

## Docs

- `README.md` — install, layer overview, the gate list
- `TERMINAL_WORKFLOW_GUIDE.md` — the real reference (~870 lines) for the daily workflow
- `aliases.md` — the alias/verb table

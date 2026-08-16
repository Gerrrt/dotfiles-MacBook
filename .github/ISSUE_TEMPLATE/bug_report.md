---
name: Bug report
about: Something in the macOS layer is broken — installer, shell, or desktop tooling
title: "bug: "
labels: bug
---

<!--
Boundary check first: core/ is a VENDORED copy of dotfiles-core. If the broken file is
under core/, please file it against dotfiles-core instead — a fix here is overwritten on
the next sync. See CONTRIBUTING.md.
-->

## What's wrong

A clear description.

## Which file(s)

e.g. `bootstrap.sh`, `os/macos.zsh`, `sketchybar/plugins/battery.sh`, `macos/defaults.sh`

## How to reproduce

```console
$ ./bootstrap.sh --links-only --dry-run
...
```

## Expected vs actual

## Environment

- macOS version:
- Chip (Apple Silicon / Intel):
- Homebrew prefix (`/opt/homebrew` or `/usr/local`):
- `zsh --version`:
- Clone path (the repo does not assume `~/dotfiles-MacBook`):

## Gate output

<!-- Where relevant. Note `make test` and `make core-audit` each take ~6 minutes on
     macOS and go near-silent partway through — that is normal, not a hang. -->

```console
$ make lint
```

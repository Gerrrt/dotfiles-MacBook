---
name: Package request
about: Add, remove, or change something in the Brewfile
title: "pkg: "
labels: enhancement
---

## Package

`brew "…"` or `cask "…"`

## What it does, and why it earns a slot

<!-- The Brewfile is a curated set, not a dumping ground. What does this replace or
     enable that nothing already installed does? -->

## Boundary check

- [ ] It is genuinely part of the **macOS** layer (a GUI app, or a tool whose config lives here)
- [ ] It is **not** something every machine should have — that belongs upstream in
      `dotfiles-core`'s package lists, so every OS repo gets it

## Notes

- Does it need config wiring in `bootstrap.sh` (and the matching `--uninstall` entry)?
- Does it need a third-party tap? (state it fully-qualified, e.g. `owner/tap/formula`)
- Is it arm64-native, or does it need Rosetta?

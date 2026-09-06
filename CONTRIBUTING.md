# Contributing to dotfiles-MacBook

This is the **macOS OS-native layer** of an eleven-repo system (Core → OS-native → Role), so
contributing here is mostly a boundary question: *does this change belong in this repo at
all?* Get that right and the rest is mechanical.

## Is it actually macOS?

Three layers, one test each:

| If it would…                                                                                                                            | it belongs in                  |
| --------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------ |
| be identical on every machine, Linux included                                                                                           | **`dotfiles-core`** (upstream) |
| differ because the OS differs — Homebrew, `/opt/homebrew`, `pbcopy`/`pbpaste`, `defaults write`, aerospace/sketchybar/karabiner/ghostty | **here**                       |
| change with the operator rather than the machine                                                                                        | a **role** repo                |

The trap is the first row. Portable logic that happens to be *convenient* here still
belongs in Core — otherwise every OS repo re-implements it and the copies drift.

## Never hand-edit `core/`

`core/` is a vendored copy of
[dotfiles-core](https://github.com/dotgibson/dotfiles-core). Anything you change there is
**overwritten on the next sync**, and two guards will stop you first: a local pre-commit
hook (installed by `./bootstrap.sh`) and the `core-integrity` CI job, which compares the
vendored tree's git object against upstream.

To change shared config, edit it **in `dotfiles-core`**. A release there fans out a
`sync/core-vX.Y.Z` PR to every OS repo, which you merge. After merging one here:

```bash
./bootstrap.sh --links-only   # re-wire any new/changed Core files
make test-repo                # prove the new Core still loads (exercises the loader)
```

## Green the gate

Humans and CI run the same commands, so "passes locally" means "passes in CI".

```bash
make lint        # shellcheck · shfmt · bash -n · zsh -n · config parse · markdown · secrets
make test-repo   # bootstrap (incl. provision), the zsh loader, defaults.sh — ~150 assertions
make verify-core # the vendored subtree is byte-for-byte what upstream says it should carry
```

`pre-commit install` mirrors these at commit time. Each gate self-skips when its tool is
missing, so `make lint` still works on a bare box — but CI has them all.

`make verify-core` also skips when it cannot reach upstream, which is right on a laptop and
wrong in CI (a skip there reads as a pass). CI sets `VERIFY_CORE_STRICT=1` so an
unverifiable run fails instead; set it locally too if you want to *prove* the subtree is
clean rather than be told it couldn't be checked.

> **`make test` and `make core-audit` are gone** (dotfiles-core#676). They ran Core's own
> `test-core.sh` / `audit-core.sh` out of the vendored subtree, and Core no longer vendors
> them: `core/` is now `core.manifest` + `core.vendor`, and that authoring tooling is in
> neither. Nothing is lost — both ran on `ubuntu-latest`, so they were a second Linux run of
> the same suites dotfiles-core's own CI runs on the same tree before it is vendored here.
> `make verify-core` is what gates the subtree now, and it checks it against upstream rather
> than against `core/`'s own internal consistency.
>
> (They were also the two slow ones — ~6 minutes each, going near-silent partway through.
> If you are looking for that warning because something seems wedged, it is no longer these.)

## Two lists that drift

The installer wires symlinks from a shared scaffold, but `--uninstall` reverses them from a
**hand-maintained list**. Adding a file that gets symlinked means updating both — otherwise
an uninstall leaves a dangling link and a stranded backup. That has happened before.

Likewise, adding a `step()` section to `wire_links()` should keep the module-group gating
(`blib_want`) intact so `--only` / `--skip` stay honest.

## Conventions

- **Commits**: conventional prefixes — `fix(bootstrap):`, `docs(readme):`, `chore(ci):`.
  Explain *why* in the body; the diff already shows *what*.
- **Shell**: bash for scripts (`shfmt -i 2`), targeting macOS's stock **bash 3.2** — no
  associative arrays, `mapfile`, `${var,,}`, or `&>>`.
- **Comments**: explain the non-obvious — a workaround, an ordering constraint, a footgun.
  Several bugs in this repo's history were introduced by removing a comment's constraint.

## Pull requests

`main` requires a PR: squash-only, with `ci ok`, `guard / integrity` and `Analyze (actions)`
green, and review threads resolved. There are no bypass actors — that applies to the
maintainer too. The PR template's checklist mirrors the boundary questions above.

<!-- This is the macOS OS-native layer. It VENDORS dotfiles-core under core/ as a git
     subtree, so the first question is always "which layer does this belong to?" -->

## What & why

<!-- One or two lines. What changed, and why. -->

## Which layer?

- [ ] This is genuinely **macOS-specific** — it would differ on Linux (Homebrew, `/opt/homebrew`,
      `pbcopy`/`pbpaste`, `defaults write`, aerospace/sketchybar/karabiner/ghostty)
- [ ] It is **not** something identical on every machine (that belongs upstream in `dotfiles-core`)
- [ ] It is **not** operator-specific tooling (that belongs in a role repo)

## Does it touch `core/`?

- [ ] **No** — `core/` is untouched

If you ticked anything under `core/`, stop: that tree is a vendored subtree, overwritten
on the next sync. Fix it upstream in `dotfiles-core` and let the release fan out a sync PR.
The local pre-commit guard and the `core-integrity` job will both reject it anyway.

## Checks

- [ ] `make lint` is green (shellcheck, shfmt, `bash -n`/`zsh -n`, config parse, markdown, secrets)
- [ ] `make test-repo` is green
- [ ] If the installer changed: `./bootstrap.sh --links-only --dry-run` still reports a sane plan
- [ ] If a new file needs wiring, `bootstrap.sh` **and** the `--uninstall` destination list
      were both updated (they are separate lists — this is where drift happens)

## Notes

<!-- Load-order implications, follow-up sync, anything reviewers should know. -->

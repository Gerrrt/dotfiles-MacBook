<!-- Back to top link -->
<a id="readme-top"></a>

<!-- Project Shields -->
<div align="center"><nobr>

[![dotgibson][dotgibson-shield]][dotgibson-url]<!--
-->[![CI][ci-shield]][ci-url]<!--
-->![Last Commit][lastcommit-shield]<!--
-->[![Contributors][contributors-shield]][contributors-url]<!--
-->[![Forks][forks-shield]][forks-url]<!--
-->[![Stargazers][stars-shield]][stars-url]<!--
-->[![Issues][issues-shield]][issues-url]<!--
-->[![MIT License][license-shield]][license-url]

</nobr></div>

<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/dotgibson/">
    <img src="https://raw.githubusercontent.com/dotgibson/.github/main/profile/logo.png" alt="Logo" width="80" height="80">
  </a>

  <h3 align="center">🍎 dotfiles-MacBook</h3>

  <p align="center">
    The macOS OS-native layer — Homebrew, AeroSpace tiling, and desktop tooling over the shared Core.
    <br />
    <a href="https://dotgibson.github.io/dotfiles-web/docs"><strong>Explore the docs »</strong></a>
    <br />
    <br />
    <a href="https://dotgibson.github.io/dotfiles-web/playground/">View Demo</a>
    &middot;
    <a href="https://github.com/dotgibson/dotfiles-MacBook/issues/new?labels=bug">Report Bug</a>
    &middot;
    <a href="https://github.com/dotgibson/dotfiles-MacBook/issues/new?labels=enhancement">Request Feature</a>
  </p>
</div>

<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#languages">Languages</a></li>
        <li><a href="#tools">Tools</a></li>
      </ul>
    </li>
    <li><a href="#getting-started">Getting Started</a></li>
    <li><a href="#whats-in-this-layer">What's In This Layer</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
  </ol>
</details>

<!-- ABOUT THE PROJECT -->
## About The Project

**`dotfiles-MacBook` is the OS-native layer for macOS** (Apple Silicon / Intel) —
one node in a cross-platform dotfiles system. The shared **Core** (zsh, tmux,
Neovim, git, starship, mise) is authored once in
[`dotfiles-core`](https://github.com/dotgibson/dotfiles-core) and vendored under
`core/` via `git subtree`, so a clone is self-contained. This repo adds only what
is specific to macOS: the `Brewfile` (`brew bundle`), Ghostty, the 1Password SSH
agent, the native `pbcopy` clipboard — **plus** a committed tiling-desktop layer:
AeroSpace, SketchyBar, and Karabiner, themed to match Core.

macOS is its own lineage — built directly on Homebrew, **not** stamped from the
Fedora template. The full docs live on the [documentation site][docs].

The system is three layers, each building on the one below:

| Layer         | Lives in                                                                                              | Owns                                                  |
| ------------- | ----------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| **Core**      | [`dotfiles-core`](https://github.com/dotgibson/dotfiles-core) → vendored into every OS repo's `core/` | zsh, tmux, nvim, git, starship — identical everywhere |
| **OS-native** | `dotfiles-{MacBook,Windows,Fedora,Arch,Debian,openSUSE,Alpine,Gentoo}` (this repo among them)         | package manager, clipboard, paths                     |
| **Role**      | `dotfiles-Offense`, `dotfiles-Defense`                                                                | offensive / defensive tooling                         |

### Languages

- [![Ruby][ruby-shield]][ruby-url]

The `Brewfile` is a Ruby DSL (`brew bundle`); everything else is shell + config over Core.

### Tools

- [![Homebrew][homebrew-shield]][homebrew-url]
- [![Ghostty][ghostty-shield]][ghostty-url]
- [![AeroSpace][aerospace-shield]][aerospace-url]
- [![SketchyBar][sketchybar-shield]][sketchybar-url]
- [![Karabiner][karabiner-shield]][karabiner-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- GETTING STARTED -->
## Getting Started

### Prerequisites

A Mac and the Xcode [Command Line Tools](https://developer.apple.com/documentation/xcode/command-line-tools)
(`xcode-select --install`) — that brings Git. `bootstrap.sh` provisions the rest
via Homebrew. Already have a Mac configured a different way? See the
[migration guide][migration] to move onto this layout safely.

### Installation

```bash
git clone https://github.com/dotgibson/dotfiles-MacBook ~/dotfiles-MacBook
cd ~/dotfiles-MacBook
./bootstrap.sh --links-only --dry-run   # preview the symlink plan (changes nothing)
./bootstrap.sh                          # Homebrew + brew bundle + symlinks
exec zsh
./bootstrap.sh --macos-defaults         # optional: apply system prefs
```

`core/` is a vendored copy and is **already present** in a clone — there is no
submodule step.

| Flag               | What it does                                         |
| ------------------ | ---------------------------------------------------- |
| `--dry-run`, `-n`  | print every planned action; change nothing           |
| `--links-only`     | just (re)create symlinks, no installs                |
| `--no-brew`        | symlinks + mise, skip Homebrew **and** `brew bundle` |
| `--set-shell`      | make the Homebrew zsh your login shell (`chsh`)      |
| `--macos-defaults` | also run `macos/defaults.sh` (system prefs)          |
| `--only zsh,nvim`  | link ONLY these module groups                        |
| `--skip desktop`   | link everything EXCEPT these module groups           |
| `--uninstall`      | remove the symlinks and restore backed-up files      |
| `--quiet`, `-q`    | show only CHANGES + the summary                      |
| `--json`           | machine-readable summary on stdout (for automation)  |
| `-h`, `--help`     | the same list, from the installer itself             |

Module groups are `zsh nvim tmux git prompt tools desktop` — the first six come
from Core, `desktop` is this layer's own (ghostty, fastfetch, aerospace,
sketchybar, karabiner).

#### Exit codes

| Code  | Meaning                                                           |
| ----- | ----------------------------------------------------------------- |
| `0`   | clean run                                                         |
| `1`   | could not run (not macOS, missing `core/`, no Command Line Tools) |
| `2`   | usage error (unknown flag, bad `--only`/`--skip` selector)        |
| `3`   | ran, but one or more steps **failed** — the box is degraded       |
| `130` | interrupted (Ctrl-C); bootstrap is idempotent, just re-run        |

Exit `3` is the one to watch in automation. Some steps must not abort the run —
`mise install`, `macos/defaults.sh`, `chsh`, the tpm clone — so a failure there
leaves you installed but *degraded* (no runtimes, no tmux plugins). The closing
line says so, the failed steps are listed under the summary, and the exit code
distinguishes it from both a clean run and a bootstrap that never started.

#### The closing checklist

A clean exit still is not a finished machine, so the run ends with a `next steps`
block — **probed, not hardcoded**, so it names only what is actually outstanding
and says nothing on a box where everything is done:

```text
==> next steps
  • Karabiner-Elements — open it once, approve its driver extension, then grant
    it Input Monitoring (System Settings → Privacy & Security)
  • git identity is still the seeded placeholder — edit ~/.config/git/local.gitconfig
  ✓ AeroSpace is running and responding
  ✓ tmux plugins installed (6)
  ✓ pre-commit hook installed
```

Two of those bootstrap now simply **does**: it installs the tmux plugins headlessly
(rather than leaving you to press `prefix + I`) and runs `pre-commit install`, so the
local lint and `gitleaks` gate exists from the first run. The `✓` lines are the proof
they landed.

The GUI permissions are the ones only you can grant. macOS keeps those grants in a
system database that is unreadable without Full Disk Access, so bootstrap cannot ask
"was this allowed?" — each `✓` there reports a *behavioural* check (the driver
extension is approved, AeroSpace answers its socket) and is worded as exactly that,
never as more.

`--dry-run` skips the block entirely: nothing ran, so every item would read as
outstanding.

#### `--json` output

One object on stdout, nothing else (the human log goes to stderr):

```json
{
  "dry_run": false,
  "ok": false,
  "linked": 40, "backed_up": 0, "seeded": 2, "skipped": 0,
  "removed": 0, "restored": 0,
  "tools": { "zsh": true, "starship": true, "mise": true, "fzf": true,
             "nvim": true, "tmux": true, "git": true },
  "errors": ["mise install failed — …; re-run: mise install"],
  "warnings": ["not yet on PATH: starship — open a new shell, …"],
  "next_steps": ["AeroSpace is not responding — launch it and grant it Accessibility …"]
}
```

`ok` is `true` iff `errors` is empty, and mirrors exit `0` vs exit `3` — check it
alone if you want one field. `warnings` are notices that do **not** degrade the
run (a tool that just needs a fresh shell), so they never clear `ok`. `tools`
reports whether each headline binary resolved on `PATH` at the end of the run.

`next_steps` is the outstanding half of the closing checklist — work that is left
for a *person*, not a defect. It never clears `ok` either, because nothing failed;
without it a fleet-provisioning script reading `ok` alone would call a box finished
while its keyboard remapper is still inert. Empty on a machine with nothing left
to do, and empty under `--dry-run`, which probes nothing.

`--uninstall --json` emits the same object, and is the only mode that fills
`removed` / `restored`. It reports `"tools": {}` — an uninstall never probes
`PATH`, so an empty object there means "not measured", not "nothing installed".

**If something goes wrong, `--uninstall` is the way back.** It removes only
symlinks that point into this repo — never a real file, never a foreign link —
and restores the most recent `.pre-dotfiles.*` backup it made. Pair it with
`--dry-run` to see exactly what it would do first.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- WHAT'S IN THIS LAYER -->
## What's In This Layer

Only what changes with the OS. The heavy lifting — the shell modules, editor, and
prompt — comes from vendored Core; this repo owns the macOS specifics:

- `Brewfile` — Homebrew packages (CLI + casks + fonts), the source of truth
- `os/macos.zsh`, `os/macos.gitconfig`, `os/macos.conf` — the macOS overlays
- `macos/defaults.sh` — the `defaults write` system-preferences script (opt-in)
- `aerospace/`, `sketchybar/`, `borders/`, `karabiner/`, `ghostty/`, `fastfetch/` — the desktop + terminal tooling
- `core/` — vendored from `dotfiles-core` (read-only here; edit upstream)

The things worth knowing — Homebrew on `/opt/homebrew` vs `/usr/local`, the native
`pbcopy`/`pbpaste` clipboard, the 1Password SSH agent, and the macOS keychain —
are written up on the hub, alongside the **[migration guide][migration]** for
moving an existing Mac onto this layout:

> **[→ dotfiles-MacBook on the documentation hub][repo-docs]**

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTRIBUTING -->
## Contributing

This is an **OS-native layer**, so the contribution rule is a boundary rule:

1. **Never hand-edit `core/`.** It is a vendored copy of `dotfiles-core` and is
   overwritten on the next sync. Fix shared config **upstream** in
   `dotfiles-core`, run `make audit` there, then `make sync` fans it out here.
2. **Keep changes genuinely macOS.** If it would be identical on every machine,
   it belongs in Core; if it changes with the operator, it belongs in a role repo.
3. **Green the gate.** `make lint` bundles the repo-owned checks locally and
   `pre-commit install` mirrors them at commit time, so "passes locally" means
   "passes in CI". The full suite:

| Gate                                   | Covers                                                                                                                                                     |
| -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| shellcheck · shfmt · `bash -n`         | repo-owned bash                                                                                                                                            |
| `zsh -n`                               | the zsh entry files (no `.sh` extension, so the bash globs miss them)                                                                                      |
| `make test-repo`                       | bootstrap (incl. provision), the zsh loader, `defaults.sh` — ~150 assertions                                                                               |
| file hygiene (CI)                      | `.pre-commit-config.yaml`'s upstream hooks over the whole tree — whitespace, EOF newlines, line endings, merge markers, shebang ↔ exec bit, yaml/json/toml |
| `make config-check`                    | every repo-owned `.json` / `.jsonc` / `.toml` parses                                                                                                       |
| `make markdownlint`                    | repo-owned markdown, against `.markdownlint.jsonc`                                                                                                         |
| `make secrets`                         | gitleaks over the repo-owned tree                                                                                                                          |
| `make verify-core`                     | the vendored Core subtree hasn't drifted — diffed byte-for-byte against the vendored subset of upstream at the recorded commit (CI sets `VERIFY_CORE_STRICT=1` so "couldn't reach upstream" fails instead of skipping) |
| `actionlint`                           | the workflows themselves                                                                                                                                   |
| macOS smoke (CI)                       | the entry points on real Darwin — clipboard, Brewfile, bootstrap                                                                                           |

   CI requires a single aggregated `ci ok` context rather than each job by name,
   so adding or renaming a leg needs no ruleset change.

Bugs and ideas: open an
[issue](https://github.com/dotgibson/dotfiles-MacBook/issues).

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- LICENSE -->
## License

Distributed under the MIT License. See [`LICENSE`](LICENSE) for more information.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- CONTACT -->
## Contact

Garrett Allen - [@gerrrrt](https://x.com/gerrrrt) - <garrettallen2@gmail.com> - [LinkedIn](https://linkedin.com/in/garrettallen2)

Project Link: [dotgibson](https://github.com/dotgibson/)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- Markdown Links & Images -->
[repo-docs]: https://dotgibson.github.io/dotfiles-web/docs/repos/dotfiles-MacBook
[migration]: https://dotgibson.github.io/dotfiles-web/docs/guides/migrating-macos
[dotgibson-shield]: https://img.shields.io/github/v/release/dotgibson/dotfiles-core?style=plastic&label=dotgibson&labelColor=181717&logo=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAF1klEQVR4nLSWbUxT7RnHr9PT09MXSltaoC9QXkqR16Iwhb0Iw8VYYE7jPri5aBaZzpmFZbpolpn4QeMyM%2BM%2B7MVt0Q9LNJIlxCzqxGWS6aKAig51vBQKIi3QltpCS0%2Fbc879pD1N3%2Bnz4fG5Pl2977v%2F331d131f5%2BZrddWQZAgAgy9uCRlefICzT6GeIsP%2FXF15kahmu9JglGmLRQoRQdIQWgu77BuWGe%2Fo%2BOqym8odApaWomTT1%2Bl2HqirahaTuJ9kQMggkgYhDRGfRiQDZBi9fuf52%2BD7l1b3ZhRcmq%2FMnBHmibuO7fvWoTalVoDjQRwL8RGgEOtzB0MbtBDnkRjGR0AgTK%2BQfNukr1LKXlhXKZpJSxTKGoFSq9vf16tQ8%2FiEh094Vu0L449mLGMup20DRWuFYVCiFm%2BvU36nTbOlMB%2BnCDxIOBzhvv6nFpc3TS0dUKDRHzh1Jk9O8wlPYN326Oa%2FJobnN8shAOxqKjrdXa8WSnGKWPewR%2FuHLG5P8oKUFJHi%2FH19F6UKEQ%2BnbJap27%2B%2BtWR15VAHgLkV%2F%2F0xW6OuQCfNE4PgmyX6f0xZKYbJDuj43lmtoYqHU%2FaZdwNXr4eoUG51zqgw%2B%2FCtrbm0UCeRynBhqVj2YC4RNC%2FuqStbKkydAODzeO7%2B6QYTpnOIYgB729R729RY9DAGafb0wDOHLwAA5vKK1mJNFoCpsxeLLn%2Fy91uU359719%2FfVXL%2BSM35IzU9rcXciCcQujz0imOfbGhOB0jkGo2hFQBW7Quzr0Zzq6vyBT%2FuKY%2BHErfBmQWLK1Lhr6l1OkleCqC0poPb%2FuTwv3OrA8DPDhgkokgLmLX77o86kqcGJmaj5xjr1JWlAAr1Js75MDEGAAI%2B1mvWX%2F1JY29XmYDPS5ZoNsrM24si1xSh3%2FRbGBYlz%2F73g41ztqliqYv1onyVHgDocMjjXASAKycavlqnZBHa2ajcasjv%2B8MbAPhRV9nI5MezB41crIPPHWOW9Gtl9XhDDCMCokIqSwGQ4shvyucFhEQCnqlSdm9k%2BdKt6XM%2FqO7aof7t8YbIIW5SHdpVIhUTAOAP0L8bmM3MHgJwByidQCgnhSmAqOEYnQ8AgRBr%2FuUzKsgggIs3pyVCfkeTCgAmFtaNOgm39C%2F3511r2W8JYvIAJbIaAwQ3vKAEoVgRaTQIBYKxqxgMs6euvdUXiQDgeHd5rV7K1fb2kC2rOgaYghQBMJ5grI3HUGuuhQiNIOWq8sy%2FLTgCKplgT0ZtCyprWw7%2FvKCyNr6yQqYg8cim59a9KQDnwv84R1%2F99UwAzsMya4vxeOYLN7YePGG%2BcAPjxXS%2BoavknFfOlRTAh8nHKNqLa1v2ZwK6dxQZtHk5ahu3%2FcYmLsoh%2B%2FsUgN%2BztDQzEvkYFBurGnan%2FS1%2B1P98L1FbxLIPzh193X%2FtwbmjiGUBYHd5nVFRCABPlxdtfh%2B3LHGKxof%2Bqo90C6yj58yi9Tm1kWjr94ZXsGhTuDuynAx2z0245yY4X06Kf9HWFd0N%2BuPbsUR64%2B3a57Erig2qIoOIlJSUNE69GWTZRFufXvRNL%2Fo2ywyJE1fMP6xWqHBEP5yfvP7%2FbAAAsFufG01mkVCqkGvLyrbNTD2mw9kfDckmE0oudx9rUZfhiF5Zd%2F%2F00QDF0NkBTJhanB3e0riHJIRKhXarqWfdu%2Bx0WnOot1ftuNR90lhQzEO0L7B2YvCm3b%2BWNI%2ByffSLq757%2BPcquYaIvBtgdcXycuzO9MzTFdccd9IwDNMVlDaXbzPXtxsVhQRDEQzl8i6d%2Buf12Y%2BONDVMo6vOfHWJxHLz3l811u8WAEZABCNAAHSI8n8k2HABKRJjLJ8JECxFMAE%2BHXhiGb7yn35vcCNDKVsEcSuv%2BEpn%2B7Etla0CwAQIOBLBhrkt85kAnwm8mX95e%2FTOa9vUZiIxQI43r0Kura9uN5SYNMoyuVDGZ2nK73C65iy28Rezo44152bSKYAvz3ifVA1lDn0WAAD%2F%2F%2FWvXexgMwqgAAAAAElFTkSuQmCC
[dotgibson-url]: https://github.com/dotgibson/dotfiles-core/releases/latest
[ci-shield]: https://img.shields.io/github/check-runs/dotgibson/dotfiles-MacBook/main?style=plastic&logo=githubactions&logoColor=white&label=CI
[ci-url]: https://github.com/dotgibson/dotfiles-MacBook/actions/workflows/ci.yml
[lastcommit-shield]: https://img.shields.io/github/last-commit/dotgibson/dotfiles-MacBook?branch=main&style=plastic&logo=git&logoColor=white
[contributors-shield]: https://img.shields.io/github/contributors/dotgibson/dotfiles-MacBook.svg?style=plastic&logo=github
[contributors-url]: https://github.com/dotgibson/dotfiles-MacBook/graphs/contributors
[forks-shield]: https://img.shields.io/github/forks/dotgibson/dotfiles-MacBook.svg?style=plastic&logo=github
[forks-url]: https://github.com/dotgibson/dotfiles-MacBook/network/members
[stars-shield]: https://img.shields.io/github/stars/dotgibson/dotfiles-MacBook.svg?style=plastic&logo=github
[stars-url]: https://github.com/dotgibson/dotfiles-MacBook/stargazers
[issues-shield]: https://img.shields.io/github/issues/dotgibson/dotfiles-MacBook?style=plastic&logo=github
[issues-url]: https://github.com/dotgibson/dotfiles-MacBook/issues
[license-shield]: https://img.shields.io/github/license/dotgibson/dotfiles-MacBook.svg?style=plastic
[license-url]: https://github.com/dotgibson/dotfiles-MacBook/blob/main/LICENSE
[docs]: https://dotgibson.github.io/dotfiles-web/docs
[ruby-shield]: https://img.shields.io/github/v/release/ruby/ruby?style=plastic&logo=ruby&logoColor=white&label=Ruby&labelColor=CC342D&color=3D59A1
[ruby-url]: https://github.com/ruby/ruby
[homebrew-shield]: https://img.shields.io/github/v/release/Homebrew/brew?style=plastic&logo=homebrew&logoColor=white&label=Homebrew&labelColor=FBB040&color=3D59A1
[homebrew-url]: https://github.com/Homebrew/brew
[ghostty-shield]: https://img.shields.io/github/v/tag/ghostty-org/ghostty?sort=semver&style=plastic&logo=gnometerminal&logoColor=24283B&label=Ghostty&labelColor=BB9AF7&color=3D59A1
[ghostty-url]: https://github.com/ghostty-org/ghostty
[aerospace-shield]: https://img.shields.io/github/v/tag/nikitabobko/AeroSpace?sort=semver&style=plastic&logo=gnometerminal&logoColor=24283B&label=AeroSpace&labelColor=BB9AF7&color=3D59A1
[aerospace-url]: https://github.com/nikitabobko/AeroSpace
[sketchybar-shield]: https://img.shields.io/github/v/release/FelixKratz/SketchyBar?style=plastic&logo=gnometerminal&logoColor=24283B&label=SketchyBar&labelColor=BB9AF7&color=3D59A1
[sketchybar-url]: https://github.com/FelixKratz/SketchyBar
[karabiner-shield]: https://img.shields.io/github/v/release/pqrs-org/Karabiner-Elements?style=plastic&logo=gnometerminal&logoColor=24283B&label=Karabiner&labelColor=BB9AF7&color=3D59A1
[karabiner-url]: https://github.com/pqrs-org/Karabiner-Elements

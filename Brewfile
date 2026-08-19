# ════════════════════════════════════════════════════════════════════════════
# Brewfile — dotfiles-MacBook
# Apply with:  brew bundle --file=~/dotfiles-MacBook/Brewfile   (bootstrap.sh does this)
#
# Language runtimes (node, python, ruby, go, rust, java, lua) are NOT installed
# here — they're managed by mise (see core/mise/config.toml). mise's shims
# provide cargo/go/python/etc. on PATH.
#
# Offensive / pentest tooling intentionally does NOT live here — it lives in
# dotfiles-Offense. Keep this box a clean dev/security-engineering environment.
#
# Reproducibility: THIS Brewfile is the committed source of truth. Homebrew 4.x
# deprecated and 6.x removed `Brewfile.lock.json`, so there is no lockfile to pin
# bottle hashes — brew installs the current bottle for each entry. Verify a machine
# matches the spec with `make brew-check` (brew bundle check). Unlike the zsh plugins
# (pinned SHAs in core/zsh/45-plugins.zsh) and the CI linters (pinned releases), brew
# packages float by Homebrew's design; pin a specific one inline (e.g. `brew "foo@1.2"`)
# only where a version genuinely matters.
# ════════════════════════════════════════════════════════════════════════════

# ── Taps ──────────────────────────────────────────────────────────────────────

# ── Mac App Store ─────────────────────────────────────────────────────────────
brew "mas"           # Mac App Store CLI — `mas install <id>` / `mas upgrade`
# Example App Store installs (uncomment + fill in your IDs):
#   mas "Amphetamine",   id: 937984704
#   mas "Lungo",         id: 1263070803
#   mas "Tailscale",     id: 1475387142
#   mas "Reeder.",       id: 1529448980

# ── Terminal & Shell ───────────────────────────────────────────────────────────
cask "ghostty"
brew "zsh"
brew "starship"
brew "zoxide"
brew "atuin"
brew "direnv"
brew "carapace"      # multi-shell completion engine (feeds fzf-tab in zsh; 00-tools.zsh inits it)
brew "asciinema"     # record + replay terminal sessions (`asciinema rec`) — for terminal demos of the setup; own command

# ── Runtime / tooling managers ─────────────────────────────────────────────────
brew "mise"                  # node/python/ruby/go/rust/java/lua — one manager
brew "pipx"                  # isolated installs for Python CLIs
brew "uv"                    # fast Python package/venv manager (Astral)

# ── Modern CLI replacements ────────────────────────────────────────────────────
brew "eza"           # ls
brew "bat"           # cat
brew "ripgrep"       # grep
brew "fd"            # find
brew "git-delta"     # git diff  (canonical formula; `delta` is only an alias of it)
brew "dust"          # du
brew "duf"           # df   (core-doctor probes this; disk usage/free)
brew "btop"          # top  (core aliases top/htop → btop expect this binary)
brew "procs"         # ps
brew "viddy"         # watch (core aliases watch → viddy; 00-tools.zsh probes HAVE_VIDDY)
brew "sd"            # sed
brew "ast-grep"      # AST-aware structural search/rewrite — the syntax-tree complement to rg(text)/sd(regex)/gron(JSON); own command (00-tools.zsh probes HAVE_ASTGREP)
brew "jq"            # JSON
brew "yq"            # YAML
brew "gron"          # greppable JSON (zsh helper expects it)
brew "jnv"           # interactive JSON explorer (jq-filter editor + collapsible viewer) — the "explore" verb to jq's "transform"; own command (00-tools.zsh probes HAVE_JNV)
brew "xan"           # fast CSV slicing (maintained successor to the archived xsv)
brew "visidata"      # interactive TUI for CSV/JSON/sqlite/parquet — the exploration complement to xan's slicing (`vd <file>`; own command)
brew "gnu-sed"       # GNU sed (`gsed`) — nvim-spectre + scripts expect it
brew "tealdeer"      # tldr   (fast Rust tldr client; zsh alias help → tldr)

# ── Network — HTTP & DNS ───────────────────────────────────────────────────────
brew "xh"            # HTTP client  (zsh aliases http/https → xh)
brew "doggo"         # DNS client   (zsh alias dns → doggo)
brew "gping"         # ping w/ graph (core alias ping → gping; 00-tools.zsh probes HAVE_GPING)
brew "croc"          # secure P2P file transfer — `croc send <file>` / `croc <code>` (e2e encrypted; own command)
brew "w3m"           # terminal web browser (Core: `web` alias; text-mode reader)

# ── File management ────────────────────────────────────────────────────────────
brew "yazi"
brew "ouch"          # one-binary archive (un)packer — Core's extract() prefers it (30-functions.zsh probes HAVE_OUCH)
brew "trash"         # rm → Trash  (macOS; safer than rm; macos.zsh aliases rm → trash)

# ── Editor & multiplexer ───────────────────────────────────────────────────────
brew "neovim"
brew "tmux"
brew "sesh"          # tmux session manager (prefix+f / Ctrl+G picker; tmux + fzf widgets use it)
brew "tree-sitter-cli"

# ── Git ────────────────────────────────────────────────────────────────────────
brew "git"
brew "git-lfs"
brew "lazygit"
brew "gh"            # GitHub CLI
brew "git-absorb"    # smart commit absorb
brew "difftastic"    # structural/AST diff — OPT-IN companion to delta, wired as `git dft` / `gdft` (never the default pager); binary is `difft` (00-tools.zsh probes HAVE_DIFFT)
brew "jj"            # jujutsu — OPT-IN colocated git companion (jjs/jjl/jjd aliases; config synced from Core's jujutsu/config.toml; 00-tools.zsh probes HAVE_JJ)
brew "onefetch"      # git repo summary (language/churn/contributors) — `onefetch` in a repo; own command
brew "gnupg"         # commit signing
brew "pinentry-mac"  # GUI pinentry for gpg on macOS

# ── Dev: lint & format ─────────────────────────────────────────────────────────
# The repo's own CI / pre-commit gate runs these; `make lint` uses the same set.
# core/ (nvim Lua, tmux scripts) is vendored and linted upstream in dotfiles-core —
# luacheck/stylua are here so you can run those checks locally before syncing Core.
brew "shellcheck"    # static analysis for bash (bootstrap.sh, macos/defaults.sh, …)
brew "shfmt"         # bash formatter (repo style: `shfmt -i 2`)
brew "pre-commit"    # local commit-time lint gate — run `pre-commit install` once
brew "actionlint"    # GitHub Actions workflow linter
brew "gitleaks"      # secret scanner — `make secrets` / pre-commit gate over the repo-owned tree
brew "luacheck"      # Lua linter (core/nvim — uses core/nvim/.luacheckrc)
brew "stylua"        # Lua formatter (core/nvim)
brew "hyperfine"     # command-line benchmarking (Core's 00-tools.zsh perf note + bench-core.sh use it; own command, probes HAVE_HYPERFINE)

# ── Productivity ──────────────────────────────────────────────────────────────
brew "fzf"
brew "gum"
brew "glow"          # markdown rendering
brew "lnav"          # log-file navigator — auto-detects formats, SQL queries + live tail over logs (`lnav <file>`; own command)
brew "navi"          # interactive fzf-driven cheatsheets (os/macos.zsh aliases cheats → navi; `cheat` stays Core's core-help)
brew "fastfetch"     # system/host info banner (os/macos.zsh aliases ff → fastfetch; config: fastfetch/) — complements onefetch (git-repo summary)
# NOTE: tealdeer / mas / trash are declared once above (Modern CLI / Mac App Store /
# File management). Duplicate declarations were removed — brew bundle is happy with one.
#
# ── Window management & keyboard (macOS desktop layer) ──────────────────────────
# Fully-qualified names auto-tap on install — no separate `tap` lines needed.
cask "nikitabobko/tap/aerospace"          # tiling WM, TOML-configured, no SIP disable (config: aerospace/)
brew "FelixKratz/formulae/sketchybar"     # programmable menu bar (config: sketchybar/)
brew "FelixKratz/formulae/borders"        # JankyBorders — focused-window ring (aerospace after-startup-command)
cask "karabiner-elements"                 # keyboard remap: Caps→Ctrl/Esc + Tab-hyper layers (config: karabiner/)

# ── Launcher ────────────────────────────────────────────────────────────────────
# App launching is primarily keyboard-first (Karabiner Tab-hyper t/b, AeroSpace
# alt-enter); Raycast is the GUI complement — its pull is clipboard history,
# snippets, and the emoji picker, which the keyboard layers don't cover. Settings
# are GUI/cloud-synced, so there's no dotfile to commit — this just installs the app.
cask "raycast"

# ── 1Password ─────────────────────────────────────────────────────────────────
cask "1password"
cask "1password-cli"

# ── Fonts ─────────────────────────────────────────────────────────────────────
cask "font-caskaydia-cove-nerd-font"
cask "font-jetbrains-mono-nerd-font"

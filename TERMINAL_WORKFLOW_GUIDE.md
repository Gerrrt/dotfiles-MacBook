# TERMINAL_WORKFLOW_GUIDE.md — dotfiles-MacBook

> A Principal-Engineer-grade audit and operating manual for the Zsh + Tmux terminal
> ecosystem shipped by **dotfiles-MacBook**. This documents *reality as configured*:
> every path, binding, cache, and load-order rule was read out of the tree, not
> assumed. Where behaviour depends on the vendored `core/` subtree it is called out
> as such (edit those upstream in `dotfiles-core`, never here).

**Scope note.** This box is the **macOS OS-native layer** of an eleven-repo, three-layer
system (Core → OS-native → Role). The interactive shell you actually get is the
*composite* of the vendored Core zsh modules and this repo's macOS overlay
(`os/macos.zsh`, `os/macos.conf`, `os/macos.gitconfig`). The guide treats that
composite as the unit of analysis, because that is what runs on the machine.
Sections 1–5 cover the terminal ecosystem the prompt centers on; **sections 6–8
extend to the rest of the repo** — the macOS desktop/window-management tier,
the maintenance/update/install toolchain, and the editor/VCS configs — so the
manual documents every capability the repo ships (see the Coverage Ledger at the
end). Where a caveat about reading depth applies, it's stated there plainly.

---

## 1. THE INITIALIZATION PIPELINE & VARIABLE FLOW

### 1.1 Lifecycle files, in the exact order zsh reads them

macOS terminals (Terminal.app, iTerm, **Ghostty**) start **login + interactive**
shells, so all four hooks below fire, in this order. The symlink column is what
`bootstrap.sh` wires up.

| Order | Repo file | Symlink target | Runs when | Job |
|------:|-----------|----------------|-----------|-----|
| 1 | `zsh/zshenv` | `~/.zshenv` | **every** shell (even scripts) | XDG base dirs, `ZDOTDIR`, `typeset -U path fpath`, `EDITOR`/`VISUAL`, `NOTES_DIR`, `$HOME/.local/bin` on PATH |
| 2 | `zsh/zprofile` | `~/.config/zsh/.zprofile` | login shells | Homebrew `shellenv` (cached), juliaup, `MISE_TRUSTED_CONFIG_PATHS`, 1Password `SSH_AUTH_SOCK` |
| 3 | `zsh/zshrc` | `~/.config/zsh/.zshrc` | interactive shells | sources the **Core loader** → the 14-module chain |
| 4 | *(none authored)* | — | login shells, post-`zshrc` | no `zlogin`/`zlogout` shipped; nothing runs here |

`ZDOTDIR` is set to `$XDG_CONFIG_HOME/zsh` in step 1, which is *why* `.zprofile`
and `.zshrc` live under `~/.config/zsh/` instead of `$HOME` — everything after
`.zshenv` is resolved relative to `ZDOTDIR`.

> **Load-order invariant.** `.zshenv` sets `typeset -U path fpath` **before anything
> touches PATH**. Every later prepend (Homebrew, juliaup, `.local/bin`) therefore
> self-dedupes; the scattered `[[ ":$PATH:" != *…* ]]` guards are belt-and-suspenders,
> not load-bearing.

### 1.2 The interactive module chain (`.zshrc` → `loader.zsh`)

`.zshrc` does almost nothing itself. It declares the order and delegates to the
vendored loader:

```text
tools → ui → options → history → aliases → git → functions → fzf → bindings → plugins → op → maint → update → os → local
```

`core/zsh/loader.zsh` is **sourced at top-level scope** (never wrapped in a
function — a function's `LOCAL_OPTIONS` would revert every `setopt` on return). For
each module it:

1. byte-compiles `<module>.zsh` → `<module>.zsh.zwc` **only if the source is newer**
   (self-healing on edit/`git pull`), then
2. `source`s the wordcode, skipping re-parse.

`.zwc` files land in `$ZSH_CFG` (the runtime dir), never the repo. There is a
fallback in `.zshrc`: if `loader.zsh` isn't linked yet (a bare `git pull` updates
`.zshrc` before `bootstrap.sh --links-only` re-links), it sources the loader via its
own resolved path so a shell never starts with *zero* Core modules.

**Why the order is load-bearing** (do not reorder casually):

- `tools` runs first — it defines `_cache_eval`, sets `HAVE_*` flags, and inits
  atuin/starship/zoxide/mise (widgets must exist before later modules bind them).
- `options` runs **compinit** — required before `fzf-tab` and `carapace` (both in
  `plugins`) and before any `compdef` (e.g. `compdef eza=ls` in `aliases`).
- `fzf` + `bindings` define zle widgets **before** `plugins` loads `zsh-vi-mode`
  (whose `zvm_after_init` hook registers the keymap).
- `update` sits late so its once/day "updates available" nudge prints just above
  the prompt — including inside each new tmux pane.
- `os` = `os/macos.zsh` (this repo) loads after Core so it can override; `local` =
  `~/.config/zsh/99-local.zsh`, the untracked per-machine escape hatch, loads dead last
  and wins.

### 1.3 Where each class of state is set

| State | Set in | Notes |
|-------|--------|-------|
| **PATH** | `.zshenv` (`.local/bin`), `.zprofile` (brew, juliaup), `00-tools.zsh` (`.local/bin` again, pre-probe) | dedup via `typeset -U path` |
| **Env vars** | `.zshenv` (XDG, EDITOR, NOTES_DIR), `.zprofile` (`SSH_AUTH_SOCK`, `MISE_TRUSTED_CONFIG_PATHS`), `00-tools.zsh` (`VIRTUAL_ENV_DISABLE_PROMPT`, `ATUIN_NOBIND`), `35-fzf.zsh` (`FZF_*`), `20-aliases.zsh` (`BAT_THEME`, `MANPAGER`), `45-plugins.zsh` (`CARAPACE_BRIDGES`, `YSU_*`) | — |
| **Aliases** | `20-aliases.zsh` (modern-stack), `25-git.zsh` (git verbs), `os/macos.zsh` (macOS-only) | every optional-tool alias is `HAVE_*`-guarded |
| **Functions** | `30-functions.zsh` (utilities), `35-fzf.zsh` (zle widgets), `25-git.zsh` (fuzzy `gaf`/`grf`/`grsf`), `50-op.zsh` (1Password) | — |
| **Plugin manager** | `45-plugins.zsh` — hand-rolled, **no Oh-My-Zsh / no Zinit** | clones to `$ZDOTDIR/plugins`, pinned by SHA |
| **Completion system** | `10-options.zsh` (`compinit`), `45-plugins.zsh` (`carapace`, `fzf-tab`), `os/macos.zsh` (direnv/gh/uv/ty + `_bootstrap`) | — |

### 1.4 Startup-performance profile

This configuration is **already aggressively optimised**. The measured hot path
spawns *zero* subprocesses for the shell-hook tools. Mechanisms found:

**Optimisations in place (verified):**

1. **`brew shellenv` is cached, not forked** (`zprofile`). Output is static per
   prefix, so it's written to `~/.cache/zsh/brew-shellenv-<prefix>.zsh` and `source`d;
   regenerated only when the `brew` binary is newer than the cache. Falls back to a
   live `eval` if the cache dir is unwritable. This matters because `exec tmux` (see
   §2.5) starts a **login shell per pane** — an un-cached `$(brew shellenv)` would
   fork brew on every pane.
2. **`_cache_eval` for every hook tool** (`00-tools.zsh`): starship, zoxide, mise, atuin
   — plus direnv/gh/uv/ty in `os/macos.zsh` — have their `init`/`activate`/completion
   scripts generated once and `source`d thereafter. Binary lookup uses zsh's
   `$commands` hash (fork-free), not `$(command -v)`. Env-sensitive generators
   (`ATUIN_NOBIND`, `CARAPACE_BRIDGES`) fold the env into the cache **filename**
   (`--salt`) so flipping the env busts the cache instead of serving stale.
3. **`compinit` fast path** (`10-options.zsh`): the `.zcompdump` security audit
   (`compaudit`) runs **at most once per 24h**. Glob qualifier `(#qN.mh+24)` means
   "older than 24h → full `compinit`; else `compinit -C` (skip the check)". The dump
   is then `zcompile`d for a faster next start.
4. **Module byte-compilation** (`loader.zsh`): all ~14 modules compiled to `.zwc`.
5. **Async plugin loading** (`45-plugins.zsh`): `romkatv/zsh-defer` pushes the two
   heaviest plugins (autosuggestions + syntax-highlighting) plus history-substring-
   search onto a post-first-prompt FIFO queue. The shell is interactive instantly;
   they "catch up" a few ms later.
6. **`diff --color` capability cached** (`20-aliases.zsh`): BSD/macOS `diff` lacks
   `--color`; the verdict is probed once and cached by binary mtime rather than
   forking `diff` every shell.

**Residual bottleneck candidates (honest findings, all minor):**

- **Once-a-day slow shell.** The first interactive shell after the 24h window pays a
  full `compaudit` over `fpath`. This is intentional (security) and self-amortising.
- **Four synchronous completion generators in `os/macos.zsh`.** `direnv`, `gh`, `uv`,
  `ty` each run through `_cache_eval` **after** compinit, on the critical path. They
  are cached (one `source` each), but only `direnv`'s chpwd hook genuinely needs to
  exist before the first prompt. `gh`/`uv`/`ty` completions could be `zsh-defer`d.
  (See §5 recommendation #1.)
- **`zstyle ':completion:*' rehash true`** (`10-options.zsh`): forces a PATH rehash on
  completion attempts. Ergonomic (newly-installed binaries complete immediately) at a
  small per-completion cost — not a startup cost.
- **`HISTSIZE=SAVEHIST=200000`** (`15-history.zsh`): a large in-memory history list.
  Negligible on modern hardware; atuin holds the real searchable history regardless.
- **Per-pane login-shell re-run.** Because `os/macos.zsh` `exec tmux`s and every new
  pane is a login shell, `.zprofile` re-runs per pane. The brew cache is precisely
  what keeps that cheap — the design is aware of this.

**To measure it yourself:** `hyperfine 'zsh -i -c exit'` (the idiom the header of
`00-tools.zsh` points at). For a flame-style breakdown, temporarily add
`zmodload zsh/zprof` at the top of `.zshrc` and `zprof` at the bottom.

---

## 2. TMUX ARCHITECTURE & SESSION MANAGEMENT

### 2.1 File layout & load layering

Tmux config is split omerxx-style into a keybinding layer and a config layer, plus a
per-OS overlay:

| Load order | File | Symlink | Owns |
|-----------:|------|---------|------|
| 1 | `core/tmux/tmux.reset.conf` | `~/.config/tmux/tmux.reset.conf` | **all keybindings** (muscle memory) |
| 2 | `core/tmux/tmux.conf` | `~/.config/tmux/tmux.conf` | terminal, options, theme/status, plugins, pop-ups |
| 3 | `os/macos.conf` | `~/.config/tmux/os.conf` | macOS-only status segment (battery) |

`tmux.conf` `source-file`s the reset file *first*, then defines everything else, then
`source-file -q`s `os.conf` (the `-q` makes it optional on boxes without one).

### 2.2 Core options & the prefix

- **Prefix: `C-a`** (screen-style; `C-b` unbound). `C-a C-a` = `last-window`
  (toggle to the last window). The reset layer defines `bind C-a send-prefix`
  *then* `bind C-a last-window`, and the later bind wins — so a literal `C-a` is
  **not** passed through to the running app; the double-tap toggles windows.
- `mouse on`, `history-limit 100000`, `base-index 1`, `pane-base-index 1`,
  `renumber-windows on`.
- `detach-on-destroy off` — killing a session **jumps to another**, doesn't drop you
  out of tmux.
- `set-clipboard on` — apps may set the system clipboard via **OSC 52**.
- `focus-events on` + `escape-time 10` — for nvim autoread/checkhealth.
- `mode-keys vi` (copy mode is vi-style).
- Terminal: `tmux-256color` + `terminal-features ",*:RGB:usstyle:hyperlinks"`
  (truecolor, undercurl, OSC-8 clickable links; newest flag last for forward-compat).
- Titles: `#{session_name} · #{pane_current_command}`.

### 2.3 The status line (hand-rolled Tokyo Night Storm)

Deliberately **not** a theme plugin — rolled by hand with native formats so the bar
can show operator-useful state and stay palette-identical to Neovim + starship.

- **Position:** top, left-justified, transparent base, 5s refresh interval.
- **LEFT — session pill** whose colour/glyph tracks client state: **blue** normal →
  **orange** (`󰠠`) when the prefix is active → **yellow** (`󰆏`) in copy/search mode.
- **WINDOWS:** inactive = muted pill (`#I: #W`); current = blue pill; a zoom glyph
  (`󰊓`) appears when the pane is zoomed.
- **RIGHT (in order):** operator-IP pill from `tmux-netinfo.sh` → cwd basename
  (`󰉋`) → clock (`󰥔 %H:%M`) → `@status_right_os` (appended per-OS). On macOS that
  appendage is the **battery pill** from `tmux-battery.sh` (`os/macos.conf`,
  `set -ga`), which self-hides on a desktop Mac with no battery.

`tmux-netinfo.sh` is the signature segment: it shows your **VPN/tunnel IP in orange**
(the callback address a reverse shell must reach) when a `tun*/wg*/tailscale0/utun*`
interface is up, else your **LAN IP in green**, else nothing.

### 2.4 Plugins (TPM)

Auto-bootstrapped: TPM is cloned on first run and `install_plugins` fires.

| Plugin | Purpose |
|--------|---------|
| `tmux-plugins/tpm` | plugin manager |
| `tmux-plugins/tmux-sensible` | sane defaults |
| `christoomey/vim-tmux-navigator` | `C-h/j/k/l` cross **seamlessly** between tmux panes and nvim splits |
| `tmux-plugins/tmux-yank` | clipboard yank integration |
| `tmux-plugins/tmux-resurrect` | save/restore sessions to disk |
| `tmux-plugins/tmux-continuum` | **automatic** periodic save + restore-on-boot |
| `wfxr/tmux-fzf-url` | `prefix + u` → fzf URLs out of the visible pane |

### 2.5 Automation hooks

- **Auto-start tmux on shell launch** (`os/macos.zsh`): an interactive login shell
  that is **not** already in tmux, **not** VS Code's integrated terminal, on a TTY,
  and without `DOTFILES_NO_AUTOTMUX` set will
  `exec tmux new-session -A -s "${DOTFILES_TMUX_SESSION:-main}"`.
  `exec` *replaces* the login shell, so detaching exits the terminal cleanly (no
  orphaned tmux-less shell). `new-session -A` attaches to the target session or
  creates it. The session **name** defaults to `main`; override it per-box with
  `export DOTFILES_TMUX_SESSION=<name>` in `~/.config/zsh/99-local.zsh` — handy when
  `@continuum-restore` brings back a session under a different name, so matching the
  name here lets `-A` attach to that restored session instead of spawning a second
  `main`. Opt out of auto-start entirely with `export DOTFILES_NO_AUTOTMUX=1`.
- **Auto-restore sessions** (`tmux.conf`): `@continuum-restore 'on'` +
  `@continuum-save-interval '15'` (minutes). `@resurrect-capture-pane-contents 'on'`
  restores scrollback; `@resurrect-strategy-nvim 'session'` restores nvim sessions.

### 2.6 Step-by-step workflows

#### A. Create, name, detach a persistent session

1. Just open a terminal — you're auto-`exec`'d into session **`main`** (the default;
   configurable via `DOTFILES_TMUX_SESSION` — §2.5).
2. New named session from inside tmux: `prefix S` (choose-session) or, faster, the
   **session picker** `prefix f` (sesh popup — see §3.4) which *creates-or-switches*
   by project/git-repo name.
3. Rename the current **window**: `prefix ,` (prefilled with current name).
4. Detach: `prefix d`. Continuum has already been snapshotting every 15 min; your
   panes/scrollback/nvim survive a reboot.
5. Re-attach later: open any terminal (auto-attaches to `main`), or
   `sesh connect <name>` / `prefix f` for a specific one.

#### B. Split, resize, navigate panes

1. Split keeping cwd: `prefix |` (vertical) / `prefix -` (horizontal). Full-span
   variants: `prefix \` (full-height vertical), `prefix _` (full-width horizontal).
2. Select a pane: `prefix h/j/k/l` — **or** `C-h/j/k/l` with **no prefix**, which
   also crosses into nvim splits (vim-tmux-navigator) — **or** `M-arrow` (no prefix).
3. Resize (hold to repeat, `-r`): `prefix H/J/K/L` (5 cells each press).
4. Zoom/maximize toggle: `prefix m`. Kill pane (no confirm): `prefix x`.
5. Type into **all** panes at once: `prefix *` (synchronize-panes toggle).
6. Floating pane (tmux 3.7+, capability-probed): `prefix F`.

#### C. Scrollback → search → system clipboard

1. Enter copy mode: `prefix Enter` (or scroll with the mouse — `mouse on`).
2. Search the scrollback: `/` (forward) or `?` (backward), `n`/`N` to cycle — the
   status pill turns **yellow** to signal copy/search mode.
3. Select: `v` begins selection; `C-v` toggles rectangle (block) selection.
4. Yank: `y` → runs `copy-pipe-and-cancel "clip"`, piping the selection through
   Core's cross-OS **`clip`** wrapper (which shells out to `pbcopy` on macOS). The
   selection survives a mouse-drag release (`MouseDragEnd1Pane` unbound), and
   `set-clipboard on` also lets fullscreen apps push to the clipboard via OSC 52.
5. Cancel: `Escape`.

### 2.7 Pop-ups (the "command surface")

Scripts live in `core/tmux/scripts/` → `~/.config/tmux/scripts/`.

| Binding | Pop-up | Script |
|---------|--------|--------|
| `prefix w` | session/window switcher (+ engagements if present) | `tmux-menu.sh` |
| `prefix f` | **sesh** session picker (zoxide+git-aware) | `tmux-sesh.sh` |
| `prefix g` | **lazygit** in the pane's cwd | (bare `lazygit`) |
| `prefix T` | persistent scratchpad session in a popup | `tmux-scratch.sh` |
| `prefix ?` | searchable cheatsheet of *this* config | `tmux-cheat.sh` |
| `prefix u` | fzf URLs out of the pane | (tmux-fzf-url) |

`tmux-scratch.sh` is subtle: it runs a persistent `_popup_scratchpad` session with
its own `popup` key-table and `prefix None`, and force-sets `detach-on-destroy on`
for *that* session only (overriding the global `off`) so closing the scratch shell
closes the popup cleanly instead of hijacking `main`. It also repairs `TERM` (popups
launch with `TERM` unset) before `tmux attach`.

---

## 3. MODERN TOOL INTEGRATION & INTERACTIVE SEARCH

### 3.1 Interactive search — fzf + ripgrep + fd

`35-fzf.zsh` sets a fully-themed, explicit Tokyo-Night-Storm `FZF_DEFAULT_OPTS`
(60% height, reverse layout, rounded border, right 65% wrapped preview) — an
*explicit* palette so fzf stays on-theme even when SSH'd into an unthemed box.

- **File source:** `FZF_DEFAULT_COMMAND='fd --type f --hidden --strip-cwd-prefix
  --exclude .git'` (dir source uses `--type d`). fzf's `Ctrl-T`/`Alt-C` reuse it.
- **Previews are binary-resolved, not literal.** `$BAT_BIN` (from `00-tools.zsh`) is
  baked into the preview string so previews work where bat is `batcat`; falls back to
  `cat`/`ls` on a bare box. Two forms are kept: `$_FZF_PREVIEW_CMD` (ends in fzf's
  `{}`) and `$_FZF_TAB_PREVIEW_CMD` (placeholder-free — fzf-tab appends `$realpath`
  itself).

**Custom zle widgets** (defined in `35-fzf.zsh`, bound in `40-bindings.zsh`), each guarded
so a bare box warns in "Core's voice" rather than erroring:

| Key | Widget | Does |
|-----|--------|------|
| `Ctrl-T` | `_fzf_file_no_hidden` | insert a fuzzy-picked file path at the cursor (fd + bat preview) |
| `Ctrl-R` | `_fzf_history_clean` | fuzzy history search (`fc -rl` piped to fzf, seeded with the current buffer) |
| `Alt-Z` | `_fzf_zoxide_jump` | fuzzy-jump to a zoxide dir (dir preview) |
| `Ctrl-E` | `_atuin_search_widget` | Atuin's full-history TUI (guarded on atuin's widget existing) |
| `Ctrl-G` | `_tmux_sessionizer` | sesh session picker (shared with `prefix f`) |

**ripgrep-powered helpers:**

- `fif <term>` — **f**ind **i**n **f**iles: `rg --files-with-matches` → fzf, with a
  bat preview that highlights the first matching line. Requires fzf + rg.
- `rg` alias = `rg --smart-case`. `grep` is deliberately left POSIX (scripts).

**Process killing:** completion is styled for it —
`zstyle ':completion:*:*:kill:*:processes' list-colors …` colourises the process
menu, so `kill <TAB>` gives a coloured, fuzzy-completable process picker (via
fzf-tab). (`procs` replaces `ps` for listing; `btop` for interactive kill.)

### 3.2 Directory traversal — zoxide

- `zoxide` is initialised (cached) in `00-tools.zsh`; **`cd` is aliased to `z`** and
  `cdi` to `zi` (interactive) in `20-aliases.zsh`.
- `Alt-Z` gives an fzf front-end over the zoxide database (`_fzf_zoxide_jump`).
- `-` is aliased to `cd -` (previous dir); `AUTO_CD` + `AUTO_PUSHD` +
  `PUSHD_IGNORE_DUPS` (`10-options.zsh`) make bare directory names cd and build a dir
  stack. Named dirs: `~dots` → `~/.config`, `~proj` → `~/Projects`.
- `fcd` — fuzzy-cd into any subdirectory (fd + fzf, degrades to `find`).
- No autojump — zoxide is the sole jumper.

### 3.3 Modern visual replacements (all `HAVE_*`-guarded)

`00-tools.zsh` probes each binary and sets a `HAVE_*` flag; `20-aliases.zsh` only rewires
the classic command when the flag is set, so a rescue shell silently falls back.

| Classic | Modern | Alias form |
|---------|--------|-----------|
| `ls` | **eza** | `ls`, `ll` (`-lah --git`), `la`, `lt`/`llt` (tree), `tree` |
| `cat` | **bat** | `cat` (`--paging=never`), `catp` (paged); sets `MANPAGER`, `BAT_THEME=ansi` |
| `find` | **fd** | `fd` (resolves `fdfind`) |
| `grep` | **ripgrep** | `rg` (own command; grep stays POSIX) |
| `cd` | **zoxide** | `cd`→`z`, `cdi`→`zi` |
| `du` | **dust** | `du` |
| `df` | **duf** | `df` (else `df -h`) |
| `ps` | **procs** | `ps` |
| `top`/`htop` | **btop** | `top`, `htop` |
| `watch` | **viddy** | `watch` |
| `ping` | **gping** | `ping` |
| `dig` | **doggo** | `dns` (distinct verb) |
| `http` | **xh** | `http`, `https` |
| `diff` | GNU/BSD | `diff --color=auto` (only if supported; cached probe) |
| `man` | **tldr** | `help` |
| `vim` | **nvim** | `vim` |

Own-command (no alias, to avoid shadowing scripts): `jq`, `yq`, `gron`, `sd`,
`ast-grep`, `hyperfine`, `shellcheck`, `shfmt`, `xan`, plus `glow` (`md`), `yazi`
(`fm`/`y`), `difft` (`gdft`), `jj` (`jjs`/`jjl`/`jjd`).

### 3.4 Terminal multiplexing ↔ interactive TUIs

The setup treats tmux pop-ups as the launch surface for full-screen TUIs so they
don't clobber your working pane:

- **lazygit** — `prefix g` opens it in a popup rooted at the pane's cwd
  (`display-popup -d "#{pane_current_path}"`); shell alias `lg`.
- **sesh** — the session manager behind both `prefix f` (tmux popup) and `Ctrl-G`
  (zsh widget), sharing **one** `tmux-sesh.sh`. `sesh list --icons` merges configs +
  running sessions + zoxide dirs; `sesh connect` creates-or-switches. In-popup fzf
  binds re-filter the list: `C-a` all, `C-t` tmux sessions, `C-g` configs, `C-d`
  zoxide dirs. Falls back to `find + fzf` when sesh isn't installed. Example config
  in `core/sesh/sesh.toml.example`.
- **yazi** — file manager, `fm`/`y`.
- **btop** — `top`/`htop`, runs inline in a pane.
- **navi** — `cheats` (macOS overlay) for interactive, arg-templated cheatsheets;
  deliberately named `cheats` so it doesn't shadow Core's `cheat`→`core-help`.
- **nvim ↔ tmux** — `vim-tmux-navigator` makes `C-h/j/k/l` a single seamless
  motion across pane and split boundaries; `focus-events on` keeps nvim autoread and
  `:checkhealth` happy.

---

## 4. COMPREHENSIVE COMMAND & SHORTCUT MATRIX

> `HAVE_*`-guarded entries fall back to the classic command when the modern tool is
> absent. `prefix` = `C-a`.

### 4.1 Shell — modern-stack aliases

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| eza | `ll` | `eza -lah --group-directories-first --icons=auto --git` | Detailed listing with git status per file |
| eza | `lt` / `llt` | `eza --tree --level=2/3` | Quick tree view of a project |
| bat | `cat` / `catp` | `bat --paging=never` / `bat` | Syntax-highlighted file view (paged variant) |
| fd | `fd` | `$FD_BIN` (fd/fdfind) | Fast, gitignore-aware file find |
| ripgrep | `rg` | `rg --smart-case` | Case-smart code search |
| zoxide | `cd` / `cdi` | `z` / `zi` | Frecency-based dir jump / interactive pick |
| dust | `du` | `dust` | Visual disk-usage tree |
| duf | `df` | `duf` | Mountpoint-aware disk free |
| procs | `ps` | `procs` | Colourised, tree-capable process list |
| btop | `top`/`htop` | `btop` | Interactive resource monitor |
| viddy | `watch` | `viddy` | Re-run a command on interval with diff highlighting |
| gping | `ping` | `gping` | Latency graph in the terminal |
| doggo | `dns` | `doggo` | Modern DNS lookup (recon) |
| xh | `http`/`https` | `xh` / `xh --https` | Poke an API/web target |
| glow | `md` | `glow --pager` | Render Markdown notes/READMEs |
| yazi | `fm`/`y` | `yazi` | TUI file manager |
| tldr | `help <cmd>` | `tldr` | Community quick-reference for a command |
| navi | `cheats` | `navi` (macOS overlay) | Interactive, templated cheatsheets |
| nvim | `vim` / `notes` | `nvim` / `cd $NOTES_DIR && nvim .` | Edit / jump to note store |
| net | `myip` | `curl -fsS https://ifconfig.me` | Public egress IP |
| net | `ports` | `ss -tulpn` \|\| `netstat -tulpn` | Listening sockets |
| net | `serve [-l] [port]` | `python3 -m http.server` + URL/QR discovery | Ad-hoc file transfer to another device |
| safety | `rm`/`cp`/`mv` | `-i` interactive (macOS: `rm`→`trash`) | Guard against accidental clobber/delete |

### 4.2 Shell — custom functions

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| functions | `mkcd <dir>` | `mkdir -p && cd` | Make and enter a dir in one step |
| functions | `cdup [n]` | climb n dirs (`cd ../../..`) | Escape deep trees fast |
| functions | `extract <archive>` | ouch/tar/zip/… with tarbomb + clobber guards | Safe one-command unpack of any format |
| functions | `mkbak <file>` | timestamped `.bak` copy (collision-safe) | Snapshot a file before editing |
| functions | `please` | re-run last command with sudo (previews+confirms) | "I forgot sudo" without retyping |
| functions | `genpw [len]` | `openssl rand` → alnum (urandom fallback) | Generate a random password |
| functions | `pullall [dir]` | parallel ff-only pull of every repo under dir | Morning refresh of all your clones |
| functions | `fcd` | fd/find → fzf → cd | Fuzzy jump to any subdir |
| fzf | `fif <term>` | `rg -l` → fzf + bat preview | Find which files contain text |
| fzf | `fbr` | fuzzy git branch checkout (local+remote) | Switch branches without typing names |
| Core | `core-doctor` / `core-version` / `core-help` | health check / version / help index | Diagnose the Core install |

### 4.3 Shell — git aliases & fuzzy helpers (`25-git.zsh`)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| git | `g` / `gst` / `gss` | `git` / `status` / `status --short` | Base verb + status |
| git | `ga` / `gaa` / `gap` | `add` / `add --all` / `add --patch` | Stage files / hunks |
| git | `gc` / `gcm` / `gca` | `commit -v` / `-m` / `-v -a` | Commit variants |
| git | `gc!` / `gcn!` | `commit --amend` / `--amend --no-edit` | Fix up the last commit |
| git | `gco` / `gcb` / `gsw` / `gswc` | checkout / `-b` / switch / `--create` | Branch switching |
| git | `gcom` / `gswm` | checkout/switch trunk via `git_main_branch()` | Jump to main/master/trunk (auto-detected) |
| git | `gd` / `gds` / `gdw` | diff / `--staged` / `--word-diff` | Review changes |
| git | `glog` / `glol` / `glola` | graph log (pretty variants) | Visual history |
| git | `gf` / `gfa` / `gl` / `gpr` | fetch / `--all --prune --tags` / pull / `--rebase` | Sync from remote |
| git | `gp` / `gpu` | push / `push -u origin <current>` | Push / set upstream |
| git | `gpf` / `gpf!` | `push --force-with-lease` / `--force` | **Safe** force (lease) vs raw force |
| git | `gsta`/`gstp`/`gstl` | stash push/pop/list | Shelve work-in-progress |
| git | `grb*` | rebase / `-i` / trunk / continue / abort | Interactive & trunk rebase |
| git | `gaf` / `grf` / `grsf` | fzf multi-select add / restore / unstage | Fuzzy stage/discard by file |
| lazygit | `lg` | `lazygit` | Full TUI git |
| difftastic | `gdft [ref]` | `git difftool --tool=difftastic` | Structural (AST) diff |
| jujutsu | `jjs`/`jjl`/`jjd` | `jj status`/`log`/`diff` | Opt-in jj on the same repo |

### 4.4 Shell — zle key bindings (vi-mode; registered via `zvm_after_init`)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| zle | `Ctrl-T` | `_fzf_file_no_hidden` | Insert a fuzzy-picked file path |
| zle | `Ctrl-R` | `_fzf_history_clean` | Fuzzy history search |
| zle | `Ctrl-E` | `_atuin_search_widget` | Atuin full-history TUI |
| zle | `Alt-Z` | `_fzf_zoxide_jump` | Fuzzy zoxide dir jump |
| zle | `Ctrl-G` | `_tmux_sessionizer` | sesh session picker |
| zle | `Ctrl-\` | `autosuggest-toggle` | Toggle autosuggestions |
| zle | `Up` / `Down` | `history-substring-search-up/down` | Prefix-filtered history |
| zle | `Ctrl-←/→` | `backward-word`/`forward-word` | Word-wise cursor motion |

### 4.5 Tmux — prefix bindings (`C-a`)

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| tmux | `prefix C-a` | `last-window` | Toggle between two windows |
| tmux | `prefix r` | reload `tmux.conf` | Apply config edits live |
| tmux | `prefix c` / `,` / `&` | new / rename / kill window (keeps path) | Window lifecycle |
| tmux | `prefix S` / `d` / `R` | choose-session / detach / refresh-client | Session control |
| pane | `prefix h/j/k/l` | `select-pane -L/D/U/R` | Move focus (vim keys) |
| pane | `prefix \|` / `-` | split vertical / horizontal (keeps path) | Split panes |
| pane | `prefix \` / `_` | full-height / full-width split | Full-span splits |
| pane | `prefix H/J/K/L` | `resize-pane` (repeatable) | Resize by holding |
| pane | `prefix m` | `resize-pane -Z` | Zoom/maximize toggle |
| pane | `prefix x` / `X` | kill-pane / swap-pane -D | Close / rotate pane |
| pane | `prefix *` | `synchronize-panes` | Type into all panes at once |
| pane | `prefix P` | toggle `pane-border-status` | Show per-pane titles |
| pane | `prefix F` | `new-pane` (3.7+, probed) | Floating pane |
| copy | `prefix Enter` | `copy-mode` | Enter scrollback |
| copy | `v` / `C-v` / `y` | begin / rectangle / `copy-pipe-and-cancel clip` | Select & yank to system clipboard |
| popup | `prefix f` | `tmux-sesh.sh` | Session picker |
| popup | `prefix g` | lazygit in cwd | Git TUI |
| popup | `prefix w` | `tmux-menu.sh` | Session/window switcher |
| popup | `prefix T` | `tmux-scratch.sh` | Scratch shell popup |
| popup | `prefix u` | tmux-fzf-url | Open a URL from the pane |
| popup | `prefix ?` | `tmux-cheat.sh` | This config's cheatsheet |

### 4.6 Tmux / terminal — no-prefix & Ghostty

| Scope/Tool | Trigger/Binding | Underlying Command/Logic | Practical Use-Case Scenario |
|------------|-----------------|--------------------------|------------------------------|
| tmux | `C-h/j/k/l` | vim-tmux-navigator | Move across panes **and** nvim splits |
| tmux | `M-arrows` | `select-pane` | Move focus without prefix |
| tmux | `M-H`/`M-L`, `S-←/→` | previous/next window | Cycle windows without prefix |
| Ghostty | `Alt-Space` | `toggle_quick_terminal` | Drop-down quick terminal |
| Ghostty | `Cmd-Shift-P` | `toggle_command_palette` | Fuzzy-search every action |
| Ghostty | `macos-option-as-alt=true` | maps Option→Alt | Makes all `Alt-*` bindings work |

---

## 5. SECURITY FORENSICS & REFACTORING RECOMMENDATIONS

### 5.1 Secrets & credential audit

**Result: clean.** A full scan (`api[_-]?key`, `secret`, `token`, `password`,
private-key headers, `AKIA…`, `ghp_…`) across every `*.zsh`, `*.sh`, `*.conf`,
`config`, `*.toml`, `*.json` in the repo (including the vendored `core/`) surfaced
**no hardcoded secrets, API tokens, or cleartext credentials.** All matches were
comments, help text, or the names of secret-*handling* code. Specifically:

- **Secrets are externalised to 1Password**, not stored. `core/zsh/50-op.zsh` wraps the
  `op` CLI: `opsecret <vault>/<item>/<field>`, `openv <.env.op> <cmd>` (injects at
  runtime via `op run`), `optoken` (TOTP → clipboard, never to history/scrollback),
  `opssh`. The module `return 0`s early if `op` isn't installed.
- **SSH keys live in the 1Password agent.** `zprofile` points `SSH_AUTH_SOCK` at the
  1Password agent socket **but guards on the socket existing** (`[[ -S … ]]`) so it
  self-disables and falls back to the default agent when 1Password isn't running —
  no broken `ssh-add`.
- **History hygiene** (`15-history.zsh`): `HISTORY_IGNORE` blocks `pass …`,
  `*--password *`, `*--token *`, `*API_KEY*`, `*SECRET*`, `op read*` from the flat
  file; `HIST_IGNORE_SPACE` lets you keep any one-off out by leading it with a space.
  atuin adds its own `history_filter`.
- **`ssh/config`** is hardened by default (`StrictHostKeyChecking ask`,
  `VerifyHostKeyDNS yes`, `HashKnownHosts yes`, modern KEX/cipher/MAC allow-lists,
  `ForwardAgent no`) and contains only **commented templates** for bastions/labs —
  no real hostnames, IPs, or usernames committed.

**Portability / hardcoded-path findings (low severity, by design):**

- The only absolute paths are **`$HOME`-relative** (e.g. the 1Password socket under
  `$HOME/Library/Group Containers/…`, `MISE_TRUSTED_CONFIG_PATHS="$HOME/dotfiles-MacBook"`).
  These are *correctly* macOS-scoped: the socket path and `osxkeychain` credential
  helper live in the **OS layer** (`zprofile`, `os/macos.gitconfig`) precisely so the
  vendored Core stays byte-identical across the fleet. This is the intended split, not
  drift.
- **Machine-specific dir assumptions are parameterised, not hardcoded**: `pullall`
  reads `$PULLALL_DIR`, `serve`/status scripts probe interfaces live, `NOTES_DIR`
  defaults but is overridable. The one convenience alias that bakes a path —
  `dotsync='cd "$HOME/dotfiles-MacBook"'` — is macOS-layer-local and `$HOME`-relative,
  so it's portable across macOS accounts.
- **`git`/identity secrets are correctly not here**: `os/macos.gitconfig` carries
  only the keychain helper + gpg program; name/email/signingkey are delegated to an
  untracked `~/.config/git/local.gitconfig`.

**Net:** nothing to remediate. The architecture already does the right thing —
secrets in 1Password, machine-specifics in the OS layer, identity in an untracked
local file.

### 5.2 Top 3 high-impact architectural modifications

Ranked for impact-per-risk, chosen to **avoid** plugin bloat. Note: the zsh/tmux
files below are **vendored Core** — implement them in `dotfiles-core`, `make audit`,
then `make sync`. Only `os/macos.*`, `ghostty/`, and this repo's own files are
edited here directly.

**1. Defer the three non-critical completion generators in `os/macos.zsh`
(execution speed).**
`gh`, `uv`, and `ty` completions are generated (cached) *synchronously after
compinit*, yet none is needed before the first prompt — only `direnv`'s chpwd hook
must be in place early. Wrapping the three in `zsh-defer` (already loaded by the time
`os` runs) moves their `source` cost off the critical path, shaving the tail of
`zsh -i -c exit` for zero behavioural change and no new dependency:

```zsh
_defer_or_now_cmd() { (( $+functions[zsh-defer] )) && zsh-defer "$@" || "$@"; }
_defer_or_now_cmd _cache_eval gh gh completion -s zsh
_defer_or_now_cmd _cache_eval uv uv generate-shell-completion zsh
_defer_or_now_cmd _cache_eval ty ty generate-shell-completion zsh
```

Keep `direnv` synchronous. Measure before/after with `hyperfine 'zsh -i -c exit'`.

**2. Make `pane-border-status` visible by default with pane titles (ergonomics).**
The config already binds `prefix P` to toggle per-pane titles but ships
`pane-border-status off`. In a heavy split workflow, unlabelled panes are the #1
"which pane am I in" tax. Turning on `pane-border-status top` with a compact,
already-in-palette format (`#{pane_index}:#{pane_current_command}`) costs nothing at
runtime (borders are already drawn) and no plugin, and pairs naturally with the
existing zoom glyph in the window pill:

```tmux
set -g pane-border-status top
set -g pane-border-format " #[fg=#{@tn_comment}]#P:#{pane_current_command} "
```

**3. Ship an opt-in startup profiler + a `prof` alias (observability without bloat).**
The config is fast *today*, but there is no first-class way to catch a regression as
tools accrete. A guarded `zmodload zsh/zprof` at the top of the module chain,
activated only when `ZSH_PROFILE_STARTUP=1`, plus a one-line `prof` helper, gives a
per-module breakdown on demand and stays completely inert otherwise:

```zsh
# top of loader.zsh (or .zshrc), before the module loop
[[ -n ${ZSH_PROFILE_STARTUP:-} ]] && zmodload zsh/zprof
# ...after the loop:
[[ -n ${ZSH_PROFILE_STARTUP:-} ]] && zprof
```

This turns "the shell feels slower lately" into a five-second, data-backed answer —
the same discipline the repo already applies to CI (pinned linters) and plugins
(pinned SHAs), extended to startup performance.

---

## 6. macOS DESKTOP & WINDOW MANAGEMENT

The repo doesn't stop at the terminal — it owns the whole keyboard-driven macOS
desktop. Four config trees, all Tokyo-Night-Storm-themed to match the shell, and all
**editable here** (this is the OS-native layer, not vendored Core).

### 6.1 AeroSpace — i3-like tiling WM (`aerospace/aerospace.toml`)

Chosen over yabai specifically because it needs **no SIP disable and no scripting
daemon** — pure declarative config, which fits the committed-as-code model. `alt` (⌥)
is the WM modifier (Ghostty's `macos-option-as-alt=true` keeps it from colliding with
terminal accent input).

- **Schema v2**, `start-at-login`, `automatically-unhide-macos-hidden-apps` (a window
  swallowed by `cmd-h` re-appears on next focus instead of vanishing from a tile).
- **Layout:** `tiles` root, `auto` orientation (widescreen → horizontal, tall →
  vertical), 4px inner gaps, `outer.top = 21` reserving the SketchyBar strip.
- **Startup commands:** launches `sketchybar` and **JankyBorders** (`borders`,
  installed via Brewfile) which rings the focused window — blue `#7aa2f7` focused,
  grey `#565f89` unfocused.
- **Auto-placement (`on-window-detected`):** utility/settings windows (System
  Settings, Activity Monitor, Calculator, Finder, 1Password) are forced `floating`.
- **Persistent workspaces 1–5** so the SketchyBar spaces row always renders.
- **Multi-monitor:** `on-focused-monitor-changed` lazily warps the mouse to the new
  monitor's center.
- **Shared cross-OS keymap:** this map is kept keystroke-for-keystroke identical to the
  Windows host's GlazeWM (`dotfiles-Windows/desktop/glazewm/config.yaml`), so the tiling
  workflow is one muscle-memory across macOS and Windows. Only bindings both WMs express
  identically are kept — hence no accordion, service mode, screenshot, per-app workspace
  pinning, or monitor-workspace-move here.

| Mode | Binding | Action |
|------|---------|--------|
| main | `alt-h/j/k/l` | focus left/down/up/right |
| main | `alt-shift-h/j/k/l` | move window |
| main | `alt-u` / `alt-p` | nudge-resize width −/+ 50 |
| main | `alt-o` / `alt-i` | nudge-resize height +/− 50 |
| main | `alt-v` | toggle tiles horizontal↔vertical |
| main | `alt-f` | fullscreen |
| main | `alt-shift-space` | toggle floating for the focused window |
| main | `alt-shift-q` | close the focused window |
| main | `alt-1..5` | focus workspace N |
| main | `alt-shift-1..5` | move window to workspace N and follow |
| main | `alt-a` / `alt-s` / `alt-d` | workspace prev / next / recent |
| main | `alt-enter` | new Ghostty window (`open -na Ghostty`) |
| main | `alt-r` | enter **resize mode** (`h/l` width, `k/j` height; esc/enter exit) |
| main | `alt-shift-r` | reload config |

### 6.2 Karabiner — Caps→Ctrl/Esc + the Tab "hyper" layer (`karabiner/karabiner.json`)

Two remaps that make the whole desktop reachable without reaching for modifiers:

- **Caps Lock → Control held / Escape tapped** — the classic modal-editor ergonomic
  (Escape for nvim, Control for everything else), zero extra keys.
- **Tab → "hyper" layer held / Tab tapped** — holding Tab sets a `hyper` variable
  that turns the alpha keys into an AeroSpace command surface (an ergonomic mirror of
  the `alt` chords, so you never contort for `alt-shift-N`):

| Hyper (hold Tab) + | Runs |
|--------------------|------|
| `h/j/k/l` | `aerospace focus` left/down/up/right |
| `shift+h/j/k/l` | `aerospace move` |
| `1..5` | `aerospace workspace N` |
| `shift+1..5` | `aerospace move-node-to-workspace --focus-follows-window N` |
| `n` / `p` | workspace next/prev (wrap) |
| `f` | `aerospace fullscreen` |
| `space` | toggle floating/tiling |
| `t` / `b` / `return` | open Ghostty / Safari / new Ghostty window |

(Each shell-out hard-sets `PATH=/opt/homebrew/bin:…` because Karabiner's exec
environment has a minimal PATH.)

### 6.3 SketchyBar — programmable menu bar (`sketchybar/`)

The macOS analog of the hand-rolled tmux status bar: a per-event plugin model with a
**single palette** in `colors.sh` (0xAARRGGBB, Tokyo Night Storm), rendered in the
already-installed CaskaydiaCove Nerd Font (no `sketchybar-app-font` dependency).

- **Bar:** top, height 20, corner radius 9, translucent storm-black, 20px blur.
- **Left:** Apple logo (click → reload) · **AeroSpace workspaces 1–5** (custom
  `aerospace_workspace_change` event; active space paints blue via `plugins/aerospace.sh`,
  click jumps) · front-app name (`front_app.sh`).
- **Right (rendered left→right):** volume · cpu · memory · disk · network · ☕ toggle.
  Battery + clock are deliberately **omitted here** — they live in the tmux bar, so
  showing them twice would duplicate.

| Plugin | Shows | Source / logic |
|--------|-------|----------------|
| `cpu.sh` | CPU % (green→yellow→red) | macOS `top -l 1` idle math |
| `memory.sh` | RAM used % | `memory_pressure` free % |
| `disk.sh` | free space on `/` | `df -H`, colours at 80/90% used |
| `network.sh` | ↓/↑ throughput | `netstat -ib` deltas cached in `$TMPDIR` |
| `volume.sh` | output volume + glyph | `volume_change` event / `osascript` |
| `caffeinate.sh` | keep-awake toggle | `caffeinate -di` with a PID-file (a free Amphetamine) |
| `front_app.sh` | focused app name | `front_app_switched` event |
| `aerospace.sh` | workspace highlight | animates the focused space pill |

### 6.4 macOS system defaults (`macos/defaults.sh`)

An **idempotent** `defaults write` sweep (run via `bootstrap.sh --macos-defaults`),
tuned for a terminal-heavy, keyboard-driven workflow. It's dry-run-aware (`-n` shadows
the mutating commands to just echo), speaks the shared Core UX palette (`core/lib/ux.sh`),
and tallies a summary at the end. Highlights:

- **Keyboard (the load-bearing ones for modal editing):** `KeyRepeat 2` +
  `InitialKeyRepeat 15` (fast repeat), **`ApplePressAndHoldEnabled false`** (keys
  repeat instead of showing the accent menu — "the single most important tweak"), full
  keyboard access mode 3, and all the "smart" text substitutions (quotes, dashes,
  capitalization, spelling) **off** so they can't mangle code.
- **Finder:** show all extensions + dotfiles, path bar, status bar, POSIX path in
  title, list view, search current folder, no `.DS_Store` on network/USB volumes.
- **Dock:** instant autohide, tile size 48, no recents, stable Spaces (`mru-spaces
  false`), minimize-to-app.
- **Screenshots:** PNG to `~/Screenshots`, no window shadow.
- **Security:** require password immediately on sleep/screensaver. Higher-friction
  toggles (Gatekeeper quarantine, app firewall, Touch-ID-for-sudo) are shipped
  **commented out** with an explicit trade-off note — opt-in, never silently applied.

---

## 7. MAINTENANCE, UPDATE & PROVISIONING

Beyond config, the repo ships a full lifecycle toolchain — install, daily upkeep,
and an umbrella command namespace. These are the capabilities the terminal sections
referenced only in passing.

### 7.1 `up` — the interactive package updater (`core/zsh/60-update.zsh`)

A distro-agnostic front end over the box's package manager (brew/pacman/dnf/zypper/
apt/apk/emerge — auto-detected via `_pkgup_mgr`). Fail-closed argument parsing (an
unknown flag is rejected with a did-you-mean, never silently applied as a privileged
update):

| Invocation | Behaviour |
|------------|-----------|
| `up` | interactive: preview pending upgrades, confirm, apply |
| `up -y` / `--yes` | auto-confirm where safe |
| `up -n` / `--dry-run` | list what *would* upgrade, touch nothing |
| `up -i` / `--interactive` | fzf/gum-pick which packages (only where partial upgrades are safe — refuses on pacman/emerge/apk by design) |

The modes are mutually exclusive (a contradiction is rejected). `60-update.zsh` also owns
the **once/day "N updates available" nudge** that prints above the prompt (`_pkgup_notice`,
count cached so the hot path never forks the package manager) and the first-run
`_core_welcome` banner.

### 7.2 `maint-*` — the scheduled maintenance job (`core/zsh/55-maint.zsh`)

Wires `core/maint/dotfiles-maint.sh` (brew + plugins + nvim + mise upkeep) to whatever
scheduler the box has — **launchd LaunchAgent on macOS**, systemd `--user` timer on
Linux, crontab elsewhere — at a time you choose:

| Command | Action |
|---------|--------|
| `maint-install [HH:MM]` | install + enable (default 13:00) |
| `maint-run` | run it now, foreground |
| `maint-log [N\|-f]` | last N log lines (default 50), or follow |
| `maint-status` | when it next runs / whether enabled |
| `maint-uninstall` | remove the schedule |

(`up` is the per-shell nudge; `maint` is the scheduled apply — two halves of the same
freshness story.)

### 7.3 `core` — the umbrella command namespace (`core/zsh/30-functions.zsh`)

One discoverable front door over Core's first-party verbs, so a newcomer types `core`
and finds everything instead of needing to know each verb by name:

| Command | Delegates to | Purpose |
|---------|--------------|---------|
| `core` (bare) | — | the cheat sheet (bare `core` is help, never an error) |
| `core help [filter]` | `core-help` | searchable index of Core commands |
| `core doctor [-v] [--json]` | `core-doctor` | report detected tools + which integrations are actually *wired* (`-v` adds versions; `--json` for statuslines/CI) |
| `core version` | `core-version` | the vendored Core layer's version stamp |
| `core update [-y\|-n]` | `up` | package updates |

The subcommand list is the single source both the `_core` completion and the
did-you-mean-on-typo read, so they can't drift.

### 7.4 Install & dev entry points (`bootstrap.sh`, `Makefile`)

`bootstrap.sh` is the installer — symlinks every config into place, runs `brew bundle`,
optionally applies defaults and sets the login shell. Fail-closed flag parser
(`KNOWN_FLAGS`), dry-run-aware, with a `--json` summary:

| Flag | Effect |
|------|--------|
| `--links-only` | symlinks only, no Homebrew/provisioning |
| `--no-brew` | skip `brew bundle` |
| `--macos-defaults` | run `macos/defaults.sh` |
| `--set-shell` | make the Homebrew zsh the login shell |
| `--only <x>` / `--skip <x>` | scope which components run |
| `--uninstall` | remove the symlinks |
| `--dry-run`/`-n`, `--quiet`/`-q`, `--json` | preview / silence / machine-readable |

Steps that must not abort the run (`mise install`, `macos/defaults.sh`, `chsh`, the tpm
clone) are recorded rather than swallowed: a failure lists itself under the summary, sets
`"ok": false` / `errors[]` in the `--json` object, and exits **3** — "ran, but degraded",
distinct from `1` (couldn't run at all) and `2` (usage error). See the README's exit-code
and `--json` tables for the full schema.

`Makefile` is the dev surface (`make` with no target lists it): `make lint`
(shellcheck + `fmt-check` + `bash -n` + `zsh -n`), `make test-repo` / `make test` /
`make test-all` (this repo's behavioral tests + the vendored Core harness), `make
bootstrap` / `bootstrap-dry` / `doctor`, `make bench` (Core shell-startup cost, gated
by `CORE_BENCH_BUDGET_MS`), `make brew-check` (Brewfile reproducibility gate), and the
Core-integrity pair `core-audit` / `verify-core` (the third, `check-core-freshness`,
retired with the per-repo watcher — Core's `fleet-drift` sweep answers that now). Shell
completion for `bootstrap.sh` ships in `completions/` (`_bootstrap`, wired by
`os/macos.zsh`).

---

## 8. EDITOR & VERSION-CONTROL TOOLING

The tools the terminal treats as black boxes — the ones that open *inside* panes and
popups — each ship a full committed config in vendored Core. Documented here for
completeness; all are edited upstream in `dotfiles-core`.

### 8.1 Neovim (`core/nvim/`) — leader `Space`, lazy.nvim, ~60 plugins

`init.lua` is a one-liner (`require("gerrrt")`); the real config is a structured Lua
tree under `lua/gerrrt/`: `config/` (options, keymaps, autocmds, clipboard, providers,
the `lazy` bootstrap), `plugins/` (one spec per plugin), `servers/` (~22 LSP server
configs), and `utils/`. Plugins are pinned via `lazy-lock.json`. Capability map:

- **Completion/LSP:** `blink.cmp`, `nvim-lspconfig` + `mason` (auto-installs servers:
  lua_ls, gopls, ruff, ts_ls, rust via `rustaceanvim`, clangd, tailwindcss, yamlls,
  solidity, and more), `lazydev` for the nvim Lua API.
- **Finding/navigation:** `fzf-lua`, `harpoon`, `flash.nvim`, `oil.nvim` +
  `nvim-tree`, `aerial` (symbols), `dropbar` (breadcrumbs), `nvim-bqf`.
- **Git:** `gitsigns`, `diffview`, `vim-fugitive`, `lazygit.nvim`, `git-conflict`,
  `gitlinker`.
- **Editing:** treesitter (+ context, textobjects, `treesj` split/join), `mini.nvim`,
  `nvim-ufo` folding, `nvim-spectre` search/replace, `conform` (format) + `nvim-lint`,
  `todo-comments`, `neogen` (docstrings).
- **Testing/debug/data:** `neotest` (python + golang), `nvim-dap` + `dap-ui`,
  `vim-dadbod` (+ UI/completion) for databases, `crates.nvim`/`package-info` for
  dependency versions.
- **UI:** `tokyonight.nvim` theme, `lualine`, `bufferline`, `incline`, `alpha` dash,
  `which-key`, `zen-mode` + `twilight`, `render-markdown`, `rainbow-delimiters`.
- **Cross-tool:** `vim-tmux-navigator` (the nvim half of the seamless `C-h/j/k/l`).

Signature keymaps (all `<leader>` = Space; `<leader>?` opens an in-editor cheatsheet of
every binding): `<leader>rc` edit config, `<leader>sv`/`sh` splits, `<leader>se`
equalize, `<leader><tab>n` new tab, `<leader>p` paste-without-yank, `<leader>D`
delete-without-yank. A minimal `core/vim/vimrc` covers plain-`vi` fallback boxes.

### 8.2 lazygit (`core/lazygit/config.yml`)

Full-TUI git (launched by `lg`, `prefix g` tmux popup, and `lazygit.nvim`). Themed to
Tokyo Night Storm (orange active border, blue/magenta cherry-pick highlights), Nerd
Font v3 glyphs, `main`/`master` branch labels in red.

### 8.3 mise (`core/mise/config.toml`) — the runtime manager

The single source for language runtimes (deliberately **not** in the Brewfile): node
LTS, pnpm, python 3.12, ruby 3.3, go, rust stable, temurin-21 JVM, lua 5.4. `auto_install
= false` (explicit installs only, no fetch-on-cd), `legacy_version_file = true` (honors
`.nvmrc`/`.ruby-version`/etc.), `experimental = true` (native shims), `lockfile = true`.
The macOS layer trusts this repo's dir via `MISE_TRUSTED_CONFIG_PATHS` (`zprofile`).

### 8.4 jujutsu (`core/jujutsu/config.toml`) — opt-in git companion

Colocated VCS that runs on the same `.git` (shell verbs `jjs`/`jjl`/`jjd`). Config:
`default-command = "log"`, builtin diff/merge editors, `auto-local-bookmark`, aliases
`l`/`st`. Never shadows git — additive only.

### 8.5 git (`core/git/gitconfig`)

The base git config (aliases are in `25-git.zsh`); pulls in the macOS layer
(`os/macos.gitconfig`: osxkeychain helper, gpg program, global excludesfile) and an
untracked `~/.config/git/local.gitconfig` for identity (name/email/signingkey) —
which is why no personal identity is committed anywhere in the repo.

---

## APPENDIX: COVERAGE LEDGER

What this manual now documents, end to end:

| Tier | Files | Section |
|------|-------|---------|
| Shell init | `zsh/*`, `core/zsh/{tools,ui,options,history,loader}` | §1 |
| Tmux | `core/tmux/*`, `os/macos.conf` | §2 |
| Modern CLI | `core/zsh/{aliases,fzf,plugins,tools}` | §3 |
| Command matrix | aliases + functions + git + zle + tmux | §4 |
| Security/refactor | secrets, `ssh/config`, `50-op.zsh`, history hygiene | §5 |
| Desktop/WM | `aerospace/`, `karabiner/`, `sketchybar/`, `macos/defaults.sh` | §6 |
| Maintenance/install | `60-update.zsh`, `55-maint.zsh`, `bootstrap.sh`, `Makefile`, `core-*` | §7 |
| Editor/VCS | `core/{nvim,lazygit,mise,jujutsu,git,vim}` | §8 |

**Reading-depth caveat (honest):** the very large modules — `30-functions.zsh` (~44 KB),
`05-ui.zsh` (the `_core_*` presentation/helper library), `nvim/` (~90 Lua files), and the
full `Brewfile` — are documented at the level of *every capability and command they
expose*, not line-by-line. `05-ui.zsh` in particular is the shared helper layer
(`_core_err`/`_core_ok`/`_core_confirm`/`_core_spin`/`_core_help`, truecolor-aware)
that the other modules call; it ships no user-facing commands of its own. If you need a
per-line audit of any single module, that's a targeted follow-up.

---

*Generated by a read-only audit of `dotfiles-MacBook` — the macOS OS-native layer plus
its vendored `core/` subtree — covering the shell, tmux, desktop/WM, maintenance, and
editor tiers. Anything under `core/` (zsh modules, tmux, nvim, lazygit, mise, jujutsu,
git) is vendored: change it upstream in `dotfiles-core`, run `make audit`, then
`make sync`. The OS-native tiers (`aerospace/`, `sketchybar/`, `karabiner/`,
`os/`, `macos/`, `Brewfile`, `bootstrap.sh`) are edited here directly.*

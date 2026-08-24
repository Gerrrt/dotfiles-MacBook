# macOS Aliases Cheat Sheet

macOS-specific aliases from `os/macos.zsh`, layered on top of Core.
See `core/` for the full Core alias reference (modern CLI, git, safety nets).

> **Note:** On macOS the Core `rm='rm -i'` safety net is overridden by
> `rm='trash'` (if the `trash` CLI is installed), which moves files to the
> Trash instead of deleting them.

## macOS Specific

| Alias       | Expands To                                                                        |
| ----------- | --------------------------------------------------------------------------------- |
| `localip`   | `ipconfig getifaddr en0` (LAN IP on primary interface)                            |
| `flushdns`  | `sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder`                 |
| `showfiles` | `defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder`  |
| `hidefiles` | `defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder` |
| `o`         | `open` — `o .` opens the current directory in Finder                              |
| `dotsync`   | `cd "$HOME/dotfiles-MacBook"`                                                     |

## Conditional (activated only when the tool is installed)

| Alias      | Expands To                                 | Requires    |
| ---------- | ------------------------------------------ | ----------- |
| `rm`       | `trash` (moves to macOS Trash)             | `trash`     |
| `cheats`   | `navi` (interactive cheat sheet)           | `navi`      |
| `masup`    | `mas upgrade` (upgrade all App Store apps) | `mas`       |
| `masls`    | `mas list` (list installed App Store apps) | `mas`       |
| `opsignin` | `eval "$(op signin)"`                      | `op`        |
| `ff`       | `fastfetch` (system/host banner)           | `fastfetch` |

## Desktop Tooling

This repo also owns the macOS desktop layer. Key config locations:

| Tool                      | Config Path   |
| ------------------------- | ------------- |
| Aerospace (tiling WM)     | `aerospace/`  |
| Sketchybar (status bar)   | `sketchybar/` |
| Karabiner (key remapping) | `karabiner/`  |
| Ghostty (terminal)        | `ghostty/`    |

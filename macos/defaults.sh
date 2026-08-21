#!/usr/bin/env bash
# macos/defaults.sh — macOS system preferences as code
#
# Usage:  bash ~/dotfiles-MacBook/macos/defaults.sh
#
# Idempotent: every `defaults write` is safe to re-run. Some changes require a
# logout/restart to fully apply; this script restarts Finder/Dock/SystemUIServer
# at the end so most take effect immediately.
#
# Tuned for a terminal-heavy, keyboard-driven security workflow. Read it before
# you run it — these are MY preferences; comment out anything you disagree with.

# Not using `set -e`: one unknown key on a future/older macOS shouldn't abort
# the whole run.
set -uo pipefail

# Palette from the VENDORED shared bash UX lib (core/lib/ux.sh) when present, so this
# installer speaks the SAME colours as bootstrap.sh + the Core layer instead of a third
# hand-rolled copy (U7). Fallback to the inline rule (same TTY+NO_COLOR gate) until a Core
# sync brings the lib. BOLD comes from tput either way (ux is a colour/glyph lib, not bold).
_SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$_SELF_DIR/../core/lib/ux.sh" ]]; then
  # shellcheck source=/dev/null
  source "$_SELF_DIR/../core/lib/ux.sh"
  GREEN=$UX_GRN YELLOW=$UX_YEL BLUE=$UX_BLU RESET=$UX_RST
  BOLD=""
  [[ -n "$GREEN" ]] && BOLD=$(tput bold 2>/dev/null || echo "")
elif [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  BOLD=$(tput bold 2>/dev/null || echo "")
  RESET=$(tput sgr0 2>/dev/null || echo "")
  GREEN="\033[0;32m"
  YELLOW="\033[0;33m"
  BLUE="\033[0;34m"
else
  BOLD="" RESET="" GREEN="" YELLOW="" BLUE=""
fi
# Section + applied-key counters drive the end-of-run summary (U6) so a long
# `defaults write` sweep ends with a tally + clear next-step, like bootstrap.sh —
# not just trailing off after the last section.
n_sections=0
n_groups=0
header() {
  n_sections=$((n_sections + 1))
  echo -e "\n${BLUE}${BOLD}==> $1${RESET}"
}
ok() {
  n_groups=$((n_groups + 1))
  echo -e "  ${GREEN}✓ $1${RESET}"
}
info() { echo -e "  ${YELLOW}• $1${RESET}"; }

# ── dry-run: `--dry-run`/`-n` prints the intended changes and mutates nothing. ─
# Implemented by SHADOWING the mutating commands, so the dozens of `defaults write`
# calls below need no per-line edits — in dry mode each one just echoes what it
# would do. (`set -e` is intentionally off, so a wrapper returning 0 changes nothing.)
# Parse EVERY argument (not just $1) so combined/extra args are rejected cleanly
# instead of silently ignored — matching bootstrap.sh's fail-closed parser (U8).
DRY=0
for arg in "$@"; do
  case "$arg" in
  --dry-run | -n) DRY=1 ;;
  -h | --help)
    echo "usage: defaults.sh [--dry-run|-n]   (no args = apply the preferences)"
    exit 0
    ;;
  *)
    echo "defaults.sh: unknown argument: $arg" >&2
    echo "usage: defaults.sh [--dry-run|-n]" >&2
    exit 2
    ;;
  esac
done
if ((DRY)); then
  header "DRY RUN — printing intended changes; the system is NOT modified"
  defaults() { if [[ "${1:-}" == write ]]; then echo "  would write: ${*:2}"; else command defaults "$@"; fi; }
  killall() { echo "  would: killall $*"; }
  chflags() { echo "  would: chflags $*"; }
  mkdir() { echo "  would: mkdir $*"; }
  osascript() { :; } # don't quit System Settings during a preview
fi

# Close System Settings so it can't override what we write
osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1 || true

# ══════════════════════════════════════════════════════════════════════════════
# Keyboard & input
# ══════════════════════════════════════════════════════════════════════════════
header "Keyboard & input"

# Fast key repeat (KeyRepeat 1 = fastest, 2 = very fast). Critical for vim/nvim.
defaults write NSGlobalDomain KeyRepeat -int 2
defaults write NSGlobalDomain InitialKeyRepeat -int 15

# Press-and-hold shows the accent menu by default — disable so keys REPEAT.
# This is the single most important tweak for modal editors.
defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false

# Full keyboard access: Tab moves between ALL controls, not just text fields.
defaults write NSGlobalDomain AppleKeyboardUIMode -int 3

# Kill text "helpers" that mangle code and shell commands.
defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false
defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false # "smart" quotes
defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false
defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false
ok "keyboard tuned (repeat on, autocorrect/smart-quotes off)"

# ══════════════════════════════════════════════════════════════════════════════
# Trackpad & mouse
# ══════════════════════════════════════════════════════════════════════════════
header "Trackpad"
defaults write NSGlobalDomain com.apple.trackpad.scaling -float 2.5  # tracking speed
defaults write com.apple.AppleMultitouchTrackpad Clicking -bool true # tap to click
defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
ok "trackpad: tap-to-click + faster tracking"

# ══════════════════════════════════════════════════════════════════════════════
# Finder
# ══════════════════════════════════════════════════════════════════════════════
header "Finder"
defaults write NSGlobalDomain AppleShowAllExtensions -bool true
defaults write com.apple.finder AppleShowAllFiles -bool true # show dotfiles
defaults write com.apple.finder ShowPathbar -bool true
defaults write com.apple.finder ShowStatusBar -bool true
defaults write com.apple.finder _FXShowPosixPathInTitle -bool true  # full path in title
defaults write com.apple.finder FXDefaultSearchScope -string "SCcf" # search current folder
defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv" # list view (clmv = column)
defaults write com.apple.finder _FXSortFoldersFirst -bool true

# Stop writing .DS_Store turds on network shares and USB volumes
defaults write com.apple.desktopservices DSDontWriteNetworkStores -bool true
defaults write com.apple.desktopservices DSDontWriteUSBStores -bool true

# Spring-loaded folders, no delay
defaults write NSGlobalDomain com.apple.springing.enabled -bool true
defaults write NSGlobalDomain com.apple.springing.delay -float 0
ok "Finder: extensions, hidden files, path bar, no .DS_Store on shares"

# ══════════════════════════════════════════════════════════════════════════════
# Screenshots
# ══════════════════════════════════════════════════════════════════════════════
header "Screenshots"
mkdir -p "${HOME}/Screenshots"
defaults write com.apple.screencapture location -string "${HOME}/Screenshots"
defaults write com.apple.screencapture type -string "png"
defaults write com.apple.screencapture disable-shadow -bool true
defaults write com.apple.screencapture include-date -bool true
ok "screenshots → ~/Screenshots (png, no window shadow)"

# ══════════════════════════════════════════════════════════════════════════════
# Dock
# ══════════════════════════════════════════════════════════════════════════════
header "Dock"
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 0
defaults write com.apple.dock autohide-time-modifier -float 0.15
defaults write com.apple.dock tilesize -int 48
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock mru-spaces -bool false # don't reorder Spaces
defaults write com.apple.dock minimize-to-application -bool true
defaults write com.apple.dock show-process-indicators -bool true
ok "Dock: autohide (instant), no recents, stable Spaces"

# ══════════════════════════════════════════════════════════════════════════════
# UI / UX
# ══════════════════════════════════════════════════════════════════════════════
header "UI / UX"
# Expand save & print panels by default
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
defaults write NSGlobalDomain PMPrintingExpandedStateForPrint2 -bool true
# Save to disk (not iCloud) by default
defaults write NSGlobalDomain NSDocumentSaveNewDocumentsToCloud -bool false
# Snappier window resizing
defaults write NSGlobalDomain NSWindowResizeTime -float 0.001
# Keep the "Are you sure..." download-warning dialog enabled (LSQuarantine = true).
# This is NOT Gatekeeper quarantine — it's the per-app open confirmation.
# To silence it system-wide: -bool false  (reduces protection; prefer xattr -d per-file).
defaults write com.apple.LaunchServices LSQuarantine -bool true
# TextEdit: plain text, UTF-8
defaults write com.apple.TextEdit RichText -int 0
defaults write com.apple.TextEdit PlainTextEncoding -int 4
defaults write com.apple.TextEdit PlainTextEncodingForWrite -int 4
ok "panels expanded, save-to-disk, plain-text TextEdit"

# Reveal ~/Library (Apple hides it by default)
chflags nohidden "${HOME}/Library" 2>/dev/null || true
# shellcheck disable=SC2088  # "~/Library" here is human-readable display text, not a path
ok "~/Library revealed"

# ══════════════════════════════════════════════════════════════════════════════
# Security & privacy  (sensible defaults — review before trusting blindly)
# ══════════════════════════════════════════════════════════════════════════════
header "Security & privacy"
# Require password immediately after sleep or screensaver begins
defaults write com.apple.screensaver askForPassword -int 1
defaults write com.apple.screensaver askForPasswordDelay -int 0
ok "password required immediately on sleep/screensaver"

# ── Optional / weakens protections — uncomment deliberately ───────────────────
# As a security engineer you'll be downloading lots of unsigned tooling. The
# tweaks below reduce friction but ALSO reduce protection. Leave them OFF unless
# you understand the tradeoff and trust your sources.
#
# Disable Gatekeeper quarantine prompt on every downloaded tool (NEEDS sudo):
#   sudo spctl --master-disable        # <- broad; prefer per-app `xattr -d com.apple.quarantine <file>`
#
# Enable the application firewall (NEEDS sudo):
#   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate on
#   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --setstealthmode on
#
# Touch ID for sudo (survives updates via the *_local file on Sonoma+):
#   echo 'auth sufficient pam_tid.so' | sudo tee /etc/pam.d/sudo_local

# ══════════════════════════════════════════════════════════════════════════════
# Apply
# ══════════════════════════════════════════════════════════════════════════════
header "Applying"
for app in "Finder" "Dock" "SystemUIServer"; do
  killall "$app" >/dev/null 2>&1 || true
done
ok "Finder, Dock, SystemUIServer restarted"

# ── summary — mirror bootstrap.sh: a tally + a clear, single next-step ──────────
echo -e "\n${BLUE}${BOLD}==> summary${RESET}"
if ((DRY)); then
  echo -e "  ${GREEN}✓${RESET} dry run — ${n_sections} sections previewed, nothing changed"
  echo -e "  ${YELLOW}•${RESET} re-run without --dry-run to apply"
else
  echo -e "  ${GREEN}✓${RESET} ${n_groups} preference groups applied across ${n_sections} sections"
  echo -e "  ${YELLOW}•${RESET} some changes need a logout/restart to fully apply"
fi

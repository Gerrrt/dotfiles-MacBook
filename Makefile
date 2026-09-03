# Makefile — single source of truth for lint/format. Humans and CI run the SAME
# commands, so "passes locally" means "passes in CI".
#
# Scope: only repo-owned files. `core/` is a vendored git-subtree from
# dotfiles-core and is linted in THAT repo's CI — reformatting it here would
# fight the subtree. A non-blocking `core-advisory` target surfaces core/ findings
# without gating. See README "Development".
#
# Quick start:  make lint   (run everything)   |   make fmt   (auto-format)

SHELL := bash
.DEFAULT_GOAL := help

# Repo-owned bash scripts: every *.sh outside the vendored core/ subtree, plus the two
# bash entry points with NO .sh extension — sketchybar/sketchybarrc and borders/bordersrc.
# Each tool requires that exact filename, so the glob would miss them. Append them
# explicitly so shellcheck/shfmt/syntax cover them like any other repo-owned script.
SH_FILES := $(shell find . -name '*.sh' -not -path './core/*' -not -path './.git/*' | sort) sketchybar/sketchybarrc borders/bordersrc
SHFMT_FLAGS := -i 2

# Repo-owned zsh modules. These are the real behavioral surface of this repo, yet
# the .sh-only globs above never reach them (the entry files have NO extension).
# `zsh -n` parses each so a broken edit can't ship green. core/ zsh is gated in
# dotfiles-core's own CI.
ZSH_FILES := zsh/zshenv zsh/zprofile zsh/zshrc os/macos.zsh

# Repo-owned markdown. `git ls-files`, not a glob, for the same reason SH_FILES appends
# two extensionless names: the glob missed real files. `"*.md" "sketchybar/*.md"` is
# top-level-plus-one-directory, so the three .github/ templates were linted by NOTHING —
# ci.yml runs this very target, so the gap was the gate's too, not just the local run.
# The pathspec matches the one Core's reusable markdown leg uses, so this repo scans the
# same set as the rest of the fleet even though its gate is its own (dotfiles-core#775).
MD_FILES := $(shell git ls-files '*.md' ':!:core/**' 2>/dev/null)

.PHONY: help lint fmt fmt-check shellcheck syntax zsh-syntax check core-advisory capabilities\
        tools test test-repo bootstrap bootstrap-dry dry-run doctor sync-core \
        verify-core core-verify core-lock brew-check packages-check secrets config-check markdownlint pins-check \
        trap-guard skip-guards

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-15s\033[0m %s\n",$$1,$$2}'

lint: shellcheck fmt-check syntax zsh-syntax trap-guard config-check markdownlint secrets pins-check capabilities ## Run all gating checks (shell + format + syntax + trap discipline + configs + markdown + secrets + core pins)

shellcheck: ## Static analysis of repo-owned bash
	@shellcheck $(SH_FILES)

fmt-check: ## Verify formatting without writing (CI uses this)
	@shfmt $(SHFMT_FLAGS) -d $(SH_FILES)

fmt: ## Auto-format repo-owned bash in place
	@shfmt $(SHFMT_FLAGS) -w $(SH_FILES)

syntax: ## `bash -n` syntax gate on every repo-owned script
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done
	@echo "syntax ok:"; printf '  %s\n' $(SH_FILES)

# ONE RECIPE LINE, DELIBERATELY — do not split the guard from the work. Every line of a
# make recipe runs in its OWN shell, so a guard that ends in `exit 0` exits only ITS line;
# make reads that as success and runs the next line, calling the very tool just reported
# missing. That is #156: all three of these printed "skip …" and then failed anyway, so
# `make lint` could not pass on a box without gitleaks, zsh or npx — the exact boxes the
# guards exist for. (`brew-check` escaped it only because its guard uses `exit 1`, which
# fails the line and aborts the target.) test/check-skip-guards.sh pins this.
zsh-syntax: ## `zsh -n` syntax gate on repo-owned zsh modules (skips if zsh absent)
	@if ! command -v zsh >/dev/null 2>&1; then echo "  skip zsh-syntax (zsh not installed)"; exit 0; fi; \
	 for f in $(ZSH_FILES); do zsh -n "$$f" || exit 1; done; \
	 echo "zsh syntax ok:"; printf '  %s\n' $(ZSH_FILES)

# Repo-owned secret scan. Core's audit runs gitleaks over core/ ONLY, so this repo's own
# tree — Brewfile, os/, zsh/, ssh/os.conf, sketchybar/, macos/defaults.sh — was never
# scanned by anything. GitHub push protection was the only net, and it only fires after
# you try to push. Version is pinned in the vendored core/scripts/tool-versions.env
# (GITLEAKS_VERSION/GITLEAKS_SHA256); CI installs that exact build via setup-core-tools.
# Self-skips when gitleaks is absent so `make lint` still works on a bare box.
secrets: ## Scan the working tree for committed secrets (gitleaks; skips if not installed)
	@# One recipe line — see the note above zsh-syntax (#156).
	@# -c core/gitleaks.toml — ONE POLICY FILE, Core's, the rule Core's own reusable
	@# lint-call.yml secrets leg states: every repo measured the same way, no repo widening
	@# its own allowlist. The stock rule set is not stricter, it is differently wrong —
	@# several defaults match on credential-shaped POSITION rather than content
	@# (curl-auth-user fires on anything after `curl -u`), so a variable reference, which is
	@# the SECURE shape because the value never enters the file, was reported as a leak.
	@# Concretely: vendored core/CHANGELOG.md documents that allowlist and quotes the example
	@# it was written for, so the stock scan flagged Core's explanation of the rule as a
	@# violation of it and this target went red on a sync carrying no credential.
	@# Not a blinding — the allowlist is scoped to the matched VALUE, not a path, rule or
	@# repo. Verified both ways with the pinned 8.30.1: the variable-reference form passes,
	@# a literal `curl -sk -u admin:<value>` in the same position still fails.
	@if ! command -v gitleaks >/dev/null 2>&1; then echo "  skip secrets (gitleaks not installed — brew bundle)"; exit 0; fi; \
	 gitleaks dir . -c core/gitleaks.toml --no-banner --redact

# Parse-gate the JSON/JSONC/TOML the macOS desktop layer is made of. Nothing checked these
# before: a malformed karabiner.json or aerospace.toml passed every gate and only failed on
# the next fresh install, silently killing the keyboard remap or the tiling WM.
trap-guard: ## Refuse a RETURN trap that does not disarm itself (shellcheck cannot see this)
	@# A bash RETURN trap is a GLOBAL slot, not a function-scoped one: armed inside a
	@# function it survives into the CALLER's frame and fires again on ITS return, where
	@# the local it cleans up is gone and `set -u` kills the script. Valid bash, so
	@# shellcheck and `bash -n` both pass it — hence a dedicated scan. The rule itself is
	@# the VENDORED _core_return_trap_hits, not a copy: see the script's header, #154.
	@./test/check-return-traps.sh $(SH_FILES)

skip-guards: ## Assert the "skips if not installed" targets actually skip (regression gate for #156)
	@./test/check-skip-guards.sh

config-check: ## Parse every repo-owned .json/.jsonc/.toml (karabiner, aerospace, fastfetch, renovate)
	@./test/check-configs.sh

# .markdownlint.jsonc existed but NOTHING ran it — 55 lines of dead config next to a 52 KB
# guide. markdownlint-cli2 is npm-only (no single binary to SHA-pin like the others), so it
# is version-pinned from the vendored tool-versions.env and run through npx. Self-skips
# without node so `make lint` still works on a bare box.
markdownlint: ## Lint repo-owned markdown against .markdownlint.jsonc (skips without node)
	@# One recipe line — see the note above zsh-syntax (#156).
	@if ! command -v npx >/dev/null 2>&1; then echo "  skip markdownlint (node/npx not installed)"; exit 0; fi; \
	 if [ -z "$(MD_FILES)" ]; then echo "  no repo-owned .md"; exit 0; fi; \
	 v="$$(sed -n 's/^MARKDOWNLINT_VERSION=//p' core/scripts/tool-versions.env | head -n1)"; \
	 npx --yes "markdownlint-cli2@$${v:-latest}" $(MD_FILES) >/dev/null \
	   && echo "  markdownlint ok ($(words $(MD_FILES)) files)" \
	   || { npx --yes "markdownlint-cli2@$${v:-latest}" $(MD_FILES); exit 1; }

core-advisory: ## Non-blocking shellcheck over vendored core/ (fixes land upstream)
	@shellcheck $$(find core -name '*.sh') || \
	  echo "(advisory) core/ findings above are fixed upstream in dotfiles-core"

# The THIRD reference to a Core commit. core-integrity and verify-core gate the subtree
# and core.lock; nothing gated the workflow pins, so a sync could advance the tree while
# the callers kept running the PREVIOUS Core's reusables — with every gate green. The
# auto-tag caller holds `contents: write`, so that is not cosmetic.
pins-check: ## Assert the reusable-workflow SHA pins equal core.lock's core_sha
	@./test/check-pins.sh

verify-core: ## Assert vendored core/ is byte-for-byte upstream @ the recorded subtree-split (catches hand-edits + orphans the dir-level manifest misses)
	@./test/verify-core.sh

# The output MUST stay byte-identical to what dotfiles-core's sync-core.sh writes, because
# that is what every other consumer reads: core-integrity.sh parses `core_tag`, and
# fleet-drift.sh reports `core_version`/`core_sha`/`core_tag` per repo. This recipe used to
# emit a DIFFERENT header and drop `core_tag` entirely — so running it (which the sync-core
# help text below tells you to do after a manual pull) silently downgraded the lock and
# produced a spurious diff against the automated writer.
#
# `core_branch` legitimately holds a SHA: the fan-out sets CORE_BRANCH=<target sha> so the
# lock records exactly what was vendored, not a moving branch name. Preserved from the
# existing lock unless CORE_BRANCH overrides it.
#
# `core_tag` is emitted as v<core.version> when core.version is a well-formed X.Y.Z, which
# is Core's release-tag convention. Vendoring an UNTAGGED Core (a pre-release SHA) is the
# one case this cannot know about — drop the line by hand there, matching sync-core.sh,
# which only emits it once Core actually carries a tag.
core-lock: ## Explain why core.lock is NOT regenerated here (it is written by Core's fan-out)
	@echo "  core.lock is not regenerated in this repo."
	@echo
	@echo "  Its format is owned by scripts/sync-core.sh in dotfiles-core, which stamps it in"
	@echo "  the SAME commit as the subtree pull. A second generator here cannot be kept in"
	@echo "  step with it (dotgibson/dotfiles-core#593). This one:"
	@echo
	@echo "    * re-derived core_sha by parsing the git-subtree-split trailer — the exact"
	@echo "      lookup core.lock exists so nobody has to do, and which breaks if the squash"
	@echo "      commit format ever changes;"
	@echo "    * carried core_branch forward by reading the previous lock, so a wrong value"
	@echo "      once written was preserved rather than corrected;"
	@echo "    * re-emitted the 'Regenerate ... with: make core-lock' header line that Core"
	@echo "      removed in #454;"
	@echo "    * predates #453, which renamed the field to core_ref."
	@echo
	@echo "  If core/ and core.lock disagree, re-run the fan-out from a dotfiles-core"
	@echo "  checkout rather than patching the lock here:"
	@echo
	@echo "      make sync            # in dotfiles-core"
	@echo
	@echo "  Then check this repo with:  make verify-core"


# The Core-authoring `test`, `test-all`, `bench` and `core-audit` are GONE
# (dotfiles-core#676) — NOT to be confused with the fleet-canonical `test` further down,
# which is a thin alias for this repo's OWN suite (test-repo). The removed ones ran
# Core's own authoring tooling — audit-core.sh, test-core.sh, bench-core.sh — out of the
# vendored subtree, and Core stopped vendoring it: a vendored core/ is now core.manifest +
# core.vendor, and that tooling is in neither.
#
# Nothing is actually lost. They ran on ubuntu-latest, so they were never macOS-hardware
# coverage — they were a second Linux run of the exact suites dotfiles-core's own CI runs
# on the same tree, before it was ever vendored here. Keeping them would have meant Core
# shipping most of scripts/ (test-core.sh alone is 833 KB) into all nine repos to serve one.
#
# What still gates the subtree HERE, and gates it better: `make verify-core` diffs core/
# byte-for-byte against the vendored subset of upstream at the recorded commit, so drift,
# orphans and omissions are all caught against the source of truth rather than against
# core/'s own internal consistency.

# skip-guards is a prerequisite here, NOT in `lint`: it drives `make` itself, and nesting a
# recursive make inside the lint graph is both surprising and slow. It is a behavioural
# assertion about the Makefile, so it belongs with the behavioural tests.
test-repo: skip-guards ## Run THIS repo's behavioral tests (bootstrap.sh, zsh loader, defaults.sh)
	@./test/test-repo.sh

brew-check: ## Verify every Brewfile formula/cask is installed (the reproducibility gate; run on macOS)
	@command -v brew >/dev/null 2>&1 || { echo "  brew not found — run this on macOS"; exit 1; }
	@brew bundle check --file=Brewfile --verbose

bootstrap: ## Install: symlinks + Homebrew + brew bundle (macOS)
	@./bootstrap.sh

bootstrap-dry: ## Preview the installer plan (symlinks); change nothing
	@./bootstrap.sh --links-only --dry-run

doctor: ## Show what bootstrap would change + verify the lint toolchain
	@./bootstrap.sh --links-only --dry-run || true
	@$(MAKE) -s tools || true

sync-core: ## Reminder: how the vendored Core subtree gets updated
	@echo "  Normally nothing to run: a dotfiles-core release opens a sync PR here"
	@echo "  automatically (sync-fanout.yml). Merge it, then:"
	@echo "    ./bootstrap.sh --links-only   # re-wire any new/changed Core files"
	@echo "    make test-repo                # prove the new Core still loads (exercises the loader)"
	@echo "  Do NOT pull the subtree by hand: that moves core/ but not core.lock, and"
	@echo "  core-integrity then reports the fresh subtree as TAMPERED. There is no local"
	@echo "  fix for that — core.lock is written by sync-core.sh in dotfiles-core, in the"
	@echo "  same commit as the pull (dotgibson/dotfiles-core#593). Re-run the fan-out:"
	@echo "    make sync                     # in a dotfiles-core checkout"

check: lint ## Alias for `lint`

# ── the fleet make vocabulary (dotfiles-core#691, audited by #846 §5h) ─────────
# Core declares ONE canonical verb set every vendoring repo must answer to —
# help lint check dry-run packages-check core-verify test — so a fleet-wide
# `make <verb>` resolves in every repo no matter each repo's historical spelling.
# This repo already did the work under its own names; the four below are thin
# `.PHONY` aliases to the canonical spelling, in the same shape as `check: lint`
# above (the old names keep working — they are the recipe holders). None is a
# stub: this repo genuinely does each — it ships a Brewfile (packages-check), a
# vendored subtree (core-verify) and its own behavioral suite (test). Verify with
# `make fleet-vocabulary` from a Core checkout; this repo's register row turns
# all-`ok`. See VENDORING.md § "The `make` vocabulary, and the test floor" in Core.
dry-run: bootstrap-dry ## Alias for `bootstrap-dry` (fleet-canonical verb)
packages-check: brew-check ## Alias for `brew-check` (fleet-canonical verb)
core-verify: verify-core ## Alias for `verify-core` (fleet-canonical verb)
test: test-repo ## Alias for `test-repo` (fleet-canonical verb; runs the suite)

tools: ## Verify the lint toolchain is installed
	@for t in shellcheck shfmt; do \
	  command -v $$t >/dev/null && echo "  ok  $$t" \
	    || { echo "  MISSING $$t — run: brew bundle (or see Brewfile 'Dev: lint & format')"; exit 1; }; \
	done

# ── the OS capability declaration (Core v5, #663/#667) ────────────────────────
# ONE definition of the schema gates all seven declaring repos: the validator is
# core/scripts/check-capabilities.sh, vendored with Core, so a schema change arrives
# with the next sync instead of needing seven hand-written greps to be updated in
# step. Core's own `make audit` runs the same script over its shipped example and
# sweeps the fleet for these files; this is the local half of that gate.
#
# The glob is guarded because an unmatched glob stays LITERAL in sh — without the
# test this would "validate" a file named `os/*.capabilities` and pass on nothing,
# which is the failure mode a gate must never have.
capabilities: ## Validate os/*.capabilities against Core's schema
	@rc=0; found=0; \
	for f in os/*.capabilities; do \
	  [ -e "$$f" ] || continue; found=1; \
	  core/scripts/check-capabilities.sh "$$f" || rc=1; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "!! no os/*.capabilities — this repo must declare one (see core/examples/os.capabilities.example)"; rc=1; fi; \
	exit $$rc

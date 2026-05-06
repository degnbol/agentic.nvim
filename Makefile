# Default tools; override like: make NVIM=/opt/homebrew/bin/nvim
NVIM     ?= nvim
LUALS    ?= $(shell which lua-language-server 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/lua-language-server")
SELENE   ?= $(shell which selene 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/selene")
STYLUA   ?= $(shell which stylua 2>/dev/null || echo "$(HOME)/.local/share/nvim/mason/bin/stylua")

PROJECT ?= .
LOGDIR  ?= .luals-log

.PHONY: luals selene selene-file format-check format format-file check test validate install-git-hooks

# Each test file runs in a fresh nvim process so module-level state, stubs,
# autocmds, and `vim.schedule`-queued callbacks cannot leak between files.
# mini.test schedules every case via `vim.schedule`, so a `vim.wait` in one
# test pumps the loop and lets queued cases from other files run mid-test —
# breaking isolation. Per-file processes prevent that.
#
# tests/init.lua additionally strips `$XDG_CONFIG_HOME/nvim` from rtp to keep
# the user's outer nvim config out of the test environment, while leaving
# other tools (git's core.excludesFile, etc.) intact.
TEST_FILES := $(shell find lua -name "*.test.lua") $(shell find tests -name "*_test.lua" -o -name "test_*.lua" 2>/dev/null)

test:
	@rc=0; for f in $(TEST_FILES); do \
		echo "=== $$f ==="; \
		$(NVIM) --headless -u tests/init.lua -c "lua require('tests.runner').run_file('$$f')" || rc=1; \
	done; \
	exit $$rc

test-verbose: test

test-file:
	$(NVIM) --headless -u tests/init.lua -c "lua require('tests.runner').run_file('$(FILE)')"

# Lua Language Server headless diagnosis report
luals:
	@VIMRUNTIME=$$($(NVIM) --headless -c 'echo $$VIMRUNTIME' -c q 2>&1); \
	if [ -z "$$VIMRUNTIME" ]; then \
		echo "Error: Could not determine VIMRUNTIME. Check that '$(NVIM)' is on PATH and runnable" >&2; \
		exit 1; \
	fi; \
	for dir in $(PROJECT); do \
		echo "Checking $$dir..."; \
		VIMRUNTIME="$$VIMRUNTIME" "$(LUALS)" --check "$$dir" --checklevel=Warning --configpath="$(CURDIR)/.luarc.json" || exit 1; \
	done

# Selene linter
selene:
	"$(SELENE)" .

# Selene a specific file
selene-file:
	"$(SELENE)" "$(FILE)"

# StyLua formatting check
format-check:
	"$(STYLUA)" --check .

# StyLua formatting (apply)
format:
	"$(STYLUA)" .

# Format a specific file
format-file:
	"$(STYLUA)" "$(FILE)"

# Convenience aggregator, NOT to be used in the CI
check: format-check luals selene

# Run all validations with output redirection for AI agents
validate:
	@mkdir -p .local; \
	total_start=$$(date +%s); \
	start=$$(date +%s); \
	make luals > .local/agentic_luals_output.log 2>&1; \
	rc_luals=$$?; \
	echo "luals: $$rc_luals (took $$(($$(date +%s) - start))s) - log: .local/agentic_luals_output.log"; \
	start=$$(date +%s); \
	make selene > .local/agentic_selene_output.log 2>&1; \
	rc_selene=$$?; \
	echo "selene: $$rc_selene (took $$(($$(date +%s) - start))s) - log: .local/agentic_selene_output.log"; \
	start=$$(date +%s); \
	make test > .local/agentic_test_output.log 2>&1; \
	rc_test=$$?; \
	echo "test: $$rc_test (took $$(($$(date +%s) - start))s) - log: .local/agentic_test_output.log"; \
	echo "Total: $$(($$(date +%s) - total_start))s"; \
	if [ $$rc_luals -ne 0 ] || [ $$rc_selene -ne 0 ] || [ $$rc_test -ne 0 ]; then \
		echo "Validation failed! Check log files for details."; \
		exit 1; \
	fi

# Install pre-commit hook that blocks the commit until `make validate` passes.
# Uses `git rev-parse --git-path` so it works for both regular repos and
# submodules (where .git is a file, not a directory).
install-git-hooks:
	@HOOK=$$(git rev-parse --git-path hooks/pre-commit); \
	mkdir -p "$$(dirname "$$HOOK")"; \
	printf '%s\n' \
		'#!/bin/sh' \
		'cd "$$(git rev-parse --show-toplevel)" || exit 1' \
		'exec make validate' \
		> "$$HOOK"; \
	chmod +x "$$HOOK"; \
	echo "Pre-commit hook installed at $$HOOK"

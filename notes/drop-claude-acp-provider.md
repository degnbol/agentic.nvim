# Drop the `claude-acp` provider

## Goal

Remove the `claude-acp` provider entirely. It is a superseded predecessor:
Zed renamed the `claude-code-acp` bridge to `claude-agent-acp` (this repo moved
to it in the commit "Move to the renamed claude-agent-acp"). Both run Claude
Code and emit identical output, so `claude-acp` carries no capability
`claude-agent-acp` lacks. It is not installed locally (`claude-code-acp` is
absent; only `claude-agent-acp` is on PATH), and this is an independent hard
fork with no upstream-parity reason to keep it.

This is **separate** from the hook-blocked-rendering plan
(`notes/agentic-hook-blocked-rendering.md`), which stays scoped to
`claude-agent-acp` regardless.

## Scope of references

8 files mention `claude-acp` / `claude-code-acp` / `ClaudeACPAdapter`. Two
categories: real wiring (delete) and shared/incidental (edit a line).

### Delete

- **`lua/agentic/acp/adapters/claude_acp_adapter.lua`** — delete the file. No
  dedicated test file exists. It overrides only `__handle_tool_call`.

### Edit — provider wiring

- **`lua/agentic/acp/agent_instance.lua`** — remove the
  `if provider_name == "claude-acp" then ... ClaudeACPAdapter ...` dispatch
  branch (the `elseif provider_name == "claude-agent-acp"` becomes the leading
  `if`).
- **`lua/agentic/config_default.lua`** — remove the `"claude-acp"` entry from
  the `@alias` provider-name union (the `--- | "claude-acp"` line) and the
  `["claude-acp"] = { command = "claude-code-acp" }` entry from `acp_providers`.
- **`lua/agentic/session_recovery.lua`** — in `is_claude_provider()`, drop the
  `Config.provider == "claude-acp"` disjunct; keep the `claude-agent-acp` check.

### Edit — comments / docs (cosmetic)

- **`lua/agentic/acp/adapters/claude_utils.lua`** — header comment says
  "helpers for Claude ACP adapters (claude_acp + claude_agent_acp)". This module
  **stays** (shared by `claude-agent-acp`). Update the comment to drop the
  `claude_acp` mention.
- **`lua/agentic/ui/permission_manager.lua`** — a comment lists providers using
  `file_path` snake_case ("claude-agent-acp, claude-acp, auggie-acp"). Remove
  `claude-acp` from the list.
- **`doc/agentic.txt`** — the providers table line
  `` `claude-code-acp`     Claude (alternative) ``. Remove it.

### Edit — tests (the real work)

- **`lua/agentic/session_registry.test.lua`** — 26 references. `claude-acp` is
  used here as a **generic sample provider** in fixtures and provider-switch
  label assertions, **not** to test claude-acp-specific behaviour. Retarget each
  to a surviving provider:
  - Claude-themed fixtures (`provider = "claude-acp"`,
    `["claude-acp"] = { command = "claude-code-acp" }`) →
    `claude-agent-acp` / `command = "claude-agent-acp"`.
  - Cases that need **two distinct providers** for switch-picker label tests
    (currently `{ "claude-acp", "gemini-acp" }`) → keep two distinct names,
    e.g. `{ "claude-agent-acp", "gemini-acp" }`. Update the corresponding
    `assert.equal("claude-acp ...", ...)` label expectations to the new name.
  - Verify no test asserts on the literal string `claude-code-acp` as a command
    in a way that now has no provider.

## Risks / things to verify

- **`claude_utils.lua` must NOT be deleted** — it is shared; `claude-agent-acp`
  depends on `suppress_placeholder_title`, `mode_switch_label`,
  `rewrite_grep_to_rg`. Only its header comment changes.
- **Provider picker / switch flow** — confirm `switch_provider` enumerates from
  `acp_providers` keys, so removing the config entry automatically drops it from
  the picker (no hardcoded list elsewhere). Grep for any other place that lists
  providers literally.
- **Session restore of an old `claude-acp` session** — a persisted session whose
  JSON records `provider = "claude-acp"` would no longer resolve to an adapter.
  Decide: acceptable (the provider is gone), or add a one-line alias/migration
  mapping `claude-acp` → `claude-agent-acp` at load. Given the hard-fork stance
  and that the bridges are equivalent, a silent remap is reasonable but optional
  — flag for the user.

## Validation

`make validate` after the edits (luals + selene + tests). The test file is the
likely failure point — read `.local/agentic_test_output.log` with `tail`/`rg` on
failure. All `session_registry.test.lua` cases must pass with the retargeted
provider names.

## Out of scope

- The hook-blocked-rendering feature (separate plan).
- Removing the `CLAUDE.md` "Fork of carlos-algms/agentic.nvim" framing — related
  to the same hard-fork decision but a doc change, handle separately.

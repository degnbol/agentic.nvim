# Plan: Claude allowed_tools
Status: reviewed

## Relevant files
- `lua/agentic/config_default.lua` (`acp_providers["claude-agent-acp"]` `:102-107`)
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua` (+ test): `build_claude_options` and `session_meta`
- `lua/agentic/acp/acp_transport.lua:24` (`IGNORE_STDERR_PATTERNS`)
- `doc/agentic.txt` (provider fields `:125-137`)
- Rule: `.claude/rules/provider-specific.md`
- Uses `permissions.auto_approve_kinds` (`lua/agentic/config_default.lua`).
- Skill: `permissions` (§ "1. Approved kinds")
- Bundled CLI: `…/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude`
- Bridge 0.97.0: `…/claude-agent-acp/dist/acp-agent.js:8749` (`userProvidedOptions`), `:8868` (spread into the SDK options)

## Background
The Claude Code CLI has an "embedded search" mode. When it is on, the CLI:
- removes the Grep and Glob tools from the agent's tool list;
- defines the shell functions `find` → bundled `bfs` and `grep` → bundled `ugrep` in the Bash tool;
- tells the agent in the system prompt to search with `find` and `grep`.

Both the bridge's CLI and the standalone CLI 2.1.310 have the same gate:

```js
function NT(){if(!Ne("true"))return!1;if(qrs())return!1;return i.CLAUDE_CODE_ENTRYPOINT!=="local-agent"}
```

- **The build fixes the switch on.** The `EMBEDDED_SEARCH_TOOLS` value was fixed to `"true"` when the CLI was built, so setting that environment variable at runtime does nothing.
- **The SDK sets the entrypoint.** `CLAUDE_CODE_ENTRYPOINT` is `sdk-ts`, so the entrypoint condition never turns the gate off.
- **`qrs()` is the only switch.** It returns the launch option `searchToolsOptIn`. At startup, the CLI sets it to true when one of these names `Glob` or `Grep`:
  - the `--tools` list, written out by name (the bridge's default preset `claude_code` doesn't count);
  - a rule in `--allowedTools`.
- **The opt-in also removes the shell functions.** The function that writes the `find`/`grep` wrappers (`Fvr`) has the same `NT()` gate.
- **Naming either tool brings back both.** The opt-in is a `.some` check over Glob and Grep, so a rule for one restores both tools. Only the tool that is named is approved.
- **The todo tools have the same opt-in.** A rule that names TodoWrite or a Task* tool turns the todo tools on, even when `todo_tools = false`.

The bridge passes `allowedTools` from `_meta.claudeCode.options` to the SDK, and the SDK passes it to the CLI as `--allowedTools`. The SDK sends no flag for an empty list (`sdk.mjs:157`).

**Why a list, not a bool:** a list maps one-to-one onto the CLI option and needs no special-case code. With the default `{ "Grep", "Glob" }`, both tools come back.

**Bare rules skip the plugin's permission checks.** The SDK approves a tool named by a bare rule before it calls `canUseTool`, so the request never reaches `PermissionManager`. For the default list that changes nothing, because `auto_approve_kinds` (default includes `search`) already approves that kind. A user rule such as `Bash(git push:*)` also bypasses `/grant` and the prompt. The help text must say this.

**Harmless SDK warning.** For bare rules, the SDK prints a `CLAUDE_SDK_CAN_USE_TOOL_SHADOWED` warning to stderr once per `query()`. The plugin causes it on purpose, so it goes into `IGNORE_STDERR_PATTERNS`. Otherwise it lands in crash reports, and in the chat if a session is rebuilt during a turn.

## Changes

### `lua/agentic/config_default.lua`
In `acp_providers["claude-agent-acp"]`, add:
```lua
--- Claude Code `--allowedTools` permission rules. Naming Grep or Glob
--- is what gives the agent those tools; without them the CLI drops both
--- and the agent searches with `grep`/`find` in Bash.
allowed_tools = { "Grep", "Glob" },
```
A user list replaces the default, because `Object.deep_merge_into` (`lua/agentic/utils/object.lua:19`) replaces lists.

### `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua`
- `agentic.acp.ClaudeProviderConfig`: new `--- @field allowed_tools string[] Claude Code permission rules, sent as --allowedTools`.

### `build_claude_options` (in the Claude adapter)
- Add a parameter `allowed_tools string[]`. `session_meta` passes `self.provider_config.allowed_tools`. Add `allowedTools = allowed_tools` to the returned table and name the field in the docstring.

### `lua/agentic/acp/acp_transport.lua`
- Add `"CLAUDE_SDK_CAN_USE_TOOL_SHADOWED", -- from Claude, caused by allowed_tools` to `IGNORE_STDERR_PATTERNS`.

### Adapter test
- New test: "passes allowed_tools as allowedTools", which asserts that `options.allowedTools` equals the provider config's list.

### `doc/agentic.txt`
New field under the `claude-agent-acp` entry, `*agentic-config-allowed_tools*`:
- Claude Code permission rules, passed as `--allowedTools`. Default `{ "Grep", "Glob" }`.
- Naming `Grep` or `Glob` gives the agent both tools. Without them the CLI leaves both out.
- Naming TodoWrite or a Task* tool turns the todo tools on, whatever `todo_tools` is set to.
- A rule here approves inside the CLI, so the call never reaches the plugin's permission prompt, `auto_approve_kinds` or `/grant`. Removing `"search"` from `auto_approve_kinds` does not make Grep or Glob prompt while this list names them. The two settings stay independent; neither changes the other.


## Expected outcome
- New and loaded Claude sessions have the Grep and Glob tools.
- In Bash, `grep` and `find` are the user's own programs again, not the `ugrep`/`bfs` wrappers.
- `allowed_tools = {}` restores the current behaviour.
- With the default list and default `auto_approve_kinds`, permission prompts don't change.

## Non-goals
- Display changes for Grep/Glob tool calls.
- A `disallowedTools` or `tools` config entry.
- Deriving `allowed_tools` from `auto_approve_kinds`, or the reverse.

## Open questions
None. Decided (user, 2026-10-26): document the bypass in the help text; `allowed_tools` and `auto_approve_kinds` stay independent, low-level settings.

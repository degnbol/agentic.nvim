# claude-agent-acp SDK internals

Reference for provider-specific behaviour of `claude-agent-acp` (Zed's ACP
bridge wrapping `@anthropic-ai/claude-agent-sdk`). This documents SDK internals
that affect agentic.nvim — not the ACP protocol itself (see SKILL.md for that).

Installed at `/opt/homebrew/lib/node_modules/@zed-industries/claude-agent-acp/`.
Package renamed to `@agentclientprotocol/claude-agent-acp` from v0.24+.

## Architecture

```
claude-agent-acp (acp-agent.js)
  +-- ACP JSON-RPC transport (stdio) <-> agentic.nvim
  +-- @anthropic-ai/claude-agent-sdk (cli.js, sdk.mjs)
       +-- Tool implementations (Read, Write, Edit, Bash, Grep, Glob, etc.)
       +-- Permission system (checkPermissions, canUseTool)
       +-- Skills system (conditional/unconditional)
```

## Session creation via _meta passthrough

`session/new` and `session/load` accept `_meta.claudeCode.options` which is
spread into SDK options:

```js
const userProvidedOptions = params._meta?.claudeCode?.options;
const options = { ...userProvidedOptions, cwd: params.cwd, ... };
```

Known passthrough fields: `additionalDirectories`, `tools`, `env`,
`disallowedTools`, `hooks`, `mcpServers`, `permissionMode`, `maxThinkingTokens`.

Some fields are overridden after the spread: `cwd`, `includePartialMessages`,
`allowDangerouslySkipPermissions`, `canUseTool`, `executable`.

## fs/readTextFile and fs/writeTextFile — dead code

The ACP bridge defines `readTextFile()` and `writeTextFile()` methods that
forward to the client. However, **the underlying SDK never calls them**. The SDK
reads and writes files directly via `node:fs/promises`. The `clientCapabilities.
fs.readTextFile` and `fs.writeTextFile` flags have no effect on tool behaviour.

This means the client cannot intercept or override file I/O — the SDK handles
it internally, including path validation.

## Permission flow

Two-tier permission check:

1. **SDK internal** (per-tool `checkPermissions`): Checks settings.json rules
   (allow/deny/ask), working directory membership, path safety. Returns
   `allow`, `deny`, or `ask`.
2. **ACP bridge** (`canUseTool`): Only called when SDK returns `ask`. Sends
   `session/request_permission` to the client.

If `Read(**)` is in settings.json allow list, the SDK auto-approves reads
internally and `canUseTool` is never called. The client never sees a
`request_permission` for reads.

## Path resolution

The SDK's path resolver (`t4` in minified code):
- `~` and `~/...` expands to home directory
- Relative paths resolve against cwd (or explicit base)
- Absolute paths are normalised

## Known SDK bugs

### Conditional skills crash on out-of-cwd paths

The Read and Write tools call a conditional-skill-activation function
(`sG6`/`gN6` in minified code) that converts absolute paths to cwd-relative
via `path.relative(cwd, filePath)`. This produces `../../..` prefixes for paths
above cwd. The `ignore` npm library (used for glob matching) rejects these with:

```
path should be a `path.relative()`d string, but got "../../../foo"
```

This call is **outside** the tool's try/catch block, so the error propagates
as a tool failure. The bug triggers when:

1. **Any** skill with `paths` triggers exists — global (`~/.claude/skills/`)
   or project (`.claude/skills/`), AND
2. The file path is outside the working directory

Global skills count because the SDK loads all skills (user + project) into
the conditional skills map. Adding `paths` to a single global skill (e.g.
`claude` with `paths: "**/CLAUDE.md,**/.claude/**"`) breaks out-of-cwd file
operations across all projects.

If no conditional skills have path triggers, the function returns immediately
(no error). Confirmed still present in SDK 0.2.83 (function renamed to `gN6`).

**Not a workaround**: `additionalWorkingDirectories` does not help. The
`ignore` library call uses `path.relative(cwd, ...)` regardless.

**Upstream issues**: anthropics/claude-code#35298 (exact bug),
#37220 (plan files variant), #44238 (Windows variant).

**Fixed** in SDK 0.2.104 (bundled with claude-agent-acp 0.27.0). Earlier
versions (0.2.71, 0.2.83) are affected. Upgrade to claude-agent-acp >= 0.27.0.

### additionalWorkingDirectories from settings.json

The SDK reads `permissions.additionalDirectories` from settings.json (via
`settingSources: ("user", "project", "local")`). These directories are:

- Expanded (tilde to home)
- Added to `toolPermissionContext.additionalWorkingDirectories`
- Included in the system prompt
- Used for permission checks

They work correctly for permission checks (paths within additional dirs are
auto-allowed in default mode). They do NOT fix the conditional skills bug above
because that code path uses `path.relative(cwd, ...)` regardless of additional
directories.

### Edits are not applied before permission

The SDK does NOT write file edits to disk before sending `request_permission`.
Verified 2026-04-17 by inspecting disk contents while a pending Edit prompt
was open. Earlier client docs incorrectly claimed otherwise.

## Edit tool (`str_replace_based_edit_tool`)

The formal Anthropic API name is `str_replace_based_edit_tool`
(`text_editor_20250728` type). The April 2025 version note from the public docs
states the rename was "to reflect its str_replace-based architecture." The tool
is **string-based, not range-based** — no line numbers in the Edit payload.

**Input schema** (`FileEditInput` in `sdk-tools.d.ts`):
```ts
{ file_path: string, old_string: string, new_string: string, replace_all?: boolean }
```

**Uniqueness is a tool-level contract.** The tool fails when `old_string`
matches multiple locations and `replace_all` is false — error: `"matches of
the string to replace, but replace_all is false. To replace all occurrences,
set replace_all to true. To replace only one occurrence, please provide more
context to uniquely identify..."`. Clients do not need to enforce uniqueness
themselves; Claude will receive the error and retry with more context.

**`replace_all` is a Claude Code extension.** The pure Anthropic API tool does
not document it. The SDK's Zod schema adds it with default `false`.

**Output carries line ranges.** `FileEditOutput.structuredPatch` is an array
of unified-diff hunks with fields `oldStart`, `oldLines`, `newStart`,
`newLines`, `lines` (line numbers in post-edit file). Defined near the
`old_string`/`new_string` schema in `cli.js` as a Zod object with those five
fields.

**Client implication for provenance tracking:** `rawOutput.structuredPatch`
is the authoritative source for "where did Claude's edit land" — prefer it
over scanning for `diff.new` as a subsequence, which is ambiguous when the
new content coincides with other file text (e.g. short replacements like
`}`, `end`, blank lines). The ACP adapter currently records `diff.old` /
`diff.new` from `rawInput` only; if you need post-edit line ranges (e.g. for
auto-approval Claude-owned-range verification), capture `structuredPatch`
from the `tool_call_update` that carries `status: "completed"`.

**Sibling commands of the API tool** (not all exposed via Claude Code's
`edit` kind):
- `view` — takes `view_range` as `(start, end)` (1-indexed; `-1` = EOF).
- `insert` — takes `insert_line` (integer; line *after* which to insert,
  0 = BOF).
- `create` — takes `file_text` (whole-file write).
The Anthropic API `str_replace` is exposed via ACP as `kind: "edit"`;
`create` is exposed as `kind: "create"`; `view` is `kind: "read"`.

## ConfigOptions — `thought_level` not emitted

The ACP schema defines `SessionConfigOptionCategory` as `"mode" | "model" |
"thought_level" | string`, and the Anthropic SDK exposes per-model effort
capability with levels `low | medium | high | max`. The bridge does **not**
expose this to clients: `buildConfigOptions` in `dist/acp-agent.js:1250-1279`
returns a hardcoded array with only `mode` and `model` entries. `thought_level`
is reserved in the schema but never populated.

Confirmed in `@agentclientprotocol/claude-agent-acp` 0.29.0.

**Client implication:** The equivalent of the TUI's `/effort` command cannot be
offered as a runtime, ConfigOption-based selector until the bridge is extended
to emit a `thought_level` option. The plugin's `AgentConfigOptions` class
already dispatches on `category == "thought_level"`
(`lua/agentic/acp/agent_config_options.lua:80-81`) — the code path is simply
unreachable because the bridge never sends that category.

**`maxThinkingTokens` is not a drop-in replacement.** It is a
`_meta.claudeCode.options` passthrough spread into SDK options at session
creation only. There is no ACP method to change it mid-session, so offering
`/effort` backed by `maxThinkingTokens` would silently diverge from the TUI's
dynamic behaviour (the TUI changes effort mid-turn).

**Tracking:** No upstream issue filed. If emitted, the selector, keymap, and
header display would be a ~30-line addition mirroring the existing model
selector in `agent_config_options.lua`.

## Environment variables

| Variable | Effect |
|----------|--------|
| `CLAUDE_CODE_SIMPLE` | Disables skills, hooks, memory, CLAUDE.md loading, background jobs |
| `CLAUDE_CODE_DISABLE_CLAUDE_MDS` | Disables CLAUDE.md loading only |
| `CLAUDE_CODE_DISABLE_ATTACHMENTS` | Disables file attachments |

## settings.json paths

The SDK reads from these sources (in order, via `settingSources`):
- **user**: `~/.claude/settings.json`
- **project**: `{cwd}/.claude/settings.json`
- **local**: `{cwd}/.claude/settings.local.json`

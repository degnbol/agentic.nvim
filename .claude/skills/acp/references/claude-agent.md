# claude-agent-acp SDK internals

Reference for provider-specific behaviour of `claude-agent-acp` (Zed's ACP
bridge wrapping `@anthropic-ai/claude-agent-sdk`). This documents bridge/SDK
internals — not the ACP protocol itself (see SKILL.md for that).

> Some sections illustrate consequences with concrete file paths from the
> agentic.nvim plugin (e.g. `lua/agentic/...`). Treat those as concrete
> examples; the surrounding analysis applies to any ACP frontend.

## Source locations

- **claude-agent-acp bridge** (npm install, readable JS):
  `/opt/homebrew/lib/node_modules/@zed-industries/claude-agent-acp/dist/acp-agent.js`.
  Package renamed to `@agentclientprotocol/claude-agent-acp` from v0.24+.
- **claude-agent-sdk** is bundled inside the bridge — same path,
  `dist/` subtree. The SDK's own npm package
  (`@anthropic-ai/claude-agent-sdk`) is at `node_modules/@anthropic-ai/`.
- **Claude Code TUI source** (private + public): cloned at
  `~/Documents/agentic/claude/` with `claude-code-private/src/` (TUI source,
  including `services/`, `assistant/`, `bridge/`) and `claude-code-public/`
  (changelog, plugins, scripts). Useful for understanding TUI-only behaviour
  not visible through ACP.

## Architecture

```
claude-agent-acp (acp-agent.js)
  +-- ACP JSON-RPC transport (stdio) <-> client (e.g. agentic.nvim)
  +-- @anthropic-ai/claude-agent-sdk (cli.js, sdk.mjs)
       +-- Tool implementations (Read, Write, Edit, Bash, Grep, Glob, etc.)
       +-- Permission system (checkPermissions, canUseTool)
       +-- Skills system (conditional/unconditional)
```

## Probing advertised slash commands

The bridge's `getAvailableSlashCommands` (`dist/acp-agent.js`) filters the
SDK's command list through a hardcoded `UNSUPPORTED_COMMANDS` block list
(`cost`, `keybindings-help`, `login`, `logout`, `output-style:new`,
`release-notes`, `todos`) before emitting `available_commands_update`.
Many TUI commands (`/doctor`, `/mcp`, `/agents`, `/skills`, `/status`,
`/config`, `/bug`, `/stats`, `/usage`, `/memory`, `/hooks`, `/bashes`,
`/pr-comments`, `/vim`, `/ide`) are not advertised to ACP at all — the
SDK's `supportedCommands()` simply does not return them in this context.

To list what's actually forwarded in the current `claude-agent-acp`
version, pipe an `initialize` + `session/new` pair into the bridge and
parse the first `available_commands_update` notification:

```sh
{
  printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":false,"writeTextFile":false}}}}'
  sleep 0.8
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}'
  sleep 6
} | claude-agent-acp
```

Each line is a JSON-RPC message. The `available_commands_update` entry
contains `params.update.availableCommands` — a list of `{name,
description, input}` objects. Re-run after bumping the bridge to catch
newly added or removed commands.

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

## Prompt loop stall — silent notification loss with working permissions

Known failure mode where `agent_message_chunk` / `tool_call` /
`tool_call_update` silently fail to reach the client for one prompt turn,
while `session/request_permission` continues to work normally. All missing
content "flushes" on the *next* user-submitted prompt.

### Why this happens — control channel vs prompt-loop asymmetry

The bridge emits two kinds of outbound messages over the same stdio pipe:

1. **`session/request_permission`** is an ACP *request* (has an `id`,
   expects a response). It is triggered from the SDK's
   `handleControlRequest` code path — a side-channel handler that runs as
   part of `readMessages`, **independent** of whether anyone is iterating
   the prompt generator. Call path:
   `SDK control_request:can_use_tool` →
   `canUseTool` callback
   (`acp-agent.js:788, 865`) →
   `this.client.requestPermission(...)`.
2. **`session/update`** notifications (`agent_message_chunk`,
   `tool_call`, `tool_call_update`, `plan`, `usage_update`, …) are
   `sendNotification` calls emitted only *after* each
   `await session.query.next()` yields a message
   (`acp-agent.js:313` inside the `prompt()` loop).

Both funnel through the same `Connection.#sendMessage` write queue
(`acp.js:1146-1161` in the ACP SDK), so there is no write-side buffering
asymmetry. The asymmetry is purely at the trigger: permissions come from
the control channel; notifications come from the prompt generator.

**If `session.query.next()` never yields for that turn, zero
notifications flow even though permission requests still round-trip.**
That is the entire symptom profile.

### What can make the generator stall

The inner `claude` CLI subprocess (spawned by `query()` in
`@anthropic-ai/claude-agent-sdk`'s `ProcessTransport`) is *persistent*
across prompts for a session — `acp-agent.js:1126` creates
`session.query` once at session creation and holds it in
`sessions[sessionId]` (`:1189-1210`). It is only closed on substrings
like `"ProcessTransport"`, `"terminated process"`, or
`"process exited with"` in the error message (`:600-609`). Generic
`RequestError.internalError` thrown on e.g. a usage-limit result
(`:449-450`) does **not** close the generator — the bridge's `finally`
only resets `session.promptRunning = false` (`:615`).

Known stall triggers (upstream issues):

- [`agentclientprotocol/claude-agent-acp#551`](https://github.com/agentclientprotocol/claude-agent-acp/issues/551) —
  after a cancelled turn, the next prompt returns `end_turn` with
  zeroed usage and **no chunks**; the prompt after *that* delivers the
  response in full. Symptom-shape match.
- [`agentclientprotocol/claude-agent-acp#497`](https://github.com/agentclientprotocol/claude-agent-acp/issues/497) —
  `prompt()` blocks forever on `session.query.next()` when the binary
  stops emitting `session_state_changed(idle)`.
- [`anthropics/claude-code#33949`](https://github.com/anthropics/claude-code/issues/33949) —
  no SSE idle watchdog inside the CLI. TCP half-open (NAT drop,
  load-balancer idle close) leaves the CLI's upstream streaming call
  hung indefinitely. Would outlive any multi-hour idle.
- [`anthropics/anthropic-sdk-typescript#867`](https://github.com/anthropics/anthropic-sdk-typescript/issues/867) —
  `messages.stream()` has no idle timeout; `for await` blocks forever
  if the server stops sending events.

`keep_alive` messages over the SDK's inter-process channel **are**
silently dropped in the SDK reader — a keepalive exists but is not
observable from the bridge, so a stuck generator can't be detected
from outside without polling for response absence.

### Client implications

- **There is nothing in the client's MessageWriter / dispatch layer can
  do** — the bytes never leave the bridge. Tests that drive client-side
  layers in isolation cannot reproduce the production symptom.
- **Viable workarounds are upstream-level**: tear down and respawn the
  claude-agent-acp subprocess before attempting auto-continue (losing
  session state unless history is re-prepended for session restore).
- **Diagnostic from outside**: a stalled generator is indistinguishable
  from a slow-but-working one without timing heuristics. The
  subscriber sees no `session/update` between `session/prompt`
  send and response. A watchdog (e.g. "if no `session/update` within
  N seconds after `session/prompt`, assume stall") is possible but
  heuristic — no protocol-level signal.
- **Do not add client-side state resets ("redraw", reset turn state, etc.)
  as a "fix"** — these do not touch the bridge's stalled generator.

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

**Output carries line ranges — but not via ACP.** The SDK's
`FileEditOutput.structuredPatch` is an array of unified-diff hunks with
fields `oldStart`, `oldLines`, `newStart`, `newLines`, `lines`. Documented in
`sdk-tools.d.ts:2262-2288` and also visible in `cli.js` as a Zod object with
those five fields.

**But the ACP bridge does not forward it.** Verified 2026-04-20 by
instrumenting tool-call handling and triggering an Edit: `rawOutput` for a
completed Edit is a plain success string like
`"The file X has been updated successfully."` — no `structuredPatch`, no
`originalFile`, no line ranges. The SDK's tool result is flattened into a
human-readable text block by the time `acp-agent.js:1694` sets
`rawOutput: chunk.content`. The structured fields exist in the SDK but are
not reachable through ACP.

The completed `tool_call_update` for an Edit is minimal:
```lua
{
    _meta = { claudeCode = { toolName = "Edit" } },
    rawOutput = "The file ... has been updated successfully.",
    sessionUpdate = "tool_call_update",
    status = "completed",
    toolCallId = "toolu_...",
}
```

Note that `kind`, `rawInput`, `title`, `argument`, `diff` are all absent on
completed updates (only the initial `tool_call` carries them) — another
reason to track edit provenance from the accumulated tool-call state across
both phases.

**Client implication for provenance tracking.** If you need post-edit line
ranges, you must synthesise them client-side from the initial `tool_call`
payload: read the file at that moment (the SDK has NOT applied the edit
yet — see "Edits are not applied before permission"), find `diff.old` by
**unique** subsequence match (the tool enforces `old_string` uniqueness at
execution time, so a non-unique match here means file state we can't
reason about), and record the start line. On the matching
`tool_call_update` with `status: "completed"`, compute the post-edit range
as `{start, start + #diff.new - 1}`.

**Sibling commands of the API tool** (not all exposed via Claude Code's
`edit` kind):
- `view` — takes `view_range` as `(start, end)` (1-indexed; `-1` = EOF).
- `insert` — takes `insert_line` (integer; line *after* which to insert,
  0 = BOF).
- `create` — takes `file_text` (whole-file write).
The Anthropic API `str_replace` is exposed via ACP as `kind: "edit"`;
`create` is exposed as `kind: "create"`; `view` is `kind: "read"`.

## Search tools (`Grep`, `Glob`)

The Grep tool's `rawInput.command` is synthesised by the bridge as a
shell-form string with `grep` as the program name even though the
implementation is statically-linked ripgrep. Flags map 1:1 to rg flags
(`-A`, `-B`, `-C`, `--glob`, `--type`, `-U --multiline-dotall`), so the
emitted string is a valid rg invocation with the wrong program name. ACP
frontends rendering the command literally should rewrite a leading
`grep ` to `rg ` for accuracy and copy-pasteability. (See the claude
skill's `internals.md` for the rg-dispatch modes — `embedded`, `builtin`,
`system`.)

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
to emit a `thought_level` option.

**`maxThinkingTokens` is not a drop-in replacement.** It is a
`_meta.claudeCode.options` passthrough spread into SDK options at session
creation only. There is no ACP method to change it mid-session, so offering
`/effort` backed by `maxThinkingTokens` would silently diverge from the TUI's
dynamic behaviour (the TUI changes effort mid-turn).

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

## Path-scoped rules (`.claude/rules/*.md`) — empirically broken under ACP

For loading mechanism details, see the global `claude` skill,
`references/internals.md` § "Memory and rule loading". Summary:
`paths`-conditional rule files are designed to load when Claude Reads
a file matching the rule's glob inside cwd. The `FileReadTool` adds
the read path to `nestedMemoryAttachmentTriggers`; the trigger is
consumed in the mid-turn agent loop (`query.ts:1580`), attaching the
rule content same-turn.

**Source-level equivalence between TUI and SDK:** the bridge spawns
the SDK CLI with `--print --input-format stream-json`. That subprocess
goes through `cli/print.ts:2147` → `ask()` → `QueryEngine.submitMessage`,
which builds a `toolUseContext` with the same fresh
`nestedMemoryAttachmentTriggers: new Set()` field as the TUI's
`REPL.tsx:2480`. The bundled SDK
(`@anthropic-ai/claude-agent-sdk/cli.js`) contains the full trigger
pipeline (`processConditionedMdRules`, `nestedMemoryAttachmentTriggers`,
`loadedNestedMemoryPaths` all present). The bridge sets
`settingSources: ["user", "project", "local"]` (`acp-agent.js:1056`),
which satisfies the `isSettingSourceEnabled('userSettings')` gate in
`claudemd.ts:1223`.

**Empirical finding (2026-05-15):** despite that source-level
equivalence, user testing with `~/.claude/rules/writing-docs.md`
(`paths: "**/*.md"`) under agentic.nvim + claude-agent-acp did not
deliver the rule content to the model after a Read of a markdown
file inside cwd. Verified semantically (asking the model to quote a
unique phrase from the rule, the model could only list system-prompt
content). Whether the TUI succeeds on the same rule has not yet been
tested side-by-side; the gap remains unexplained.

**Test protocol to bisect** (TUI vs ACP):

1. Add a unique sentinel string to a user rule (e.g.
   `SENTINEL-X9: only present in writing-docs.md`).
2. Add a unique sentinel to a subdir CLAUDE.md
   (`some/subdir/CLAUDE.md`) — exercises the same trigger pipeline
   via a different code branch (nested CLAUDE.md walk rather than
   conditional-rule glob match).
3. Fresh session in the project. Prompt: "Use the Read tool to read
   `some/subdir/<file>.md`."
4. Prompt: "Quote the SENTINEL line exactly if you see it."
5. Repeat in TUI and via agentic.nvim ACP. Record:
   - quoted / did not quote, for the rule sentinel
   - quoted / did not quote, for the subdir CLAUDE.md sentinel

Outcome interpretation:

| TUI rule | ACP rule | TUI claude.md | ACP claude.md | Diagnosis |
|---|---|---|---|---|
| ✓ | ✓ | ✓ | ✓ | Mechanism works; the earlier "no" was self-report noise. |
| ✓ | ✗ | ✓ | ✗ | ACP regression of the full trigger pipeline (rule and CLAUDE.md both). |
| ✓ | ✗ | ✓ | ✓ | ACP regression of the rule subsystem only. |
| ✗ | * | ✗ | * | TUI doesn't fire either — invalid test setup or source-trace gap. |

**Until empirically clarified:** treat path-scoped user rules as
**not reliably delivered through ACP**. For content that must reach
an ACP session, prefer:
- skills (loaded via the Skill tool, supported by SDK)
- CLAUDE.md at project root (eager-loaded by SDK regardless of path
  triggers)
- in-prompt @-mentions of the rule file

A separate option is client-side reimplementation in agentic.nvim:
watch tool-call events for Reads, match against `~/.claude/rules/*.md`
frontmatter globs, inject matching content as system reminders. This
would also extend the mechanism to non-Claude providers (Codex,
Gemini, opencode, Mistral) which inherit nothing from the Claude
config. See agentic.nvim `TODO.md` for the feature entry.

# Feature: gutter identity for the agent-orchestration tools

## Problem

Claude Code's own orchestration tools — tool search, inter-agent messaging,
background-task control, cron, MCP — all reach the chat as ACP kind `other` and
render the 󰒓 gear. The bridge has no display formatter for any of them, so
`toolInfoFromToolUse` takes its default branch (`dist/tools.js`: `title: name ||
"Unknown Tool", kind: "other"`) and the head repeats the bare tool name beside a
glyph that says nothing.

A survey of the session cache (93 projects, every persisted `tool_call`) found
32 distinct `other` arguments; after subtracting what `a809b95` already fixed,
what is left is one coherent family.

Glyph vocabulary rules and the sign-column rule this extends are in
[PLAN-gutter-identity.md](PLAN-gutter-identity.md).

## What the cache shows

All-time count / count in sessions started since the 2026-09-11 name-dispatch
fix. Both columns are *initial* `tool_call` state — `_on_tool_call_update`
persists neither `kind` nor `argument`, which is also the state the dispatch
below fires on.

| Tool | Count | Head field in `rawInput` |
| --- | --- | --- |
| `ToolSearch` | 433 / 12 | `query` |
| `mcp__*` (4 servers) | 53 / 7 | — (parsed from the name) |
| `SendMessage` | 32 / 7 | `to`, `summary` |
| `Monitor` | 9 / 0 | `description` |
| `TaskStop` | 9 / 0 | `task_id` (optional) |
| `TaskOutput` | 5 / 0 | `task_id` |
| `ScheduleWakeup` | 5 / 0 | `reason` |
| `ListAgents` | 5 / 2 | — |
| `CronCreate` | 1 / 0 | `cron` |
| `CronDelete` | 1 / 0 | — (`CronDeleteInput` is `{ id }`, no `cron`) |

`CronList` is unobserved but free to cover — same family, same empty input as
`ListAgents`.

`TaskCreate`, `TaskUpdate`, `TaskGet` and `TaskList` are **not** coverable and
must stay out of the table. `shouldEmitToolCall` (`dist/acp-agent.js:7500`)
suppresses them by name: their tool_use is surfaced as a `plan` snapshot, never
as a `tool_call`. Their absence from the survey is structural, not chance — and
it is also why only `TaskStop` and `TaskOutput` appear, since neither is in
`isTaskTool`.

Deliberately excluded: `RemoteTrigger`, `PushNotification`, `ReportFindings`,
`ShareOnboardingGuide`, `LSP`, `ListMcpResources*`. One sighting between them,
no shared family, and each would need a glyph of its own — they stay on the
gear until something makes them worth a row in the vocabulary.

## Changes

### Mint the kind and the name-derived head, before the rawInput gate

`claude_utils.lua` owns the mapping, in one place and one representation:

```lua
--- Tools this plugin kinds itself, because the bridge kinds them all `other`.
--- @type table<string, string>
M.TOOL_KINDS = {
    SlashCommand = "SlashCommand",
    Skill = "Skill",
    ToolSearch = "ToolSearch",
    SendMessage = "SendMessage",
    ListAgents = "ListAgents",
    Monitor = "Monitor",
    ScheduleWakeup = "ScheduleWakeup",
    TaskStop = "TaskControl",
    TaskOutput = "TaskControl",
    CronCreate = "Cron",
    CronDelete = "Cron",
    CronList = "Cron",
}

--- Server and tool halves of an `mcp__<server>__<tool>` wire name, or nil for
--- any other name.
--- @return string|nil server
--- @return string|nil tool
function M.split_mcp_name(tool_name)

--- This plugin's kind for a claude tool name, or nil when the bridge's own
--- kind stands. `bridge_kind` gates the unbounded `mcp__` population: an MCP
--- tool the bridge does give a formatter keeps the richer kind it assigned.
--- @return string|nil
function M.tool_kind(tool_name, bridge_kind)
```

`tool_kind` calls `split_mcp_name`, so the `mcp__` pattern is written once and
the head branch reuses it. The three `MODE_SWITCH_TOOLS` names stay in their own
table: they share one kind but differ in head label, which no name→kind map can
express.

A new `ClaudeAgentACPAdapter:__apply_tool_identity(message, update)` applies
both, called from `__build_tool_call_message` and `__build_tool_call_update`
ahead of `__apply_raw_input`. It sets `message.kind`, and the part of the head
derivable from the name alone (below). Named for what it establishes, not for
what it reads.

Three placement facts decide that it runs before the gate:

- The tool name is on `_meta.claudeCode.toolName` of **every** notification
  built from a cached `tool_use`, initial `tool_call` included. Minting needs
  nothing from `rawInput`.
- `__apply_raw_input` early-returns on empty `rawInput`
  (`claude_agent_acp_adapter.lua:168-170`), and a streamed top-level call
  carries `rawInput = {}` on the initial `tool_call`. Minting inside the gate
  means the first frame of all 433 ToolSearch-shaped calls renders the gear and
  then flips — and `ListAgents` and `CronList`, whose input is empty by
  definition, would never mint at all.
- `_on_tool_call` persists `kind` on phase 1 only
  (`session_manager.lua:1049-1058`). A kind that arrives on phase 2 is not in
  the session JSON, so a restored session renders the gear forever. Minting at
  phase 1 fixes that for `Skill` and `SlashCommand` too — a deliberate
  side-effect of putting them in the table, and the reason to.

The ladder inside `__apply_raw_input` then reads `local kind = message.kind or
update.kind` at its head (`:208`) and uses that one spelling throughout,
replacing both the name-keyed branches at the top and the `update.kind` local
below. `MODE_SWITCH_TOOLS` keeps its name lookup for the label.

### Refine the head from rawInput

**The rule: the head drops the tool name exactly when the glyph is unique to
that tool, and keeps it when the glyph is a family's.** Nothing is lost for the
two sign-less consumers — the picker preview renders `**<kind>** \`<arg>\``
(`session_restore.lua:246-252`) and the Path B prose prefix renders `Tool call
(<kind>): <arg>`, so both already print the kind beside the head.

Per-kind field knowledge lives beside the kind table, not in the adapter:

```lua
--- Head text for a kind this plugin minted. Returns nil when the bridge's own
--- title stands (Skill, SlashCommand, the mode switches), "" to clear a title
--- that is only the tool's name, and the name-derived head for the family
--- kinds. `raw_input` may be empty — every field it reads is optional.
--- @return string|nil
function M.tool_head(kind, raw_input, tool_name)
```

`__apply_tool_identity` calls it with an empty input to set the base head;
`__apply_raw_input` grows **one** branch that calls it again with the real input
and returns. Every missing-field fallback then has one place to live, and is
unit-testable without an adapter.

| Kind | Base head | Refined |
| --- | --- | --- |
| `ToolSearch` | bare | `query` |
| `SendMessage` | bare | `to`, or `to: summary` |
| `Monitor` | bare | `description` |
| `ScheduleWakeup` | bare | `reason` |
| `ListAgents` | bare | — (stays bare) |
| `TaskControl` | `<tool>` | `<tool>: <task_id>` |
| `Cron` | `<tool>` | `CronCreate: <cron>` only |
| `Mcp` | `<server>: <tool>` | — |

A base head that is already right is why `CronDelete` and `CronList` read
`CronDelete` rather than the dangling `CronDelete: ` a field-only rule would
produce, and why `TaskStop` survives its optional `task_id`. The adapter has the
precedent at `:239-244`, where `SubAgent` guards an empty `description` for the
same reason.

`SendMessage`'s `summary` is documented **in the tool's own input schema** as "a
5-10 word label for your own transcript row (not transmitted)" — a head is
precisely what it is for. Note that `SendMessageInput` is not exported from
`sdk-tools.d.ts`, so this is not checkable from the installed bridge. The
`to: summary` shape matches the `SubAgent` head (`<type>: <description>`)
already in the adapter.

Split the MCP name with `^mcp__(.-)__(.+)$`: the non-greedy first capture stops
at the first `__`, and no observed server name contains one
(`claude_ai_Linear`, `zotero-mcp`, `cclsp`, `semble`).

### Stop `strip_kind_prefix` firing on a minted head

`prepare_block_lines` calls `strip_kind_prefix(kind, argument)` at `:517` to
undo the bridge's own `"Read filename.txt"` titles. Against a head this plugin
built it can only misfire: a `Monitor` whose description begins "Monitor the CI
run" renders as `the CI run` (spiked). Guard it to the bridge-assigned
lowercase protocol kinds — a CamelCase kind is one the adapter minted, and a
head the adapter wrote needs no undoing.

### Glyphs

Eight entries on `Glyphs.KIND`, keyed lowercase (`kind_glyph` looks up through
`AcpKind.normalise`). Every codepoint was resolved by name against
`SymbolsNerdFontMono-Regular.ttf` and checked against all 47 glyphs already in
the module.

| Key | Glyph | Codepoint | Name | Why |
| --- | --- | --- | --- | --- |
| `toolsearch` | 󰦬 | `U+F09AC` | `md-toolbox` | The toolbox is what gets searched; `md-magnify` is spent on `search`, and the head carries the query |
| `sendmessage` | 󰒊 | `U+F048A` | `md-send` | Unambiguous at one cell; nothing else here is a paper plane |
| `listagents` | 󰡉 | `U+F0849` | `md-account_group` | **Alias of `COMMAND.agents`** |
| `mcp` | 󰌘 | `U+F0318` | `md-lan_connect` | **Alias of `COMMAND.mcp`** |
| `monitor` | 󰐷 | `U+F0437` | `md-radar` | Sweeping until a condition holds. Not `md-monitor_eye`: reads as a screen and collides in spirit with `read`'s eye |
| `taskcontrol` | 󱊖 | `U+F1296` | `md-tray_full` | Family glyph; the head names the operation. Not `md-robot_outline` — outline-vs-filled against `subagent`'s 󰚩 is the indistinguishability the module docstring exists to prevent |
| `schedulewakeup` | 󰒲 | `U+F04B2` | `md-sleep` | A "Z". `md-alarm` was rejected: it is the same round face as `status_icons.pending` 󰔛 `md-timer_outline` with bell ears, indistinguishable at one cell. Same disqualification killed `md-autorenew`/`md-update` against `in_progress` 󰁪 |
| `cron` | 󰃰 | `U+F00F0` | `md-calendar_clock` | Recurring, against the wakeup's single fire. The calendar grid dominates, so it survives the 󰔛 check |

Write the two aliases as assignments after `Glyphs.COMMAND`
(`Glyphs.KIND.listagents = Glyphs.COMMAND.agents`), not as repeated codepoints —
`/agents` and `ListAgents` are one identity reached through two channels, the
relation `KIND.think`/`THINKING` and `COMMAND.hooks`/`HOOK` already encode, and
the shared identity should survive a later change to either side.

`mcp`, `taskcontrol` and `cron` join `CODE_KINDS`. Their heads are identifiers
and expressions, and that table's docstring gives the reason: a column that
switched guarding on whether one head happened to contain an underscore or a
`*` would read as arbitrary. The other five take prose heads (a query, a
description, a reason) and keep the on-demand guard.

Aside: `SymbolsNerdFontMono-Regular.ttf` ships inside kitty's app bundle and is
the only font on this machine covering the `nf-md` range — nothing in
`~/Library/Fonts` or `/Library/Fonts` has it. The whole vocabulary renders by
kitty's fallback chain alone.

## What does not change

- **Permissions.** `READ_ONLY_KINDS` is `read`+`search` and `FILE_SCOPED_KINDS`
  the five mutating kinds (`permission_manager.lua:85-97`); these tools matched
  neither as `other` and match neither after. `_try_auto_approve` reads the
  bridge's `toolCall.kind` and substitutes the tracker kind only when that is
  read-only or `skill` (`:382-386`), so the cache key is unaffected, and
  `permission_hook.lua` derives its kind from its own `NAME_TO_KIND`.
- **The unknown-kind warning.** `acp_client.lua:508` tests
  `KNOWN_ACP_KINDS[update.kind]` — the raw bridge kind, before any adapter
  re-kinding. `other` is in the set, so nothing fires today and nothing after.
- **Body rendering and folding.** The generic body branch
  (`tool_call_renderer.lua:1060-1103`) already pretty-prints a JSON body and
  folds past `other_max_lines`; it was written for exactly these tools. No new
  fold source, no `folds.scm` change.
- **The PostToolUse hook path.** `hook_patch_facts` returns before
  `__build_tool_call_update`, so nothing mints on it.
- **Other providers.** These are Claude Code tools; the opencode/codex/gemini
  adapters are untouched and keep the gear if they ever emit one.
- **`doc/agentic.txt`.** The glyph vocabulary is canonical in `glyphs.lua` and
  deliberately not in the help.

Docstrings to update: the `Glyphs.KIND` header, and the `provider-system`
skill's tool-identity section. `AcpKind.normalise`'s enumeration of minted kinds
should become a pointer to `ClaudeUtils.TOOL_KINDS` rather than grow to
thirteen names — a second copy of the table is a second thing to drift.

**The refined head does not survive a restore.** `_on_tool_call_update`
persists `status`, `description`, `body`, `diff` and `skill_path`, not
`argument` (`session_manager.lua:1490-1500`), so a restored session replays the
base head while the kind and glyph are correct. That is the already-filed
[bug-chat-history-drops-tool-call-enrichment.md](bug-chat-history-drops-tool-call-enrichment.md),
not this plan's to fix — but the base heads above are chosen so the degraded
case still reads (`TaskStop`, `cclsp: rename_symbol`, a bare `###`).

## Test

In `claude_agent_acp_adapter.test.lua` under the existing `describe("dispatch on
the tool name")`, reusing `make_capturing_adapter`:

- **A `SlashCommand` update test, written before the ladder rewrite.** No test
  covers that branch today, and switching the ladder onto `message.kind` is
  exactly the change that could kill it silently.
- Kind mints on the initial `tool_call` with `rawInput = {}` — the regression
  guard for the placement decision.
- `ToolSearch` takes the query as its head; `ListAgents` stays bare through
  both phases.
- `SendMessage` renders `to` alone, and `to: summary` when both are present.
- `TaskStop` and `TaskOutput` collapse to one kind and each keeps its own
  operation in the head; `TaskStop` with no `task_id` renders name-only.
- `CronDelete` renders name-only (it has no `cron` field).
- `mcp__cclsp__rename_symbol` → kind `Mcp`, head `cclsp: rename_symbol`; an
  `mcp__` tool arriving with a non-`other` bridge kind keeps that kind.
- An unlisted tool name keeps `other` and the title-derived argument.

In the renderer: `strip_kind_prefix` leaves a `Monitor` head beginning with the
word "Monitor" intact.

One test spans the two files and catches the only failure mode neither side can
see — a minted kind with no glyph, which renders a silent gear: for every kind
`ClaudeUtils.TOOL_KINDS` can produce, assert
`Glyphs.KIND[AcpKind.normalise(kind)]` is non-nil. Preferred over a
glyph-uniqueness test: uniqueness is a one-off mechanical check (done — 47
distinct literals, the only collisions being the two declared aliases), whereas
its alias allowlist would be seven groups of rot.

## Out of scope

`ClaudeUtils.MODE_SWITCH_TOOLS` maps `EnterPlanMode`, `ExitPlanMode` and
`EnterWorktree`, but not `ExitWorktree` — which exists (`sdk-tools.d.ts:56`).
It falls to the generic branch and renders the gear with a title-derived head.
Never observed in the cache, so it is flagged rather than fixed here.

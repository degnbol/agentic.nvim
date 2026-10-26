# Plan: Claude tool call heads from rawInput, not the bridge title
Status: draft

## Relevant files
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua` (`__handle_tool_call` 195-219, `__build_tool_call_message` 232-248, `set_head` 285-289, `__apply_tool_identity` 305-318, `__apply_raw_input` 330-451)
- `lua/agentic/acp/adapters/claude_utils.lua` (`nonempty`/`qualified` 107-121, `HEADS`/`tool_head` 131-187, `rewrite_grep_to_rg` 334-339, `PLACEHOLDER_TITLES`/`suppress_placeholder_title` 341-368)
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.test.lua`
- `lua/agentic/acp/acp_client.lua` (`__resolve_fetch_fields` 674-687, `__build_tool_call_message` 796-811; shared, not edited)
- `lua/agentic/ui/tool_call_renderer.lua` (`search_title_flags` 452-462, `first_quoted_string` 429, consumer 1114-1116; not edited)
- Bridge v0.95.0 `dist/tool-calls/`: `renderer.js` (`toolCall` 104-127, `refinement` 129-141, `partialRefinement` 149-160, `memoryRecall` 410-431), `field-tracker.js` 6-14, `reporters/*.js`; `acp-agent.js` 10042-10057, 10585
- Skills: `provider-system` (§ Tool identity, 366-371), `rendering` (bare `###`, 99-101)
- `notes/bug-placeholder-titles.md`, `notes/audit-edge-cases.md` items 0.7, 3.18, 3.21

## Background

### Facts about the bridge (v0.95.0)
1. Every title of a tool use is a function of the tool's input (plus cwd): `facts(toolUse)` → `reporterFor(name).toolUse(input)` (`renderer.js:83-89`). No reporter's `toolResult` returns a title; only the synthetic compaction call does (`compaction.js:21,45`).
2. Every notification built from a tool use carries `rawInput` for a non-AIR client: the initial `tool_call` (empty `{}` while input streams, `renderer.js:117-121`), `partialRefinement` (the top-level fields so far, `:156`), `refinement` (complete, `:136`), and the permission-surfaced eager `tool_call` (`acp-agent.js:7588`, complete input). `rawInput` is a whole value that replaces the client's copy (`field-tracker.js:6-14`); the tracker drops it only when unchanged, and then also drops the title (which derives from it).
3. Synthetic tool calls carry a title and no `rawInput`: `memory_recall` ("Recalled 3 memories", `renderer.js:410-431`) and `compact` ("Compact conversation", `compaction.js:16-25`). Their input never streams, so their title is never a placeholder, and they have no input to build a head from.
4. MCP and unknown tools use `GenericReporter`: title = tool name, or `"Unknown Tool"` when the name is empty (`interaction.js:158-161`). `_meta.claudeCode.toolName` carries the same name (`renderer.js:578`).
5. TodoWrite and Task* never surface a `tool_call` from the stream; only a permission request does, with complete input (`acp-agent.js:10042-10057, 10585`). Their fallback titles (`Create task`, `Update task`) cannot reach the client.
6. NotebookEdit is titled `"NotebookEdit"`, kind `other`, for a non-AIR client (`file-edit.js:151-152`); `"Edit notebook"` is AIR-only.

### Every path by which placeholder text reaches a Claude head
| # | Path | Example text |
|---|---|---|
| P1 | Initial `tool_call`: base `argument = update.title` (`acp_client.lua:802`), filtered only by the drifting list (`claude_agent_acp_adapter.lua:216`, `claude_utils.lua:347-359`) | `Task (high effort)`, `Read File (1 - 20)` (renders `File`), `Find \`src\``, `grep -i`, `Report findings: none found`, `Asking for your input` |
| P2 | Update fallback `command or suppress(title)` (`claude_agent_acp_adapter.lua:431-436`) — reached by execute, search, `think` without `subagent_type` (Agent before its type, ReportFindings), and `other` (AskUserQuestion, unknown tools) | `Task (high effort)` / `<description> (high effort)`, `grep -n`, `Find \`src\`` |
| P3 | Plugin sentinel `"unknown skill"` (`:351`) | `unknown skill` |
| P4 | Plugin sentinel `"unknown fetch"` via the shared `__resolve_fetch_fields` (`acp_client.lua:684-686`, called at `:405`) | `unknown fetch` |
| P5 | SubAgent head `"%s, %s: %s"` with `"default"` and `""` (`:414-427`) | `default, : ` |
| P6 | Read range parsed from the title (`:390-402`) — feeds the head's `path:N` (`tool_call_renderer.lua:845-858`) | (title dependency, no placeholder text today) |

P5 is unreachable with v0.95.0: `kind` there is the bridge kind (`ToolCallKinds:apply` stores `update.kind`, `tool_call_kinds.lua:27-30`; `__apply_tool_identity` never mints `SubAgent`), and Agent/Task are kinded `think` (`agent.js:11`), so neither `kind == "SubAgent"` nor `kind == "other" and subagent_type` holds. The prompt body it sets already arrives as `content[1]` (`agent.js:12`).

### Rule
**The Claude adapter writes no head from `update.title`, except on a notification without `rawInput`.** A notification with `rawInput` gets its head from `rawInput` fields (empty until the field arrives) or, for a tool the adapter has no field knowledge of, from `_meta.claudeCode.toolName`.

Why it cannot drift: a placeholder is the bridge's text for an input field that is not there yet. Notifications without `rawInput` have no streaming input (fact 3). Notifications with `rawInput` never read the title, so no rewording or new fallback string in a reporter can reach a head. The only bridge-side dependency left is the SDK tool input schema (field names), which the adapter already depends on. MCP and unknown tools lose nothing: their title is the tool name (fact 4).

The bridge title carries information `rawInput` lacks only for synthetic calls (fact 3), which the rule keeps. The Grep title is the one place the adapter would otherwise have to re-derive a format — see Q1.

`set_head`'s guard (`:285-289`) stays: it protects identity heads written on result updates, which carry `_meta` but no `rawInput`. Inside `__apply_raw_input`, heads are written unconditionally, because `rawInput` there is the complete current input (fact 2).

## Changes

### `claude_agent_acp_adapter.lua`
1. `__handle_tool_call`: delete line 216 (`suppress_placeholder_title`).
2. `__build_tool_call_message`: right after the base build, `if update.rawInput then message.argument = "" end` — replaces the bridge title on every tool use; a synthetic call keeps its title. Delete `had_raw_input` (235-236) and the execute special-case (240-246); change 3 makes `__apply_raw_input` cover it.
3. `__apply_raw_input`: gate on `if not rawInput then return end` instead of nil-or-empty (332). The initial `tool_call`'s `{}` now runs the ladder, so each branch writes its empty head and the fallback branch writes the tool name on the first frame (needed for permission-surfaced no-input calls such as TaskList, which would otherwise stay blank). Update the docstring of `__apply_tool_identity` (295-301), which cites the old gate.
4. Skill (349-351): `message.argument = skill or ""`; drop the sentinel comment.
5. Read range (390-402): replace the title parse with `elseif rawInput.limit then message.read_range = { offset = 1, limit = rawInput.limit }` — same value the bridge puts in the title (`read.js:7-9`).
6. Fetch (404-405): `if rawInput.query or rawInput.url then self:__resolve_fetch_fields(message, rawInput) else message.argument = "" end`. The shared helper keeps its sentinel for auggie.
7. Subagent (406-427): one branch keyed on the tool name, `elseif tool_name == "Agent" or tool_name == "Task" then`, which sets `kind = "SubAgent"` when `rawInput.subagent_type` is non-empty (as now) and `message.argument = ClaudeUtils.subagent_head(rawInput)`. Delete the unreachable `SubAgent`/`other` branch (414-427, P5).
8. Fallback (428-436):
   - `execute`: `message.argument = command or ""`.
   - `search`: per Q1.
   - any other kind: `message.argument = tool_name` when `tool_name` is non-nil; else leave `argument` alone (bridge's untracked fallback, no `_meta`).
   Body extraction and `lift_execute_description` stay as they are.

### `claude_utils.lua`
9. Delete `PLACEHOLDER_TITLES` and `suppress_placeholder_title` (341-368).
10. Add `M.subagent_head(raw_input: agentic.acp.ClaudeAgentRawInput): string` — `"<subagent_type>: <description>"`, else the one present, else `""`; built from `nonempty` and `qualified` (107-121).
11. Q1 option A only: add `M.search_head(tool_name: string, raw_input: agentic.acp.ClaudeAgentRawInput): string` and delete `rewrite_grep_to_rg`.

### Tests (`claude_agent_acp_adapter.test.lua`)
- 587-592: expect `""` for a Skill without a name.
- 1034-1080 (`subagent heading`): give `think_update` `_meta.claudeCode.toolName = "Agent"`; add a case with `description` only (head is the description, kind stays unset) and one with `effort` only (head `""`). The "think call without a type" case (1075) keeps no `_meta` and still asserts `kind` nil.
- 1462-1479: an unknown tool heads with its name (`"Frobnicate"`) on the initial `tool_call` and on the update; the title `"Frobnicate thing"` is never shown.
- New, in `updates that leave out unchanged fields`: initial `tool_call` with `rawInput = {}` and titles `Terminal`, `Read File (1 - 20)`, `Task (high effort)`, `grep -i` → head `""`; a `tool_call` without `rawInput` titled `Compact conversation` keeps the title; a WebFetch update with only `prompt` → head `""`; a Read update with `limit` only → `read_range = { offset = 1, limit = … }`.
- Q1 cases for Grep and Glob.

### Docs
- `provider-system` skill 366-371: the identity step's reason no longer cites the empty-`rawInput` gate; state the rule above in one sentence under § Tool identity.

## Expected outcome
- No Claude tool head shows bridge fallback text or a plugin sentinel. While input streams, the head is a bare `###` (`rendering` skill 99-101) until its field arrives.
- MCP, unknown tools, NotebookEdit, ReportFindings and AskUserQuestion head with the tool name (MCP keeps its `server: tool` head). Compaction and memory recall keep their bridge titles.
- Agent calls without `subagent_type` head with the description; the `(… effort)` suffix is no longer shown (it was shown only when `subagent_type` was absent).
- New bridge versions cannot add a placeholder to a Claude head; no list to maintain.

## Non-goals
- Other providers: `"unknown fetch"` in the shared `__resolve_fetch_fields` (auggie), `"unknown codex command"`, opencode's `"pending..."` and `"unknown skill"`.
- Kind changes (e.g. kinding an Agent call `SubAgent` before `subagent_type` arrives).
- `notes/bug-path-b-replay-empty-argument.md` (empty-argument history records); this plan only changes which text is in `argument`.

## Open questions
- **Q1 — Grep and Glob heads.** Grep's title is a grep command line the adapter does not build; the renderer reads `-i`/`-P` and the first quoted word from it (`tool_call_renderer.lua:452-462, 1114-1116`). Glob's is ``Find `path` `pattern` ``. Options:
  - A. Build both from `rawInput` in `ClaudeUtils.search_head` (port of `search.js:17-51` plus `grepOutputMode`/`grepPath` 58-83, emitting `rg` directly). Fully title-free; about 40 lines, and it must track the CLI's input aliases (`-l`/`-c` booleans, `file_path` for `path`), as the bridge's own comments show it does.
  - B. Use the title only once `rawInput.pattern` is present (both tools require `pattern`), else `""`; keep `rewrite_grep_to_rg`. A title absent on such an update means unchanged, so leave `argument` alone then. Few lines; keeps a dependency on the title's format, not on its fallbacks.
- **Q2 — tools without field knowledge.** The plan heads them with the tool name. That drops the bridge's input-derived text for: AskUserQuestion (single question; the question also arrives as the body, `interaction.js:76-79,86`), ReportFindings (finding count; findings also in the body, `:145-148`), TodoWrite/TaskCreate/TaskUpdate (permission-surfaced only, fact 5). Alternative: add per-tool builders for any of these to `HEADS`. Which, if any?

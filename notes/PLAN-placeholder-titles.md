# Plan: Claude tool call heads from rawInput, not the bridge title
Status: reviewed (open questions)

## Background

### Files
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua`: `__handle_tool_call`, `__build_tool_call_message`, `set_head`, `__apply_tool_identity`, `__apply_raw_input`.
- `lua/agentic/acp/adapters/claude_utils.lua`: `nonempty`, `qualified`, `HEADS`, `tool_head`, `rewrite_grep_to_rg`, `PLACEHOLDER_TITLES`, `suppress_placeholder_title`.
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.test.lua`, `claude_utils.test.lua`.
- `lua/agentic/acp/acp_client.lua`: `__resolve_fetch_fields`, `__build_tool_call_message` (shared, not edited).
- `lua/agentic/ui/tool_call_layout.lua`: `search_title_flags`, `first_quoted_string` and their search-section consumer (not edited).
- Bridge v0.97.0 `dist/tool-calls/`: `renderer.js` (`facts`, `toolCall`, `refinement`, `partialRefinement`, `permissionToolCall`, `memoryRecall`, `toolUseMeta`), `field-tracker.js` (`REPLACED_FIELDS`), `reporters/*.js`; `dist/acp-agent.js` (`isTaskTool`, `shouldEmitToolCall`).
- Skills: `provider-system` § "Tool identity is `_meta.claudeCode.toolName`, not `title`"; `rendering` (the bare `###` paragraph).
- Notes: `notes/bug-placeholder-titles.md`; `notes/audit-edge-cases.md` items 0.7, 3.18, 3.21.

### Bridge facts
1. Every title of a tool use is a function of the tool's input (plus cwd): `facts(toolUse)` → `reporterFor(name).toolUse(input)`. Two result paths also set a title, and neither reaches a Claude head: `ExitPlanModeReporter.toolResult` ("Exited Plan Mode"; the adapter heads mode switches by name, `MODE_SWITCH_TOOLS`) and the synthetic compaction call (`compaction.js`).
2. Every notification built from a tool use carries `rawInput` for a non-AIR client: the initial `tool_call` from `toolCall` (empty `{}` while input streams), `partialRefinement` (the top-level fields so far), `refinement` (complete), and `permissionToolCall` (complete). `rawInput` is a whole value that replaces the client's copy (`REPLACED_FIELDS`); the tracker drops it only when unchanged, and then also drops the title (which derives from it).
3. Synthetic tool calls carry a title and no `rawInput`: `memory_recall` (`memoryRecall`, "Recalled 3 memories") and `compact` ("Compact conversation"). Their input never streams, so their title is never a placeholder, and they have no input to build a head from. The ExitPlanMode plan-file clear call carries `rawInput`, but only for an AIR `planFile` client, which this plugin is not.
4. MCP and unknown tools use `GenericReporter`: title = tool name, or `"Unknown Tool"` when the name is empty. `_meta.claudeCode.toolName` carries the same name (`toolUseMeta`).
5. TodoWrite and Task* (`TaskCreate`/`TaskUpdate`/`TaskList`/`TaskGet`) never surface a `tool_call` from the stream (`shouldEmitToolCall`); only a permission request does, with complete input. Their fallback titles (`Create task`, `Update task`) cannot reach the client. `PlanToolReporter` kinds them `think`.
6. NotebookEdit is titled `"NotebookEdit"`, kind `other`, for a non-AIR client (`NotebookEditReporter.toolUse`); `"Edit notebook"` is AIR-only.
7. Agent/Task (`AgentReporter`) and ReportFindings are kinded `think`; AskUserQuestion `other`.

### Placeholder paths
| # | Path | Example text |
|---|---|---|
| P1 | Initial `tool_call`: base `argument = update.title` (`ACPClient:__build_tool_call_message`), filtered only by the drifting list (`suppress_placeholder_title` in `__handle_tool_call`) | `Task (high effort)`, `Read File (1 - 20)` (renders `File`), `Find \`src\``, `grep -i`, `Report findings: none found`, `Asking for your input` |
| P2 | Fallback branch of `__apply_raw_input`: `command or suppress_placeholder_title(title)` — reached by execute, search, `think` without `subagent_type` (Agent before its type, ReportFindings), and `other` (AskUserQuestion, unknown tools) | `Task (high effort)` / `<description> (high effort)`, `grep -n`, `Find \`src\`` |
| P3 | Plugin sentinel `"unknown skill"` (Skill branch of `__apply_raw_input`) | `unknown skill` |
| P4 | Plugin sentinel `"unknown fetch"` via the shared `__resolve_fetch_fields` (fetch branch) | `unknown fetch` |
| P5 | SubAgent head `"%s, %s: %s"` with `"default"` and `""` (the `kind == "SubAgent" or (kind == "other" and rawInput.subagent_type)` branch) | `default, : ` |
| P6 | Read range parsed from the title (`CanonicalToolCall.parse_read_range(update.title)` in the read branch) — feeds the head's `path:N` | (title dependency, no placeholder text today) |

P5 is unreachable: `kind` there is the bridge kind (`ToolCallKinds:apply` stores `update.kind`; `__apply_tool_identity` mints only `TOOL_KINDS` values and `Mcp`, never `SubAgent`), and Agent/Task are kinded `think` (fact 7), which the branch before it takes. The prompt body it sets already arrives as `content` (`AgentReporter` `display`).

### Rule
**The Claude adapter writes no head from `update.title`, except on a notification without `rawInput`.** A notification with `rawInput` gets its head from `rawInput` fields (empty until the field arrives) or, for a tool the adapter has no field knowledge of, from `_meta.claudeCode.toolName`.

Why it cannot drift: a placeholder is the bridge's text for an input field that is not there yet. Notifications without `rawInput` have no streaming input (fact 3). Notifications with `rawInput` never read the title, so no rewording or new fallback string in a reporter can reach a head. The only bridge-side dependency left is the SDK tool input schema (field names), which the adapter already depends on. MCP and unknown tools lose nothing: their title is the tool name (fact 4).

The bridge title carries information `rawInput` lacks only for synthetic calls (fact 3), which the rule keeps. The Grep title is the one place the adapter would otherwise have to re-derive a format — see Q1.

`set_head`'s guard stays: it protects identity heads written on result updates, which carry `_meta` but no `rawInput`, and the existing `set_head` calls in `__apply_raw_input` (SendMessage, `tool_head`) keep it. The writes changes 4–8 make are plain assignments, because `rawInput` there is the complete current input (fact 2): a field once present stays present, so an empty write happens only while the head is still empty.

## Changes

### `claude_agent_acp_adapter.lua`
1. `__handle_tool_call`: delete the `update.title = ClaudeUtils.suppress_placeholder_title(update.title)` line.
2. `__build_tool_call_message`: right after the base build, `if update.rawInput then message.argument = "" end` — replaces the bridge title on every tool use; a synthetic call keeps its title. Delete `had_raw_input`, the trailing execute special-case and its comment; change 3 makes `__apply_raw_input` cover it.
3. `__apply_raw_input`: gate on `if not rawInput then return end` instead of nil-or-empty. The initial `tool_call`'s `{}` now runs the ladder, so each branch writes its empty head and the fallback branch writes the tool name on the first frame (needed for permission-surfaced no-input calls such as TaskList, which would otherwise stay blank). Update the `__apply_tool_identity` docstring, whose second paragraph gives the old gate as the reason it runs outside `__apply_raw_input`; the remaining reason is that minting needs only `_meta`.
4. Skill branch: `message.argument = skill or ""`; drop the sentinel comment.
5. Read branch: replace the `update.title` parse with `elseif rawInput.limit and rawInput.limit > 0 then message.read_range = { offset = 1, limit = rawInput.limit }` — the range `ReadReporter` puts in the title (it also requires `limit > 0` and defaults `offset` to 1).
6. Fetch branch: `if rawInput.query or rawInput.url then self:__resolve_fetch_fields(message, rawInput) else message.argument = "" end`. The shared helper keeps its sentinel for auggie.
7. Subagent: replace the `kind == "think" and rawInput.subagent_type` branch with one keyed on the tool name, `elseif tool_name == "Agent" or tool_name == "Task" then`, which sets `kind = "SubAgent"` when `rawInput.subagent_type` is a non-empty string (today any truthy value, so `""` mints `SubAgent` with an empty head) and `message.argument = ClaudeUtils.subagent_head(rawInput)`. Delete the unreachable `SubAgent`/`other` branch (P5).
8. Fallback branch:
   - `execute`: `message.argument = command or ""`.
   - `search`: per Q1.
   - any other kind: `message.argument = tool_name` when `tool_name` is non-nil; else leave `argument` alone (bridge's untracked fallback, no `_meta`).
   Body extraction and `lift_execute_description` stay as they are.

### `claude_utils.lua`
9. Delete `PLACEHOLDER_TITLES` and `suppress_placeholder_title`.

### Tests
`claude_agent_acp_adapter.test.lua`:
- `the SKILL.md a Skill call loaded` › "probes nothing before the name streams": expect `""`; drop the sentinel comment above it.
- `subagent heading`: give `think_update` `_meta.claudeCode.toolName = "Agent"`; add a case with `description` only (head is the description, kind stays unset), one with `effort` only (head `""`), and one with `subagent_type = ""` (kind stays unset). "leaves a think call without a type alone" keeps no `_meta` and still asserts `kind` nil.
- `updates that leave out unchanged fields` › "writes no head when neither title nor command came": invert and rename — an unknown tool heads with its name (`"Frobnicate"`) on the initial `tool_call` and on the update; the title `"Frobnicate thing"` is never shown.
- New, in `updates that leave out unchanged fields`: initial `tool_call` with `rawInput = {}` and titles `Terminal`, `Read File (1 - 20)`, `Task (high effort)`, `grep -i` → head `""`; a `tool_call` without `rawInput` titled `Compact conversation` keeps the title; a WebFetch update with only `prompt` → head `""`; a Read update with `limit` only → `read_range = { offset = 1, limit = … }`; a Read update with `limit = 0` → no `read_range`.
- Q1 cases for Grep and Glob.

`claude_utils.test.lua`: `subagent_head` with both fields, type only, description only, neither, and empty strings.

### Docs
- `provider-system` skill § "Tool identity is `_meta.claudeCode.toolName`, not `title`": the last paragraph's reason (`__apply_tool_identity` stays out of the `rawInput` gate because the initial `tool_call` carries an empty `rawInput`) no longer holds; replace it, and state the rule above in one sentence.

### Notes
- Delete `notes/bug-placeholder-titles.md` when this lands; mark `notes/audit-edge-cases.md` items 0.7, 3.18, 3.21 resolved.

## Additions

### `claude_utils.lua`
- `M.subagent_head(raw_input: agentic.acp.ClaudeAgentRawInput): string` — `"<subagent_type>: <description>"`, else the one present, else `""`. Built from `nonempty` and `qualified`; `qualified` alone does not cover description-only.
- Q1 option A only: `M.search_head(tool_name: string, raw_input: agentic.acp.ClaudeAgentRawInput): string`, and delete `rewrite_grep_to_rg`.

## Expected outcome
- No Claude tool head shows bridge fallback text or a plugin sentinel. While input streams, the head is a bare `###` (`rendering` skill) until its field arrives.
- MCP, unknown tools, NotebookEdit, ReportFindings and AskUserQuestion head with the tool name (MCP keeps its `server: tool` head). Compaction and memory recall keep their bridge titles.
- Agent calls without `subagent_type` head with the description; the `(… effort)` suffix is no longer shown (it was shown only when `subagent_type` was absent).
- New bridge versions cannot add a placeholder to a Claude head; no list to maintain.

## Non-goals
- Other providers: `"unknown fetch"` in the shared `__resolve_fetch_fields` (auggie), `"unknown codex command"`, opencode's `"pending..."` and `"unknown skill"`.
- Kind changes (e.g. kinding an Agent call `SubAgent` before `subagent_type` arrives).
- `notes/bug-path-b-replay-empty-argument.md` (empty-argument history records); this plan only changes which text is in `argument`.

## Open questions
- **Q1 — Grep and Glob heads.** Grep's title is a grep command line the adapter does not build; `tool_call_layout.lua` reads `-i`/`-P` from it (`search_title_flags`) and, without `search_pattern`, the first quoted word (`first_quoted_string`). Glob's is ``Find `path` `pattern` ``. Options:
  - A. Build both from `rawInput` in `ClaudeUtils.search_head` (port of `GrepReporter`/`GlobReporter.toolUse` plus `grepOutputMode`/`grepPath` in `reporters/search.js`, emitting `rg` directly). Fully title-free; about 40 lines, and it must track the CLI's input aliases (`-l`/`-c` as `true` or `"true"`, `file_path` for `path`), as the bridge's own comments show it does.
  - B. Use the title only once `rawInput.pattern` is present (both tools require `pattern`), else `""`; keep `rewrite_grep_to_rg`. A title absent on such an update means unchanged, so leave `argument` alone then. Few lines; keeps a dependency on the title's format, not on its fallbacks.
- **Q2 — tools without field knowledge.** The plan heads them with the tool name. That drops the bridge's input-derived text for: AskUserQuestion (single question; the question also arrives as the body), ReportFindings (finding count; findings also in the body), TodoWrite/TaskCreate/TaskUpdate (permission-surfaced only, fact 5). Alternative: per-tool heads for any of these. `HEADS` is keyed by minted kind, so each needs a `TOOL_KINDS` entry and a `Glyphs.KIND` glyph, or a separate name-keyed table. Which, if any?

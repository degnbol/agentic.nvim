# Plan: adapters extend the base tool-call builders
Status: reviewed spec

## Relevant files
- `lua/agentic/acp/acp_client.lua` — `__build_tool_call_message`,
  `__handle_tool_call`, `__build_tool_call_update`, `extract_failure_reason`,
  `find_content_diff`, `extract_content_body`, `exec_shell` (docstring),
  `subagent_task_id`
- `lua/agentic/acp/adapters/auggie_acp_adapter.lua`, `codex_acp_adapter.lua`,
  `cursor_acp_adapter.lua`, `gemini_acp_adapter.lua`,
  `opencode_acp_adapter.lua`, `mistral_vibe_acp_adapter.lua` —
  `__handle_tool_call` / `__build_tool_call_message`
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua` —
  `__handle_tool_call`, `__build_tool_call_message`,
  `__build_tool_call_update`, `__apply_tool_identity`, `__apply_raw_input`,
  `__apply_terminal_output`, `set_head`
- `lua/agentic/acp/adapters/claude_utils.lua` — `MODE_SWITCH_TOOLS`,
  `TOOL_KINDS`, `tool_kind`, `HEADS`, `tool_head`,
  `unwrap_tool_use_error`, `suppress_placeholder_title`
- Tests: `acp_client.test.lua` ("exec shell"),
  `claude_agent_acp_adapter.test.lua`, `opencode_acp_adapter.test.lua`,
  `gemini_acp_adapter.test.lua`, `tests/integration/fast_event_tool_call.test.lua`
- `.luarc.json` (`need-check-nil: Error`), `.claude/rules/provider-specific.md`
- Notes: `notes/FIX-placeholder-titles.md`,
  `notes/feature-provider-drift-detection.md`,
  `notes/refactor-acp-kind-normalisation.md`,
  `notes/FIX-gemini-permission-handler.md`
- Skills: `provider-system` (§ "Adapter override points", § "Edit diffs come
  from `content[]`"), `lua-class`

## Background
`ACPClient:__build_tool_call_message` builds the shared fields of an initial
tool call (`tool_call_id`, `kind`, `status`, `argument`, `body`, `task_id`,
`shell`), and `__handle_tool_call` sends it. Five adapters override the
handler instead and rebuild the message by hand: auggie, codex, cursor,
gemini, opencode. None of the five gets the base `body`. Mistral overrides
the builder but copies the base table, without `task_id` and `shell`.
Cursor's override adds nothing: it is the base without `body`. `task_id`
and `shell` have nil defaults for these providers, so their absence changes
nothing today. It does mean that a new base field does not reach these
adapters (`exec_shell`'s docstring says "Reaches only blocks built by the
base").

No commit gives a reason for the five lacking `body`. The overrides date
from the per-provider split (fa66ff1), and the move into the base (b9a6d38)
left them in place. So all providers take the base output, and an adapter
differs only where its provider sends something differently. Opencode 2.2.5
sends no `content` on an initial `tool_call`, so the base `body` is nil for
it. Its title is the tool name until the input arrives, which the adapter
shows today as a `"pending..."` sentinel.

Codex and gemini read the edit diff from `content[1]` without checking the
entry's type, and mistral reads it from `content[1]` only. If a text entry
came first, as opencode sends on write/edit completion, codex and gemini
would build `{ new = {}, old = {} }`. `ToolCallDiff.extract_diff_blocks`
fills an empty `old` with the whole file, so the result renders as a
deletion of every line, and the diff stays frozen after the first render.
It is not known whether either bridge sends such an entry first. The base
already has `find_content_diff`, which scans for the `diff` entry.

Two adapters drop a call: auggie a call without `rawInput`, gemini a `read`
without `locations`. That is a second reason why they override the
handler. A base predicate for "is this call shown" lets every adapter
override only the builder and keeps the builder's result non-nil.

Claude has the same pattern three times:
- `__build_tool_call_update` copies the base builder so that it can unwrap
  the `tool_use_error` envelope in `failure_reason`. `__apply_terminal_output`
  unwraps a different input, the held terminal output, and stays as it is.
- Two places classify mode switches. `__handle_tool_call` builds a whole
  message by hand for `MODE_SWITCH_TOOLS` and bypasses the base.
  `__apply_raw_input` sets the same kind, label and `exits_plan` again,
  behind its `rawInput` gate. Mode switches are a name→kind mint plus a
  name→head lookup, which `TOOL_KINDS` and `HEADS` already express (`HEADS.Cron`
  gives one kind per-tool heads).
- Both builders run the same five `__apply_*` steps in the same order.

The hand-built mode-switch message is also the only reason why an initial
`ExitPlanMode` call has no body. The `MODE_SWITCH_TOOLS` docstring says the
body holds internal instructions. In bridge 0.97.0 that is not true for the
initial call: `ExitPlanModeReporter.toolUse` sends the plan as `display`
(`tool-calls/reporters/interaction.js`), and EnterPlanMode
(`GenericReporter`) sends no display. The update path keeps the body today
(the sidecar body of `switch_mode` in `tool_call_layout.lua`). So when mode
switches use the base, both paths keep the body.

## Changes
### Base contract (`acp_client.lua`)
- New protected predicate:
  ```lua
  --- Whether a tool_call is shown. Default: true. Adapters override this to
  --- drop calls their provider sends empty.
  --- @protected
  --- @param update agentic.acp.ToolCallMessage
  --- @return boolean shown
  function ACPClient:__shows_tool_call(update)
  ```
- `__handle_tool_call`: return when `__shows_tool_call` is false, else
  build and send. Its docstring says it is not an override point: adapters
  override `__shows_tool_call` and `__build_tool_call_message`.
- `__build_tool_call_message` docstring: adapters override it and start
  from the base result.
- `exec_shell` docstring: delete "Reaches only blocks built by the base
  `__build_tool_call_message`".

### Adapters
Each `__handle_tool_call` override is replaced by a
`__build_tool_call_message` override that starts from
`ACPClient.__build_tool_call_message(self, update, session_id)` and keeps
its `body`.
- **cursor**: delete the override. Its human-written comment
  `-- TODO: implement Cursor-agent tool calls` moves to the class
  docstring.
- **auggie**: `__shows_tool_call` is false when `rawInput` is nil or empty.
  The builder keeps today's `argument`/`diff` rules. The diff stays from
  `rawInput` (`provider-system`: auggie sends complete input).
- **codex**: `argument = update.title or "unknown codex command"`. The diff
  comes from `self:find_content_diff(update)`. The `read`/`edit` path and
  the `parsed_cmd` rules do not change.
- **gemini**: `__shows_tool_call` is false for a `read` without
  `locations`. The diff comes from `find_content_diff`. The rules for the
  location argument and for the execute title split do not change. The
  synthetic `tool_call` from `__handle_request_permission` still goes
  through `__handle_tool_call`.
- **opencode**: on the base message, `argument = ""` when `update.title ==
  update.kind`, so the head is a bare `###` until the input arrives. Then
  today's title remaps (`list`, `websearch`, `task`, `skill`, `todowrite`)
  and the `grep`/`glob` command and `search_pattern` from `rawInput`, with
  `""` where that command falls back to `"pending..."` today.
- **mistral**: start from the base message instead of copying it. The diff
  comes from `find_content_diff`, which makes the old `type == "diff"`
  check unneeded.

### Claude (`claude_agent_acp_adapter.lua`, `claude_utils.lua`)
- File-local `apply_shared_fields(self, message, update, session_id)`:
  runs `__apply_tool_identity`, `__apply_message_result`,
  `__apply_raw_input`, `__apply_list_agents_result`, `__apply_edit_diff`,
  in this order. Its docstring says it sets the fields that both a
  `tool_call` and a `tool_call_update` take from a tool use, and points at
  the docstrings of `__apply_list_agents_result` and `__apply_edit_diff`
  for the order. Both builders call it in place of the five calls.
- `__build_tool_call_update`: start from
  `ACPClient.__build_tool_call_update(self, update, session_id)`, then
  `message.failure_reason = message.failure_reason and
  ClaudeUtils.unwrap_tool_use_error(message.failure_reason)`, then
  `apply_shared_fields`, then the update-only steps (terminal output,
  `TaskStop`, `output_ended`, rejection) as today.
- Mode switches as a mint:
  - `TOOL_KINDS` gains `EnterPlanMode = "switch_mode"` and
    `ExitPlanMode = "switch_mode"`. `tool_kind` returns a table hit
    whatever the bridge kind.
  - `HEADS.switch_mode = function(_, tool_name) return
    M.MODE_SWITCH_TOOLS[tool_name] end`. It gives nil for a `switch_mode`
    tool that is not in the table, so such a tool goes through the ladder
    as today.
  - `__apply_tool_identity`: also sets `message.exits_plan = tool_name ==
    "ExitPlanMode" or nil` when it mints `switch_mode`.
  - `__apply_raw_input`: delete the `mode_label` local, its branch and
    the comment above it. The generic `tool_head` call heads mode
    switches.
  - Delete the `__handle_tool_call` override. It also holds
    `update.title = ClaudeUtils.suppress_placeholder_title(update.title)`.
    If `FIX-placeholder-titles.md` has not landed, that call becomes
    `message.argument = ClaudeUtils.suppress_placeholder_title(message.argument)`
    right after the base build in `__build_tool_call_message`. After the
    move, the read-range parse in `__apply_raw_input` gets the raw
    placeholder title instead of `""`. `parse_read_range` gives no range
    for either, because a placeholder has no `(N - M)`.
  - Stale docstrings: `TOOL_KINDS` ("kinds every one of these `other`",
    "`MODE_SWITCH_TOOLS` stays a table of its own … which no name→kind
    map can express"), `tool_head` (where it names mode switches as a nil
    case), and the `MODE_SWITCH_TOOLS` sentence "Body contains internal
    instructions, not user-facing content." `MODE_SWITCH_TOOLS` becomes
    the head label table that `HEADS.switch_mode` reads.

### Notes
- `notes/FIX-placeholder-titles.md` change 1 says where its line goes if
  this plan lands first.
- `notes/feature-provider-drift-detection.md`: its mode-switch check
  (`update.kind == "switch_mode"` with no `MODE_SWITCH_TOOLS` row) sits in
  `__apply_tool_identity` after this plan.
- `notes/refactor-acp-kind-normalisation.md` § "Where a protocol kind
  enters": the adapter block sites become the base builder plus the
  adapters' kind remaps. Whichever plan lands second updates that list.

### Docs (`provider-system` skill)
- Frontmatter description, pipeline diagram and routing table: the
  tool-call override points become `__shows_tool_call`,
  `__build_tool_call_message` and `__build_tool_call_update`.
- § "Adapter override points": document `__shows_tool_call`. In the
  paragraph "Override a `__` handler when …", Gemini's synthetic
  `tool_call` names `__handle_request_permission`.
- § "Edit diffs come from `content[]`": delete the paragraph about
  adapters that index `content[1]`.

## Callers to audit
- `ACPClient:__handle_session_update` (`tool_call` dispatch) and gemini's
  `__handle_request_permission` call `__handle_tool_call`.
- Codex's and mistral's `__build_tool_call_update` call
  `ACPClient.__build_tool_call_update`; unchanged.
- Direct builder calls in tests: `claude_agent_acp_adapter.test.lua`,
  `acp_client.test.lua` ("exec shell"),
  `tests/integration/fast_event_tool_call.test.lua`.
- `SessionManager:_on_tool_call` and `MessageWriter:write_tool_call_block`
  get the same fields as before, plus `body` for the five adapters.
- `exits_plan` is read by `SessionManager:_on_request_permission` and
  persisted by `chat_history.lua`.

## Tests
### Pin (pass before and after; write first)
- New `lua/agentic/acp/adapters/adapters.test.lua`: for every adapter
  class (`setmetatable({}, { __index = Adapter })`, `exec_shell` and
  `subagent_task_id` stubbed), the initial message of a plain `execute`
  call carries `shell` and `task_id`. For claude, also the update of a
  call with a tool name that touches no session state. The base-only case
  stays in `acp_client.test.lua`.
- Per-adapter head rules as they are today, in new
  `auggie_acp_adapter.test.lua`, `codex_acp_adapter.test.lua`,
  `mistral_vibe_acp_adapter.test.lua` and in `gemini_acp_adapter.test.lua`
  and `opencode_acp_adapter.test.lua`. Opencode: the `grep`/`glob`
  `search_pattern`.
- Auggie shows no call without `rawInput`. Gemini shows no `read` without
  `locations`. A gemini `edit` permission request gives the synthetic
  `tool_call` with its diff, through `__handle_request_permission`.
- `claude_agent_acp_adapter.test.lua`: "unwraps a failure reason's
  tool_use_error envelope", the `exits_plan` cases and a `switch_mode`
  tool not in `MODE_SWITCH_TOOLS` (a name such as `EnterWorktree` with
  bridge kind `switch_mode`) keep passing. A failed update with no
  `rawOutput` has `failure_reason` nil.

### New (fail before, pass after)
- `acp_client.test.lua`: `__shows_tool_call` false sends no
  `on_tool_call`.
- Edit diff found at `content[2]` behind a `content` entry: codex, gemini,
  mistral.
- Claude: "renders ExitPlanMode as a switch to Normal" expects
  `{ "the plan" }` as body. Drop its comment "The body holds internal
  instructions, not user-facing content."
- Claude: `__build_tool_call_update` of an ExitPlanMode result (status
  `completed`, no `rawInput`) gives `switch_mode`, `Normal` and
  `exits_plan == true`. Today it gives none of these, because the mode
  branch sits behind the `rawInput` gate.
- A text `content[1]` on the initial call gives `body` for auggie, codex,
  cursor and gemini.
- Opencode: a call whose title equals its kind, and a `grep`/`glob` call
  without `rawInput`, give `argument == ""`.

## Expected outcome
- Every adapter's initial message has every base field, `body` included.
  A new base field reaches all providers without adapter changes.
- Opencode heads show no `pending...`.
- Codex, gemini and mistral find an edit diff anywhere in `content[]`.
- An initial ExitPlanMode call shows its plan body, as its update already
  does. A completed ExitPlanMode update keeps its kind, head and
  `exits_plan`.
- Footers, heads and diffs are otherwise unchanged.

## Non-goals
- Opencode's `__handle_tool_call_update` override. Its body rules depend on
  the status, and the base `body` on an in-progress update would be new
  content.
- Codex's and mistral's `__build_tool_call_update`: they already extend the
  base.
- Whether a mode switch's result text (EnterPlanMode's result) should show.
  Both paths show it today and after this plan.
- Claude head rules (`FIX-placeholder-titles.md`).


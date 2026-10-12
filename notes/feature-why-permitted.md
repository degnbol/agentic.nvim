# Plan: show what decided each tool call's permission
Status: spec

## Relevant files

- `lua/agentic/ui/permission_manager.lua` — `decide` (`:324`),
  `_try_auto_approve` (`:378`), `auto_approve`/`auto_reject` (`:245-268`),
  `_remembered_leaf_patterns` (`:292`), `_bash_effects_clear` (`:515`),
  `_complete_request` (`:961`), `clear` (`:1055`),
  `reject_and_cancel_remaining` (`:1067`)
- `lua/agentic/utils/permission_rules.lua` — `evaluate` (`:2500`), the approve
  walk's leaf check (`:1044-1214`), `should_auto_reject` (`:2450`) and its leaf
  check (`:2397-2410`)
- `lua/agentic/utils/permission_structured.lua` — `decide_leaf` (`:696`),
  `deny_leaf`, `agentic.PermKind` (`:31`)
- `lua/agentic/permission_hook.lua` — PreToolUse entry point (`M.evaluate`)
- `lua/agentic/session_manager.lua` — PermissionManager construction (`:447`),
  `_on_tool_call` (`:1971`), `_do_load_acp_session` (`:4044-4084`)
- `lua/agentic/session_restore.lua` — `replay_messages` (`:370`), which builds
  the replayed block field by field (`:386-396`)
- `lua/agentic/ui/message_writer.lua` — `ToolCallBase`,
  `update_tool_call_block`, the four `apply_status_footer` callers (`:2743`,
  `:2924`, `:2952`, `:3090`)
- `lua/agentic/ui/tool_call_renderer.lua` — `apply_status_footer` (`:1855`)
- `lua/agentic/theme.lua` — highlight groups
- `doc/agentic.txt` — `8.2 AUTO-APPROVAL` (`:714`), highlight table (`:1040-1050`)
- Skills: `permissions` (the ladder, gate kinds), `rendering` (footer layout),
  `provider-system` (tool-call lifecycle), `session-lifecycle` (`destroyed`
  guard, load path)

## Background

A tool call that runs without a prompt says nothing about why. The plugin
knows the decider when its own ladder or its prompt decided. It does not know
when the provider decided:

| Decider | Known to the plugin? |
| --- | --- |
| Read-only tool kind (Read, Grep, Glob) | yes — `decide` rung 1 |
| Skill tool call (`Config.auto_approve_skills`) | yes — rung 2 |
| Shell command, per single command: structured `read_only` / `safe_write` / `deny` gate, settings.json `Bash(...)` pattern, remembered single command | yes — rungs 3 and 5, after the change below |
| Shell redirect or `rm` cleared by a grant | yes — rung 5 |
| Allow/reject-always cache | yes — rung 4 |
| File tool call cleared by a grant | yes — rung 6 |
| User at the prompt | yes — `_complete_request`, `reject_and_cancel_remaining` |
| Provider: no permission needed, settings rule, permission mode, auto-mode classifier, another provider's own logic | no |

The provider row cannot be split. The SDK reports no allow decisions to a
host. It reports classifier *denials* only (`SDKPermissionDeniedMessage`,
`subtype: 'permission_denied'`), and claude-agent-acp does not forward that
message. The transcript has no per-call verdict: `serverClassifierContext` on
tool results holds request context (`git_state`, `live_cwd`, `platform`). So a
provider-decided call shows no word.

The settings row and the provider row are different. The plugin reads
settings.json `Bash(...)` patterns itself and matches them per single command.
A match there is the plugin's decision and shows `glob-allow` or
`glob-deny`. A settings.json
allow that the SDK applies to the whole call never reaches the plugin and shows
nothing.

### One call, several deciders

A shell command passes rung 5 only when every single command in it is allowed
and every file effect clears a grant. Each single command can be allowed by a
different source: `grep x f | sort -o /tmp/out` needs `read-only` for `grep`,
`safe-write` for `sort -o`, and `grant` for nothing (no redirect). With
`> /tmp/out` instead of `-o`, it needs `read-only` and `grant`. Every source
was required, so the footer lists every distinct one.

Today the walk does not say which source allowed a single command:
`decide_leaf` returns `"allow"` without the gate kind, and `ctx.allow` merges
settings patterns with remembered single commands. The change below makes the
walk collect the sources.

### Two paths reach `decide`

- **canUseTool** — `session/request_permission` → `_try_auto_approve`. The
  request carries `toolCallId`.
- **PreToolUse hook** — `hooks/permission_hook.sh` → `permission_hook.lua`, for
  `Bash|Write|Edit`. Its input carries `tool_use_id`
  (`PreToolUseHookInput`, `claude-agent-sdk/sdk.d.ts:2742`). claude-agent-acp
  sets `toolCallId` from the same `tool_use.id`, so the ids match. `evaluate`
  keeps passing the fixed id `"hook"` to `decide`, so the grant check's
  `exclude_id` behaviour does not change. It reads `tool_use_id` separately to
  record the deciders.

The hook RPC (`nvim --server`) and the ACP `tool_call` notification arrive on
different channels, so the verdict can arrive before the block exists.

**Hard constraint: no render work in the hook.** `permission_hook.lua` wraps
the verdict in one `pcall` that abstains on any error. A render error inside it
would silently change a permission decision. The hook has also hung before
(three `hook_cancelled` records at 600 s), and a hung hook blocks the tool
call. So the hook only writes a table entry. All chat and history work runs
later, through `vim.schedule`.

### UI delivery

1. **Footer suffix** (chosen) — `╰─  ✔ completed · grant`. No extra row. The
   footer already holds the call's outcome, and "what let it run" is part of
   that outcome. The footer is real buffer text, so `/grant` search finds
   every call a grant allowed. The footer is rewritten on every status change,
   so the words follow the status.
2. **Header end-of-line virt_text** — lands after a wrap or off screen on long
   arguments, and mixes identity with outcome.
3. **On-demand float** on a key — fits rule-level detail, but is invisible
   until asked (see Non-goals).

### Vocabulary

Each decider value is also its display word. The gate kinds keep their
`permissions.json` names, with `-` for `_`.

| Decider | Value |
| --- | --- |
| Read-only tool kind; structured `read_only` gate | `read-only` |
| Structured `safe_write` gate | `safe-write` |
| Structured `deny` gate | `deny` |
| settings.json `Bash(...)` allow pattern | `glob-allow` |
| settings.json `Bash(...)` deny pattern | `glob-deny` |
| Remembered single command; allow-always cache hit | `session-allow` |
| Reject-always cache hit | `session-reject` |
| Grant scope (file tool call, redirect, `rm`) | `grant` |
| Skill tool call | `skill` |
| User at the prompt, allow option | `prompt-allow` |
| User at the prompt, reject option | `prompt-reject` |
| Provider | *(none)* |

Several values join with `, ` in this order: `read-only`, `safe-write`,
`glob-allow`, `session-allow`, `grant`. A denial has exactly one decider: the
first single command that matched a deny.

Every word names its verdict: `deny`, `glob-deny`, `session-reject` and
`prompt-reject` reject, the rest allow. So ` failed · prompt-allow` is a tool
error, and ` failed · prompt-reject` is a rejection.

The first `allow_always` click is `prompt-allow`. Every later hit of that cache
entry, or of a single command it remembered, is `session-allow`.

### All footers

`<d>` is the decider list. A word shows on every footer write once the
decision is known, `pending` and `in_progress` included.

| Verdict | 󰔛 pending | 󰁪 in_progress | ✔ completed |  failed | 󰜺 cancelled |
| --- | --- | --- | --- | --- | --- |
| allow by `<d>` | `󰔛 pending · <d>` | `󰁪 in_progress · <d>` | `✔ completed · <d>` | ` failed · <d>` (tool error) | `󰜺 cancelled · <d>` |
| deny by `<d>` | `󰔛 pending · <d>` | — | — | ` failed · <d>` | — |
| not yet known, or provider | `󰔛 pending` | `󰁪 in_progress` | `✔ completed` | ` failed` | `󰜺 cancelled` |

Examples: `✔ completed · read-only, grant`, ` failed · deny`,
` failed · glob-deny`, `󰔛 pending · prompt-allow`,
` failed · session-reject`.

When the word appears:

- **canUseTool verdict or prompt choice** — recorded before the provider
  starts the call, so it shows on `pending` when the scheduled callback runs.
- **Hook verdict** — the hook runs just before the call starts. The word shows
  on `pending` or `in_progress`, depending on whether the scheduled callback
  runs before the provider sends `in_progress`.
- **Provider** — never known, so no word on any status.

A call cancelled while its prompt is open (`<C-c>`, or the queued calls after
"reject all") gets no word.

## Changes

### `permission_structured.lua`

- Add `--- @alias agentic.PermAllowKind "read_only"|"safe_write"`, the kinds
  `eligible_allow_kinds` (`:596-604`) can return.
- `decide_leaf` returns the matched allow kind as a second value:
  `--- @return agentic.PermDecision decision` and
  `--- @return agentic.PermAllowKind|nil kind The allow gate kind that matched; nil unless decision is "allow"`.
  At `:724`: `return "allow", kind`. The kind is the first match by entry
  (the command's own entry before `"*"`), then by kind (`read_only` before
  `safe_write`).

### `permission_rules.lua`

- Add `--- @alias agentic.utils.PermissionRules.Source agentic.PermAllowKind|"glob_allow"|"session_allow"`.
- `evaluate(command, extra_allow)` gains a third return:
  `--- @return table<agentic.utils.PermissionRules.Source, true> sources Every source that allowed a single command; empty unless ok`.
  `evaluate` returns `{}` when `ok` is false, because leaves before the failing
  one have already written to `ctx.sources`. `should_auto_approve` ignores
  the third return.
- `evaluate` builds the walk context with settings patterns and `extra_allow`
  apart: `ctx.allow_settings`, `ctx.allow_remembered`, and `ctx.sources = {}`.
  Update the `WalkCtx` alias (`:430`). The approve walk reads `ctx.allow` at
  `:1070` (the `rm` effect bypass) and `:1214`; both test both lists.
  `TallyCtx` and `command_known_safe` (`:1960`) belong to the tally walk and
  do not change.
- At the leaf check (`:1211-1214`): a structured `"allow"` adds its kind to
  `ctx.sources`. Otherwise a settings.json match adds `"glob_allow"`, else a
  remembered match adds `"session_allow"`. The first match wins for one single
  command.
- Statements the walk approves without a leaf check add `"read_only"`: a test
  command (`[[ -f a ]]`, `:1646-1649`) and an assignment (`x=1`,
  `walk_assignment`, `:1455-1457`, `:1487`). They change nothing on disk, so
  `read-only` is the true description. A call whose only statements are these
  then still shows a word.
- Function bodies: `walk_function_definition` (`:1243-1246`) gives `body_ctx`
  its own `sources = {}` and stores it as `funcs[name]` in place of `true`.
  The call site (`:1115-1116`) merges `funcs[name]` into `ctx.sources`. A
  defined function adds sources only when it is called, and a body that fails
  partway adds none.
- `should_auto_reject(command)` gains a second return:
  `--- @return "deny"|"glob_deny"|nil source`. `command_is_denied`
  (`:2397-2410`) and `reject_walk` (`:2425-2440`) return
  `"deny"|"glob_deny"|nil` in place of a boolean: `"glob_deny"` for a glob deny,
  `"deny"` for `deny_leaf`. Wrappers that recurse through `reject_walk`
  (`timeout`, `sh -c`, `:2380-2392`) pass the value up. The existing
  `if … then` tests work unchanged with a string.

### `permission_manager.lua`

- Add `--- @alias agentic.PermissionDecider "read-only"|"safe-write"|"deny"|"glob-allow"|"glob-deny"|"session-allow"|"session-reject"|"grant"|"skill"|"prompt-allow"|"prompt-reject"`.
- `decide(kind, tool_call, diff)` gains a second return:
  `--- @return "allow"|"deny"|nil verdict` and
  `--- @return agentic.PermissionDecider[]|nil deciders In display order`.
  - Rung 1 `{ "read-only" }`, rung 2 `{ "skill" }`.
  - Rung 3: `{ source }` from `should_auto_reject`, with `_` → `-`.
  - Rung 4 `{ "session-allow" }` or `{ "session-reject" }`.
  - Rung 5: the `evaluate` sources with `_` → `-`, in display order, plus
    `"grant"` when `effects` is non-empty. An effect clears only inside a
    grant scope (`_bash_effects_clear`, `:515-556`).
  - Rung 6 `{ "grant" }`.
- New field `_deciders table<string, agentic.PermissionDecider[]>`: deciders
  for blocks that do not exist yet. Cleared in `clear()`.
- New field `on_decided? fun(tool_call_id: string, deciders: agentic.PermissionDecider[])`,
  set by SessionManager, in the style of `on_hidden`.
- New `PermissionManager:stash_deciders(tool_call_id, deciders)`: writes
  `_deciders[tool_call_id]`. Nothing else.
- New `PermissionManager:record_deciders(tool_call_id, deciders)`:
  `stash_deciders`, then `vim.schedule` a function that calls `on_decided` if
  it is set. No other work, so it is safe inside the hook's `pcall`.
- New `PermissionManager:take_deciders(tool_call_id)` →
  `agentic.PermissionDecider[]|nil`: returns and removes the entry.
- `_try_auto_approve`: call `record_deciders` only when `auto_approve` /
  `auto_reject` returns true. When they return false (no matching option), the
  request goes to the prompt and the ladder did not decide it.
- `_complete_request`: when the selected option resolves to a kind, call
  `record_deciders(toolCallId, { "prompt-allow" })` for `allow_*` and
  `{ "prompt-reject" }` for `reject_*`.
- `reject_and_cancel_remaining`: `record_deciders(toolCallId, { "prompt-reject" })`
  for the current request, which gets `reject_once`. The cancelled queued
  requests, `<C-c>` and `remove_request_by_tool_call_id` (nil option) get none.

### `permission_hook.lua`

- `local decision, deciders = pm:decide(kind, tool_call, diff)`.
- If `decision` and `type(payload.tool_use_id) == "string"`, call
  `pm:record_deciders(payload.tool_use_id, deciders)`. Nothing else is added.

### `session_manager.lua`

- At PermissionManager construction, set `on_decided` to
  `self:_on_permission_decided(id, deciders)`.
- New `SessionManager:_on_permission_decided(tool_call_id, deciders)`:
  - Return when `self.destroyed` (`session-lifecycle` skill: async callbacks
    that write to buffers must check it).
  - If the writer from `_writer_for(id)` has no tracker for `id`, return. The
    entry stays in `_deciders` for `_on_tool_call`.
  - Otherwise `take_deciders(id)`, then
    `update_tool_call_block({ tool_call_id = id, decided_by = deciders })`,
    `chat_history:update_tool_call(id, { type = "tool_call", tool_call_id = id, decided_by = deciders })`,
    and `_history_changed`.
- `_on_tool_call`: set `decided_by = self.permission_manager:take_deciders(id)`
  on the new block and on its history message.
- `_do_load_acp_session`: after `permission_manager:clear()` and
  `ChatHistory.read`, for each `saved_history.messages` entry of type
  `tool_call` with `decided_by`, call
  `permission_manager:stash_deciders(msg.tool_call_id, msg.decided_by)`. The
  provider's replay then reaches `_on_tool_call`, which takes it. Without this,
  the replay rebuilds the messages without the field and the next `save()`
  erases it from the file.

### `session_restore.lua`

- `replay_messages`: add `decided_by = msg.decided_by` to `tool_block`. This
  covers `restore_from_history`, the local fallback and subagent transcripts.

### `message_writer.lua`

- `ToolCallBase`: add
  `--- @field decided_by? agentic.PermissionDecider[] What let the call run or stopped it; nil when the provider decided`.
  `update_tool_call_block` already merges fields into the tracker (`:2826`).
  On Neovim 0.12 `tbl_deep_extend` replaces a list value whole, so a new list
  leaves no stale entries, here or in `ChatHistory:update_tool_call`.
- The four `apply_status_footer` callers pass
  `table.concat(tracker.decided_by, ", ")` when the list is non-empty, else nil
  (`tool_call_block` at `:2743`). A `decided_by`-only update then refreshes the
  footer through the existing paths: diff `:2924`, unchanged content `:2952`,
  full re-render `:3090`.

### `tool_call_renderer.lua`

- `M.apply_status_footer(bufnr, footer_line, status, note)`, with
  `--- @param note string|nil Text after the status, set off by " · "`. The
  renderer stays free of permission terms.
- When `note` is set, the line becomes `status_text .. "· " .. note .. " "`.
  The status extmark keeps its range (the padded status, as today). A second
  `NS_STATUS` extmark, with the same options, covers `· <note>` with
  `Theme.HL_GROUPS.FOOTER_NOTE`. The separator sits in the note's extmark, so
  the status group's background does not run under it.

### `theme.lua`

- `FOOTER_NOTE = "AgenticFooterNote"`, linked to `Comment`. The note must not
  compete with the status colour.

### `doc/agentic.txt`

- `8.2 AUTO-APPROVAL`: give each bullet its footer word, and split the shell
  bullet into its sources (`read-only`, `safe-write`, `glob-allow`,
  `session-allow`, and `grant` for a redirect or `rm`). Then one paragraph:
  several words mean each was needed; `deny`, `glob-deny` and
  `session-reject` reject; a prompted call shows `prompt-allow` or
  `prompt-reject`; a call with no word was decided by the provider.
- Section 10 highlight table: add `AgenticFooterNote  Comment  Footer note after the status`.

### Tests

- `permission_structured.test.lua`: `decide_leaf` returns the matched kind,
  including a command whose own entry matches `safe_write` while `"*"`
  matches `read_only` (reports `safe_write`).
- `permission_rules.test.lua`: `evaluate` sources for `grep x f` (read_only),
  `sort -o x f` at `"safe_write"` (safe_write), a settings-only match
  (glob_allow), a remembered-only match (session_allow), a pipeline mixing them,
  `[[ -f a ]]` and `x=1` (read_only). A failing command returns `{}`. A
  function adds its body's sources only when called. `should_auto_reject`
  source for a structured deny, a glob deny, and a deny inside `sh -c`.
- `permission_manager.test.lua`: `decide` returns the right deciders for each
  rung, including `{ "read-only", "grant" }` for `grep x f > /tmp/out`.
  `record_deciders` stores the entry and calls `on_decided` only after the
  event loop runs. `take_deciders` removes the entry. `_try_auto_approve`
  records nothing when the request has no matching option.
  `_complete_request` records `prompt-allow` for allow options and
  `prompt-reject` for reject options. `reject_and_cancel_remaining` records
  `prompt-reject` for the current request only. Rung 4 records
  `session-allow` or `session-reject` by the cached action.
- `permission_hook.test.lua`: a decided call records against `tool_use_id`. An
  undecided call records nothing. The verdict returns and `on_decided` was not
  called synchronously.
- `session_manager.test.lua`: deciders recorded before `tool_call` show on the
  block when it arrives. Deciders recorded after it update the footer and the
  history. A destroyed session ignores a late callback. Session load keeps
  `decided_by` from the saved file.
- `session_restore.test.lua`: `replay_messages` passes `decided_by` to the
  block.
- `tool_call_renderer.test.lua`: footer text and both extmark ranges, with and
  without a note.

## Expected outcome

- The footers in § All footers.
- The words show on the first footer write after the decision. For prompted
  calls and canUseTool verdicts that is before `in_progress`. For hook verdicts
  it is when the scheduled callback runs.
- Restored sessions, by session/load or local replay, show the same words.
- Known inaccuracy: a settings.json `deny` that the SDK applies can override a
  hook `allow` (documented on `SDKPermissionDeniedMessage`). That call fails
  with the hook's allow deciders, although the user's settings rule stopped
  it. The plugin cannot see this case.

## Non-goals

- Splitting the provider row (no permission needed vs settings rule vs mode vs
  classifier). The SDK gives the host no signal for allows.
- Rule-level detail (which grant scope, which gate, which single command), for
  example in an on-demand float. That needs the sources to carry detail
  strings.
- Rendering the SDK's `permission_denied` system message. claude-agent-acp
  does not forward it.
- Updating the footer diagram in the `rendering` project skill. That is a skill
  edit, done at commit time with the user's consent.

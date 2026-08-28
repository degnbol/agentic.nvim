# PLAN: surface hook activity in the chat buffer

Status: **designed, reviewed twice, not implemented.** All design decisions are
settled; the plan is implementable as written.

Evidence is first-hand: bridge/SDK source and plugin source at the pinned
versions, plus counts over this project's own transcript history. **Counts drift**
as sessions accumulate — quoted for shape, not as fixtures. Snapshot:
`claude-agent-acp` 0.66.0, `@anthropic-ai/claude-agent-sdk` 0.3.220, CLI 2.1.220.

Split out of this plan: showing *why* a tool call was permitted →
`notes/feature-why-permitted.md`. It shares a data source with this work but is a
separate UI concern.

## Goal

A hook that injects context, or that times out, is invisible in AgenticChat. Only
*blocking* hooks show, and only incidentally — a block becomes the tool result.

Make hook activity visible and attributable, without inventing a second source of
truth for the conversation itself.

## Why the ACP feed cannot carry this

| SDK system message | bridge handling | visible today |
| --- | --- | --- |
| `permission_denied` | `tool_call_update` `status:"failed"` (`acp-agent.js:2051`) | yes — as the tool result |
| `informational` | `agent_message_chunk` (`acp-agent.js:2107`) | yes — indistinguishable from model prose |
| `hook_started` / `hook_progress` / `hook_response` | bare `break` (`acp-agent.js:2129-2131`) | **no** |

`hook_response` is the payload we want (`sdk.d.ts:3916`). Two independent reasons
it never arrives:

1. `Options.includeHookEvents` defaults `false` (`sdk.d.ts:1619-1626`) and the
   bridge never sets it. It *is* settable — `_meta.claudeCode.options` is spread
   in at `acp-agent.js:4433` and `includeHookEvents` is not among the
   ACP-controlled overrides that follow (`:4446-4452`).
2. Enabling it changes nothing: the bridge drops the events regardless, and that
   switch's `default` arm is `unreachable()`. The SDK emits SessionStart/Setup
   hook events regardless of the flag; those are dropped too.

`additionalContext` is never a message at all — it is merged into the model's
context inside the CLI (`sdk.d.ts:6791`: *"non-error feedback delivered to the
model"*).

**Do not plan a fix inside `MessageWriter` or the adapters** for the dropped
events — the bytes never leave the bridge. Record the gap under CLAUDE.md §
"Upstream issues" so the local channel below reads as a stopgap.

Related: `notes/agentic-hook-blocked-rendering.md` owns the blocking case; its
"non-zero exits are invisible" caveat is the *Failures* category below.

### Hook feedback that arrives as model prose

A blocking `UserPromptSubmit` or `Stop` hook reaches the client as a real
`agent_message_chunk`, so it renders as if the model said it. The command-notice
work left this site as prose and deferred it here.

It is convertible, because the impersonating text is bridge-generated rather than
model-authored. ACP's `agent_message_chunk` has no severity field, so the bridge
folds the level into the text at `acp-agent.js:2107`, emitting `**Warning:** `,
`**Notice:** ` or `**Suggestion:** ` prefixes (level `info` is left plain as
transcript-only noise). A chunk beginning with one of those at a message boundary
is a hook notice, and can route to `write_notice` instead of the prose path.

This is a heuristic on generated text, not a protocol guarantee — the prefix set
is version-coupled to the bridge, and level `info` is indistinguishable from prose
by construction. Independent of the transcript reader; it needs only unit 1.

## The transcript is the channel

The CLI writes purpose-built records to
`~/.claude/projects/<slug>/<session-id>.jsonl`. **All hook records are nested
under `attachment`** — no top-level `"type":"hook_*"` envelope (2108/2108 nested,
0 top-level):

```json
{"type":"attachment","attachment":{
   "type":"hook_additional_context",
   "content":["Dotfiles conventions: when looking for any program's config…"],
   "hookName":"UserPromptSubmit","hookEvent":"UserPromptSubmit",
   "toolUseID":"hook-8ab624f2-…"},
 "uuid":"…","parentUuid":"…","timestamp":"…","sessionId":"5bcf246d-…"}

{"type":"attachment","attachment":{
   "type":"hook_success","hookName":"PreToolUse:Bash","hookEvent":"PreToolUse",
   "toolUseID":"toolu_01G2wfPp3cY3ADJNXx922NU9",
   "command":"~/.config/claude/hooks/shell-guard.sh",
   "content":"","stdout":"{\"hookSpecificOutput\":{…}}","stderr":"",
   "exitCode":0,"durationMs":142},
 "uuid":"…","parentUuid":"…", …}
```

`hook_success` carries exactly those ten keys — no `outcome`.

### Getting the path

`transcript_path` is on every `BaseHookInput` (`sdk.d.ts:166`), and the plugin's
own PreToolUse hook already receives the whole hook input: `permission_hook.sh`
base64s stdin into `permission_hook.lua`, which decodes it at
`permission_hook.lua:57` and currently reads only `tool_name` / `tool_input` /
`session_id`. One extra field read.

**Read the field only — add no work to that script.** It is the one that hangs
(all three `hook_cancelled` records are `hooks/permission_hook.sh` at 600 s), and
its verdict computation is wrapped in a `pcall` returning abstain on error, so any
failure inside it silently changes a permission decision. See
`notes/feature-why-permitted.md` § "Hard constraint".

Prefer this over deriving the path from the cwd slug. Three limits, which shape
the design rather than being worked around:

- **claude-only.** Registered through `_meta.claudeCode.options`
  (`acp_client.lua:20-36`). Other providers never supply a path; the feature
  no-ops.
- **Gated on the hook matcher** `Bash|Write|Edit` (`acp_client.lua:25`). A session
  that only Reads/Greps/Fetches never learns the path.
- **Arrives late** — unknown until the first matching tool call, possibly several
  turns in. Hence the catch-up rule in "Reader design".

**Guard against a subagent path.** Subagent transcripts
(`<session-id>/subagents/agent-*.jsonl`) carry the *same* `sessionId` as the
parent, so a hook firing inside a subagent hands back a subagent path. No hook
records exist in any subagent file here, so it may never fire, but
`basename(path) == session_id .. ".jsonl"` is one line and removes the risk.

### Ownership, ordering, and attribution

```
L28  assistant  tool_use                        parent=L27
L30  hook_success             PreToolUse:Bash    parent=L28   ← branch off the call
L31  hook_success             PreToolUse:Bash    parent=L30
L32  hook_additional_context  PreToolUse:Bash    parent=L31   ← points at its producer
L33  user       tool_result                      parent=L28   ← also off the call
```

Hook records form a **sibling branch** off the invoking `tool_use`; the
`tool_result` parents straight back to the `tool_use`, bypassing them. So an
injection is provably *not part of the tool result* — it is a separate input the
model received. That is the basis for rendering it as its own region.

- **File order gives sequence; `parentUuid` gives the precise link.** Most
  `hook_additional_context` records point at the `hook_success` that produced
  them — that is how a body is attributed to a *script*.
- **Do not attribute on `toolUseID`** — over a hundred context records share a `toolUseID` with
  2–3 `hook_success` records. **Do not attribute on `hookName`** either:
  `hook_success` carries a matcher suffix the context record lacks
  (`SessionStart:startup` vs `SessionStart`).
- **`hookName` alone does not identify a body.** ~20 tool calls carry two context
  records with identical `hookName` from different scripts, so the `command` join
  is load-bearing for the foldtext, not optional enrichment.
- **`toolUseID:match("^toolu_")` distinguishes tool-owned from turn-boundary
  records.** All `toolu_` records resolve to a `tool_use` in the same file; zero
  orphans. The other forms are not a single synthetic prefix: `UserPromptSubmit`
  uses `hook-<uuid>`, `SessionStart` uses `SessionStart…` *or* a bare uuid, `Stop`
  uses bare uuids. Both kinds render as blocks (see "Rendering"), so this filter
  is for *heading* and *placement*, not for discarding anything.

**Ordering is not uniform:**

```
PreToolUse  before tool_result: 1835/1835
PostToolUse after  tool_result:   56/56
```

The bridge corroborates (`acp-agent.js:5948-5950`): *"a PostToolUse hook can fire
after that"*.

## Record taxonomy

Exactly four attachment types carry a `hookEvent`:

| type | count | meaning |
| --- | --- | --- |
| `hook_success` | 1670 | a hook ran to completion |
| `hook_additional_context` | ~358 | context delivered to the model |
| `hook_non_blocking_error` | ~84 | non-zero exit, ignored |
| `hook_cancelled` | ~3 | timed out — keys are exactly `{type, hookName, hookEvent, toolUseID, command, durationMs, timedOut, timeoutMs}`, **no `stdout`/`exitCode`/`content`** |

Sub-classify `hook_success` on the **parsed** `stdout.hookSpecificOutput` keys —
never on substring presence, which false-positives when a rewritten Bash command
contains the word. Parsed, the classes sum exactly:

| `hookSpecificOutput` | count | agent saw it |
| --- | --- | --- |
| `permissionDecision` | 1309 | no — out of scope, see `notes/feature-why-permitted.md` |
| `additionalContext` | 259 | yes — **duplicates `hook_additional_context`** |
| `updatedInput` | 49 | no — see `notes/PLAN-updated-input-display.md` |
| `additionalContext` + `updatedInput` | 9 | partly — **the classes are not disjoint** |
| unparseable stdout | 24 | no |
| empty stdout | 20 | no |
| | **1670** | |

Read bodies only from `hook_additional_context`; `hook_success` is the roster of
what ran. Otherwise the 259+9 render twice.

Do not claim a per-call record bound: attachments per `toolUseID` are
`{1: 1474, 2: 96, 3: 89, 4: 7, 5: 12}`.

### What gets rendered

Three categories, referred to by name throughout the rest of this plan.

#### Injected context

`hook_additional_context`, ~358 records. The content the model received. Every one
renders, whether tool-owned or turn-boundary:

| origin | count |
| --- | --- |
| tool-owned (`PreToolUse:*`, `PostToolUse:*`) | ~217 |
| turn-boundary (`SessionStart`, `UserPromptSubmit`, `Stop`) | ~141 |

#### Unrecognised output

`hook_success` with no known `hookSpecificOutput` key (44 = 24 unparseable + 20
empty stdout). Intended as "a guard ran and passed quietly", but no such record
exists — there are no tool-owned *silent* passes:

```
20  Stop             completion-review.sh   → no owning call, content empty
13  PreToolUse:Edit  nvim-cmd-guard.sh      → toolu_-owned, content NON-empty
11  PreToolUse:Write nvim-cmd-guard.sh      → toolu_-owned, content NON-empty
```

Every tool-owned record carries `content`. At the time of writing it read
`m='`:help'` — a shell-assignment leak from that script rather than deliberate
output, since fixed.

**Surface it anyway.** The category is "output we do not recognise", and both
things it can be are worth seeing: a hook bug shows up early instead of silently
producing nothing, and an unfamiliar schema is not quietly discarded. That is why
this is a second body channel rather than a relabelling of the roster — it renders
`hook_success.content`, unlike injected context which renders
`hook_additional_context`.

#### Failures

Content-gated. `hook_cancelled` always;
`hook_non_blocking_error` only when it carries real stderr. All ~84 current
non-blocking errors have `stdout == ""`, `exitCode == 1` and the SDK's placeholder
stderr:

```
"Failed with non-blocking status code: No stderr output"
```

so the gate is implementable only as *stderr ≠ that literal* — **version-coupled
to the CLI**; revisit on bump. Ungated it would raise 84 false alarms about
working hooks (`path-skill-guard.sh` ×82, `bell.sh` ×2, all exiting 1 as a
"nothing to say" return). The gate keeps the timeouts, all three of which are
`hooks/permission_hook.sh` at 600 s — *our own* hook hanging.

## Rendering

**Each record is one closed fold row, appended to the chat buffer — no heading.**
A hook injection is a separate input the model received between tool uses, even
when the preceding tool call is what triggered it, so it is its own region rather
than part of the tool call's output. `SessionStart`, `UserPromptSubmit` and `Stop`
records are not special-cased.

**Follow unit 5's shape** (`feature-thinking-summary-line.md` § "That row **is**
the closed fold"): the body goes in a `markdown-fold` fence closed at render, the
glyph is a `sign_text` extmark on the fence's visible row, and the summary lives
in the foldtext. Not `write_notice` — that method builds a heading, and a heading
is what this shape exists to avoid:

`queries/agentic/context.scm` captures `(section (atx_heading (inline))
(fenced_code_block))`, so a *titled* heading over a fenced body pins the
treesitter-context breadcrumb for as long as the cursor stays in the section.
Hook bodies are fenced, so headings would pin — and inconsistently, since an empty
ATX heading has no `inline` child and is never captured, meaning the ~86 untitled
records would behave differently from the titled ones. No heading, no divergence.
This is the same reasoning unit 5 gives for having none.

Glyph constraints come from `PLAN-gutter-identity.md` § "Glyph vocabulary", not
from this plan: `nf-md-*`, never emoji, `sign_text` must be `glyph .. " "`, must
avoid the seven tool kinds (󰈈 󰏫 󰆍 󰍉 󰖟 󰚩 󰒓), and `󰋚` history is reserved for a
future rewind. `󰛢` U+F06E2 `nf-md-hook` satisfies all of them.

Body: parse the record line as JSON, render `content` neatly when present, write
the line verbatim when it does not parse. `content` is a list whose single element
is **plain text** (358/358) — do not attempt a second JSON parse one level in.
Bodies run 25–1844 chars (1–25 lines).

The fold must be closed **explicitly** via `self:_close_fold(anchor)`, with
`Renderer.set_dim_range` for the dim. `MessageWriter._pending_fold_ops`' field
docstring documents the foldexpr leak whereby a fold created after a closed one
inherits the closed state, so nothing may rely on the default. `wrap_prose` the
body as sidecar bodies are, so the foldtext's line count matches what `zo` shows.

Appending a region rather than mutating a tool-call block avoids three constraints
a fields-on-the-block design would have to change: the frozen-diff early return
for Edit/Write (the `already_has_diff` branch in
`MessageWriter:update_tool_call_block`), the single-valued `fold_anchor`/`fold_open`
return contract in `prepare_block_lines`, and `vim.tbl_deep_extend` replacing
list-valued fields in the `ToolCallBase` merge.

**Placement of late records.** PreToolUse records (1835/1835, the overwhelming
majority) are on disk before the terminal `tool_call_update`, so draining there
appends immediately after the tool-call block — the correct position. PostToolUse
records (56, of which ~28 are injected context) land after the tool result; if the drain
waits until turn end, intervening prose will already have been written and the
block appends after it. Options: accept the slight misordering, or adopt trigger 3
below to drain promptly. Not blocking — it affects ~28 records.

**Nothing to do for the blocking case.** A block arrives as a `tool_result` with
`is_error`, already lifted into `ToolCallBase.failure_reason`.

## Triggers

Two real signals plus one that needs an adapter change:

1. **Terminal `tool_call_update`** — covers every PreToolUse record, and appends
   in the right place.
2. **Turn end.** `MessageWriter:finalize_turn` has **nine** call sites in
   `session_manager.lua` — four command notices, three `/delete`+`/rename` failure
   messages, the usage-limit respawn path, and one on `subagent_writer`. Hooking the drain at the call sites means nine edits and a
   guaranteed miss — introduce a single chokepoint. This is the backstop for the
   last call of a turn and for turn-boundary records.
3. **The bridge's PostToolUse-callback `tool_call_update`**
   (`acp-agent.js:5966-5979`) — **currently dropped before the plugin sees it.**
   `ClaudeAgentACPAdapter:__handle_tool_call_update` returns early when `not update.status
   and (not rawInput or empty)`, and that update has neither. Optional: it only
   buys prompt placement for the ~28 PostToolUse injected-context records. If adopted the change
   must be **drain-only** — admitting it into `__build_tool_call_update`
   would set `body` from `extract_content_body`, mutating
   `tracker.body` through the `---` divider path (the body-merge divider path in `update_tool_call_block`)
   even though `already_has_diff` prevents any re-render, and that mutated body is
   what gets persisted (the `ChatHistory.ToolCall` projection in `SessionManager:_on_tool_call_update`).

   Scope if adopted: fires for every tool *except* TodoWrite and `Task*` (skipped
   at `acp-agent.js:5930-5944`), never for a tool that did not run; registration
   is gated on `registerHooks` (`:5946`), false only inside `replaySessionHistory`
   (`:3622`), so live turns always register.

Byte offsets make drains non-duplicating, and reads are synchronous so concurrent
drains cannot interleave. Turn cancellation (Ctrl-C), turn errors and
`respawn_after_usage_limit` all still reach a `finalize_turn`, so trigger 2 covers
them.

## Reader design

Minimal I/O: given a path and a byte offset, return newly appended lines and the
new offset.

**Catch-up on first path discovery, not `fs_stat` at load.** The path is unknown
until the first matching hook fires — by which time the file size also swallows the
current turn's records. Instead: record a wall-clock marker when the session is
created *or* loaded; on first path discovery, read the file once and keep records
with `timestamp >= marker`; then set the offset to the file size. All hook records
carry a UTC `Z` ISO-8601 `timestamp`, so the comparison is a plain string compare.
This collapses the new-vs-resume special case into one rule and prevents a resumed
session re-rendering its entire history (up to ~1.8 MB).

- A separate process appends: `new_offset` points **just past the last complete
  line**. That *is* the carry-the-remainder mechanism — no separate remainder
  state.
- **`size < offset` → reset the offset.** `seek("set", offset)` past EOF returns
  nothing, permanently. Covers compaction, rotation, and replacement under the
  same name.
- Filter to `type == "attachment"` with a `hookEvent`, then dispatch by group.
- Subagent transcripts out of scope (and see the basename guard above).

Error handling, against the "never silently swallow" rule: a record that does not
parse is *rendered verbatim* — visible, not swallowed. A missing or unreadable
transcript when a path *was* supplied surfaces once via `Logger.notify`;
`debug_to_file` alone is off by default and would hide it.

## Structure

| piece | location | contract |
| --- | --- | --- |
| byte-exact tail read | `read_appended(abs_path, offset)` in `lua/agentic/utils/file_system.lua` | → `lines, new_offset`; `new_offset` just past the last complete line |
| record decoder | new `lua/agentic/acp/adapters/claude_hook_records.lua` | pure line → `{group, hook_name, command, content, …}`; no IO, no state |
| drain + offset + marker | new `lua/agentic/hook_record_reader.lua`, one per session, instantiated in `SessionManager:new` alongside `ChatHistory`/`PermissionManager` | `drain()`; unit-testable without a SessionManager |
| block rendering | a `markdown-fold` fence + `sign_text` glyph + per-kind foldtext, per unit 5 | no heading, no new writer method |

`claude_utils.lua` is "constants and helpers for the Claude ACP adapter" — jsonl
record decoding is a different contract, so a sibling file rather than an addition.
A per-session reader object (not two fields on the 2700-line `SessionManager`)
satisfies `.claude/rules/multi-tabpage.md`: no module-level per-tabpage state.

**Do not build the tail read on `FileSystem.read_from_disk`** — its
`content:gsub("\r\n", "\n")` (`file_system.lua:51`) desynchronises byte offsets.
Use `io.open` + `seek("set", offset)`.

**Reset.** Path, offset and marker must be cleared wherever the ACP session is torn
down. `SessionManager:_cancel_session` nils `session_id` and installs
a fresh `ChatHistory`; `/clear`, `/new`, provider switch and restart all route
through it. A stale path+offset carried into the next session reads the wrong file
at the wrong position. Also state how the state interacts with `_restoring` /
`_session_epoch` / `_destroyed` (the `SessionManager` class field docs).

## Persistence

A standalone hook block wants a new `ChatHistory.Message` variant — the alias has
no hook case today (`chat_history.lua:23-27`). That is the clean route, and notably
*cheaper* than the alternative: a new `ToolCallBase` field would be silently
dropped by both hand-picked field projections
(the `ChatHistory.ToolCall` projections in `SessionManager:_on_tool_call_update` and `session_restore.lua`), the known class in
`notes/bug-chat-history-drops-tool-call-enrichment.md`.

Restore is phased last. Until it lands, say so in the writer's docstring so the
next reader does not file the absence as a bug.

## Phasing

Phase 1 has **no dependency on the gutter-identity programme** — it is file IO and
decoding with no rendering, so it can proceed in parallel with that programme's
unit 1. Phase 2 onward consumes unit 5's fold-row shape and its per-kind foldtext
dispatch, so it waits on **unit 5**; it is independent of units 1–4. The separate
`informational` conversion below is the one part that needs unit 1.

1. `read_appended` + the reader object (path, marker, offset, `drain()`) + the
   decoder. No rendering. Testable in isolation.
2. Injected context as fold rows on triggers 1 and 2 — the bulk of the value
   (~358 records). Needs unit 5.
3. Failures and unrecognised output.
4. Optional: trigger 3 (adapter change, drain-only) for prompt placement of the
   ~28 PostToolUse records.
5. Persistence — new `ChatHistory.Message` variant.

Tests are **co-located `<module>.test.lua`** per `.claude/rules/tests.md` —
`lua/agentic/utils/file_system.test.lua` already uses `os.tmpname()` in five
places, the pattern for the byte-offset tests. `tests/fixtures/` is not the right
home. `make validate` is the gate.

## The fold row

The glyph is settled: `󰛢` U+F06E2 `nf-md-hook` for injected context, satisfying
every constraint in `PLAN-gutter-identity.md` § "Glyph vocabulary". Failures need a
second glyph from the same vocabulary.

**The script basename in the foldtext, and nothing else.** Where the row lands
already says what the event was — beside a tool call for
`PreToolUse`/`PostToolUse`, at the turn boundary for
`SessionStart`/`UserPromptSubmit`/`Stop` — so naming the event is redundant with
position. The glyph says "hook". The only thing position and glyph do not carry is
which script ran:

```
󰛢 ··· shell-guard.sh · 8 lines ···
󰛢 ··· json-validate.sh · 3 lines ···
󰛢 ··· 12 lines ···                     ← no name available
```

This extends `folds.lua`'s `M.foldtext` (`··· %d lines ···`) per fold kind, which
unit 5 is already doing for thought folds — one dispatch, two consumers.

`hookName` is not a fallback. It is lossy enough to give adjacent rows identical
summaries over different bodies: `PreToolUse:Bash` covers five scripts
(`shell-guard` 56, `git-repo-guard` 38, `bash-pitfall-guard` 24,
`nvim-headless-remind` 22, `jq-guard`), `PreToolUse:Edit` five more.

**No name means no name shown.** The `parentUuid` join lands for 253 of 339
records; all 86 misses are `UserPromptSubmit`, whose records never point at a
`hook_success`, so no script name exists. Those fall back to the plain line count —
which is the unmodified foldtext, so it costs nothing.

Foldtext is virtual text, not buffer content, so markdown never parses it. That
removes the emphasis hazard a raw-text heading would have carried for basenames
containing two underscores (`my_hook_name.sh` → `_hook_`).

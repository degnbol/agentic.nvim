# Bug: hook blocks render one drain late

## Observed

A `PreToolUse` hook's injected context renders *below* the prose and tool calls
that followed the call it fired on, instead of directly under that call's block:

````markdown
Plan rewritten. One thing to flag first — the hook reports the file changed
externally between my failed Bash write and this Write … Checking whether it's
recoverable:
###
```zsh
git status --porcelain plans/…
```
 ✔ completed
###
```markdown-fold pre-edit-track.sh
/Users/…/plans/….md was modified externally since your last edit.
```
````

Not the misordering `PLAN-hooks_in_chat.md:287-293` accepts — that covers
`PostToolUse` records only. `pre-edit-track.sh` is registered `PreToolUse` on
`Write|Edit`, and `session_manager.lua:1505-1518` drains on every terminal
`tool_call_update` precisely so those land under the block that triggered them.

## Cause

The premise that comment and plan rest on — *"a PreToolUse hook's records are on
disk before this call's terminal update"* — was inferred from **file order** in
the transcript jsonl (`PreToolUse before tool_result: 1835/1835`). File order is
not write order. From the transcript of the run above:

```
284 assistant  tool_use Write            19:20:09.988  uuid f33be277
288 attachment hook_non_blocking_error   19:20:10.148  toolUseID toolu_01W2Ve…
289 attachment hook_success              19:20:10.238  pre-edit-track.sh
290 attachment hook_additional_context   19:20:10.238  toolUseID toolu_01W2Ve…
291 user       tool_result               19:20:57.150  uuid 31acb910
292 attachment queued_command            19:17:00.352  parent 31acb910
293 attachment queued_command            19:17:58.627  parent 31acb910
```

Lines 292-293 falsify the inference: attachments timestamped 3½ minutes *before*
line 291 sit *after* it in the file, so position says nothing about when a line
was written. They do not pin when the 288-290 batch reached disk — that chain
parents to the **assistant** message (284), already persisted at 19:20:09 — so
the exact flush moment stays unknown.

It does not need to be known. The plugin tails a file another process writes
with no completion signal, so **every drain trigger is a guess**: not the
terminal update, not the bridge's `PostToolUse` callback update
(`hook_patch_facts`, `claude_agent_acp_adapter.lua:276-325`), not a deferred
re-read. The drain empirically missed; the fix below is correct whatever the
flush timing turns out to be, which is the point of it.

### Rejected: drain later instead

Keep append-at-end and move *when* the drain fires — to the head of the next
content write (start of a prose run, so once per run: `_chunk_start_line == nil`;
plus `write_tool_call_block` and `finalize_turn`). All of §2 and §3 below
disappear. In the demonstrated case the next prose chunk arrives hundreds of ms
after the records exist, so they would land correctly.

Rejected anyway: it is the same race with a wider window, and the failure is
silent and unreproducible when it does bite.

## Fix

Place a region by the tool call it belongs to, not by where the buffer happens
to end when the drain fires. `attachment.toolUseID` on the record
(`toolu_01W2Ve…`) is byte-identical to the plugin's own `tool_call_id`, and
`claude_hook_records.lua:145-154` currently drops it.

Verified across `~/.claude/projects/*/*.jsonl`: `toolUseID` is present on
3374/3374 hook attachments in every group; 198/235 context-record ids appear
verbatim as a `tool_call_id` in `~/.cache/nvim/agentic/sessions/` (the remainder
are sessions that were never persisted); 0/125 `toolu_` references in a main
transcript point at a `tool_use` absent from that file, so a record cannot
mis-anchor onto a subagent block.

Both existing drain triggers stay. They stop being correctness-relevant and
become only *when to look* — which also retires the `PostToolUse` misordering
caveat, since those records carry a `toolUseID` too.

### 1. Carry the anchor through

- `claude_hook_records.lua` — add `tool_call_id` to `HookRecord`, straight from
  `attachment.toolUseID`. **No `^toolu_` prefix test**: the block lookup is a
  better test than a prefix rule, and also covers a `toolu_` record whose block
  was never rendered. The `@field` must say the slot is overloaded —
  turn-boundary events put `"SessionStart"`, `hook-<uuid>` or a bare message
  uuid there — otherwise the next reader trusts the name.
- `hook_record_reader.lua` — no change, the field rides along.
- `session_manager.lua:1380` — pass `record.tool_call_id` to `write_hook_block`.

### 2. Insert at the anchor

`MessageWriter:write_hook_block(body, script, tool_call_id)` resolves
`tool_call_blocks[tool_call_id]`, reads its range extmark
(`nvim_buf_get_extmark_by_id`, `NS_TOOL_BLOCKS`) and inserts at **`end_row + 2`**:
`end_row` is the status-footer row, and the block's trailing blank is appended
*after* the extmark is set (`message_writer.lua:2010-2017`), so it sits at
`end_row + 1`.

Split `_write_collapsed_region` (`message_writer.lua:688-747`) three ways so the
two placements share what they should:

- **build** the fenced lines from `body` + `source` (pure),
- **place** them — append at end, or `set_lines` at a row,
- **decorate** `body_start..body_end` (sign, dim, `_close_fold`). On the insert
  path those rows derive from the insert row, not from `nvim_buf_line_count`.

The inserted layout must reproduce the append path's byte for byte, `###`
included: a tool call block's *first* line is `### <name>`
(`tool_call_renderer.lua:183`), and the bare `###` is what closes that section
so treesitter-context does not pin the tool call's heading over the region
(`queries/agentic/context.scm`). Emit it unconditionally on the insert path, but
do **not** consume `_pending_section_break` — that flag refers to the most
recently written block, which by then may not be the anchor.

Three append-only steps stay on the append path:

- `_end_prose_run` — the run below a mid-buffer insert is still live.
- `_release_prose_pin` — an inserted region follows nothing, so releasing the
  pin would discard a viewport promise about unrelated content.
- `flush_thought_run` — load-bearing when appending (the region would otherwise
  land above the thought), but anchored it force-renders buffered thinking for
  no ordering reason.

**Repeat records on one anchor.** A block's end extmark does not move for
inserts below it, so a second record would insert at the same row, *above* the
first, reversing transcript order. Give the tracker a `trailing_insert_mark_id`:
a zero-width mark in `NS_TOOL_BLOCKS`, placed at the insert point on first use
with `right_gravity = true` so it rides past each inserted region and the next
insert reads it back. Handles repeats within a drain and across drains
(~20 tool calls carry two context records — `PLAN-hooks_in_chat.md`). It must be
dropped alongside the tracker when `update_tool_call_block` bails on a corrupt
range (`message_writer.lua:2139-2141`).

**Bail to append on a bad anchor**, mirroring that same sanity gate: extmark
missing, `details.end_row` nil, `start_row >= end_row`, or `end_row` past
`nvim_buf_line_count`.

That bail is a guard, not the fix for §2's real hazard:

> **Stale trackers survive a session clear.** `ChatWidget:clear()`
> (`chat_widget.lua:316-347`) empties the buffers and clears `NS_USER_ACTIONS`
> and `NS_DECORATIONS` via `MessageWriter.clear_regions`, but not
> `Renderer.NS_TOOL_BLOCKS`; `SessionManager:_load_session`
> (`session_manager.lua:2441-2467`) rebuilds `chat_history` and `_hook_records`
> but leaves `message_writer.tool_call_blocks` populated. Those extmarks
> collapse onto row 0 on the `set_lines(0, -1)`. Today a stale id costs nothing.
> With anchoring, a record that slips past the reader's `_marker` — which
> truncates to the whole second, so a same-second record from the outgoing
> session passes — inserts at row 0 of the *new* conversation.
>
> Reset `tool_call_blocks` and clear `NS_TOOL_BLOCKS` where the buffers are
> cleared. Pre-existing bug; this change is what makes it bite.

### 3. Shift the rows the insert moves

Mid-buffer insertion is already a solved problem here: `update_tool_call_block`
resizes blocks above live prose and fixes up the absolute-row state at
`message_writer.lua:2236-2266` via `shift_across_block` (`:2031`). An insert is
the degenerate case of that arithmetic — nothing is swallowed, so everything at
or after the insert row shifts by `+#lines` and the pin never needs releasing.
What differs is the field set, not the maths, so extract
`_shift_rows_below(row, delta)` over `_chunk_start_line`,
`_prose_run_start_line` and `_prose_anchor_line`.

- **Not** `_last_divider_line`: it is a line *count*, and its only reader
  `emit_divider` is called solely on `subagent_writer`
  (`session_manager.lua:505`) while the drain writes to `self.message_writer`.
- The turn-usage footer is an extmark on the last row (`:1315`), so it moves on
  its own — but keep the drain last in `_finalize_turn`, which still appends
  unanchored records.
- Region signs, fold anchors and block extmarks all move with their lines.
- `_auto_scroll(bufnr)` before the write — the insert grows the buffer, so the
  `autoscroll` skill's discipline rule applies to this path too.
- A mid-buffer insert dirties the treesitter tree and foldexpr for everything
  below it, unlike an append. `update_tool_call_block` already pays this cost;
  noted because this path adds ~2 more per tool call in a long chat
  (cf. `notes/bug-autoscroll-conceal-perf.md`).

### 4. Tests

- `claude_hook_records.test.lua` — `toolUseID` surfaces as `tool_call_id`;
  absent → nil.
- `message_writer.test.lua` — region lands under its anchor when other content
  follows; a `###` sits above it; appends at end for an unknown anchor; falls
  back to append on a stale or degenerate anchor; two records for one anchor
  keep transcript order; the insert neither releases the prose pin nor consumes
  `_pending_section_break`; a live prose run below the insert is still bracketed
  from its own first row.
- `session_manager.test.lua` — the drain forwards the anchor id.

### 5. Correct the stale premise

Both places assert the falsified on-disk-before-terminal-update claim and would
otherwise re-seed it: the comment at `session_manager.lua:1505-1509` and
`PLAN-hooks_in_chat.md:287-293`.

## Out of scope

Hook regions are still not persisted — `ChatHistory` has no hook message
variant, so a restored session shows none of them
(`message_writer.lua:786-787`).

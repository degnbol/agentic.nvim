# Plan: ACP v2 Edit/Write diffs — every hunk, and the patch facts
Status: draft
Priority: P2

## Relevant files
- `lua/agentic/acp/adapters/claude_v2_codec.lua` (`v1_diffs`, `v1_content`, `decode_tool_call_update`), its test
- `lua/agentic/utils/unified_diff.lua`, its test
- `lua/agentic/acp/acp_client.lua` (`find_content_diff`)
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua` (`__apply_edit_diff`, `hook_patch_facts`, `__handle_tool_call_update`), its test (`on a recorded ACP v2 turn, decoded`)
- `lua/agentic/ui/message_writer.lua` (`ToolCallDiff`, `file_created`/`hunk_ranges` fields, `update_tool_call_block`)
- `lua/agentic/ui/tool_call_diff.lua`, `tool_call_layout.lua` (diff render, `cached_diff_blocks`), `diff_jump.lua` (permission float jumps)
- `lua/agentic/utils/grant_safety.lua` (`is_pure_addition`, `edit_target_range`), `ui/permission_manager.lua` (`_kind_args`)
- `lua/agentic/session_manager.lua` (`_try_record_edit_range`, `_record_file_op`)
- `lua/agentic/skeptic/turn.lua` (`unified_diff`)
- `tests/fixtures/acp_v2_turn.jsonl`
- Bridge 0.97.0: `dist/diff.js` (`previewPatchContent`, `v2UpdateFromDiffToolResponse`, `v2DiffContent`, `hunkRange`), `dist/tool-calls/reporters/file-edit.js`, `dist/acp-agent.js` `previewFileChange`
- Skills: `provider-system` § "Edit diffs come from `content[]`"; global `acp` → `references/claude-agent.md` § PostToolUse update

## Background
On v2 an Edit/Write diff is a git patch of the whole-file change, 3 context
lines per hunk (`diffHunks`). It comes from the PreToolUse preview
(`previewFileChange`), then again from the PostToolUse hook only when the
written file differs from the prediction — the field tracker drops an
unchanged `content` (fixture line 22: the hook update holds only `locations`).
`EditReporter` sends no input diff to a v2 client, so the patch is the only
diff an Edit or Write has.

**Gap 1 — only hunk 1 renders.** The codec's one-v1-item-per-hunk output is a
real v1 shape: the v1 PostToolUse update (`toolUpdateFromDiffToolResponse`)
sends exactly that. The codec cannot do better in v1 terms: one item spanning
all hunks needs the unchanged lines between them, which the patch does not
hold. So the codec stays, and the adapter must read every diff item. The
tracker's `diff` holds one old/new pair, so it needs a way to hold more.
Additive (`rest`) rather than a list-typed `diff`: `diff` is persisted in
session files, and the other adapters keep sending one pair.

`replace_all` stops being read: every site of a patch is its own hunk, and
matching a hunk with context "all" times would duplicate blocks. The adapter
is v2-only (`ClaudeAgentACPAdapter.v2_codec`), so no v1 path needs it.

**Gap 2 — no `hunk_ranges`, no `file_created`.** The facts are in the patch
(`changes[1].operation`, hunk headers) but the v1 items drop the headers. The
codec is the only layer that sees them, so it emits them in the v1 shape that
already carries them: a status-less `tool_call_update` with
`_meta.claudeCode.toolResponse = { type, structuredPatch }`, after the update
whose content held the patch. `hook_patch_facts` then works unchanged. The
facts now arrive before the tool runs (from the preview); both consumers
(`_record_file_op`, `FileActivity`) only act on `completed`, and a changed
hook patch re-sends them.

**Merge hazard.** v2 can deliver a second patch (the hook's). `tbl_deep_extend`
merges `diff.old`/`diff.new`/`diff.rest`/`hunk_ranges` by index, leaving stale
tails. Today's guard (ignore hook content) does not apply on v2. Assign those
two fields wholesale, as `set_output_tail` does. The rendered diff stays frozen
at the first render (`cached_diff_blocks` included); only tracker data updates.

## Changes
1. `unified_diff.lua`: `Hunk` gains `old_start`, `old_count`, `new_start`,
   `new_count` (integers, read from the header). A zero count keeps git's
   header start, which names the line before (`hunkRange`).
2. `claude_v2_codec.lua`:
   - `local function patch_facts(diff) -> table|nil` — the v1 hook
     `toolResponse` of a v2 diff: `{ type = "create"|"update", structuredPatch
     = { { oldStart, oldLines, newStart, newLines }... } }`. `type` from
     `changes[1].operation` (`add` → `create`). A zero-count side gets its start
     back + 1 (the SDK `structuredPatch` start, not git's). Nil without
     `changes[1]`; empty `structuredPatch` without a patch (a created file whose
     text cannot be patched still reports `create`).
   - `decode_tool_call_update`: after the v1 update of a report whose content
     holds a v2 diff, append `{ sessionUpdate = "tool_call_update", toolCallId,
     _meta = { claudeCode = { toolName, toolResponse } } }`. Not from
     `decode_permission` (one request out; the preview update precedes it).
   - Docstrings: what the facts update comes from.
3. `acp_client.lua`: `ACPClient:find_content_diffs(update) ->
   agentic.acp.ToolCallDiffContent[]` (every `type == "diff"` entry, in order);
   `find_content_diff` returns its first.
4. `message_writer.lua`:
   - `ToolCallDiff` gains `@field rest? { old: string[], new: string[] }[]` —
     further old/new pairs of the same change, in file order.
   - `file_created` doc: reported once the provider knows the change, which on
     some providers is before the tool runs.
   - `update_tool_call_block`: when the partial has `diff` or `hunk_ranges`,
     assign it over the merged tracker's.
5. `tool_call_diff.lua`: `M.pairs(diff) -> { old: string[], new: string[] }[]`
   (`{old,new}` then `rest`). `extract_diff_blocks` gains
   `opts.pairs?` (`{old,new}[]`): match each pair as now, concatenate the
   blocks, sort by `start_line`; `old_text`/`new_text` stay for one pair.
6. Consumers read `ToolCallDiff.pairs`:
   - `tool_call_layout.lua` build: pass all pairs; `is_create` requires every
     old side empty.
   - `diff_jump.lua`: the fallback `extract_diff_blocks` and reverse match take
     all pairs (cache path unchanged).
   - `grant_safety.lua`: `is_pure_addition` — every pair is one;
     `edit_target_range` — span from the first pair's match start to the last
     pair's match end, nil when any pair is not found (a superset, so the
     disjointness check stays conservative).
   - `session_manager.lua` `_try_record_edit_range`: skip a diff with `rest`
     (one record per call; claiming the span between hunks would claim lines
     the agent did not write). `_record_file_op` fallback unchanged (one pair
     for a creation).
   - `skeptic/turn.lua` `unified_diff`: one `vim.text.diff` per pair, joined.
7. `claude_agent_acp_adapter.lua`:
   - `__apply_edit_diff`: first diff item → `old`/`new`, the rest → `rest`,
     `all = false`; drop the `replace_all` read and rewrite the docstring (the
     patch is the diff; the partial-input reason still rules out `rawInput`).
   - `hook_patch_facts` docstring: on v2 the codec builds this update from the
     patch and it carries no `content`; the merge-hazard paragraph moves to
     `update_tool_call_block`.
8. Tests:
   - `unified_diff.test.lua`: header numbers, including `@@ -9 +8,0 @@` and
     a count-less range.
   - `claude_v2_codec.test.lua`: multi-hunk patch → N diffs then one facts
     update; `add` → `type = "create"`; zero-count start correction; diff
     without patch → no diff items, facts with empty `structuredPatch`; no
     facts update for content without a v2 diff.
   - `claude_agent_acp_adapter.test.lua`: two diff items → `diff.rest`,
     `all == false` with `replace_all = true` in `rawInput`; recorded v2 turn
     → `hunk_ranges = {{start_line=1,end_line=1}}`, `file_created = false`.
   - `tool_call_diff`/`tool_call_layout` tests: two far-apart pairs render two
     hunks at their lines; `cached_diff_blocks` holds both.
   - `grant_safety.test.lua`: `is_pure_addition` and `edit_target_range` with
     `rest`.
   - `message_writer.test.lua`: a second, shorter `diff` / `hunk_ranges`
     replaces the first, no stale tail.
   - `session_manager.test.lua`: `_try_record_edit_range` skips a diff with
     `rest`.
9. Docs: `provider-system` skill § "Edit diffs come from `content[]`" — replace
   the `replace_all` paragraph with: on v2 a change arrives as one diff item
   per hunk, read into `diff.rest`, and `hunk_ranges`/`file_created` come from
   the codec's facts update. `doc/agentic.txt` needs nothing (no user-visible
   option changes).

## Expected outcome
- A replace_all over far-apart sites, a long Edit whose middle is unchanged,
  and a Write over an existing file render every hunk; diff jumps reach each.
- File activity on v2 records `create` vs `edit` exactly and carries line
  ranges; session files keep `hunk_ranges`.
- Grant checks see the whole change: no multi-hunk edit passes as a pure
  addition because hunk 2 was invisible.

## Non-goals
- An Edit the bridge cannot patch (file >1 MiB, CR line endings, binary,
  `old_string` not unique) shows no diff on v2 — the bridge sends none.
- A created file whose text cannot be patched shows no diff.
- Context lines in owned ranges: a single-hunk record claims its 3 context
  lines each side, as a v1 `old_string`'s anchor lines were claimed; not
  narrowed here.
- Recording owned ranges for multi-hunk edits (needs several records per call).

## Open questions
1. Permission Q: add a v2 note to the global `acp` skill's
   `references/claude-agent.md` § PostToolUse update (a v2 client gets a
   `diff` with `changes` and a git `patch`, 3 context lines, no
   `toolResponse`; the preview sends it first and the hook re-sends only when
   it differs)? Yes / no.

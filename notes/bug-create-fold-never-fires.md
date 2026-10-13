# Bug: `create_max_lines` folds a created file only on the streaming path

Line numbers against `cc07515` + working tree.

## Mechanism

`prepare_block_lines` sets `is_create` (`tool_call_renderer.lua:894-895`) from
`#source_lines == 0` and an empty `diff.old`, i.e. from whether the target file
can be read *at render time*. `_render_block_fold` (`message_writer.lua:2498`)
stores the resulting state in `fold_open`, and the status-only branch of
`update_tool_call_block` replays it at final status
(`message_writer.lua:2949-2951`). So the result depends on the disk state when
the diff first renders:

| when the diff first renders | outcome |
| --- | --- |
| non-final status, file not yet written | collapses at final status (correct) |
| diff arrives on the `completed` update | file exists → `fold_state = "open"` |
| restore from session history | file exists → `fold_state = "open"` |
| file unreadable, or an existing 0-byte file | `is_create = true` — not a create |

The `#source_lines == 0` clause stops a large Write over an existing file from
folding (Write sends no `old_string`, so an empty `diff.old` alone does not
identify a create). Disk state after the edit cannot separate a create from a
Write over an existing file, and `kind` cannot either.

`file_created` (set by `hook_patch_facts`, `claude_agent_acp_adapter.lua:505`)
is exact but does not solve this: only the Claude adapter sets it, it arrives
after the tool runs (after the first render), and the history payloads do not
persist it.

So record existence before the edit lands and before the first render, persist
it, and read it at render.

## 1. Record it before the first render

Pre-edit facts are recorded in `_try_record_edit_range`
(`session_manager.lua:2040`). It skips `completed`/`failed` (disk is post-edit)
and `self._loading` (the session/load replay sends past edits as `pending`
while disk is post-edit). The new recorder needs the same two skips.

It must run *before* the writer call, not after it like
`_try_record_edit_range` (`:1992`, `:2458`). `_render_block_fold` fixes
`fold_open` at the first render, and the status-only branch only replays it. A
flag set after that render has no effect on the streaming path.

- `_on_tool_call` (`:1948`): set `tool_call.file_existed_before` before
  `write_tool_call_block` at `:1967`.
- `_on_tool_call_update`: set it on `tool_call_update` before
  `writer:update_tool_call_block` at `:2456`, only when the tracker does not
  have it yet. Take the path from `tool_call_update.argument or
  tracker.argument`. `tbl_deep_extend` in `update_tool_call_block` merges the
  field into the tracker.

Value: `vim.uv.fs_stat(path) ~= nil`. Use `fs_stat`, not a read: existence is
the question, and a directory, an unreadable file and a 0-byte file all count
as existing.

Guard `argument ~= ""` explicitly. `fnamemodify("", ":p")` is the cwd, so an
empty argument stats the working directory and records "existed".
(`_try_record_edit_range` guards only `not tracker.argument`. That is harmless
there because `read_from_disk` rejects a directory, but do not copy it.)

## 2. Persist it

History payloads are built field by field (`session_manager.lua:1971-1984` in
`_on_tool_call`, `:2462-2473` in `_on_tool_call_update`). Add the flag to both,
and add `@field file_existed_before? boolean` to
`agentic.ui.MessageWriter.ToolCallBase` (`message_writer.lua:104`). Without
this, the restore path stays broken.

## 3. Read the flag at render

`is_create = tool_call_block.file_existed_before == false`, in place of the
`#source_lines == 0` + empty-`diff.old` pair. Use `== false`, not `not …`: nil
means "not observed before the edit" (a diff that first arrived at
completion), which must not collapse.

A diff that first arrives on the `completed` update re-renders with a final
status, so `_render_block_fold` queues the close directly. No change to the
status-only branch is necessary.

## Tests

- `tool_call_renderer.test.lua`, `describe("create collapse")` (`:1014`): set
  `file_existed_before` in `fold_state_for` instead of depending on
  `read_stub` returning nil. Add a case: `file_existed_before = true` with an
  empty `diff.old` and a large `diff.new` stays `open`.
- `message_writer.test.lua`: "closes a large created file only when it
  completes" (`:5156`) and "keeps a fold the user opened through a repeated
  completion" (`:5197`) depend on their `/tmp` paths not existing. Set
  `file_existed_before = false` on the block. Add a case: a block written with
  `status = "completed"` and `file_existed_before = false` (the restore shape)
  folds closed.
- `session_manager`: the flag is `false` for an absent path, `true` for an
  existing one, unset for an empty `argument`, unset during `_loading`, and set
  on the message before the writer receives it.

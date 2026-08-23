# Bug: `create_max_lines` never folds a created file

Found reviewing `47f46a3` + `e3c0710`. Line numbers are against `50ed666`;
`message_writer.lua` has uncommitted changes from unrelated work in flight, so
anchor on the named symbols there.

## Mechanism

`is_create` at `tool_call_renderer.lua:755-756` requires `#source_lines == 0`,
i.e. *the target file could not be read*, and fold state is applied only at
final status (both `is_final_status` gates in `MessageWriter`). By then a
successful create is on disk, so the collapse never fires. Verified by headless
render:

| when the diff first renders | outcome |
| --- | --- |
| streaming (`pending` → `completed`) | status-only branch of `update_tool_call_block` returns before the fold block; never reached |
| diff arrives on the `completed` update | re-renders, but the file exists → `fold_open = true` |
| restore from session history | file exists → `fold_open = true` |
| file unreadable at final status | `fold_open = false` — the `argument == ""` pathology, which is not a create |

`e3c0710` added the `#source_lines == 0` clause to stop a large Write over an
existing file from folding (Write sends no `old_string`, so the previous
`diff.old`-only test called it a create). That removed the false positive and the
true positive together.

Nothing at final render substitutes for the missing fact: `kind` doesn't
separate a create from a Write over an existing file. So record existence before
the edit lands, persist it, and read it at render.

## 1. Record it where pre-edit facts are already recorded

`_try_record_edit_range` (`session_manager.lua:1028`) exists for exactly this
shape of problem — it is called from both `_on_tool_call` (`:1009`) and
`_on_tool_call_update`, works off the merged tracker rather than a partial
update, is idempotent, and skips `completed`/`failed` because disk is post-edit
by then. Mirror it: a sibling that sets
`tracker.file_existed_before = vim.uv.fs_stat(path) ~= nil` on the first call
that has a path and a non-final status.

`fs_stat`, not a read: existence is the question, and a directory, an unreadable
file and a 0-byte file all count as existing.

Guard `argument ~= ""` explicitly — `fnamemodify("", ":p")` is the cwd, so an
empty argument would stat the working directory and record "existed".
(`_try_record_edit_range` itself guards only `not tracker.argument`, at `:1051`;
harmless there because `read_from_disk` rejects a directory, but don't copy it.)

## 2. Persist it

History payloads are built field-by-field (`session_manager.lua:996-1005` and
`:1256-1262`), so the flag has to be added to both, plus
`@field file_existed_before? boolean` on `agentic.ui.MessageWriter.ToolCallBase`
(`message_writer.lua:79-89`). Skipping this leaves the restore path — where the
old behaviour was most visible — still broken.

## 3. Read the flag at render

`is_create = tool_call_block.file_existed_before == false`, replacing the
`#source_lines == 0` + empty-`diff.old` pair. `== false` rather than `not …`:
nil means "never observed pre-edit" (a diff that first arrived at completion),
which must not collapse.

## 4. Apply the fold on the frozen path

Even with a correct flag a streaming create never folds, because
`update_tool_call_block`'s status-only branch returns before the fold block.
Store the render's `fold_anchor` offset on the tracker and apply fold state from
that branch once the status is final.

## Tests

- Rewrite the three `describe("create collapse")` cases
  (`tool_call_renderer.test.lua:381-420`) to set `file_existed_before` instead of
  relying on `read_stub` returning nil. As written they assert a state production
  never reaches.
- `session_manager`: the flag is `false` for an absent path, `true` for an
  existing one, and unset for an empty `argument`.
- `message_writer`: a `completed` status-only update on a create block whose diff
  exceeds `create_max_lines` closes the fold.

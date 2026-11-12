# Plan: A chat id that outlives its ACP sessions
Status: reviewed spec

Builds on the buffer-name change (names `agentic://<key>/…`, `BufferNames`,
`SessionResume.open_name`, `SessionRegistry.session_for_key`).

## Relevant files

- `lua/agentic/ui/chat_history.lua` — `ChatHistory` fields, `new`,
  `copy_prefix`, `get_file_path`, `find_files`, `read_saved`, `save`,
  `from_data`, `read_sessions_from_folder`, `newest_per_id`,
  `match_sessions`; types `SessionRef`, `SessionHeader`, `SessionMeta`,
  `StorageData`, `ForkLink`
- `lua/agentic/session_manager.lua` — `_adopt_session`, `_session_changed`,
  `_install_history`, `_reset_conversation`, `load_acp_session`,
  `_do_load_acp_session`, `PendingLoad`, `target_session_id`, `new_session`
  (comment on the history's file), `ForkStart`, `fork_at_cursor`,
  `_do_start_fork`, `_started_fork`, `_delete_session`, `_persist_history`,
  `_write_session`, the `resume_session` keymap (`marked_id`)
- `lua/agentic/session_recovery.lua` — `renew_session`, `restart_client`
  (carry `sm.chat_history`; tests only)
- `lua/agentic/session_registry.lua` — `session_for_key`
- `lua/agentic/session_resume.lua` — `resume`, `open_name`, `PickerOpts`
- `lua/agentic/session_resume_builtin.lua`, `session_resume_fzf.lua` —
  `marked_id`, preview cache keyed by `item.session_id`
- `lua/agentic/init.lua` — `load_acp_session`, `resume_session`
- `lua/agentic/subagents.lua` — `rename_buffers`
- `lua/agentic/ui/message_writer.lua` — `write_fork_link`
- `lua/agentic/utils/buffer_names.lua` — `Parts.key` docstring
- Docs: `doc/agentic.txt` (`*agentic-buffer-names*`, `agentic.load_acp_session`,
  `agentic.resolve_session`, `*agentic-commands-resume*`), `CLAUDE.md`
  ("Session cache location"), `session-lifecycle` skill
- Tests: `chat_history.test.lua`, `session_resume.test.lua`,
  `session_manager.test.lua`, `session_recovery.test.lua`,
  `tests/integration/test_open_names.lua`, `test_fork.lua`,
  `test_session_load.lua`, `test_history_new_session.lua`

## Background

A chat moves to a new ACP session on a provider switch (`switch_provider`),
on a re-create from history (`restart_session`, a failed load's fallback)
and on a renewal (`SessionRecovery.renew_session`, after a usage limit or a
re-login's `restart_client`). Each move changes `session_id`, so:

- Buffer names change, and rows written before the move (session messages,
  fork links) name the old id. `gf` on one finds no live session and loads
  the pre-move file into a second chat.
- `ChatHistory:save` writes `<new-id>.json`; `<old-id>.json` stays as a
  stale copy of the conversation before the move.
- `_adopt_session` resets the history's creation time.

The chat id is the first ACP session id a history is adopted under, kept by
the history for its life. The session file is named by it, and the file
name is its only record: existing files need no migration, since each is
named by its first id. The file keeps the current ACP id in `session_id`,
which `session/load` takes.

A history that has never been adopted has no chat id: `ChatHistory:new` and
`copy_prefix` (a fork) leave it nil, so `/new` and a fork start a new chat;
`switch_provider`, `restart_session` (`vim.deepcopy`), `renew_session`,
`restart_client` and the load fallback carry it.

Buffer names follow one invariant: the key is `self:chat_id()`, else
`tostring(self.id)`. Every change of `chat_id()` renames. A chat's key then
changes only at a reset or a load, both after `_subagents:reset()`, so
transcripts and inputs need no rename, and a buffer's key always resolves
to its owner through `session_for_key`.

## Changes

1. `ChatHistory`:
   - Field `chat_id?: string`. `copy_prefix` does not copy it.
   - `get_file_path(chat_id, cwd)`, `find_files(chat_id)`,
     `read_saved(chat_id)`: parameter renamed; behaviour unchanged.
   - `save(cwd)` writes `<chat_id>.json` and refuses without `chat_id`
     ("No chat_id set"). The file stores `session_id`, not `chat_id`.
   - `ChatHistory.from_data(data, chat_id: string)`: the chat id is the
     file's name, given by the caller.
   - Types: `SessionRef.session_id` becomes a required `chat_id`;
     `StorageData` keeps `session_id` (the ACP id); `SessionMeta` has
     `chat_id` (the file name) and `session_id` (from the file, else the
     file name).
   - `ForkLink.session_id` becomes `ForkLink.chat_id`; `from_data` reads
     `link.chat_id or link.session_id`.
   - `newest_per_id` groups by `chat_id`. `match_sessions` matches a prefix of
     `chat_id` or `session_id`.
2. `SessionManager`:
   - `SessionManager:chat_id(): string|nil` replaces `target_session_id`:
     `chat_history.chat_id`, else `_pending_load.chat_id`.
   - `SessionManager:_name_buffers()`: `widget:rename_buffers(self:chat_id()
     or tostring(self.id))`. Called by `_reset_conversation`,
     `_install_history`, `_adopt_session`, `load_acp_session` when it defers
     (`_pending_load`) and `_do_load_acp_session`. `_session_changed` no
     longer renames.
   - `_adopt_session`: when the history has no `chat_id`, set it to
     `session_id` and reset `timestamp`; otherwise keep both.
   - `load_acp_session(chat_id, cwd, model, on_shown)`, `PendingLoad.chat_id`
     and `_do_load_acp_session(chat_id, …)`: `read_saved(chat_id)` and
     `from_data(data, chat_id)`. One local ACP id, `saved.session_id` else
     `chat_id` (no file: the id is an ACP id), feeds `self.session_id`,
     `agent:load_session`, `agent:unsubscribe`, `chat_history.session_id`
     and the resume notice. Without a file, `chat_history.chat_id = chat_id`.
   - `ForkStart.source_chat_id: string` beside `source_id` (the ACP id for
     `fork_session`). Links store `chat_id`; both title fallbacks use the
     chat id's first 8 characters; `_started_fork` finds the source with
     `SessionRegistry.session_for_key(fork.source_chat_id)`.
   - `_delete_session` removes the files of `chat_history.chat_id` and tests
     that instead of `self.session_id`; `_persist_history` and
     `_write_session` test `history.chat_id`.
   - The `resume_session` keymap marks `self:chat_id()`.
   - `new_session`: drop the comment about the new id having no file yet.
3. `SessionRegistry.session_for_key(key)`: the session whose `chat_id()` or
   `session_id` is `key`, else `by_id[tonumber(key)]` while its `chat_id()`
   is nil.
4. Delete `Subagents:rename_buffers` and its call. In
   `SessionResume.open_name`, check only the keyed session's buffer for a
   reload, not every live session's.
5. `SessionResume.resume(ref, opts)` keys on `ref.chat_id`. Pickers: items
   and the fzf preview cache key on `chat_id`; `PickerOpts.marked_id` and
   `Agentic.resume_session` use the owner's `chat_id()`.
6. `Agentic.load_acp_session({id}, …)`: `{id}` is a chat id, or the ACP id of
   a session with no saved file.
7. Docs and docstrings: `*agentic-buffer-names*` keys on the chat id ("the
   ACP session id the chat started with"); `agentic.load_acp_session` and
   `agentic.resolve_session` say chat id; `CLAUDE.md` cache path
   `<chat-id>.json`; `session-lifecycle` skill names line;
   `BufferNames.Parts.key`, `copy_prefix`, `session_for_key`, `PendingLoad`,
   `marked_id` in `PickerOpts` and `session_resume_builtin.lua`.
8. Tests (first):
   - A save after `switch_provider`, `restart_session` and `renew_session`
     writes the same file with the new `session_id`, keeps `timestamp`, and
     keeps the buffer names; `gf` on a message row written before the move
     shows the live transcript.
   - A legacy file loads under its file name; a file whose `session_id`
     differs from its name sends `session/load` for the inner id.
   - `copy_prefix` drops `chat_id`; a fork gets its own chat id and file.
   - `session_for_key` finds a live switched chat by its current ACP id.
   - A load fallback without a file starts a new chat id.
   - Picker rows and `match_sessions` by either id; `/delete` during a
     switch removes the chat's file.
   - `test_open_names.lua` "renames transcripts and blocks when the session
     id changes" becomes: names stay after `_adopt_session(…, true)`.

## Expected outcome

- A chat keeps one id, its buffer names, its creation time and one session
  file across provider switches, re-creates from history and renewals.
- Names and fork links written from this change on open the chat's live
  buffers.
- Existing session files load unchanged.

## Non-goals

- Merging the stale `<old-id>.json` copies past switches left behind: each
  stays a chat of its own, and rows written before this change open them.
- `Agentic.load_acp_session` with a later ACP id of a switched chat that is
  not open: `:AgenticResume` prefix matching covers it.
- What `AgenticSessionChanged`, the welcome header and ACP messages carry:
  they keep the ACP id.

## Open questions

None.

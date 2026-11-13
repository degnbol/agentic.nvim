# Plan: append finished messages to the session file
Status: reviewed (open questions)
Priority: P3

After 6a17d2e (landed): `_is_finished` lists its `side_records` type, and
its `from_data` round-trip test and unknown-kind filter
(`remove_unknown_side_records`) move to `ChatHistory.read` here.

f87761d (landed) moved `_agents` and `_agent_key` to `Subagents`
(`lua/agentic/subagents.lua`, `agent_key`), so `_chain_running`'s subagent
half is a `Subagents` method.

## Relevant files

- `lua/agentic/ui/chat_history.lua` — `save`, `from_data`, `get_file_path`, `find_files`, `read_sessions_from_folder`, mutators
- `lua/agentic/ui/chat_history.test.lua` — "save and read", "list_sessions", "find_files", "get_file_path"
- `lua/agentic/session_manager.lua` — `_persist_history`, `_agent_key`, `_agents[...].open`, `_do_load_acp_session` (`saved_data`), `_delete_session`
- `lua/agentic/session_resume.lua` — `SessionResume.resume` reads `read_saved`
- `lua/agentic/session_resume_fzf.lua` — the preview reads the session file; `ctrl-x` deletes it
- `lua/agentic/ui/message_writer.lua` — local `is_final_status`
- `lua/agentic/utils/file_system.lua` — `write_atomic`, `mkdirp`
- `CLAUDE.md` § Session cache location
- Skill: `session-lifecycle`

## Background

`ChatHistory:save` encodes the whole history (all messages, subagent messages,
subagents, file activity) and rewrites `<session-id>.json`, after a `mkdirp`.
The cost of one save grows with the session: the largest saved session is
10 MB, and `vim.json.encode` of it takes 12 ms. `_history_changed` saves on
every history change while no turn is pending: at each turn end, on every
main-agent chunk of a turn no prompt started (`_on_agent_chunk`), and each time a
background subagent's tool call completes or fails after the turn
(`_on_tool_call_update`). The session picker also
decodes every session file in full to list titles.

Most messages do not change after they are finished, so a save only needs to
append the messages that finished since the last save. A message that is not
finished is not written: after a crash, a tool call with no final status or a
half-streamed reply is not a result to resume from. Old `.json` sessions are not
read; they can be converted separately.

## Changes

### Files

Per session, in the project folder:

- `<session-id>.meta.json` — header: `session_id`, `title`, `timestamp`,
  `last_activity`, `cwd`, `provider`, `provider_version`, `model`,
  `subagents`, `file_activity`, `prompt_count` (the non-synthetic `user`
  messages in `messages`). Rewritten on every save with
  `FileSystem.write_atomic`, which also creates the folder.
- `<session-id>.jsonl` — one record per line,
  `{"seq":<integer>,"message":<message>}`. `seq` is the message's insertion
  order across `messages` and `subagent_messages`. A full log write uses
  `FileSystem.write_atomic` (tmp file + `fs_rename`), so a crash never leaves
  half a rewrite.

### `lua/agentic/utils/tool_call_status.lua` (new)

```lua
--- @param status agentic.ui.ToolCallStatus|nil
--- @return boolean final `completed`, `failed` or `cancelled`
function M.is_final(status)
```

`message_writer.lua` replaces its local `is_final_status` with it.

### `lua/agentic/utils/file_system.lua`

```lua
--- Append `content` to a file, creating it.
--- @param abs_path string
--- @param content string
--- @return boolean ok
--- @return string|nil err
function FileSystem.append_to_disk(abs_path, content)
```

`FileSystem.mkdirp`'s docstring says it stays named because
`chat_history.test.lua` stubs it; update or drop that reason once the tests
below stop stubbing it.

### `lua/agentic/ui/chat_history.lua`

New private fields on `agentic.ui.ChatHistory`:

```lua
--- @field _next_seq integer
--- @field _seq table<table, integer> Message → seq, weak keys
--- @field _written table<table, true> Messages whose record is in the log, weak keys
--- @field _rewrite boolean The next save writes the whole log
--- @field _log_path? string Log the written records are in
```

New public field, set by `ChatHistory.read` from the meta file and by `save`:

```lua
--- @field cwd? string Working directory the session was saved under
```

Mutators:

- `add_message`, and `append_agent_text` when it adds a message: give the
  message the next seq.
- `append_agent_text` merging into a written message, `update_tool_call` on a
  written message, `set_subagent_task` changing a written message's
  `agent_key`: set `_rewrite`. `update_tool_call` gives the merged
  table the old one's seq.

New functions:

```lua
--- Whether `msg` is finished: `user`, `session_message`, `subagent_end` and
--- `side_records` are finished when added; a `tool_call` at a final status; an `agent` or `thought`
--- once a later message shares its list and `agent_key`, or once
--- `running(msg.agent_key)` is false.
--- @param msg agentic.ui.ChatHistory.Message
--- @param running fun(agent_key: string|nil): boolean
--- @return boolean
function ChatHistory:_is_finished(msg, running)

--- Path of the log beside a meta file.
--- @param meta_path string `<dir>/<session-id>.meta.json`
--- @return string log_path `<dir>/<session-id>.jsonl`
function ChatHistory.log_path(meta_path)

--- Read a session from its meta file and the log beside it. A log line that
--- does not decode (a write cut short by a crash) is left out and reported.
--- A missing log reads as no messages.
--- @param meta_path string
--- @return agentic.ui.ChatHistory|nil history Messages in seq order, all marked written to this log; `_next_seq` past the highest seq
--- @return string|nil err
function ChatHistory.read(meta_path)

--- Delete a session's meta file and its log.
--- @param meta_path string
--- @return boolean ok
--- @return string|nil err
function ChatHistory.delete(meta_path)
```

`get_file_path(session_id, cwd)` keeps its name and returns the meta path.
`save`, `read` and `delete` take the log path from `ChatHistory.log_path`, so
the `.meta.json` → `.jsonl` mapping exists once.

`save` gets a second parameter:

```lua
--- @param cwd string
--- @param running fun(agent_key: string|nil): boolean Whether the agent of a message chain (nil: the main agent) is still running
--- @return string|nil err
function ChatHistory:save(cwd, running)
```

- Write the meta file first (`write_atomic` creates the folder, so `save`
  no longer calls `mkdirp`).
- `_rewrite`, or a log path other than `_log_path`: write every finished
  message in seq order as a new log (`write_atomic`). Otherwise append the
  finished unwritten messages in seq order with one `append_to_disk`; with
  none, no log write.
- On success mark them written, clear `_rewrite`, and set `_log_path` and
  `cwd`.
- `dirty` after a successful save: true while a finished message is
  unwritten. An unfinished message does not count: quit protection while an
  agent works comes from `SessionManager:_sync_modified`, which keeps the
  chat modified while a turn or a subagent works.

Other changes in the file:

- `from_data` (with its `subagent_event` filter) and the `StorageData` class
  go. `ChatHistory.read` builds the history.
- The `dirty` field docstring and the `save` docstring ("Clears `dirty` on
  success") take the meaning above.
- `ChatHistory.read_saved` uses `ChatHistory.read` and
  returns `agentic.ui.ChatHistory|nil`. `SessionResume.resume` reads the
  same `cwd`, `provider` and `model` fields from it. `_do_load_acp_session`
  drops `saved_data` and its `from_data` call: `saved_history` is the
  `read_saved` result, and the `_cwd` fallback reads `saved_history.cwd`.
- `find_files` looks for `<session-id>.meta.json`.
- `read_sessions_from_folder` reads only `*.meta.json`, takes
  `prompt_count` from it, and strips `%.meta%.json$` for the session id.
- `agentic.acp.SideRecord`'s docstring (from 6a17d2e)
  names `ChatHistory.read` instead of `from_data` as where a field rename
  needs a migration.

### `lua/agentic/session_manager.lua`

- New `SessionManager:_chain_running(agent_key)`: for nil,
  `self:_turn_open()`. Otherwise true when an agent in `self._agents`
  is `open` and its child id or `self:_agent_key(child_id)` is the given id.
- `_persist_history` passes `function(id) return self:_chain_running(id) end`.
- `_delete_session`'s `do_delete` calls `ChatHistory.delete` for each path
  `find_files` returns.

No caller replaces the message lists in place, so nothing sets `_rewrite`
from outside. A load: the
main messages are the file's records plus the replay's tail. A re-create
from history (the load fallback, `restart_session`) takes a new session id,
so its first save writes the whole log (the log path differs from
`_log_path`). `restart_session`'s `vim.deepcopy` keeps `_seq` and `_written`
consistent: it copies keys through the same cache as the lists, and keeps
the weak-key metatable.

### `lua/agentic/session_resume_fzf.lua`

- Preview: replace `FileSystem.read_json(item.file_path)` with
  `ChatHistory.read(item.file_path)`; it reads `history.messages`.
- `ctrl-x`: replace `os.remove(item.file_path)` with
  `ChatHistory.delete(item.file_path)`.

### `CLAUDE.md` § Session cache location

Name both files, and grep `"title":"<name>"` in `*.meta.json`.

### Tests (`chat_history.test.lua`)

Replace "save and read" with:

- Two saves with a message added between: the log after the second save
  starts with the bytes of the first.
- A pending tool call is not in the log; after its final status, the next save
  appends it.
- An agent message is not written while it is the last of a running chain; it
  is written once a later message is added, or once `running` returns false.
- Updating a written tool call makes the next save rewrite the log, and
  `ChatHistory.read` gives the updated call once.
- Round trip: `save` then `ChatHistory.read` gives the same `messages`,
  `subagent_messages` (in order), `subagents`, title and file activity.
  The side-record round trip (`side_records` message, `passed` hook with an
  empty body, `is_compaction`) reads through `ChatHistory.read`; a
  `side_records` message is in the log after the save that adds it.
- A save under a new session id writes the whole log.
- A log whose last line is cut off reads the other records and returns an
  error.
- A meta file with no log reads as a history with no messages.
- `ChatHistory.delete` removes both files.

These cases write to disk (`use_disk`): the new writes go through
`write_atomic` and `append_to_disk`, which the `write_file` and `mkdirp`
stubs do not cover.

Update "list_sessions", "find_files", "get_file_path" and "read_saved"
(it returns a history; the undecodable case corrupts the meta file) for the
meta file. Delete the "from_data" case.

## Expected outcome

- A save costs in proportion to the messages that finished since the last
  save plus the meta file, not to the session's length. A rewrite happens
  only after a written message changes or the history is replaced.
- Listing sessions reads only the meta files.
- After a crash, a resume shows the session up to its last finished messages.
- `dirty` means only that a finished message is not on disk.

## Non-goals

- Reading or converting old `<session-id>.json` files.
- Saving in the middle of a turn (unchanged: the turn-end save writes it).

## Open questions

1. Main chain running outside a prompt. `_chain_running(nil)` is
   `self:_turn_open()`, but a main-agent turn no prompt started (a received
   message starts one) streams with `_prompt_pending == 0`, and
   `_on_agent_chunk` calls `_history_changed` on each of its chunks. Each
   save then sees the reply as finished and writes it; the next chunk merges
   into a written message and sets `_rewrite`, so the turn rewrites the
   whole log per chunk. No field records such a turn today. Options: add a
   state for an unprompted main turn and count it in `_turn_open`;
   or stop saving per main chunk outside a prompt, as subagent text already
   does.
2. Tool calls that never reach a final status. Only a cancelled turn
   (`_mark_unresolved_tool_calls_cancelled`) and a subagent that ends other
   than `completed` stamp `cancelled`. A turn that ends with an error, or a
   provider that drops a call, leaves it pending: it is never written, even
   on a clean quit, and `dirty` does not protect it. Should a `tool_call`
   also count as finished once `running(msg.agent_key)` is false,
   as `agent` and `thought` do?

# Plan: split old read ranges once, where a session file is read
Status: reviewed spec
Priority: P3

## Relevant files
- `lua/agentic/session_resume.lua` — `SessionResume.replay_messages` (the
  `tool_call` branch)
- `lua/agentic/ui/chat_history.lua` — `ChatHistory.from_data`,
  `prepend_history_messages` (reads `read_range`)
- `lua/agentic/acp/canonical_tool_call.lua` — `split_read_range`, `normalise`
- Tests: `lua/agentic/ui/chat_history.test.lua` (`from_data`),
  `lua/agentic/session_resume.test.lua` (`replay_messages`),
  `lua/agentic/acp/canonical_tool_call.test.lua` (`split_read_range`)
- Notes: `notes/PERF-append-session-log.md` deletes `from_data` and does not
  read old `.json` files
- Skills: `implement`

## Background
Tool call records saved before ingress normalisation (4af0d60) hold a read's
range in `argument` (`path (1 - 20)`). Live records are split at ingress
(`CanonicalToolCall.normalise`). `replay_messages` runs `split_read_range`
on every stored `tool_call` record at every replay: on a load, on each
`_reload_chat`, and each time a subagent transcript is rendered again.
`from_data` is the only place a session file becomes a history. It already
migrates old data: it drops `subagent_event` rows and side records of
unknown kinds. The split belongs there, once per read. It also gives
`prepend_history_messages` the same record shape as a live one; its text
does not change, because `format_read_range` writes back the `(N - M)` the
split removed.

## Changes
- `chat_history.lua`, `from_data`: after the filters, replace each
  `tool_call` message in `instance.messages` and `instance.subagent_messages`
  with `CanonicalToolCall.split_read_range(msg, msg.kind)`. Use a local
  `split_read_ranges(messages)` beside `remove_unknown_side_records`, with a
  one-line docstring naming the old format. It updates the list in place
  (`from_data`'s lists are new tables from `vim.tbl_filter`); the
  replacements are copies, so `data`'s message tables stay as read. The history stays not dirty: the
  file is rewritten in the new shape at the next save, as for the other
  migrations.
- `session_resume.lua`, `replay_messages`: the `tool_call` branch calls
  `writer:write_tool_call_block(ChatHistory.to_tool_call_block(msg))`. Drop
  the comment. The `CanonicalToolCall` require stays (`status_word`).
- Tests (first):
  - `chat_history.test.lua`: `from_data` on a `read` record with
    `argument = "a.lua (1 - 20)"` gives `argument = "a.lua"` and
    `read_range = { offset = 1, limit = 20 }`, in both message lists. An
    `execute` record whose argument ends in `(1 - 2)` is unchanged.
  - `session_resume.test.lua`, `replay_messages` case "splits a saved
    read's range, keeping execute fences": the read half moves to the
    `from_data` test above. The execute half stays, renamed "keeps a saved
    execute body's fences": replay must still not run `normalise`.

## Expected outcome
Old session files render as today. The split runs once per file read, not
once per replay.

## Non-goals
- Rewriting session files on disk at load.
- The session picker preview (`SessionResume.format_preview`), which reads
  the raw file and shows `argument` only.

## Open questions
None.

Order: `notes/PERF-append-session-log.md` deletes `from_data` and reads only
the new `.jsonl` log, which holds no unsplit record. This plan applies only
while `from_data` exists. If PERF lands first, only the `replay_messages`
change and its test remain: no loaded record needs the split.

# Bug: the first save after a session/load drops what only the file held

Found in code review of `89fae9e`. Mechanism read from code.

## Mechanism

`_do_load_acp_session` starts from an empty `ChatHistory:new()`. From the
session file it copies only `title`, `file_activity`, `subagents` and
`subagent_messages`, and it stashes each tool call's `decided_by` for the
replayed call to take. The messages come from the provider's replay. The
first change after the load
saves the whole history (`ChatHistory:save`), so the file is rewritten from
the replay. Anything the file held that the replay does not carry is lost:

- the original `timestamp` (overwritten at the start of the load);
- any message the provider does not replay;
- tool-call fields that the replay sends in a different form than live
  updates did.

## Fix

`notes/PLAN-load-file-first.md`.

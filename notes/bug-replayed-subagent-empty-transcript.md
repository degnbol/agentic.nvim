# Bug: a subagent block from a session/load replay points to an empty transcript

Found by a headless load of real sessions (claude-agent-acp 0.85.1). Mechanism
read from code.

## Observed

- After a `session/load`, the subagent block opens an empty transcript.
- The subagent's messages sit in a second transcript that no block points to.
- The saved file gains one `subagents` entry per replayed subagent, with no
  `task_id`. An empty entry is encoded as `[]`.

## Mechanism

- The bridge replays a subagent under the id
  `<session-id>:replay-subagent:<toolu-id>` (`acp-agent.js`, `replaySessionHistory`).
  Live, the child id is the SDK task id.
- `_open_agent` makes the block and the `subagents` entry under the replay id.
  The record lookup (`_read_agent_record` → `agent:subagent_record`, a meta
  file named by the agent id) misses that id, so the block's
  `subagent` info has no `agent_type`, a predicted mode and `confirmed = false`.
- While `_loading`, the subagent gates in `_on_session_update` and
  `_on_tool_call` return before `_note_agent_task`. So the replay id never gets
  its `task_id`.
- `_restore_transcripts` maps the file's messages (keyed by `task_id`) to the
  live child id from the file. It makes one transcript for that id, which holds
  the messages, and one empty transcript for the replay id, which the block
  points to.

## Scope

- With `notes/PLAN-load-file-first.md`, the part of a session that the file
  covers no longer goes through the replay. The bug remains for subagents in
  the replay's tail, and for a load with no session file.
- The replay id ends in the `toolu` id of the `Agent` call, and that id equals
  the `task_id` that the file records for the live child. A fix can map the
  replay id to its task id from that suffix. This is provider knowledge, so it
  belongs in the Claude adapter (next to `subagent_task_id`).

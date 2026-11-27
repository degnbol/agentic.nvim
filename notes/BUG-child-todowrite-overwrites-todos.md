# Bug: a subagent's TodoWrite list replaces the main agent's todos

`SessionManager:_on_session_update` renders every `plan` update into the main
todos panel (`self.todo_list:render(update.entries)`) and ignores
`source_session_id`.

claude-agent-acp 0.97.0 sends a child's `plan` on the child session (stamped
`parentToolUseId`, routed by `routeUpdate` in `native-subagents.js`). Its
entries depend on the tool:
- Task tools (`TaskCreate`, `TaskUpdate`, `TaskList`): the whole list of the
  root session (`session.taskState`), which subagents share. The main panel is
  the right place for it.
- `TodoWrite`: the child's own list (`planEntries(chunk.input)` in
  `acp-agent.js`). Rendering it replaces the main agent's list.

The bridge does not disable `TodoWrite`; which of the two the SDK offers is a
Claude Code setting. Shared code cannot tell the two `plan` kinds apart from the
update alone.

Not yet reproduced in a live session. Reproduce: integration test with a
`plan` whose `source_session_id` is an announced child, then check the main
todos buffer.

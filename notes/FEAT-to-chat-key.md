# Plan: key from a subagent to its chat
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/config_default.lua` (`keymaps.agent` and its heading comment)
- `lua/agentic/session_manager.lua` (`_bind_fork_keymaps`)
- `lua/agentic/utils/buf_helpers.lua`
- `lua/agentic/subagents.lua` (`_bind_agent_keymaps`, `_open_input`'s
  `setup_buf`)
- `lua/agentic/ui/chat_widget.lua` (`show`, `target_win`)
- `doc/agentic.txt` § agentic-subagents, keymap table
- Skills: `subagents`; rule `session-isolation`

## Background
`:Agentic` from a transcript already shows that session's chat
(`SessionRegistry.current()` resolves the buffer's owner). A key saves the
typing, from transcripts and from subagent message inputs.

## Changes
- Extract `BufHelpers.bind_window_variants(keys, bufnr, fn, desc)` from the
  local table in `_bind_fork_keymaps`: binds each key, plus `<C-w>` + key
  (split) and `<C-w>g` + key (tab); `fn(mods)`. `_bind_fork_keymaps` uses it.
- `keymaps.agent.to_chat = "<localLeader>h"`; heading comment mentions
  message inputs.
- Bind it in `Subagents:_bind_agent_keymaps` and in `_open_input`'s
  `setup_buf` with `fn(mods) = self._widget:show(mods, self._widget:target_win())`.
- `doc/agentic.txt`: the key in the keymap table and § agentic-subagents.

## Expected outcome
One key from any transcript or subagent input shows the chat; `<C-w>` and
`<C-w>g` before it open the chat in a split or a tab. From a nested subagent
it also goes to the chat.

## Non-goals
- A key to the direct parent of a nested subagent.

## Open questions
None.

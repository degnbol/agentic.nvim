# Plan: keep the chat modified while a subagent works
Status: reviewed spec

## Relevant files

- `lua/agentic/session_manager.lua` — `_sync_modified`, `_set_prompt_pending`, `_history_changed`, `_write_session`, `_start_agent`, `_end_agent`, `_close_agents`, `_forget_agents`, `_reset_subagents`, `_advance_session_epoch`, `_on_subagent_update`, `agentic.SessionManager.Agent.open`
- `tests/integration/test_buffer_lifecycle.lua` — "subagent transcript" and its helpers (`subagent_chunk`, `capture_notify`)
- `doc/agentic.txt` — `*agentic-buffers*`
- Skills: `session-lifecycle`; global `acp` → `references/claude-agent.md` § "Background subagents hold the prompt turn"

## Background

`_sync_modified` sets the chat's `modified` flag to `history.dirty` or
`_prompt_pending > 0`. Its docstring gives the reason for the second term: a
running turn counts even once written, because quitting would cut it off. So
`:qa`, `:wqa`, `:bd` and `:e` refuse while the main turn runs.

claude-agent-acp keeps `session/prompt` open until the background subagents
of that turn end, so they are usually covered by `_prompt_pending`. A
subagent works with no turn pending after an early settle: the next prompt is
echoed, that turn ends, and the subagent still works. Foreground subagents
run only inside a turn, so outside one every open subagent is a background
one.

In that state the flag tracks only unsaved history. A subagent's chunks and
tool calls only mark the history dirty; it is written when one of its tool
calls ends or a row (session message or end) is written. So the chat is clean from each such
save until the next chunk, while the subagent still works. A `:qa` in that
window quits, `VimLeavePre` stops the provider, and the subagent's work stops
with no warning.

The rule for the main turn applies to a subagent too: while it works, the
chat is still being written. `open` on `agentic.SessionManager.Agent`
already records "working, as far as this session manager knows".

Transcripts keep their own flag (`unsaved` only). `:bd` or `:bw` on a
transcript does not stop its agent, so there is nothing to protect there.

## Changes

### `lua/agentic/session_manager.lua`

New local function, above `_sync_modified`:

```lua
--- Whether `sm` has a turn pending or an open subagent.
--- @param sm agentic.SessionManager
--- @return boolean
local function turn_or_subagent_running(sm)
```

A local function, not a method: every test stub that calls the real
`SessionManager._sync_modified` already has `_agents` and `_prompt_pending`.

New method, beside `_set_prompt_pending`:

```lua
--- Mark a subagent working or not, and with it the chat's `modified` flag.
--- @param agent agentic.SessionManager.Agent
--- @param open boolean
function SessionManager:_set_agent_open(agent, open)
```

- `_sync_modified`: the chat's flag becomes
  `unsaved or turn_or_subagent_running(self)`.
  Docstring: "the chat's also while a turn or a subagent works. Running work
  counts even once written: quitting would cut it off, so `:qa`, `:wqa`,
  `:bd` and `:e` refuse until it ends. ...".
- `_start_agent`, `_end_agent` and the `_forget_agents` loop write `open`
  through `_set_agent_open`. It is the only writer of `open` after
  construction; `_open_agent` and `_restore_transcripts` still build agents
  with `open = false`.
- `_history_changed`: docstring "With no turn in flight the change is written
  at once. Mid-turn only the chat's `modified` flag follows it, and the
  turn-end save writes it." (drops "an idle session is never left modified",
  which an open subagent makes false).
- `_reset_subagents`: `self:_sync_modified(self.chat_history)` after
  `self._agents = {}`.
- `_advance_session_epoch`: call `_forget_agents` before
  `_set_prompt_pending(0)`, so the last sync sees both cleared.
- `_write_session`: the notice condition becomes
  `turn_or_subagent_running(self)`, and the text "History written; the chat
  stays modified while a turn or a subagent runs".

### `doc/agentic.txt` (`*agentic-buffers*`)

- Replace "The chat is 'modified' while a running turn's history is not yet
  written." with "The chat is 'modified' while its history is not yet
  written, and while a turn or a subagent works."
- In the next sentence, replace "An idle session writes" with "With no turn
  running, the session writes".

### `tests/integration/test_buffer_lifecycle.lua`

Model the early settle: no turn pending, a subagent started through
`_on_subagent_update` with `state = { state = "running" }`, then a chunk from
it so the history is dirty. The new cases go in a nested
`describe("while a subagent works")` inside "subagent transcript", where its
helpers are in scope:

- chat modified:
  - set while a subagent works, also after `:w`;
  - cleared when an `idle` update ends it;
  - cleared by `on_disconnect` (`_close_agents`);
  - cleared by `_reset_subagents` (`clear_chat`);
  - cleared by `_advance_session_epoch`.
- quitting:
  - `:qa` refuses with E37;
  - `:bd` on the chat refuses with E89;
  - `:wqa` writes the session file with the chunk in it, does not quit, and
    shows the `_write_session` notice (`capture_notify`);
  - `:qa` quits after an `idle` update ends the subagent.

## Expected outcome

- `:qa`, `:wqa`, `:wq` and `:x` on the chat, `:bd` on the chat and `:e` on
  the chat refuse while a subagent works, as they do during a main turn.
  `:qa!`, `:bd!` and `:e!` still act.
- `:w` while a subagent works writes the history, keeps the chat modified and
  says why.
- With no turn running and no subagent working, the flag means only "the
  history is not on disk".

## Non-goals

- The transcripts' `modified` flag.
- Which messages a save writes (`PLAN-append-session-log.md`, which relies on
  this plan for quit protection).
- The main agent's follow-up cycle after a background subagent ends outside
  any turn (`acp` → `references/claude-agent.md` § "Background subagents hold
  the prompt turn"). The flag clears at the subagent's `idle` update, so a
  `:qa` during the follow-up cuts it off. Nothing on ACP v1 marks the cycle's
  end: claude-agent-acp reports it only to v2 clients (`ForegroundEvents` in
  its `turn-events.d.ts`), and the cycle's `usage_update` tagged
  `task-notification` also comes for placeholder results that end nothing.
- A subagent the provider never reports as ended. It stays working until
  `on_disconnect`, a new session or `:qa!`, as its working indicator does. A
  state other than `idle` or `unknown` (for example `failed`) is treated as
  still working, as it is today for the indicator.

## Open questions

None.

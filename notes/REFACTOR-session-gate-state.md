# Plan: one load state, one turn predicate, one gate reason
Status: reviewed spec

## Relevant files
- `lua/agentic/session_manager.lua`:
  - load state: `_loading`, `_loading_saved`, `_replay_hold`, `_replay_dropped`,
    `_pending_load_session_id`/`_cwd`/`_model` (class fields); the constructor's
    on-ready callback; `load_acp_session`, `_do_load_acp_session` (and its
    `session/load` callback), `_refresh`, `_advance_session_epoch`,
    `_cancel_session`, `_dispatch_turn`, `_take_replay_update`,
    `_dispatch_replay_tail`
  - `_loading` readers: `_persist_history`, `_sync_modified`, `_history_changed`,
    `_write_session`, `_write_chat_row`, `_on_agent_chunk`, `_on_session_update`
    (`subagent_update` branch), `_on_tool_call`, `_try_record_edit_range`,
    `_submit_defer_reason`
  - `is_generating` readers passing `mid_turn`: `_display_context_usage`, `_rename_session`, `_refresh_name`,
    `_notice_model_switched`, `_notice_mode_switched`,
    `_notice_thought_level_switched`, the `GrantCommand:new` closure
  - gate: `agentic.SubmitDeferReason`, `HOLD_CAUSE`, `_submit_defer_reason`,
    `_submit_hold_reason`, `_handle_input_submit`, `_relay`, `_drain_queue`
- `lua/agentic/session_recovery.lua` — `_announce_reauth` (`mid_turn = sm.is_generating`)
- `lua/agentic/grant_command.lua` — `is_mid_turn` constructor argument (unchanged)
- `lua/agentic/ui/message_writer.lua` — `write_notice` (`mid_turn` contract, unchanged)
- Tests: `lua/agentic/session_manager.test.lua` (`_do_load_acp_session: _loading_saved flag`,
  `_advance_session_epoch`, `_submit_defer_reason`, `submit gating`,
  `_drain_queue`, `in-flight gate accounting`, the `_notice_model_switched`
  case "takes the notice level from the generating state", and the stubs that
  set `_loading` or `_submit_hold_reason`), `lua/agentic/session_recovery.test.lua`
  (`make_session`), `tests/integration/test_session_load.lua`,
  `tests/integration/test_history_new_session.lua`, `tests/integration/test_native_subagents.lua`,
  `tests/integration/test_usage_limit.lua`
- Docs: `session-lifecycle` skill (§ Guards, § The in-flight counter), project
  `CLAUDE.md` § Session lifecycle (names `_loading_saved`)
- Notes that read `_loading`: `notes/FEAT-shell-changes-from-git.md`,
  `notes/bug-create-fold-never-fires.md`; `notes/PERF-append-session-log.md`
  (`_chain_running(nil)` and its open question 1)
- Skills: `session-lifecycle`, `implement`, `lua-class`

## Background
### Load state
Four fields encode one load's progress:
- `_loading_saved`: a load is deferred or in flight. Read only by the
  constructor's on-ready, which otherwise starts a new session. That
  callback runs on first ready. For the session whose constructor created
  the provider's client, it runs again on each reconnect
  (`ACPClient._on_ready`); `AgentInstance.get_instance` does not keep the
  callback of a later session.
- `_loading`: the `session/load` RPC is in flight and still gates.
- `_replay_hold`: the held replay of a load that rendered the file.
- `_replay_dropped`: `_refresh` gave up a held replay; the rest of it is
  dropped until the load ends or a turn starts.

Five sites reset different subsets: `_refresh`, `_advance_session_epoch`,
`_dispatch_turn`, the load callback (two branches), `_cancel_session`.
`_loading_saved` is reset only by the load callback, past its epoch check.
`/new` or `/delete` during a load (via `_advance_session_epoch`) leaves it
`true`: the disconnect fails the pending `session/load`, but its callback
returns at the epoch check, so the reconnect's on-ready starts no new
session. `_refresh` also leaves it `true`, but there the epoch still
matches, so the failed load's error branch clears it before on-ready runs.

A turn sent in `dropping` (`_refresh` during the hold, then a submit)
clears `_replay_dropped` while `_replay_hold` is already nil. A later
successful load callback then calls `_dispatch_replay_tail(nil)`, which
errors in `ipairs`.

The reachable combinations are five states. `deferred` already has its own
data (`_pending_load_*`), so it needs no state value:

| State | Today | Who enters it |
|---|---|---|
| none | all unset | start, every exit |
| deferred | `_pending_load_*` set, `_loading_saved` | `load_acp_session` before ready |
| `loading` | `_loading`, no hold | `_do_load_acp_session` without the file |
| `holding` | `_loading`, `_replay_hold` | `_do_load_acp_session` with the file |
| `dropping` | `_replay_dropped` | `_refresh` in `holding` |

`_refresh` in `loading` goes to none. The RPC callback still passes the
epoch check and ends the load as today.

### Turn in flight
Four sites ask "is a prompt's turn or a load's replay writing to the chat?":
- `_history_changed`: `_prompt_pending == 0 and not _loading` means save now.
- `_on_tool_call`: the same, to drain side records.
- `_on_agent_chunk`: a thinking start with `_prompt_pending == 0`
  (`starts_unprompted`) and `not _loading`, to drain side records.
- `_write_chat_row`: `_prompt_pending > 0 or _loading` means `mid_turn`.

Seven `write_notice` callers and the `/grant` closure ask the same thing
(`mid_turn`: "will the turn's own end still finalize the writer?"). But they
read `is_generating`. That differs in two cases:
- After `<C-c>` the prompt callback is still pending. `stop_generation` has
  cleared `is_generating`, so a notice finalizes the writer while late
  updates still arrive. The callback finalizes again.
- During a load replay, `is_generating` is false, so `/rename`, a mode
  switch or the `/context` notice finalizes the writer mid-replay.
  `_write_chat_row` already treats the replay as mid-turn.

`_submit_defer_reason` already explains why it reads `_prompt_pending`
and not `is_generating`. `is_generating` is the header's running state
(`_set_generating` → `widget:set_running`). `_refresh` and the
`switch_provider` guard read it as that state, and stay as they are.

The other `_loading` readers ask a narrower question: "is a replay of past
work arriving?" They are `_persist_history`, `_sync_modified`,
`_write_session`, `_try_record_edit_range`, the `subagent_update` branch of
`_on_session_update`, and `_submit_defer_reason`. They stay distinct from
the turn predicate.

### Gate reasons
`_submit_hold_reason` runs `_submit_defer_reason` and maps `in_flight` and `usage_limited` to nil.
`HOLD_CAUSE` already keys exactly the two reasons that hold a user's submit
(`loading`, `not_ready`). So the filter repeats a fact the table already
holds.

## Changes
### Load state (`session_manager.lua`)
- Class fields: replace `_loading`, `_loading_saved` and `_replay_dropped`
  with `_load_state? "loading"|"holding"|"dropping"`. Replace the three
  `_pending_load_*` fields with `_pending_load? { session_id: string, cwd?: string, model?: string }`.
  `_replay_hold` stays. It holds data, and only the setter makes or clears it.
- New `SessionManager:_set_load_state(state)`: sets `_load_state`, then
  `self._replay_hold = state == "holding" and {} or nil`, then
  `self:_sync_modified(self.chat_history)`, as `_set_prompt_pending` does
  for its counter. `_sync_modified` reads the load state, so every change
  must resync. Without this, `_advance_session_epoch` would sync (through
  `_set_prompt_pending(0)`) before it resets the load state. It is the only
  writer of both fields. Every entry into `holding` comes from nil (through
  `_advance_session_epoch`), so there are no held updates to keep.
  Drop the explicit `_sync_modified` after the state clears in the load
  success branch.
- New `SessionManager:_replaying(): boolean`: `_load_state == "loading" or _load_state == "holding"`.
  This replaces every read of `_loading`. `_on_session_update` passes it to
  `Subagents:update`.
- Constructor on-ready: `if self._pending_load then` (take it, clear it,
  `_do_load_acp_session`) `elseif not self._load_state then new_session`.
- `load_acp_session`: the deferred branch sets `_pending_load` only.
- `_do_load_acp_session`: after `_advance_session_epoch`,
  `_set_load_state(from_file and "holding" or "loading")`. Compute `from_file`
  before this call. Today `_replay_hold = {}` is set after `_render_history`.
  It must still be set before `load_session` goes out. Updates cannot arrive
  between these lines (one tick), so it is safe to set it earlier.
  Callback:
  - error: `_set_load_state(nil)`, then the fallback.
  - success: when `_load_state == "holding"`, take `_replay_hold`, then
    `_set_load_state("loading")` (still replaying, so
    `_try_record_edit_range` skips the tail), then `_dispatch_replay_tail(hold)`.
    In every case it then calls `_set_load_state(nil)` where it clears
    `_loading` today. `dropping` skips the tail, as `_replay_dropped` does today.
- `_take_replay_update`: append when `holding`. Return `_load_state == "dropping"` otherwise.
- `_refresh`: `holding` → `dropping`, `loading` → nil. `dropping` stays as it is.
- `_advance_session_epoch`: `_set_load_state(nil)`. This is now the only
  transition reset. It also covers the `_loading_saved` that `/new`
  strands today.
- `_cancel_session`: drop its three load resets, its comment about them and
  the docstring's "Also clears the load gate."
  Every caller but `destroy` goes on to `_advance_session_epoch`
  (`new_session`, `_delete_session`, `restart_session` via
  `replace_with_history`). `destroy` sets `destroyed`, which every callback
  checks.
- `_dispatch_turn`: `if self._load_state == "dropping" then self:_set_load_state(nil) end`,
  in place of `_replay_dropped = nil`.

### Turn predicate (`session_manager.lua`, `session_recovery.lua`)
- New `SessionManager:_turn_open(): boolean`: `self._prompt_pending > 0 or self:_replaying()`.
  Docstring: a prompt's turn or a load's replay is still arriving, and its
  own end will finalize the writer. A turn no prompt started
  (a received message) is not counted.
- `_history_changed`: `if not self:_turn_open() then persist`.
- `_on_tool_call`: `elseif not self:_turn_open() then`.
- `_on_agent_chunk`: the drain condition becomes
  `not self:_replaying() and (starts_response or (starts_thinking and not self:_turn_open()))`,
  and the `starts_unprompted` local goes. This is equivalent to today. A
  response start drains mid-turn but not during a replay.
- `_write_chat_row`: `local mid_turn = self:_turn_open()`.
- `mid_turn = self:_turn_open()` replaces `mid_turn = self.is_generating` in
  `_display_context_usage`, `_rename_session`, `_refresh_name`, `_notice_model_switched`,
  `_notice_mode_switched`, `_notice_thought_level_switched`,
  `Recovery._announce_reauth`. The `GrantCommand:new` closure becomes
  `function() return self:_turn_open() end`.
- The RESUME notice in the load success branch passes
  `mid_turn = self:_turn_open()`, read after the load state clears. A load
  that went `dropping` and then saw a turn start then does not finalize the
  writer under that turn.
- Docs: `MessageWriter.Notice.mid_turn` ("True when a turn is running") and
  the `GrantCommand:new` `is_mid_turn` param say "a turn or a load's replay".
- `is_generating` keeps its readers `_refresh`, `switch_provider` and the
  header. Its class field doc says it is the header's running state.

### Gate reasons (`session_manager.lua`)
- Delete `_submit_hold_reason`. Rename `HOLD_CAUSE` to `SUBMIT_HOLDS`.
  Docstring: the reasons that hold a prompt the user sends, each with its
  phrase. The others (`in_flight`, `usage_limited`) hold only the queue's
  automatic drain.
- Move the "Neither a turn in flight nor the usage limit holds one"
  rationale from `_submit_hold_reason` into the `SUBMIT_HOLDS` docstring.
- `_handle_input_submit`: `if SUBMIT_HOLDS[self:_submit_defer_reason(input_text)] then`.
- `_relay`: `local reason = self:_submit_defer_reason(instruction)`. Send
  when `not SUBMIT_HOLDS[reason]`. Return `SUBMIT_HOLDS[reason]`.
- `_drain_queue` keeps `_submit_defer_reason` (all reasons hold a drain).

### Tests
Write the new cases first; they fail now.

`session_manager.test.lua`:
- Reconnect after `/new` mid-load: start a load, call `_advance_session_epoch`.
  The on-ready callback then calls `new_session`. Fails today
  (`_loading_saved` is left true).
- Load success after `dropping` → turn: no `_dispatch_replay_tail` call, no
  error. Fails today (`ipairs(nil)`).
- `/rename` during a load replay: `mid_turn` is true. Same for a notice
  after `stop_generation` with `_prompt_pending == 1`.
- `_set_load_state`: `_replay_hold` is `{}` only in `holding`. The chat's
  `modified` follows a change of state (dirty history, `loading` → nil).
- `restart_session` mid-load, not from a file, with a dirty history: the
  chat is `modified` afterwards.
- `_refresh`: `holding` → `dropping` (updates dropped), `loading` → nil.
- `_dispatch_turn` from `dropping` → nil.
- `_cancel_session` no longer touches the load state. `_advance_session_epoch`
  clears it.
- Rename the `_do_load_acp_session: _loading_saved flag` block to the load
  state and assert `_load_state`/`_pending_load` instead. Replace each stub
  that sets `_loading = true` with `_load_state = "loading"` and the
  `_replaying`/`_turn_open` methods copied from `SessionManager`. Replace the
  `_submit_hold_reason` stubs with `SUBMIT_HOLDS`-based callers (no stub).
- "takes the notice level from the generating state": set
  `_prompt_pending = 1` instead of `is_generating`, and copy `_turn_open`.
`session_recovery.test.lua`: `make_session` sets `is_generating`; give it
`_prompt_pending = 0` and the `_replaying`/`_turn_open` methods, which
`_announce_reauth` now calls.
Integration: `test_session_load.lua` reads `_replay_hold` (unchanged),
`_replay_dropped == nil` → `_load_state ~= "dropping"` ("drops the rest of
the replay after a refresh") and `_loading` → `_load_state == nil` ("ends
the hold when a new session supersedes the load").
`test_history_new_session.lua` `assert_carried`: `_loading_saved` →
`_load_state == nil`.
`test_native_subagents.lua` "a load does not drain": `_loading = true` →
`_load_state = "loading"`.

### Docs
- `session-lifecycle` skill § Guards: replace the `_loading_saved` bullet
  with `_pending_load` / `_load_state` (on-ready skips while either is set).
  Race 1 and the `destroyed` bullet name the `_loading_saved` guard; rename
  it there too. § The in-flight counter: "the prompt callback reads
  it as …" stays. Add that `_turn_open` (counter or replay) is what notices
  and saves ask.
- Project `CLAUDE.md` § Session lifecycle: `_loading_saved` →
  `_load_state`.
- `notes/FEAT-shell-changes-from-git.md`, `notes/bug-create-fold-never-fires.md`:
  `self._loading` → `self:_replaying()`.
- `notes/PERF-append-session-log.md`: `_chain_running(nil)` becomes
  `self:_turn_open()`.

## Expected outcome
- One field says where a load is, and one setter changes it.
  `_advance_session_epoch` is the one transition reset.
- A reconnect after `/new` or `/delete` mid-load starts a session again.
- A load that ends after a turn sent in `dropping` no longer errors.
- Notices written during a load replay, or after `<C-c>` before the prompt
  callback, no longer finalize the writer under the turn.
- One gate function. The submit/relay vs drain split is a table lookup.

## Non-goals
- Withdrawing a deferred load (`_pending_load`) on `/new` before the agent is
  ready.
- Counting a turn no prompt started (received message) as open. That is
  `notes/PERF-append-session-log.md` open question 1. `_turn_open` is where
  it would go.
- Changing `is_generating` semantics or the header.

## Open questions
None.

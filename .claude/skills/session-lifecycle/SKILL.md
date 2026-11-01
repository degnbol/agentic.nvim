---
name: session-lifecycle
description: Session lifecycle races, epoch guard, cross-turn MessageWriter state, and header state pipeline. Use when editing SessionManager, ChatHistory, session creation or session restore paths, the _restoring/_session_epoch/destroyed guards, MessageWriter cross-turn flags (reset at turn boundary), ChatWidget header rendering, WindowDecoration, or vim.b[buf].agentic_header. Covers "session restore", "epoch guard", "MessageWriter cross-turn state", and "header state pipeline".
---

# Session lifecycle

## Session lifecycle races and the epoch guard

For the three restore paths (`session/load`, `restore_from_history`,
`respawn_preserving_history`) and what each sends on the wire, see the
`provider-system` skill § "Chat buffer is UI only". A `session/load` with a
session file renders the file; the replay is held and only its tail after
the file is dispatched (`_dispatch_replay_tail`).

Two races leave a callback acting on a session that has moved on:

1. **Constructor on-ready race:** `AgentInstance.get_instance()` calls `on_ready`
   synchronously when the instance already exists. The constructor wraps the
   inner logic in `vim.schedule`. When `load_acp_session()` is called immediately
   after construction (from `SessionRestore.resume`), the deferred callback fires
   after `_do_load_acp_session` — without the `_restoring` guard it would call
   `new_session()`, replacing the loaded session.

2. **Session destroyed while its `session/new` is in flight:** the unused
   session a resume replaces (through `BufWinLeave`), or `:bd` right after
   creation. The callback closure holds the destroyed `self`; when the
   response arrives it would run `_handle_new_config_options` against wiped
   buffers. Bail out at the top of the create_session callback when
   `self.destroyed` is true.

**Guards:**

- `_restoring` flag — prevents the deferred on-ready callback (race 1).
- `_session_epoch` counter — monotonically incremented by `new_session()`,
  `_do_load_acp_session` and `_delete_session` (which ends a conversation with
  no `new_session` behind it). The `create_session` and `session/load`
  callbacks capture the epoch at call time and reject a response that a
  later transition superseded (e.g. `/new` during a load). Long-running
  side flows capture it too: `run_login` holds the epoch across the login so
  its callback cannot recover into a replaced conversation.
- `destroyed` flag — set in `SessionManager:destroy`; `SessionRegistry.destroy`
  is a no-op once it is set. Checked at the top of the `create_session`
  callback for race 2 (`destroy` advances neither the epoch nor
  `_restoring`).

**Rules:**

- Any code path that initiates a session transition must increment
  `_session_epoch`. Any async callback that sets `self.session_id` must check
  that its captured epoch matches `self._session_epoch`.
- Any async callback on a SessionManager that writes to its buffers or the
  registry must check `self.destroyed` — the instance may have been
  replaced while the RPC was in flight.
- `_do_load_acp_session` must feed `result.configOptions` through
  `_handle_new_config_options` on success (mirrors the `new_session` path) —
  otherwise a restored session has no config options.

## The in-flight counter

`_prompt_pending` counts outstanding prompt callbacks. It gates no submit — the
provider runs a mid-turn prompt as the next turn — only the automatic drains
(`_drain_queue`, `_dispatch_deferred_prompts`), which is what advances the queue
one block per turn. The prompt callback reads it as "a turn is still
streaming": it runs the turn boundary below but not the idle signals
(`_set_generating(false)`, indicator, `_notify_attention`). An epoch mismatch runs neither.

## Cross-turn state hazards in MessageWriter

MessageWriter carries mutable flags that persist across turns. Any flag set
during a turn MUST be cleared at the turn boundary (`append_separator`) or on
the next tool call — otherwise it silently corrupts all subsequent turns.

Known hazards (and their reset points):

| Flag | Set when | Reset in |
|------|----------|----------|
| `_pending_section_break` | Tool call block written | Next `write_message_chunk`, `finalize_turn`, `reset_turn_state` |
| `_chunk_start_line` | First streamed chunk | `_reflow_chunks(flush_all=true)` via `append_separator` |

When adding new per-turn state to MessageWriter, always ensure it resets at the
turn boundary. The `send_prompt` response callback (which calls
`append_separator`) runs inside `vim.schedule` from `_handle_message` — do not
add another `vim.schedule` wrapper or the cleanup races with the next turn.

## Header state and external UI plugins

Runtime session data (title, context, state) flows to external UI plugins
(incline.nvim, tabline plugins) through the **headers state pipeline**, not
through buffer names.

**Pipeline:** every header writer (`ChatWidget`, `SubagentTranscript`) →
`WindowDecoration.set_header()` → `vim.b[buf].agentic_header` →
`AgenticHeadersChanged` User autocmd (`data.buf`) → external plugin refresh.
State facts go through `set_header_fact()`, a no-op when the fact holds.
`set_header` also renders the winbar, local-scope, in every window showing
the buffer.

`vim.b[buf].agentic_header` (`ChatWidget.HeaderParts`) is the single source
of truth. Its `running`/`waiting`/`idle` facts are independent;
`WindowDecoration.header_state` picks the one shown. `vim.b[buf].agentic_window` names
the buffer's panel. `WindowDecoration.header_chunks` is the one layout of the
parts: the default winbar concatenates it, and outside readers use it rather than
rebuild the order.

**Do not rely on buffer names for UI display.** `nvim_buf_set_name` fires no
event floating-window plugins respond to. Names are `agentic://<id>/<panel>`;
only the chat's tail follows the session title.

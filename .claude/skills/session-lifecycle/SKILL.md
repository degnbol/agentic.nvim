---
name: session-lifecycle
description: Session lifecycle races, epoch guard, cross-turn MessageWriter state, and header state pipeline. Use when editing SessionManager, ChatHistory, session creation or session restore paths, the _restoring/_session_epoch/destroyed guards, MessageWriter cross-turn flags (reset at turn boundary), ChatWidget header rendering, WindowDecoration, or vim.b[buf].agentic_header. Covers "session restore", "epoch guard", "MessageWriter cross-turn state", and "header state pipeline".
---

# Session lifecycle

## Session lifecycle races and the epoch guard

For the three restore paths (`session/load`, `restore_from_history`,
`respawn_preserving_history`) and what each sends on the wire, see the
`provider-system` skill § "Chat buffer is UI only".
The races below all concern Path A (`session/load`) interleaving with
the constructor's `session/new`.

Three race conditions can overwrite `self.session_id` during ACP
`session/load`:

1. **Constructor on-ready race:** `AgentInstance.get_instance()` calls `on_ready`
   synchronously when the instance already exists. The constructor wraps the
   inner logic in `vim.schedule`. When `load_acp_session()` is called immediately
   after construction (from the session picker), the deferred callback fires
   after `_do_load_acp_session` — without the `_restoring` guard it would call
   `new_session()`, replacing the loaded session.

2. **Stale create_session response race:** The constructor's `new_session()`
   sends `session/new` (async RPC). The user then browses the session picker for
   seconds/minutes. `_do_load_acp_session` sets `_restoring = true` and sends
   `session/load`. The load completes and clears `_restoring = false`. The
   `session/new` response then arrives — `_restoring` is false, so the callback
   overwrites `session_id` with the stale new-session ID.

3. **Cross-provider restore, two linked hazards.** Picking a saved session
   whose provider differs from `Config.provider` requires destroying the
   picker's `current_session`, flipping `Config.provider`, and letting
   `SessionRegistry.create()` spawn a replacement bound to the new agent.
   This sequence surfaces two races that don't affect same-provider restore:

   a. **Capability check during agent init.** `agent_supports_load` is called
      synchronously inside the picker callback. A freshly-spawned agent has
      `agent_capabilities == nil` (initialize RPC still in flight). Treating
      nil as "no support" silently drops into the non-ACP fallback path.
      Treat nil as "support-assumed" — `load_acp_session` already queues via
      `_pending_load_session_id` until on_ready fires.

   b. **Stale `session/new` callback from the outgoing provider.** The
      original SessionManager's `create_session` RPC may still be in flight
      when it's destroyed. The callback closure holds a reference to the
      destroyed `self`; when the response arrives it would run
      `_handle_new_config_options` against wiped buffers. Bail out at the top
      of the create_session callback when `self.destroyed` is true.

**Guards:**

- `_restoring` flag — prevents the deferred on-ready callback (race 1) and
  catches in-flight create callbacks while load is active.
- `_session_epoch` counter — monotonically incremented by `new_session()`,
  `_do_load_acp_session` and `_delete_session` (which ends a conversation with
  no `new_session` behind it). The `create_session` callback captures the epoch
  at call time and rejects the response if the epoch has advanced (race 2).
  This catches stale responses even after `_restoring` is cleared. Long-running
  side flows capture it too: `run_reauth` holds the epoch across the browser
  OAuth round-trip so its callback cannot recover into a replaced conversation.
- `destroyed` flag — set in `SessionManager:destroy`; `SessionRegistry.destroy`
  is a no-op once it is set. Checked at the top of the `create_session`
  callback for race 3b (epoch/restoring can't catch it because they track the
  replacement's state, not the destroyed sender's).

**Rules:**

- Any code path that initiates a session transition must increment
  `_session_epoch`. Any async callback that sets `self.session_id` must check
  that its captured epoch matches `self._session_epoch`.
- Any async callback on a SessionManager that writes to its buffers or the
  registry must check `self.destroyed` — the instance may have been
  replaced while the RPC was in flight.
- `_do_load_acp_session` must feed `result.configOptions` through
  `_handle_new_config_options` on success (mirrors the `new_session` path) —
  otherwise the header stays on the previous provider's model after a
  cross-provider restore.

## The in-flight counter

`_prompt_pending` counts outstanding prompt callbacks. It gates no submit — the
provider runs a mid-turn prompt as the next turn — only the automatic drains
(`_drain_queue`, `_dispatch_deferred_prompts`), which is what advances the queue
one block per turn. The prompt callback reads it as "a turn is still
streaming": it runs the turn boundary below but not the idle signals
(`is_generating`, indicator, `[idle]`). An epoch mismatch runs neither.

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

Runtime session data (mode, context %, session name) flows to external UI
plugins (incline.nvim, tabline plugins) through the **headers state pipeline**,
not through buffer names.

**Pipeline:** `SessionManager` → `ChatWidget:render_header()` /
`set_chat_title()` / `set_badge()` → `WindowDecoration.set_header()` →
`vim.b[buf].agentic_header` → `AgenticHeadersChanged` User autocmd (`data.buf`)
→ external plugin refresh. `set_header` also renders the winbar, local-scope,
in every window showing the buffer.

`vim.b[buf].agentic_header` (a `HeaderParts`: `title`, `context`, `badge`,
`session_name`, `trust`) is the single source of truth for header display
data; `vim.b[buf].agentic_window` names the buffer's panel.

**Do not rely on buffer names for UI display.** `nvim_buf_set_name` fires no
event floating-window plugins respond to. Names are `agentic://<id>/<panel>`;
only the chat's tail follows the session title.

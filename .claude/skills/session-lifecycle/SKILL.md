---
name: session-lifecycle
description: Session lifecycle races, epoch guard, cross-turn MessageWriter state, and header state pipeline. Use when editing SessionManager, ChatHistory, session creation or session restore paths, the _restoring/_session_epoch/_destroyed guards, MessageWriter cross-turn flags (reset at turn boundary), ChatWidget header rendering, WindowDecoration, or vim.t[tab].agentic_headers. Covers "session restore", "epoch guard", "MessageWriter cross-turn state", and "header state pipeline".
---

# Session lifecycle

## Session lifecycle races and the epoch guard

For the three restore paths (`session/load`, `restore_from_history`,
`respawn_after_usage_limit`) and what each sends on the wire, see the
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

3. **Cross-provider restore, three linked hazards.** Picking a saved session
   whose provider differs from `Config.provider` requires destroying the
   current tab's SessionManager, flipping `Config.provider`, and letting
   `get_session_for_tab_page` spawn a replacement bound to the new agent.
   This sequence surfaces three races that don't affect same-provider restore:

   a. **Capability check during agent init.** `agent_supports_load` is called
      synchronously inside the picker callback. A freshly-spawned agent has
      `agent_capabilities == nil` (initialize RPC still in flight). Treating
      nil as "no support" silently drops into the non-ACP fallback path.
      Treat nil as "support-assumed" — `load_acp_session` already queues via
      `_pending_load_session_id` until on_ready fires.

   b. **Tab-id-based deferred destroy.** `ChatWidget.on_hide` schedules
      `SessionRegistry.destroy_session(tab_page_id)` via `vim.schedule` when
      `chat_history.messages` is empty. If a replacement session has been
      installed on the same tab before that callback runs, a naive
      destroy-by-tab-id would wipe the replacement. The scheduled closure
      captures the session instance (`this`) and only destroys when
      `SessionRegistry.sessions[this.tab_page_id] == this` — so the replacement
      survives. `SessionManager:destroy` also disarms `on_hide` before
      `widget:destroy()` as belt-and-braces.

   c. **Stale `session/new` callback from the outgoing provider.** The
      original SessionManager's `create_session` RPC may still be in flight
      when it's destroyed. The callback closure holds a reference to the
      destroyed `self`. When the response arrives, the callback runs
      `_handle_new_config_options` → `_update_chat_header` →
      `WindowDecoration.set_headers_state(self.widget.tab_page_id, ...)`,
      stomping the replacement session's headers with the outgoing
      provider's model. Bail out at the top of the create_session callback
      when `self._destroyed` is true. Also clear
      `vim.t[tab_page_id].agentic_headers` in `SessionManager:destroy` so
      the replacement starts from a clean slate — per-tab header state
      outlives the session that wrote it.

**Guards:**

- `_restoring` flag — prevents the deferred on-ready callback (race 1) and
  catches in-flight create callbacks while load is active.
- `_session_epoch` counter — monotonically incremented by both `new_session()`
  and `_do_load_acp_session`. The `create_session` callback captures the epoch
  at call time and rejects the response if the epoch has advanced (race 2).
  This catches stale responses even after `_restoring` is cleared.
- `_destroyed` flag — set in `SessionManager:destroy`. Checked at the top of
  the `create_session` callback for race 3c (epoch/restoring can't catch it
  because they track the replacement's state, not the destroyed sender's).

**Rules:**

- Any code path that initiates a session transition must increment
  `_session_epoch`. Any async callback that sets `self.session_id` must check
  that its captured epoch matches `self._session_epoch`.
- Any async callback on a SessionManager that writes to tab-scoped state
  (`vim.t[tab].agentic_headers`, `SessionRegistry.sessions[tab]`, etc.) must
  check `self._destroyed` — the instance may have been replaced on the same
  tab while the RPC was in flight.
- `_do_load_acp_session` must feed `result.configOptions` through
  `_handle_new_config_options` on success (mirrors the `new_session` path) —
  otherwise the header stays on the previous provider's model after a
  cross-provider restore.

## Cross-turn state hazards in MessageWriter

MessageWriter carries mutable flags that persist across turns. Any flag set
during a turn MUST be cleared at the turn boundary (`append_separator`) or on
the next tool call — otherwise it silently corrupts all subsequent turns.

Known hazards (and their reset points):

| Flag | Set when | Reset in |
|------|----------|----------|
| `_suppressing_rejection` | Permission rejected | `append_separator`, `write_tool_call_block` |
| `_rejection_buffer` | With above | With above |
| `_last_wrote_tool_call` | Tool call block written | Next `write_message_chunk` |
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
`ChatWidget:set_chat_title()` → `WindowDecoration.set_headers_state()` →
`vim.t[tab].agentic_headers` → `AgenticHeadersChanged` User autocmd → external
plugin refresh.

`vim.t.agentic_headers` is the single source of truth for header display data.
Each panel has a `HeaderParts` table with `title`, `context`, and optional extra
fields (e.g. `session_name`). External plugins read these fields in their render
functions and refresh via the `AgenticHeadersChanged` autocmd.

**Do not rely on buffer names for UI display.** `nvim_buf_set_name` sets neovim's
internal buffer path (visible in `:ls`) but does not fire events that floating
window plugins respond to. The buffer name is a secondary artifact — the headers
state is the primary mechanism.

# Plan: reapply and announce the model when a session is restored
Status: reviewed

## Relevant files
- `lua/agentic/session_manager.lua` (SM): `new_session`, `_do_load_acp_session`, `restore_from_history`, `restart_session`, `switch_provider`, `_adopt_history`, `announce_model_loaded`, `_handle_model_change`, `_sync_history_context`
- `lua/agentic/session_recovery.lua`: `respawn_preserving_history`
- `lua/agentic/acp/agent_config_options.lua`: `set_pending_initial_model`, `_flush_pending_initial_model`, `get_model`
- `lua/agentic/session_restore.lua`: `check_conflict`, `do_restore` (the two restore paths)
- `lua/agentic/ui/chat_history.lua`: `model` field
- `lua/agentic/session_manager.test.lua`: the `announce_model_loaded` cases
- Skills: `session-lifecycle` (restore paths, `_restoring`/epoch/`destroyed` guards)
- Related: `notes/PLAN-agent-view-consolidation.md` moves `announce_model_loaded` into `AgentView`; whichever lands second follows the other.

## Background
A session is restored, or re-created with its history, by these paths:

| Path | Used by | Saved model reapplied? | Model shown? |
|---|---|---|---|
| A. `_do_load_acp_session` | `session/load` providers (`SessionRestore.do_restore`, `Agentic.load_acp_session`) | Yes, `set_pending_initial_model(model)` | In the resume notice body, `Provider: X · Model: Y`. A `Loaded` line also follows when the switch goes through (`_handle_model_change` → `announce_model_loaded`). |
| B. `restore_from_history` | Providers without `session/load`, the fallback when `session/load` fails (`_fallback_restore_from_local`), `restart_session` | **No.** `new_session` with `restore_mode` takes no `preserved_model`, and nothing reads `history.model`. | **No.** `new_session` writes the `Loaded` line only outside `restore_mode`. |
| C. `SessionRecovery.respawn_preserving_history` | Respawn after a usage limit | **No**, as B. | **No** (`quiet_welcome`). |
| D. `switch_provider` | Provider switch | Not applicable: a new provider. | **No.** |

So on paths B and C the session continues on the provider's default model, and the chat does not say so. The skip came from commit a4c8974, whose reason (the model is in the header) that same commit made untrue.

Further facts the changes depend on:
- **Path A ignores legacy options.** Its load callback reads only `result.configOptions`, after `config_options:clear()` at the start of the load. `new_session` also reads `response.modes` and `response.models`. So a legacy-models provider has no model options after a load.
- **Path A has no guard.** The load callback checks neither `self.destroyed` nor the epoch. The `session-lifecycle` skill requires a `destroyed` check for any async callback that writes to the buffers. A cross-provider restore during the load destroys the session (`session_restore.lua`), and `/new` during the load advances the epoch.
- **History models go stale.** `restart_session` and the respawn copy the in-memory history, whose `model` is refreshed only at save (`_sync_history_context`). It can be older than the live model.
- **`announce_model_loaded` dedupes on `_announced_model_id`**, for one case: `new_session` announces `preserved_model` before the switch to it returns, and the switch callback announces the same id again. `_notice_model_switched` and `new_session` maintain the field for that. The dedupe also drops wanted lines: an empty session reuses its ACP session on restore (`check_conflict` is false), has already announced its model, and a restore on the same model then writes no line after the replay.
- **The current-model expression is repeated four times:** `(model and model.currentValue) or legacy_agent_models.current_model_id`. The repeats are in `_sync_history_context`, `new_session` (twice), `_do_load_acp_session` and `_flush_pending_initial_model`.
- **The "offered" check is repeated:** `get_model(id) or legacy_agent_models:get_model(id)` appears in `set_pending_initial_model` and in the flush.

The `Loaded` line means "from here on, model X". On a restore it belongs after the replayed messages, where the session continues. The older messages may have run on other models.

## Changes
1. **`agent_config_options.lua`**: two accessors. Use them at every repeat listed in Background.
   ```lua
   --- The id of the model the session runs on.
   --- @return string|nil model_id nil before the provider reports models
   function AgentConfigOptions:current_model_id()

   --- Whether the provider offers a model, as a config option or a legacy model.
   --- @param model_id string
   --- @return boolean
   function AgentConfigOptions:has_model(model_id)
   ```
2. **SM: new `_apply_session_options(response)`**, extracted from `new_session`'s configOptions-or-legacy branch (configOptions, else `set_legacy_modes` + header, else `set_legacy_models`). `new_session` and the path A load callback both call it, in place of path A's configOptions-only read.
   ```lua
   --- Take the mode and model options a session/new or session/load response
   --- carries, in either the configOptions or the legacy form.
   --- @param response table The RPC result
   function SessionManager:_apply_session_options(response)
   ```
3. **SM: new `_resume_model(model_id)`**, beside `announce_model_loaded`:
   ```lua
   --- Put a restored session back on its saved model and announce, at the end
   --- of the chat, the model it runs on.
   --- @param model_id string|nil Saved model id; nil keeps the current model
   function SessionManager:_resume_model(model_id)
   ```
   - `announce_model_loaded(current_model_id())`: the model the session runs on now. Nil (no model options yet) writes nothing.
   - `model_id` offered or no model options yet: `set_pending_initial_model(model_id)`. It switches now or on a later options update, and does nothing when the model is already current. The switch callback writes its own `Loaded` line on success, and an ERROR on failure.
   - `model_id` not offered by a provider that reports models: `Logger.notify` a WARN naming the saved and the current model.
   - So a restore onto another model shows two lines, `Loaded <default>` then `Loaded <saved>`. Each line is true when written, and no line names a model whose switch failed.
4. **Remove the dedupe.** Delete `_announced_model_id` and its reads and writes (`SessionManager:new`, `announce_model_loaded`, `_notice_model_switched`, `new_session`). `new_session` announces `current_model_id()` in place of `preserved_model`, and the switch to `preserved_model` announces itself, as in step 3.
5. **`restore_from_history`**: new `opts.model?: string`. `self:_resume_model(opts.model or history.model)` after `SessionRestore.replay_messages`, in both branches.
6. **`_do_load_acp_session`**:
   - Capture the epoch after `_advance_session_epoch()`. Return early in the load callback when `self.destroyed` or the epoch has moved.
   - Replace the `set_pending_initial_model` call with `self:_resume_model(model)`, after the resume notice.
7. **`restart_session`**: pass the live model, `config_options:current_model_id()`, captured before `_cancel_session`. `restore_from_history` takes it as `opts.model`, which overrides `history.model`.
8. **`respawn_preserving_history`**: capture `sm.config_options:current_model_id()` before invalidating the instance. In `on_created`, reapply it after `_adopt_history`. Whether to announce it is Open question 2.
9. **`switch_provider`**: `self:_resume_model(nil)` after the provider notice in `on_created`. Update its comment, which says `restore_mode` skips the announce.
10. **`new_session`**: add a comment at the `not restore_mode` gate: a restore announces after its own content, through `_resume_model`.
11. **Tests**, in `session_manager.test.lua` beside the `announce_model_loaded` cases, with a stub session:
    - `_resume_model`: announces the current model; queues an offered saved model; a saved model not offered gives a WARN; no model options queue it without a WARN; nil only announces.
    - A successful switch to the queued model writes a second `Loaded` line; a failed one writes the ERROR and no line.
    - Delete the dedupe cases (the repeated `announce_model_loaded("m")`).
    - `restore_from_history`, both branches: the `Loaded` line follows the replayed messages.
    - `restart_session`: the restore gets the live model, not the one from the last save.
    - Path A load callback: legacy `models` in the result fill the options; the callback writes nothing after `destroyed` or an epoch change.
    - `AgentConfigOptions:current_model_id` and `has_model`, in `agent_config_options.test.lua`.
    - `make validate`.

## Expected outcome
- Every restore, restart and provider switch ends with a `Loaded <name> · <id>` line, written after the replay.
- Restores, restarts and respawns continue on the saved model when the provider offers it, and warn when it does not.
- Path A works for legacy-models providers, and its callback no longer writes into a destroyed or replaced session.

## Non-goals
- Showing model switches made before the restore. Switch lines are display-only (`write_message` never calls `add_message`), so the history does not hold them. Keeping them needs a history message type that is replayed but never sent to the model.
- Showing the model in the header.
- Subagent models (`notes/PLAN-agent-view-consolidation.md`).

## Open questions
1. **Model in the resume notice.** On path A the resume notice body already names the model, so with this change it appears twice. Keep both, or drop `Model: **Y**` from the notice so the `Loaded` line is the one model record, as on a new session?
2. **Announce on respawn.** The respawn after a usage limit passes `quiet_welcome` so that no session divider appears mid-conversation. Should it write the `Loaded` line (the model may have changed if the saved one is no longer offered), or only reapply the model?

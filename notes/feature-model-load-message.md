# Show model load as a chat event marker

## Goal

When a model is loaded — at session start and on every model switch — write a
short event line into the chat buffer announcing which model is now active,
including its full id and description. The line doubles as a temporal marker:
its position in the scrollback shows *when* the model was loaded/switched
relative to the conversation.

Also rebalance the header: stop showing the model name in the incline header
(switching is rare; the chat marker covers it), keeping only `mode · %` there.

## What ACP actually gives us (feasibility — verified)

Investigated during design; these constraints shaped the plan.

- **Model object has exactly three fields:** `modelId`, `name`, `description`
  (`acp_client.lua:1192`). "Full model details" = those three. The
  `description` already states the context window (e.g. "Opus 4.8 with 1M
  context window"), so it carries the "show the model's context" ask.
- **No per-component context breakdown.** The TUI `/context` breakdown
  (CLAUDE.md vs system prompt vs tools vs memory) is computed TUI-side and is
  **not forwarded over ACP**. `usage_update` carries only aggregate `used` /
  `size` / `cost`. CLAUDE.md cannot be separated from the system prompt.
- **No baseline before the first turn.** Every `usage_update` the bridge emits
  fires *inside the prompt loop* (`acp-agent.js` ~647/830/986/1174 — compaction,
  result, mid-stream delta, rate-limit). There is **no `usage_update` at
  `session/new`**. The first `used` we ever see is mid-first-turn and already
  bundles the user's first message + response. The SDK's `getContextUsage`
  (real retained context) is called by the bridge only post-compaction and is
  **not exposed as a callable ACP method**.

  Consequence: a true "startup context: X / Y" fill number is **unobtainable**.
  We do not fake one. The window *size* is conveyed by the description text;
  the live fill `%` already lives in incline and updates per turn.

- **Locally-written messages are display-only.** `MessageWriter:write_message`
  (`message_writer.lua:250`) only appends to the buffer; it never calls
  `ChatHistory:add_message`. So the model-load line is **not persisted, not
  sent to the model, not replayed on restore** (same property as the
  intercepted `/context` output). No context pollution. Corollary: it will not
  reappear after a restore — and we deliberately do not re-emit it on restore
  (the model is already shown by incline; replaying a synthetic line every
  restore is noise).

## Message format

Identical for session start and model switch. No timestamp, no heading.

```
**Loaded Opus 4.8 (1M context)** · claude-opus-4-8[1m]
Opus 4.8 with 1M context window. Best for complex agentic work.
```

- First line **bold** (`**Loaded <name>** · <modelId>`) — distinct enough to
  catch the eye as an event marker without a heading's weight; markdown bold
  renders already, no new highlight group.
- Second line: the `description`, plain.
- Uniform verb **"Loaded"** for both cases. On a switch the prior model appears
  earlier in scrollback, so "Loaded Sonnet" reads naturally as the switch.
- **No timestamp.** Positional placement is the temporal marker. At startup the
  line sits directly under the welcome header (`session_manager.lua:149`), which
  already carries `# YYYY-MM-DD HH:MM · <short-id>`. Nothing else in chat is
  timestamped; adding one only here would be inconsistent.
- **No fill/baseline line** (unobtainable — see feasibility above).

## Triggers

- **Session start:** write the model lines immediately after the welcome header,
  once the model list is known (after `set_models` from the `session/new`
  response).
- **Model switch:** write the lines inline at the moment of the switch.
- **Not on restore.**

## Implementation — all inside `lua/agentic/session_manager.lua`

Status: **done**. No cross-repo work, no `lua/plugins/ui.lua` (incline) change —
incline reads the joined `context` string, so dropping the model from
`_update_chat_header` is sufficient.

The live model-switch path is `SessionManager:_handle_model_change` (modern
configOptions *and* legacy `agent:set_model`). `AgentModels:handle_agent_update_model`
in `agent_models.lua` is **never called in production** (only by its own test) —
the routing-a-writer-into-AgentModels concern in the original plan was moot, so
that file is left untouched. One owner (`SessionManager`) holds the writer.

1. **`SessionManager:announce_model_loaded(model_id)`** — formats and writes the
   two-line marker via `message_writer:write_message(ACPPayloads.generate_agent_message(lines))`.
   Resolves the model via `config_options:get_model` (modern) or
   `legacy_agent_models:get_model`; both expose `name`/`description`. Applies the
   "Default (recommended)" → first-word-of-description extraction. Dedups on
   `_announced_model_id` (a per-SessionManager field) so the session-start
   announce and the async pending-initial-model flush don't double up.

2. **`_update_chat_header`** — model block dropped; header context = `mode · %`.

3. **Session start** — in `new_session`'s post-welcome `vim.schedule`, gated on
   `not restore_mode`, announce the *effective* model (`preserved_model` or
   current value). `_announced_model_id` is reset at the top of `new_session` so
   the marker always writes on `/new` even when the model is unchanged.

4. **Switch** — `_handle_model_change`'s success callback calls
   `announce_model_loaded` (replaced the old `Logger.notify`).

Tests: `session_manager.test.lua` → `describe("announce_model_loaded")` covers
format, Default extraction, unknown-id fallback, dedup, and nil.

## Out of scope / deferred

- Per-component context breakdown (CLAUDE.md vs system prompt) — not reachable
  via ACP.
- Startup baseline fill number — not reachable pre-turn via ACP.
- Re-emitting the marker on restore — add later if missed.
- Lighting up the bottom statusline (`laststatus=0` border) with the `%` — the
  "interesting but not needed" Q4b; decompose header into structured fields
  only when a second consumer actually exists.

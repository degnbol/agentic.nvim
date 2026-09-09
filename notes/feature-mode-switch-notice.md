# Plan: render a mode switch as a chat notice

> **Scope.** `/trust <scope>` and a mode switch (`acceptEdits`/`auto`) both
> grant broader auto-approval for the session, but only one records itself in
> the chat. Fix the channel choice for mode; do not merge the two state
> machines.

## The asymmetry

`MessageWriter:write_notice` is the established
channel for "the user changed session config locally" — see its docstring
(`message_writer.lua:875`, *"A notice records something the user did"*).
Callers: `/trust` set (`session_manager.lua:759`), `/trust off` (`:805`),
`/rename` (`:728`), `/context` (`:708`), model switch (`:1816`), provider
change (`:2676`), resume (`:2551`). `Glyphs.NOTICE` has TRUST, RENAME,
CONTEXT, MODEL, PROVIDER, RESUME — no MODE.

Mode switch is the one holdout on `Logger.notify` (`session_manager.lua:1556`),
directly above the model switch that already went the other way
(`_handle_model_change:1573`).

The persistent-state channel is *not* in scope. Mode lands in
`headers.chat.context` (`_update_chat_header:1668`), which the built-in winbar
renders; `/trust` lands in `headers.chat.trust`, which `concat_header_parts`
(`window_decoration.lua:38`) never reads. That is deliberate, not a gap —
`trust_safety.lua:47` names the two destinations a scope display string is
built for, "the chat notice heading, the headers state external UI plugins
render", and the values are prose (`"Recoverable edits under ~/src/x"`,
`"tmp scratch (/tmp, /var/folders/…)"`), not header-width labels. Leave
`concat_header_parts` alone.

**Provider-initiated mode changes** are inconsistent between paths: the legacy
path notifies (`agent_modes.lua:95`, reached from `current_mode_update`), the
configOptions path is silent (`_handle_new_config_options` only refreshes the
header).

## 1. Mode switch renders as a notice

Mirror `_notice_model_switched` exactly.

- **`glyphs.lua`** — add `Glyphs.NOTICE.MODE`. Must be distinct from every
  `KIND` value and every other `NOTICE` value (the module docstring states the
  constraint). `󰓾` (`nf-md-toggle_switch`, U+F04FE) is the proposal: a mode is a
  switch position. Verified distinct from every `KIND`, `KIND_DEFAULT`,
  `THINKING`, `HOOK`, `NOTICE` and panel-title glyph. Not `󰒓` — that is
  `KIND_DEFAULT`. `doc/agentic.txt` has no glyph list as such; the edit is the
  command enumeration at `:686`.

  The notice title uses the raw mode name, where `_update_chat_header:1670`
  strips a `" Mode"` suffix — "Plan Mode" in the notice, "Plan" in the header.
  Deliberate: the notice has the width for it. Change both or neither.

- **`agent_config_options.lua`** — add `get_mode_display(mode_value) → name,
  description` beside `get_mode` (`:235`), reading `self:get_mode(mode_value)`
  then `self.legacy_agent_modes:get_mode(mode_value)`. Both option shapes carry
  `name` and `description` (`acp_client.lua:1287`; `agentic.acp.AgentMode`).
  Falls back to `mode_value` when neither resolves. Fold the existing
  `get_mode_name` into it and update its two call sites (`session_manager.lua:1555`,
  `:1669`).

  Not a `SessionManager:_resolve_mode_display` mirroring
  `_resolve_model_display` (`:1748`): that one lives on `SessionManager` only
  because of the `"Default (recommended)"` unwrapping hack, which modes have no
  analogue for. Mirroring the placement would import a reason that doesn't apply
  and duplicate a lookup that already exists.

- **`session_manager.lua`** — add `_notice_mode_switched(mode_id)` mirroring
  `_notice_model_switched` (`:1802`): title `name`, body `{ description }` when
  non-empty, `mid_turn = self.is_generating`.

- **`_handle_mode_change`** (`:1529`) — take an `opts` third parameter and, in
  the success branch, call `self:_notice_mode_switched(mode_id)` only when
  `opts.as_notice`. Otherwise stay silent (header still updates). Keep the ERROR
  `Logger.notify` in the failure branch: a failed RPC is not a user action and
  has no notice convention.

**An `as_notice` flag is required** — `_handle_mode_change` has the same replay
problem `_handle_model_change` does. `AgentConfigOptions:set_initial_mode`
(`agent_config_options.lua:173`) calls it from the `create_session` callback
(`session_manager.lua:2340`) whenever `provider_config.default_mode` is set and
differs from the provider's current mode. That fires on `new_session`, `/new`,
`/clear` (`:1878`), plan-exit "clear context & implement" (`:1286`), provider
switch (`:2670`), `restore_from_history` (`:2967`), and usage-limit respawn —
the last of which already passes `quiet_welcome` specifically to avoid mid-
conversation chat noise. Without the flag every one of those emits a notice.

Set `as_notice = true` from the picker callback only (`session_manager.lua:329`,
reached via `show_mode_selector`) — the sole user-initiated path. The flag has
to cross the call rather than being a closure split, because the notice fires in
the RPC success branch.

The `get_mode_name` nil-return that `:1557` concatenates without a fallback is
not demonstrably reachable: every path validates the id against the option list
first (`_show_selector:385`, `agent_modes.lua:63`, `set_initial_mode:182`). Keep
the fallback in `get_mode_display` — it's free — but this change does not fix a
live bug.

## 2. Provider-initiated mode changes

Decide this by intent, not by which path happens to fire.

The model precedent is silence: a provider-side model switch
(`_handle_new_config_options`, e.g. a rate-limit fallback) moves `currentValue`
and updates the header without announcing. Matching that means **deleting the
`Logger.notify` in `AgentModes:handle_agent_update_mode`** (`agent_modes.lua:95`)
so both mode paths behave alike. Keep the invalid-mode WARN above it — that is
an error, not a state announcement.

Two facts make deletion the easy call rather than a trade:

- `handle_agent_update_mode` early-returns when `#self._modes == 0`
  (`agent_modes.lua:74`), which is every configOptions provider — so for
  claude-agent-acp the deletion is a no-op.
- The "user needs it in scrollback" counter-argument is already satisfied. An
  `ExitPlanMode` renders in the chat as a `switch_mode` tool-call block
  (`message_writer.lua:1929`, `tool_call_renderer.lua:1090`; see the
  `provider-system` skill § switch_mode). A notice would be a second record of
  the same event.

Deletion also removes today's double-announcement on legacy providers that echo
`current_mode_update` after a client `set_mode`: without it, §1 turns two toasts
into a notice *plus* a toast.

**Tests encode the current behaviour and must be edited with it:**
`agent_modes.test.lua:114` ("updates current_mode_id and notifies on valid
mode") and `session_manager.test.lua:73` ("updates state, re-renders header,
notifies user") both assert the notify. They are the only recorded intent for
that announcement — check them before deleting, in case they document a reason
this section missed.

## Test

Follow the shape of the existing model-notice coverage
(`session_manager.test.lua:760-890`), which never drives `_handle_model_change`
— it builds a stub session and calls `_notice_model_switched` directly.

- `_notice_mode_switched` → `write_notice` with `Glyphs.NOTICE.MODE` and the
  resolved name; body present/absent for a mode with/without a description.
- `mid_turn` passthrough: notice written while `is_generating` does not
  finalize the turn (mirrors the model-notice assertion).
- `get_mode_display` in `agent_config_options.test.lua`, beside the existing
  `get_mode_name` cases (`:183-209`): configOptions option, legacy mode,
  unknown id → falls back to the value.
- One `_handle_mode_change` case, to pin the split from the `as_notice` flag:
  picker path notices, `set_initial_mode` path stays silent. Needs a fake
  `agent:set_config_option` plus `_handle_new_config_options` /
  `_update_chat_header` stubs — worth it only for this assertion.

Plus the two §2 test edits above.

## Out of scope

`/trust <scope>` and mode `acceptEdits` are near-duplicate concepts — both
grant broader edit auto-approval for the session, from two independent state
machines. Unifying the display makes that overlap *more* visible, not less.
Whether they should be one mechanism is a larger question; see
`PLAN-auto-mode-integration.md`, where the deterministic ladder and the SDK
mode already have to be reconciled at the permission layer.

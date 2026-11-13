# Plan: AgentConfigOptions — one entry lookup, and callbacks given once
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/acp/agent_config_options.lua` — `new`, `bind_keymaps`,
  `has_model`, `set_pending_initial_model`, `_flush_pending_initial_model`,
  `set_initial_mode`, `getter`, `get_mode`, `get_mode_name`, `get_model`,
  `get_model_name`, `model_entry`, `model_display`, `show_mode_selector`,
  `show_model_selector`, `show_thought_level_selector`,
  `_flush_pending_model_select`
- `lua/agentic/acp/agent_modes.lua` (`get_mode` → `agentic.acp.AgentMode`),
  `agent_models.lua` (`get_model` → `agentic.acp.Model`): the legacy lists,
  not changed
- Callers: `lua/agentic/session_manager.lua` — `_info_snapshot`
  (`get_mode_name`), `_reapply_model` (`has_model`),
  `_notice_mode_switched` (`get_mode` + legacy `get_mode`), the
  `create_session` callback (`set_initial_mode`); `lua/agentic/subagents.lua`
  `set_config_options` (constructor only, unchanged)
- Tests: `lua/agentic/acp/agent_config_options.test.lua`;
  `lua/agentic/session_manager.test.lua` — the config-options mocks in
  `describe("_on_session_update: current_mode_update")`,
  `describe("model announce")` and `describe("_handle_mode_change")`, and
  the `set_initial_mode` stubs. `ui/agent_view.test.lua` constructs with
  no-op callbacks and needs no change.
- `notes/FIX-model-selector-order.md` — edits `show_model_selector` and
  `_show_selector`
- Skills: `lua-class`, `implement`

## Background
Two independent accretions in one class.

**Lookup.** A mode or model id is found in the config option
(`getter(self.mode|self.model, id)`) or in the legacy list
(`legacy_agent_modes:get_mode`, `legacy_agent_models:get_model`). The
"try both" lookup is repeated at these sites, among others:
- `model_entry` (local): config option, else legacy.
- `has_model`: the same two calls, `~= nil`.
- `get_model_name`: the same, `.name`. No caller in `lua/`; only a mock in
  `session_manager.test.lua` names it.
- `get_mode_name`: the mode version of `get_model_name`.
- `SessionManager:_notice_mode_switched`: `get_mode(id) or
  legacy_agent_modes:get_mode(id)` inline.
- `_flush_pending_initial_model` (`is_legacy = self:get_model(model_id) ==
  nil`) and `set_initial_mode` (branches on `get_mode` vs legacy
  `get_mode`) need the source as well as the entry.

**Callbacks.** The constructor stores `_set_mode_callback`,
`_set_model_callback` and `_set_thought_level_callback`. Nevertheless
`set_initial_mode` and the three `show_*_selector` methods take a callback
parameter, and every caller passes the stored callback or an equivalent:
- `bind_keymaps` and `_flush_pending_model_select` pass
  `self._set_*_callback`.
- `SessionManager`'s `create_session` callback passes
  `function(mode, is_legacy) self:_handle_mode_change(mode, is_legacy) end`.
  The stored mode callback calls `_handle_mode_change(mode_id, is_legacy,
  opts)`, and `set_initial_mode` passes no `opts`, so the two are the same.

## Changes
### `agent_config_options.lua` — lookup
- New local, and two methods that replace `model_entry`, `has_model`,
  `get_mode`, `get_model`, `get_mode_name` and `get_model_name` (all
  deleted):
  ```lua
  --- The option of `id` in `option`, else the legacy entry `legacy_get` gives.
  --- @param option agentic.acp.ConfigOption|nil
  --- @param legacy_get fun(id: string): table|nil
  --- @param id string
  --- @return table|nil entry
  --- @return boolean is_legacy True when only the legacy list has it; false on a miss
  local function lookup(option, legacy_get, id)

  --- @param mode_id string
  --- @return agentic.acp.ConfigOption.Option|agentic.acp.AgentMode|nil entry
  --- @return boolean is_legacy
  function AgentConfigOptions:mode_entry(mode_id)

  --- @param model_id string
  --- @return agentic.acp.ConfigOption.Option|agentic.acp.Model|nil entry
  --- @return boolean is_legacy
  function AgentConfigOptions:model_entry(model_id)
  ```
  A miss returns `nil, false`. Each method is one line over `lookup`.
- `set_pending_initial_model`, `_flush_pending_initial_model`: use
  `self:model_entry(id)`; `is_legacy` is its second return.
- `model_display`: `self:model_entry(id)`, `fallback:model_entry(id)`.
- `current_thought_level_label` keeps `getter`; thought levels have no
  legacy list.

### `agent_config_options.lua` — callbacks
- `set_initial_mode(target_mode)`: no callback parameter. One
  `self:mode_entry(target_mode)` call:
  - entry and target ≠ current mode → `self._set_mode_callback(target_mode,
    is_legacy)`;
  - entry and target == current mode → nothing;
  - no entry → the warning of today.
  An empty or nil target returns early, as today.
- `show_mode_selector()`, `show_model_selector()`,
  `show_thought_level_selector()`: no parameter; each wraps its stored
  callback with `{ as_notice = true }` as today. `bind_keymaps` and
  `_flush_pending_model_select` call them with no argument.

### Callers (`session_manager.lua`)
- `_info_snapshot`: compute `local mode = mode_id and
  options:mode_entry(mode_id)` before the `snap` literal; the field
  becomes `mode = mode and mode.name`.
- `_reapply_model`: `not options:model_entry(model_id)`.
- `_notice_mode_switched`: `local mode = self.config_options:mode_entry(mode_id)`.
- `create_session` callback: `self.config_options:set_initial_mode(
  self.agent.provider_config.default_mode)`.

### Tests (write first)
`agent_config_options.test.lua`:
- A local `make(handlers)` returns a fresh instance whose three callbacks
  are spies (`handlers.mode`, `.model`, `.thought_level`, each defaulting
  to a recorder). The selector and `set_initial_mode` cases use it instead
  of the shared no-op instance.
- `describe("mode_entry")` and `describe("model_entry")` replace the
  `get_mode`, `get_model`, `get_mode_name` and `has_model` blocks: a
  config-option hit (`is_legacy == false`), a legacy hit (`true`), the
  config option winning over a legacy entry with the same id, and a miss
  asserting both returns (`nil`, `false`).
- `set_initial_mode` with no callback argument: an available non-current
  mode calls the mode spy with `is_legacy` and no opts; the current mode
  calls nothing and does not warn; an unknown mode warns.
- `show_*_selector` with no argument: a pick calls the matching spy with
  `{ as_notice = true }` (existing assertions, new call shape).
- `_flush_pending_initial_model` passes `is_legacy` for a legacy model
  (existing case, kept).

`session_manager.test.lua`:
- `describe("model announce")`: replace `get_model`, `legacy_agent_models`
  and `model_display = AgentConfigOptions.model_display` with
  `model_entry = function(_, id) return models[id], false end` beside
  `model_display`; `model_display` now calls `self:model_entry`.
- `describe("_handle_mode_change")`: replace `get_mode = function() end`
  with `mode_entry = AgentConfigOptions.mode_entry` (it reads
  `legacy_agent_modes`, which the mock has).
- `describe("_on_session_update: current_mode_update")`: delete the dead
  `get_mode_name`/`get_model_name` keys (`render_info` is stubbed there).
- The `set_initial_mode = function() end` stubs stay.

## Expected outcome
No change in behaviour.
1. One lookup per option kind, giving the entry and its source.
2. Each option kind's change callback is given once, at construction.

## Non-goals
- Merging `AgentModes`/`AgentModels` into `AgentConfigOptions`.
- The selector order (`FIX-model-selector-order.md`). Either plan can land
  first; the second rebases the `show_model_selector` signature.

## Open questions
None.

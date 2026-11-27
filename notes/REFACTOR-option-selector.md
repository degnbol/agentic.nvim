# Plan: one option selector for modes, models and config options
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/acp/agent_config_options.lua` — `_show_selector`
- `lua/agentic/acp/agent_modes.lua` — `show_mode_selector`
- `lua/agentic/acp/agent_models.lua` — `show_model_selector`
- New `lua/agentic/ui/option_selector.lua` and its test
- Tests: `lua/agentic/acp/agent_modes.test.lua`, `agent_models.test.lua`,
  `agent_config_options.test.lua` (`show_*_selector` blocks, unchanged)
- `notes/FIX-model-selector-order.md`, `notes/REFACTOR-agent-config-lookup.md`
- Skills: `lua-class`, `implement`

## Background
Three functions open the same picker: `AgentConfigOptions:_show_selector`,
`AgentModes:show_mode_selector` and `AgentModels:show_model_selector`. Each returns false for an empty list, formats
a row as `● name: description` with `●` on the current entry, and calls
back only when the pick is not the current entry. They differ only in
the list, the prompt, the id field (`value`, `id`, `modelId`) and the
current id. A change to the row format or the pick rule must be made in
all three.

The shared picker knows nothing of ACP: a list of named entries, a
current id and a pick rule. It goes in its own module under `ui/`, which
all three require.

## Changes
1. New `option_selector.lua` with `show` (Additions).
2. `AgentConfigOptions:_show_selector(target, prompt, handle_change)`:
   keeps its nil-`target` guard, then returns
   `OptionSelector.show(target.options or {}, { prompt = prompt, current =
   target.currentValue, id_of = function(o) return o.value end },
   function(value) handle_change(value, false) end)`.
3. `AgentModes:show_mode_selector`: returns `OptionSelector.show(self._modes,
   { prompt = "Select Agent Mode:", current = self.current_mode_id, id_of =
   function(m) return m.id end }, set_mode_callback)`.
4. `AgentModels:show_model_selector`: the same with `"Select Model:"`,
   `self.current_model_id` and `modelId`.

## Additions
### `lua/agentic/ui/option_selector.lua`
```lua
--- @class agentic.ui.OptionSelector.Opts
--- @field prompt string
--- @field current string|nil Id of the current entry, marked `●`
--- @field id_of fun(item: table): string

--- Pick an entry with `vim.ui.select`. Rows read `name: description`, or
--- `name` without a description. `on_pick` runs only for an entry other
--- than the current one.
--- @param items { name: string, description?: string }[]
--- @param opts agentic.ui.OptionSelector.Opts
--- @param on_pick fun(id: string)
--- @return boolean shown False when `items` is empty
function M.show(items, opts, on_pick)
```

### Tests
`option_selector.test.lua` (stub `vim.ui.select`, revert in `after_each`):
- empty list → false, no `select` call;
- `format_item` gives `● a: desc` for the current entry, `  b` for one
  with an empty description, `  c` for one with none;
- a pick of another entry calls `on_pick` with its id; a pick of the
  current entry and a cancel (`nil`) do not.

The existing `show_*_selector` cases in `agent_modes.test.lua`,
`agent_models.test.lua` and `agent_config_options.test.lua` pass
unchanged.

## Expected outcome
No change in behaviour. One row format and one pick rule for every
selector.

## Non-goals
- Merging `AgentModes`/`AgentModels` into `AgentConfigOptions`.
- The model order (`FIX-model-selector-order.md`). That plan's ordered
  list becomes the `items` argument of `OptionSelector.show` (through its
  new `options` parameter of `_show_selector`, and in
  `AgentModels:show_model_selector`). Either plan can land first; the
  second rebases.
- The callback parameters of the public `show_*_selector` methods
  (`REFACTOR-agent-config-lookup.md`); it does not touch these lines.

## Open questions
None.

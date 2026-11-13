# Plan: Model selector order
Status: reviewed spec
Priority: P3

## Relevant files
- `lua/agentic/acp/agent_config_options.lua` — `show_model_selector`, `_show_selector`
- `lua/agentic/acp/agent_models.lua` — legacy `AgentModels:show_model_selector`
- `lua/agentic/utils/model_order.lua` (new), `lua/agentic/utils/model_order.test.lua` (new)
- `lua/agentic/acp/agent_config_options.test.lua`, `lua/agentic/acp/agent_models.test.lua`
- `notes/REFACTOR-option-selector.md` — moves the `vim.ui.select` call of
  `_show_selector` and `AgentModels:show_model_selector` into
  `OptionSelector.show`; the ordered list becomes its `items`. Either plan
  can land first; the second rebases.
- `.claude/rules/tests.md`, skills: `implement`, `lua-class`
- Provider source (read-only): claude-agent-acp `dist/session-model.js`
  (`buildModelConfigOption` keeps the SDK's order; duplicate display names
  fall back to labels such as `Opus 4.6 (claude-opus-4-6)`, near line 512)

## Background
The model selector shows the provider's options in the provider's order.
Neither the plugin nor snacks' `vim.ui.select` sorts them (snacks sorts only a
non-empty query: `snacks/picker/core/matcher.lua:136`, `sort_empty = false`).
With claude-agent-acp the list is:

```
Default (recommended): Opus 5.5
Opus 5.5, Fable 5.1, Sonnet 5.5, Haiku 5.5      ← current lineup
Haiku 4.5, Sonnet 5, Opus 5, Fable 5, Opus 4.8, Opus 4.7, Opus 4.6, Sonnet 4.6
```

The head is useful: the default, then the newest model of each family. The
tail (older models) has no visible order. No field marks a model as current or
old, but the provider's order does: the head is the leading run of rows that
are either the first of their family or have no version. Keep that run as the
provider gives it, and sort the rest.

`Default` stays a separate row: a session on `default` follows the CLI's
default when it changes, so it is a different setting from the concrete model.

The rule uses only option names, so it is general code. A list with no
versioned names keeps its order (the whole list is the head).

## Changes

### New `lua/agentic/utils/model_order.lua`

```lua
--- @param name string
--- @return string|nil family_key lowercased name without its version
--- @return string|nil version e.g. "4.8"
function M.family_version(name)

--- @generic T
--- @param items T[]
--- @param name_of fun(item: T): string
--- @return T[] ordered new list; `items` is not changed
function M.order_by_family(items, name_of)
```

`family_version`:
- The version is the first word of the form `%d+(%.%d+)*` that starts after a
  space and ends at a space, `(`, `,`, `:` or end of string. So `GPT 4o`,
  `Model 480B` and `5 Opus` have no version; `Llama 3.1 70B Instruct` has
  `3.1`. A trailing `.` is not part of the version.
- The family key is the name with the version removed, whitespace collapsed,
  lowercased: `Gemini 2.5 Pro` → `gemini pro`; `Opus 4.6 (1M context)` →
  `opus (1m context)`.
- No version → `nil, nil`.

`order_by_family`:
1. Head: walk the list from the start. A row joins the head if it has no
   version, or if it is the first row of its family key. The first row that
   fails both ends the head.
2. Tail: all remaining rows, sorted by
   - family key (rows with no version use their lowercased name),
   - version newest first via `vim.version.cmp` (no version sorts last),
   - provider index (keeps the sort stable; `table.sort` is not).
3. Return head followed by tail. Empty and one-item lists come back as copies.

Claude's duplicate-name labels (`Opus 4.6 (claude-opus-4-6)`) parse as a
version plus a suffix family; in the tail they sort beside other rows of that
suffix family. Accepted: they are rare and the order stays deterministic.

### `lua/agentic/acp/agent_config_options.lua`
- `_show_selector(target, prompt, handle_change, options)`, new docstring line
  `--- @param options agentic.acp.ConfigOption.Option[]|nil rows to show; default target.options`.
  The existing guard stays on `target.options`.
- `show_model_selector`:
  ```lua
  local options = self.model
      and self.model.options
      and ModelOrder.order_by_family(self.model.options, function(o) return o.name end)
  local shown = self:_show_selector(self.model, "Select model to change:", on_pick, options)
  ```
  Mode and thought-level selectors do not change.
- The `●` marker compares `item.value` with `currentValue`, and `on_choice`
  reads only `selected.value`, so reordering cannot select the wrong option.

### `lua/agentic/acp/agent_models.lua`
- `show_model_selector`: give `vim.ui.select`
  `ModelOrder.order_by_family(self._models, function(m) return m.name end)`
  (after the existing empty guard). `on_choice` reads `modelId`, not the index.

### Tests
- `model_order.test.lua`, `family_version`: no version; trailing `.`;
  `5 Opus`; `Opus 4.6 (1M context)`; `GPT 4o`; `Model 480B`;
  `Llama 3.1 70B Instruct`; empty string.
- `model_order.test.lua`, `order_by_family`:
  - the claude-agent-acp list above gives the expected order (below);
  - a list with no versions keeps its order;
  - `GPT 5, o3, GPT 4.1, o4-mini` → `GPT 5, o3, GPT 4.1, o4-mini`
    (head ends at `GPT 4.1`; the tail sorts `gpt` before `o4-mini`);
  - `4.10` sorts above `4.9`; `5` and `5.0` keep provider order;
  - families that differ only in case are one family;
  - two rows with the same name keep provider order;
  - empty list, one item; the input list is not changed.
- `agent_config_options.test.lua` › `show_model_selector`: items given to
  `vim.ui.select` are in the new order and `●` is on the `currentValue` row;
  the mode selector keeps provider order.
- `agent_models.test.lua` › `show_model_selector`: the items are ordered.

## Expected outcome
```
  Default (recommended): Opus 5.5
● Opus 5.5: For complex work and everyday tasks
  Fable 5.1: …
  Sonnet 5.5: …
  Haiku 5.5: …
  Fable 5: …
  Haiku 4.5: …
  Opus 5: …
  Opus 4.8: …
  Opus 4.7: …
  Opus 4.6: …
  Sonnet 5: …
  Sonnet 4.6: …
```
If the provider changes its head order, the head follows it.

## Non-goals
- Merging `Default` with its concrete model (claude-agent-acp's AIR
  `recommendedValue` opt-in; it also changes the effort option).
- Editing the provider's labels, e.g. removing "(recommended)".
- Ordering the mode, thought-level, or other config-option selectors.
- Ordering in other places that list models (header, info panel).

## Open questions
None.

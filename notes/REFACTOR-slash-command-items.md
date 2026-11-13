# Plan: one builder of slash command completion items
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/completion/lsp_server.lua` — `get_slash_completions`,
  `get_slash_word_completions`
- `lua/agentic/completion/lsp_server.test.lua` —
  `describe("slash command completion")`,
  `describe("bare word slash command completion")`

## Background
`get_slash_completions` and `get_slash_word_completions` both read
`States.getSlashCommands(bufnr)` and make one item per command with the same
`label`, `kind`, `detail` and `filterText`. They differ only in the start of
the replaced range, the `/` before `newText`, and `score_offset` (5 for a
typed `/`, none for a bare word). An item field added to one path and not
the other makes the two menus show one command differently.

## Changes
1. Add `slash_command_items` (Additions) above `get_slash_completions`.
2. `get_slash_completions`: after it finds `slash_col`, build
   `range = { start = { line = cursor_line, character = slash_col }, ["end"] = { line = cursor_line, character = cursor_col } }`
   and return `slash_command_items(bufnr, range, "/", 5)`.
3. `get_slash_word_completions`: after it finds `word_col`, build the same
   range from `word_col` and return
   `slash_command_items(bufnr, range, "", nil)`.
   Its docstring drops ", inserting "/pymol"": the item replaces the typed
   word, so "py" becomes "pymol", as the test "inserts bare word via
   textEdit (no slash prefix)" asserts.

## Additions
### `lsp_server.lua`
```lua
--- Completion items for the buffer's slash commands, each replacing
--- `range` with `prefix` and the command.
--- @param bufnr integer
--- @param range lsp.Range
--- @param prefix string
--- @param score_offset integer|nil
--- @return table[]
local function slash_command_items(bufnr, range, prefix, score_offset)
```

### Tests (`lsp_server.test.lua`)
Existing cases in both `describe` blocks pass unchanged. Add to
`bare word slash command completion` an assertion that an item has no
`score_offset`, and to `slash command completion` that it has 5, so the
one difference in ranking is fixed by a test.

## Expected outcome
No behaviour change. Both menus build items in one place.

## Non-goals
- The `@` file items and buffer word items.
- The trigger patterns of the two functions.

## Open questions
None.

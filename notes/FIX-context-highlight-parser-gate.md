# Plan: check that a parser exists before context highlighting
Status: reviewed spec
Priority: P3

## Relevant files
- `lua/agentic/utils/treesitter.lua`: `highlight_map_in_context`
- `lua/agentic/ui/tool_call_layout.lua`: `hunk_rows`, the only caller; the `use_context_highlights` gate in `diff_section`
- `lua/agentic/utils/zsh_parse_guard.lua`: `defuse_hang_triggers`
- Tests: `lua/agentic/utils/treesitter.test.lua`, `lua/agentic/ui/tool_call_layout.test.lua`, `lua/agentic/ui/tool_call_renderer.test.lua`

## Background
The edit-diff gate in `tool_call_layout.lua` turns on context highlighting when
`lang ~= ""`. Nothing checks that a parser for `lang` is installed. For a file
whose language has no parser, `highlight_map_in_context` joins the whole
reconstructed file and runs `ZshParseGuard.defuse_hang_triggers` over it before
`get_string_parser` fails. Measured on nvim 0.12.6 (`--clean`): about 0.9 ms per
call at 5000 lines, called once per hunk side (`hunk_rows`) on every render of
every edit to such a file.

`vim.treesitter.language.add(lang)` is the probe (verified on 0.12.6):
- `"lua"` (installed) → `true`
- `""` → `nil, 'Invalid language name ""'`
- `"nonexistent_lang"` → `nil, 'No parser for language "nonexistent_lang"'`

It raises on a parser object that exists but cannot load, so it needs `pcall`,
and the result must be `true`: `pcall` alone is true in all three cases. A miss
costs about 0.05 ms (it searches the runtime path), a hit about 0.006 ms.

The check goes in `highlight_map_in_context` only. Its contract is already "nil
when no parser is installed", and it already gives `nil` silently on a parse
failure (the `pcall` around `get_string_parser`), so the probe changes its cost,
not its behaviour. The gate keeps `lang ~= ""`: a second probe there saves only
the 0.05 ms misses.

The same wrong idiom, `return pcall(vim.treesitter.language.add, lang)`, is the
local `has_parser` skip helper in three test files, so those helpers are true
for every language and never skip.

## Changes
### 1. `lua/agentic/utils/treesitter.lua`
- Add:
  ```lua
  --- Whether a parser for `lang` is installed and loads.
  --- @param lang string Parser language
  --- @return boolean
  function M.has_parser(lang)
      local ok, available = pcall(vim.treesitter.language.add, lang)
      return ok and available == true
  end
  ```
- `highlight_map_in_context`: return `nil` at the top when not
  `M.has_parser(lang)`, before the reconstruction. The `pcall` around
  `get_string_parser` stays for other parse failures.

### 2. Tests
- `treesitter.test.lua`, `tool_call_layout.test.lua`,
  `tool_call_renderer.test.lua`: delete the local `has_parser` and call
  `Treesitter.has_parser`. The last two files add
  `local Treesitter = require("agentic.utils.treesitter")`.
- `treesitter.test.lua`:
  - `has_parser`: true for `"lua"`, false for `""` and `"nonexistent_lang"`.
  - The existing case "returns nil when no parser is installed": also spy on
    `ZshParseGuard.defuse_hang_triggers` and assert no call; revert the spy in
    `MiniTest.finally`. It fails on the current code.

## Expected outcome
- An edit to a file with no installed parser does no reconstruction and no
  hang-trigger scan per render.
- Test cases that need a parser skip when it is not installed, instead of
  failing.

## Non-goals
- `string_highlight_trees` probes with `language.add` without `pcall`, so a
  parser that cannot load raises there. It stays visible.
- `bootstrap.lua` `register_languages`: it registers `agentic` with
  `language.add`'s `path` and `symbol_name` options, and its `pcall` already
  catches the failure it guards. `has_parser` takes no options.
- The cost of one reconstruction per hunk side per render (`TODO.md`
  § Inline bugs).
- Parsing less than the whole reconstruction: the comment in
  `highlight_map_in_context` above `lang_tree:parse` gives why a narrower
  window gives wrong captures.

## Open questions
None.

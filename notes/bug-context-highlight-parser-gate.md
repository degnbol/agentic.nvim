# Bug: context highlighting does not check that a parser exists

Line numbers against `cc07515` + working tree.

## Mechanism

`use_context_highlights` (`tool_call_renderer.lua:1204-1206`) gates context
highlighting on `lang ~= ""` alone. Nothing checks that a grammar for `lang` is
installed.

For a path whose language has no installed parser,
`highlight_map_in_context` concatenates the whole reconstructed file and runs
`ZshParseGuard.contains_hang_trigger` over it (`treesitter.lua:48-53`)
*before* `get_string_parser` fails at `:54-58`. Measured on nvim 0.12.6
(`--clean`): ≈0.9 ms per call at 5000 lines, ×2×`#diff_blocks`, on every render
of every edit to such a file.

## The probe

Name it once, in `lua/agentic/utils/treesitter.lua`:

```lua
--- @param lang string
--- @return boolean
function M.has_parser(lang)
    local ok, available = pcall(vim.treesitter.language.add, lang)
    return ok and available == true
end
```

**Both halves are needed.** Verified on nvim 0.12.6: `language.add` returns
`true` when the parser is loadable and `nil, "No parser for language …"` (or
`nil, 'Invalid language name ""'`) when it is not. A bare `pcall(...)` is
always true. The `pcall` is still necessary because `loadparser` →
`_ts_add_language_from_object` raises on an unloadable object.

## Two placements, different jobs

- **`use_context_highlights` (`tool_call_renderer.lua:1204-1206`)** — replace
  `lang ~= ""` with `Treesitter.has_parser(lang)`. It includes the empty-string
  case (`language.add("")` → `nil, 'Invalid language name ""'`) and runs
  once per render instead of per block.
- **Top of `highlight_map_in_context`** — same call, as the function's own
  guard, so no caller pays the concat + hang-scan for a language that can
  never parse.

Cost is net-positive in both directions (nvim 0.12.6, `--clean`): a miss costs
≈0.05 ms (`language.add` searches the runtime path on every miss), a hit
≈0.006 ms, against ≈0.9 ms saved per call.

`has_parser` also replaces the same broken idiom in the skip helpers at
`treesitter.test.lua:7-9` and `tool_call_renderer.test.lua:8-10`. They return
true for every language.

## Tests

In `treesitter.test.lua`, not the renderer: spy on
`ZshParseGuard.contains_hang_trigger`, call `highlight_map_in_context` with
`lang = "nonexistent_lang"`, assert zero calls. It is deterministic and fails
on the current code. The existing case "returns nil when no parser is
installed" asserts only the `nil` result, which the current code already
gives. A renderer-side test needs a real extension whose parser is absent from
the test runtime, and stops working when someone installs it.

Two gaps in the same file:

- No case calls `highlight_map_in_context` with `file_lines = {}` — the shape
  of every created-file block (`ToolCallDiff._create_new_file_diff_block`).
- No case uses out-of-range `splice_start`/`splice_end`. There, only the
  `math.min`/`math.max` clamps at `treesitter.lua:37-38` keep the result
  correct (`_create_new_file_diff_block` sets `end_line = max(1, #new_lines)`).

## In the same gate

`tool_call_renderer.lua:1202-1203`: `n_context_lines` is not a count of
context lines and not the reconstruction's length
(`#source_lines - (e - s) + #new_lines`).
`math.max(#source_lines, #diff.new)` is an upper bound on it. Rename to
`max_reconstructed_lines`.

## Related, not in this fix

- **`bootstrap.lua:24-28`** (`register_languages`) uses the same
  `pcall(language.add, …)` idiom. The failure it guards (`markdown.so`
  present, unloadable) *raises* inside `_ts_add_language_from_object`, so
  `pcall` returns false and the markdown fallback fires. Not a live bug.
  `has_parser` can replace it only if it also accepts `language.add`'s `opts`
  (`path`, `symbol_name`).
- **Per-block reconstruction cost.** The map is rebuilt per block per side, so
  a multi-hunk diff reconstructs the file `2 × #diff_blocks` times. The fix is
  to splice every block into one reconstruction per side. The comment at
  `tool_call_renderer.lua:1195-1198` states the current cost.

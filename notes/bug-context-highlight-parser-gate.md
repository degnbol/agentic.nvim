# Bug: context highlighting no longer checks that a parser exists

Found reviewing `47f46a3` + `e3c0710`. Line numbers are against `50ed666`.

## Mechanism

`tool_call_renderer.lua:782-784` gates context highlighting on `lang ~= ""`
alone. Before `47f46a3`, `pcall(vim.treesitter.get_parser, bufnr, lang)` also
proved a grammar existed; the plan for that change correctly called the `pcall`
dead (`get_parser` returns `nil, err` rather than raising) but the
`ok_parser and parser` pair it fed was still filtering on availability. That
filter is gone.

For a path whose language has no installed parser,
`highlight_map_in_context` now concatenates the whole reconstructed file and
runs `ZshParseGuard.contains_hang_trigger` over it (`treesitter.lua:48-53`)
*before* `get_string_parser` fails at `:54` — measured 0.39 ms per call at 5000
lines, ×2×`#diff_blocks`, on every render of every edit to such a file.

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

**Both halves are needed.** Verified on nvim 0.12.4 against
`runtime/lua/vim/treesitter/language.lua:107-140`: `language.add` returns `true`
when the parser is loadable and `nil, "No parser for language …"` (or
`nil, 'Invalid language name ""'`) when it is not — a bare `pcall(...)` is always
true and would repeat exactly the dead-check mistake. The `pcall` still earns
its place because `loadparser` → `_ts_add_language_from_object` raises on an
unloadable object.

## Two placements, different jobs

- **`use_context_highlights` (`tool_call_renderer.lua:782-784`)** — replace
  `lang ~= ""` with `Treesitter.has_parser(lang)`. It subsumes the empty-string
  case (`language.add("")` → `nil, 'Invalid language name ""'`) and is evaluated
  once per render instead of per block.
- **Top of `highlight_map_in_context`** — same call, as the mechanism's own
  guard, so no caller can pay the concat + hang-scan for a language that can
  never parse.

Cost is net-positive in both directions: a miss costs 0.088 ms (`language.add`
globs the runtime path on every miss — not a hash lookup) against 0.39 ms saved;
a hit costs 0.002 ms.

`has_parser` also replaces the identical broken idiom in the skip helpers at
`treesitter.test.lua:7-9` and `tool_call_renderer.test.lua:7-9`, which currently
return true for every language.


## Tests

In `treesitter.test.lua`, not the renderer: spy on
`ZshParseGuard.contains_hang_trigger`, call `highlight_map_in_context` with
`lang = "nonexistent_lang"`, assert zero calls. Deterministic, and it fails
today. A renderer-side test would need a real extension whose parser happens to
be absent from the test runtime, and would stop biting the moment anyone
installs it.

Two gaps in the same file, both cheap:

- `highlight_map_in_context` is never called with `file_lines = {}` — the shape
  every created-file block takes, via `_create_new_file_diff_block`.
- Nor with out-of-range `splice_start`/`splice_end`, where the `math.min`/
  `math.max` clamps at `treesitter.lua:37-38` are the only thing keeping that
  path correct (`end_line` is `max(1, #new_lines)`).

## While in the gate

`tool_call_renderer.lua:780`: `n_context_lines` is neither a count of context
lines nor the reconstruction's length (`#source_lines - (e - s) + #new_lines`) —
`math.max(#source_lines, #diff.new)` is an upper bound on it.
`max_reconstructed_lines`.

## Related, not in this fix

- **`init.lua:434-438`** uses the same `pcall(language.add, …)` idiom, but the
  failure it guards (`markdown.so` present, unloadable) *raises* inside
  `_ts_add_language_from_object`, so `pcall` returns false and the markdown
  fallback at `:441` does fire. Worth switching to `has_parser` for clarity once
  that helper exists; not a live bug.
- **Per-block reconstruction cost.** The map is rebuilt per block per side, so a
  multi-hunk diff reconstructs the file `2 × #diff_blocks` times. Splicing every
  block into one reconstruction per side is the fix; the comment at `:773-776`
  is honest about the current cost.

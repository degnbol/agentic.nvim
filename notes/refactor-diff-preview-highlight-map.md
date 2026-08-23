# Refactor: fold `diff_preview`'s highlight map into the shared helper

Found reviewing `47f46a3` + `e3c0710`. Line numbers are against `50ed666`.

`diff_preview.lua:59-109` is a hand-rolled subset of
`Treesitter.highlight_map_in_context`: one tree, no injection walk, no `_`/
`@spell` capture filtering. The duplication was justified while the shared
helper demanded a bufnr. Since `47f46a3` it takes lines, so it no longer is.

## Change

Replace the local function and the now-unused `ZshParseGuard` require with a
call at `:217`:

```lua
local row_col_hl = Treesitter.highlight_map_in_context({}, lang, 0, 0, new_lines)
```

`file_lines = {}` with a `0,0` splice clamps to empty prefix and suffix, so the
reconstruction is `new_lines` verbatim — the same string the local version
parses.

**Pass `{}`, not the file's real content**, even though the preview renders
virt_lines inside the actual file buffer at known coordinates. `new_lines` here
has already had unchanged lines filtered out, so splicing it back at
`block.start_line` would reconstruct a file that never existed. (The chat
renderer gets real context because it maps over unfiltered `block.new_lines` and
indexes by `pair.new_idx`.)

## Three output differences, none blocking

- Rows with no captures come back absent rather than `{}`; the only consumer,
  `:221`, reads `row_col_hl and row_col_hl[row - 1]`.
- `#new_lines == 0` yields `{}` rather than `nil`; the consumer loop never runs.
- The preview gains injected-language highlighting **and gains colour it is
  currently losing**: the local version writes `@spell.lua` over `@comment.lua`,
  and `@spell` has no foreground, so comments and docstrings render uncoloured in
  the preview today.

## Verification

`diff_preview.test.lua` has no highlight-map cases, so this is an eyeball, not a
test-covered change — open a preview of a docstring-heavy or markdown edit and
confirm the third difference is the improvement it should be.

Independent of `bug-context-highlight-parser-gate.md`: `lang == ""` and missing
parsers both already return nil via `get_string_parser`. That fix only makes the
miss path cheaper.

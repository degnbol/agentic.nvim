# Plan: one extended-colour parse and one text emit in `Ansi`
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/utils/ansi.lua` — `apply_sgr`, `process_line`
- `lua/agentic/utils/ansi.test.lua` — `describe("process_lines")`

## Background
Two copies in one module:
- `apply_sgr` parses the extended colour in its `c == 38` and `c == 48`
  branches with the same code: `5;n` is a palette index, `2;r;g;b` is RGB.
  Only the target field differs.
- `process_line` emits a plain-text run in two branches: the rest of the
  line when no ESC follows (`if not esc_pos`), and the text before an ESC
  (`if esc_pos > pos`). Both append the text, advance `col`, and add a span
  when the SGR state is not empty.

## Changes
1. Add the local `extended_color` (Additions) above `apply_sgr`. The `38`
   branch becomes
   `local color, skip = extended_color(codes, i); state.fg = color or state.fg; i = i + skip`,
   and the `48` branch the same with `state.bg`.
2. `process_line`: in the loop, `local stop = esc_pos and esc_pos - 1 or len`.
   When `stop >= pos`, the one emit block runs on `line:sub(pos, stop)`.
   Then `if not esc_pos then break end`. The CSI and skip steps after it are
   unchanged. The `#text > 0` guard goes: the loop runs only while
   `pos <= len`.

## Additions
### `ansi.lua`
```lua
--- The colour of an extended colour code (`38` or `48`) at `codes[i]`:
--- `5;n` is a palette index, `2;r;g;b` is RGB.
--- @param codes integer[]
--- @param i integer
--- @return string|nil color "#rrggbb"; nil for another or a short form
--- @return integer skip Codes after `codes[i]` that the colour used
local function extended_color(codes, i)
```

### Tests (`ansi.test.lua`)
Existing cases pass unchanged ("handles 256-colour mode", "handles true
colour (24-bit RGB)", "handles text before first escape", "handles line
with only escape codes"). Add, written first and passing on today's code:
- `48;5;n` and `48;2;r;g;b` set the background.
- After `31`, `38;2;1;2` (short RGB form) leaves the foreground as `31` set
  it.

## Expected outcome
No behaviour change.

## Non-goals
- The `0` reset written twice in `apply_sgr`.
- `dim` in the highlight key but not in the highlight.

## Open questions
None.

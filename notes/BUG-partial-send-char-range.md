# Bug: a charwise partial send cuts or drops the last char
Status: draft

## Relevant files
- `lua/agentic/ui/input_dispatch.lua`: `clamp_char_range`, `send_opts`, `motion_span`, `visual_span`
- Tests: `lua/agentic/ui/input_dispatch.test.lua` "partial_send", `tests/integration/send.test.lua`
- Help: `:h 'selection'`, `:h '[`, `:h getregion()`, `:h getregionpos()`, `:h vim.str_utf_end()`

## Background
`clamp_char_range` turns the inclusive end column into an exclusive one: `ec + 1`, or `ec` when `'selection'` is `exclusive`. Two defects follow:
1. An inclusive charwise visual send that ends on a multibyte char cuts the char after its first byte. Example: `v4l` on `abc é` sends `abc ` plus the first byte of `é`, which is invalid UTF-8, and leaves the second byte in the input.
2. With `'selection'=exclusive`, the send operator (`<CR>{motion}`) drops the last char of a charwise motion. `']` is inclusive for every `'selection'` value, but `clamp_char_range` applies `exclusive` to it too. Example: `<CR>e`.

`getregion()` / `getregionpos()` are not a drop-in fix. Tested on NVIM 0.12.6 (`nvim --clean --headless -l`). They match the current code on position order, `$` and `INT_MAX` end columns, and empty lines. They differ here:

| Case | Current code | `getregion` / `getregionpos` | Native `d` |
|---|---|---|---|
| Inclusive visual ends on a multibyte char (`v4l` on `abc é`) | `ec + 1` cuts the char after its first byte: invalid UTF-8 | whole char | whole char |
| `'selection'=exclusive`, `v` with no move | no-op | one char | one char |
| `'selection'=exclusive`, `vj` from col 0 to col 0 | includes the newline | no newline | includes the newline |
| A column past the line end (not `INT_MAX`) | clamps | `E964` | n/a |

For the operator, `getregion` with its default `exclusive` (from `'selection'`) has the same defect as the current code.

## Changes
- `clamp_char_range`: take whether the end is inclusive as a parameter, instead of reading `'selection'`. For an inclusive end, the exclusive end is `ec + 1 + vim.str_utf_end(end_line, ec + 1)` (the whole char at `ec`).
- `_send_operator` (`motion_span` after the dedup plan): the end is always inclusive.
- `_send_visual` (`visual_span`): the end is inclusive unless `'selection'` is `exclusive`.
- Tests: `v4l` on `abc é` sends `abc é` and leaves an empty line; with `'selection'=exclusive`, `<CR>e` on `hello world` sends `hello`.

## Expected outcome
A charwise send never splits a multibyte char, and the send operator sends the whole motion for every `'selection'` value.

## Non-goals
- Using `getregion()` / `getregionpos()` (see the table).

## Open questions
- With `'selection'=exclusive`, `v` with no move sends nothing, but native `d` deletes one char. Match native `d`?

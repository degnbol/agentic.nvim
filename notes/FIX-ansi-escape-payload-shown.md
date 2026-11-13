# Plan: Strip every escape sequence whole in `Ansi`
Status: spec

## Relevant files
- `lua/agentic/utils/ansi.lua` — `process_line` (the escape scan), module docstring
- `lua/agentic/utils/ansi.test.lua` — `describe("process_lines")`
- `notes/REFACTOR-ansi-parse-copies.md` — also edits `process_line`
- Skills: `implement`, `neovim`

## Background
`process_line` strips a CSI sequence only when its parameters are digits and
`;` (`^%[([%d;]*)([%a@-~])`). For any other escape it skips `ESC` and the
next byte (the branch commented "try OSC (ESC ]) or other"), so the rest of
the sequence stays in the clean text. Measured with `Ansi.process_lines`:

| Input | Clean text today | Source |
|---|---|---|
| `\27]8;;http://x.io\27\\link\27]8;;\27\\ end` | `8;;http://x.iolink8;; end` | OSC 8 hyperlink, `ls --hyperlink=always` |
| `\27]0;title\7text` | `0;title\7text` | OSC 0 title, BEL terminator |
| `\27[?25lhidden\27[?25h` | `?25lhidden?25h` | CSI with private parameter (cursor hide/show) |
| `\27[>4;2mk` | `>4;2mk` | CSI with private parameter, final `m` |
| `\27(B\27[mreset` | `Breset` | nF escape: `tput sgr0` on xterm-256color is `\E(B\E[m` |

All five rows have one cause: the scan knows the end of only one escape
shape. ECMA-48 gives each escape a shape that fixes its end, so one scan by
shape strips them all:

- CSI: `ESC [`, parameter bytes 0x30–0x3F, intermediate bytes 0x20–0x2F,
  final byte 0x40–0x7E.
- Control string (OSC `]`, DCS `P`, SOS `X`, PM `^`, APC `_`): up to the
  first BEL or `ESC \`. Output is split into lines before the parse, so an
  unterminated string runs to the end of the line.
- nF escape: `ESC`, intermediate bytes 0x20–0x2F, final byte 0x30–0x7E.
- Anything else (Fe, Fp, Fs escapes): `ESC` and one byte, as today.

SGR stays as today: a CSI with final `m` and parameters of digits and `;`
only. A private parameter (`\27[>4;2m`) is not SGR and must not change the
colour state.

## Changes

### `lua/agentic/utils/ansi.lua`
1. Add the local `escape_end` (Additions) above `process_line`.
2. `process_line`: replace the CSI match and the skip branch with
   `local seq_end = escape_end(line, esc_pos)`, then
   `local sgr = line:sub(esc_pos, seq_end):match("^\27%[([%d;]*)m$")`;
   when `sgr`, `apply_sgr(state, sgr)`. Then `pos = seq_end + 1`. The
   comments "All CSI sequences are stripped …" and "Not a recognised CSI
   sequence …" go.
3. Docstrings: `process_line` "strip all CSI sequences" becomes "strip all
   escape sequences". The module docstring is still true; no change.

## Additions

### `ansi.lua`
```lua
--- The last byte of the escape sequence that starts at `line:sub(i, i)`, an
--- ESC. Shapes per ECMA-48: a CSI; a control string (OSC, DCS, SOS, PM,
--- APC) up to its BEL or `ESC \` terminator, or to the end of `line`; an nF
--- escape; otherwise ESC and the byte after it.
--- @param line string
--- @param i integer index of the ESC in `line`
--- @return integer last index of the sequence in `line`, at most `#line`
local function escape_end(line, i)
```
Patterns (decimal escapes; byte ranges as above):
- CSI: `line:find("^%[[\48-\63]*[\32-\47]*[\64-\126]", i + 1)`.
- Control string: `line:find("^[%]PX^_]", i + 1)`; end at the earlier of
  `line:find("\7", i + 2, true)` and the second byte of
  `line:find("\27\\", i + 2, true)`; neither → `#line`.
- nF: `line:find("^[\32-\47]+[\48-\126]", i + 1)`.
- Otherwise `math.min(i + 1, #line)`. An unterminated CSI or nF (no final
  byte on the line) takes this branch, as today.

### Tests (`ansi.test.lua`)
Written first; each fails on today's code except the last:
- OSC 8 with `ESC \`: `\27]8;;http://x.io\27\\link\27]8;;\27\\ end` →
  `link end`.
- OSC 0 with BEL: `\27]0;title\7text` → `text`.
- Unterminated OSC: `a\27]8;;http://x.io` → `a`.
- Private CSI: `\27[?25lhidden\27[?25h` → `hidden`, no spans.
- Private CSI with final `m`: `\27[>4;2mk` → `k`, no spans.
- nF escape: `\27(B\27[mreset` → `reset`.
- CSI with an intermediate byte: `\27[2 qx` → `x`.
- SGR with colon subparameters: `\27[38:5:208mx` → `x`, no spans.
- SGR after an OSC: `\27]8;;u\27\\\27[31mred\27[0m` → `red`, one span at
  cols 0–3.
- Lone ESC at line end: `a\27` → `a`.

## Expected outcome
- No part of an escape sequence shows in a tool's output: OSC hyperlinks
  and titles, private-mode CSI, and charset escapes are stripped whole.
- SGR colours render as today. An SGR with colon subparameters
  (`38:5:208`) is stripped with no colour change; today its parameters show
  as text.

## Non-goals
- Rendering OSC 8 hyperlinks as links.
- Control strings that span lines.
- SGR colon subparameters (`38:5:208`).
- `REFACTOR-ansi-parse-copies.md`: its change 2 keeps "the CSI and skip
  steps" unchanged; whichever plan lands second rebases on the other. The
  two do not conflict in behaviour.

## Open questions
None.

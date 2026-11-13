# Plan: budget lines show the time to the limit, in aligned columns
Status: reviewed spec
Priority: P2
Depends:

## Relevant files
- `lua/agentic/budget.lua` (`pace`, `trailing_pace`, `state`)
- `lua/agentic/budget.test.lua`
- `lua/agentic/ui/chunks.lua`
- `lua/agentic/ui/info_panel.lua` (`window_line`, `InfoPanel.lines`, `render`)
- `lua/agentic/ui/info_panel.test.lua` (`highlighted`)
- `lua/agentic/utils/duration.lua` (`format`)
- `doc/agentic.txt` § agentic-budget
- Skills: `implement` (Lua reference), `writing`; rule `help.md`

## Background
The info panel shows one line per usage window:
```
- 5h: 43% used · resets 19:10 (in 2h52m) · on pace for 94%
- 7d: 96% used · resets Sun 19:00 (in 50h42m) · on pace for 127%
```
"On pace for 127%" says the limit comes before the reset, but not when. The
time to the limit is the number a user acts on. The pace already holds it:
`pace = u + rate × R`, with `u` the window's utilization, `rate` the fraction
used per second and `R` the seconds to the reset. So the limit is
`(1 − u) ÷ rate = (1 − u) × R ÷ (pace − u)` seconds away, and it is earlier
than the reset exactly when the pace is above 1.

Both lines show the time to the limit. When it is later than the reset, the
user can compare the two times to see the margin. When it is earlier, it is
coloured as a warning, as the pace above 1 is now.

## Changes
`lua/agentic/budget.lua`: new
`Budget.limit_in(window, now): integer|nil`, seconds until utilization
reaches 1 at the pace's rate: `floor((1 − u) × R ÷ (pace − u))` with
`pace = Budget.pace(window, now)` and `R = Budget.resets_in(window, now)`.
Nil when the pace is nil, `u ≥ 1`, or `pace − u ≤ 0`. That last condition
covers a window past its reset (`pace` is `u` there) and a rate of 0 or
below.

`lua/agentic/ui/chunks.lua`: new
`Chunks.columns(rows, specs): agentic.ui.Chunk[][]`, with a new
`chunks.test.lua`.
- `rows`: `agentic.ui.Chunk[][]`. Cell `i` of a row is chunk `i`, holding
  only the part that changes between rows.
- `specs`: `{ prefix: string, right: boolean }[]`. `prefix` is the fixed text
  before the column's cells.
- Each cell is padded with spaces to the widest cell of its column
  (`vim.fn.strdisplaywidth`): before the cell when `right`, else after it.
- A row with fewer cells ends after its last cell, with no trailing padding.
- Output chunks per cell, in order: the prefix's leading spaces (no
  highlight), the rest of the prefix (the cell's highlight), the padding (no
  highlight) when `right`, the cell (its highlight), the padding (no
  highlight) when not `right`. Empty chunks are left out. So a highlighted
  chunk's text does not depend on the other rows.

`lua/agentic/ui/info_panel.lua`:
- `window_line` becomes `window_cells(window, now): agentic.ui.Chunk[]` and
  returns the cells only. `InfoPanel.lines` passes the rows of all windows
  through `Chunks.columns` together, with these specs:
  | prefix        | right | cell                                | highlight |
  |---------------|-------|-------------------------------------|-----------|
  | `- `          | no    | label                               | `Budget.hl(window.state)` |
  | `  `          | yes   | `43% used`                          | `Budget.hl(window.state)` |
  | `  resets `   | yes   | `19:10` / `Sun 19:00`               | |
  | ` (in `       | yes   | `Duration.format(resets_in) .. ")"` | |
  | `  limit in ` | yes   | `"~" .. Duration.format(limit_in)`  | warning when `limit_in < resets_in` |
- A window past its reset has the first two cells only (`- 5h   0% used`
  under `43% used`). A window with a nil `limit_in` has no last cell.
- The `on pace for` part is removed. `Budget.pace` stays for `Budget.state`
  and the statusline. `limit_in < resets_in` is the same test as
  `pace > 1`, so the panel, `Budget.state` and the statusline agree.

`doc/agentic.txt` § agentic-budget: add a `budget.limit_in()` entry after
`budget.pace()`, as short as that entry is.

Tests:
- `budget.test.lua`: `limit_in` for a known pace; nil with a nil pace, when
  used up, past the reset, and at a rate of 0.
- `chunks.test.lua`: `Chunks.columns` left and right padding, a row with
  fewer cells, a wide (multi-byte) cell, and the chunk order with highlights.
- `info_panel.test.lua`: update the exact-line and `on pace` assertions to
  the new format. One two-window test with reset times and durations of
  different widths checks that the columns line up. Check the warning
  highlight on `limit in`/`~…` before the reset and its absence after.

## Expected outcome
```
- 5h  43% used  resets     19:10 (in  2h52m)  limit in  ~6h12m
- 7d  96% used  resets Sun 19:00 (in 50h42m)  limit in ~34h10m
```
The 7d `limit in ~34h10m` is coloured `AgenticBudgetWarning`, because it is
earlier than its reset.

## Non-goals
- Tokens or sessions left: `IDEA-budget-sessions-left.md`.
- Moving the budget lines into another panel: `IDEA-session-stats-logging.md`.
- Days in `Duration.format`, which has other callers. Right after a 7d reset
  a very low rate can give a wide value such as `~900h00m`.
- The statusline format.

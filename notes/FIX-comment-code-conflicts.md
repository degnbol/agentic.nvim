# Plan: Resolve three comment/code conflicts
Status: spec

Three independent items. In each, a comment or doc and its code disagree.
Decided: item 1 fixes the code (inset offsets), item 2 fixes the doc, item 3
fixes the code (line background on every modified new line, as upstream
`e2937ac`). Items can land separately.

## Relevant files
- `lua/agentic/ui/permission_float.lua` — `PermissionFloat._anchor_position` and its docstring, `PermissionFloat:_placement`
- `lua/agentic/ui/permission_float.test.lua` — `describe("_anchor_position")`
- `lua/agentic/config_default.lua` — `agentic.UserConfig.PermissionFloat` `@field anchor`, `row_offset`, `col_offset`; `permission_float` defaults
- `doc/agentic.txt` — `*agentic-config-permission_float*`
- `lua/agentic/ui/permission_manager.lua` — `CACHE_KEY_FIELDS`, `CACHE_NOISE_FIELDS`, `PermissionManager:_build_cache_key`
- `lua/agentic/utils/diff_highlighter.lua` — `M.apply_new_line_word_highlights`, `M.apply_diff_highlights`, `M.find_inline_change`
- `lua/agentic/utils/diff_highlighter.test.lua`
- `lua/agentic/ui/tool_call_layout.lua` — where `"new_modification"` rows are made (paired lines of a same-length hunk)
- Skills: `permissions` (item 2), `rendering` (item 3)
- nvim help: `nvim_open_win()` `anchor` (api.txt) — the float's own corner is put at (row, col)

## Background

### 1. Permission float offsets
Code (`_anchor_position`): the offsets are added to the corner of the parent
window, `row = (N and 0 or win_h) + row_offset`,
`col = (W and 0 or win_w) + col_offset`. Positive is down and right for every
corner. The float's own corner is the same as `anchor`
(`_placement` passes `anchor = self._anchor`), so `(0, 0)` is flush with the
corner. The four tests assert the additive formula.

Docs (`config_default.lua` `@field`, `doc/agentic.txt`): "Inset from the
anchored corner", positive is up for `S*` and left for `*E`. The
`_anchor_position` docstring is in conflict with itself: "positive moves
inward from the natural edge", followed by additive formulas and "use
negative col_offset to inset".

History:
- `07e4bdb` added code, docstrings, tests and defaults together with
  `anchor = "NE"`, `row_offset = 1`, `col_offset = -1`. Under the code that is
  a 1-cell inset on both axes, which the word "Inset" describes.
- `9e307ef` (an auto-scroll commit) changed only `anchor` to `"SE"`. Under
  the code, `row_offset = 1` now puts the float 1 row below the window's
  bottom edge (on the statusline or the next window).

Additive offsets do not keep their meaning when the anchor changes; inset
offsets do.

### 2. Cache noise fields on the known-kind path
`CACHE_NOISE_FIELDS` doc: "Used by the hybrid path; also skipped if listed in
CACHE_KEY_FIELDS." Code: the known-kind path keys on its listed fields and
does not use the noise filter. Code and doc came together in `238facd`, and
the code has always been like this. No field is in both tables today. A field
listed as identity is a deliberate choice that a noise filter would silently
make unused.

### 3. New-line highlight when a line only lost characters
`apply_new_line_word_highlights` highlights the new half of a paired
modified line. Word branch (inserted text exists): only `DIFF_ADD_WORD` on
the inserted range, no line background. `else` branch (no inserted text, e.g.
`"ab"` → `"a"` or `"abc"` → `""`): `DIFF_ADD` line background on the whole
line. The comment says "Entire line changed", but a fully replaced line goes
to the word branch.

The old half (`apply_diff_highlights`, modification case) always gets the
`DIFF_DELETE` line background, with `DIFF_DELETE_WORD` on top.

History:
- `7a4765d` (upstream): both halves were symmetric. The word branch added the
  line background unless the change spanned the whole line. The `else`
  comment was already wrong.
- `6b224f4` (upstream, rich diff preview): removed the line background from
  the new half's word branch, and made the old half's line background
  unconditional. This is where the asymmetry started.
- `db05b4d` (fork): changed to `line_hl_group` extmarks. No change to the logic.
- Upstream `e2937ac` (#273, "fix(diff): background on diff lines", not in
  this fork): added the line background back to the word branch, "so
  unchanged portions of the changed line keep the added-line color, matching
  the deleted/modified path". The diff is only that call plus one test.
  Upstream's line background is a `vim.highlight.range` over the text, not a
  `line_hl_group` extmark.

No test covers `apply_new_line_word_highlights`.

## Changes

### 1. Permission float offsets: inset
- `_anchor_position`: `row = N and row_offset or win_h - row_offset`; `col = W and col_offset or win_w - col_offset` (N/W from the first/second character of `anchor`). Docstring: "Offsets are an inset from the corner: positive moves into the parent window on both axes, for every anchor." Delete the per-corner formulas and the "use negative … to inset" notes.
- `config_default.lua`: `col_offset = 1`, which keeps the 1-cell inset of the original defaults. `row_offset = 1` stays. `@field` text: "Inset from the anchored corner (positive = into the window)". `@field anchor` and the comment above `permission_float` say "chat window"; since `c61b19f` the parent is the window showing the tool call, as `doc/agentic.txt` says. Fix both in the same edit.
- `doc/agentic.txt`: the same offset wording. Change the `col_offset` default to `1`.
- `permission_float.test.lua` `_anchor_position`: change the four cases to inset semantics, with names that state the rule, e.g. "SE: positive offsets move up and left". Expected values with `win_w = 200`, `win_h = 100`: NW `(2, 3)` → `(2, 3)`; NE `(1, 1)` → `(1, 199)`; SW `(1, 4)` → `(99, 4)`; SE `(2, 3)` → `(98, 197)`.
- A user config that sets the offsets for the old semantics changes behaviour. The user's nvim config does not set `permission_float`.

### 2. Cache noise fields: fix the doc
- `permission_manager.lua` `CACHE_NOISE_FIELDS` docstring: change the last sentence to "Used only by the hybrid path: a known kind keys on its `CACHE_KEY_FIELDS` alone."
- Tests: no change.

### 3. New-line highlight: line background on every modified new line
- Both branches apply the line background, so call `apply_add_line_highlight` above the `if` and keep only the word range in the conditional. The function then does what `apply_diff_highlights` does for the old half. Delete the `else` and its comment.
- Check that `DIFF_ADD_WORD` shows above the `line_hl_group` background. The old half already uses the same combination (`line_hl_group` plus a `vim.highlight.range` word). If the word overlay does not show, set a priority.
- Tests (`diff_highlighter.test.lua`, read with `nvim_buf_get_extmarks(..., { details = true })` on a scratch buffer; the line mark is in `details.line_hl_group`, unlike upstream's test helper): `"ab"` → `"a"` gives a `DIFF_ADD` line extmark and no word range; `"hello world"` → `"hello big world"` gives a `DIFF_ADD` line extmark and `DIFF_ADD_WORD` at cols 6–10; `"abc"` → `"xyz"` gives a line extmark and word cols 0–3; `"abc"` → `""` gives a line extmark on the empty line.

## Expected outcome
- Permission float offsets are an inset for every anchor; the default float
  is 1 cell inside the `SE` corner. Docs and docstring say so.
- The `CACHE_NOISE_FIELDS` doc states the hybrid-path-only filter. No
  behaviour change.
- The new half of a modified line always has the added-line background, with
  word emphasis on inserted text.

## Non-goals
- Other permission float options (`width`, `border`, resize handling).

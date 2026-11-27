# Plan: cut the prefix-boundary suffix where the match ends
Status: spec

## Relevant files
- `lua/agentic/utils/text_matcher.lua` — `PREFIX_STRATEGIES`, `find_all_prefix_boundary_matches`, `_try_find_prefix_boundary_matches`, `trim_trailing`, `trim_space`
- `lua/agentic/utils/text_matcher.test.lua` — `describe("find_all_prefix_boundary_matches")`
- `lua/agentic/ui/tool_call_diff.lua` — `match_or_substring_fallback` appends `match.suffix` to the last OLD and NEW lines (the only consumer of `suffix`)
- Skills: `implement`, `neovim`

## Background
When OLD ends in a partial line, `find_all_prefix_boundary_matches` matches the last OLD line (`last_target`) as a prefix of the file line and returns the rest as `suffix`. `match_or_substring_fallback` appends `suffix` to the last OLD and NEW lines so the diff shows whole lines. The blocks are display-only; the file is not written from them.

`_try_find_prefix_boundary_matches` always cuts at `file_line:sub(#last_target + 1)`. The second strategy (`trim_trailing`) and the third (`trim_space`, removes every `%s`) compare normalised text, so the matched part of `file_line` can be shorter or longer than `#last_target`. Measured with `nvim -l` against the current code:

| file line | last OLD line | strategy | `suffix` | rendered OLD line |
|---|---|---|---|---|
| `  return 1 + extra` | `return 1` | 3 | ` 1 + extra` | `return 1 1 + extra` |
| `x  = 1;` | `x =` | 3 | `= 1;` | `x == 1;` |
| `line two = full content;` | `line two␣␣` | 2 | ` full content;` | `line two   full content;` (drops `=`) |

NEW gets the same wrong suffix. In the third row, trailing whitespace on the last OLD line makes `#last_target` overshoot the match.

Root cause: `starts_with` answers only yes or no, and the caller guesses the cut. Only the strategy knows where its match ends, so it returns that position.

For strategy 2, `T = trim_trailing(target)` ends in a non-space byte (or is empty), so "trimmed file starts with T" is equivalent to "file starts with T". The match ends at `#T + 1`. For strategy 3, walk the file line: skip `%s` bytes (the class `trim_space` removes) and compare the others in order against `trim_space(target)`. The match ends after the file byte that consumes the last target byte. Whitespace bytes never occur inside a UTF-8 multibyte sequence, so a byte walk is safe.

Both normalising strategies ignore the target's trailing whitespace, but the rendered line still shows it. A cut at the end of the non-space match therefore duplicates that whitespace. Example: file `{"a  ", "    foo"}`, OLD `{"a", "␣␣"}` (head needs strategy 2). Today it renders `    foo`, correct by chance (`#last_target` happens to equal the file's leading whitespace). A cut at the bare match end (byte 1) renders `      foo`. So after the match end, both strategies also consume up to `n` file `%s` bytes, where `n` is the count of the target's trailing whitespace bytes. That makes the target's trailing whitespace stand in for the same amount of file whitespace. The exact strategy matches that whitespace literally and does not need this.

Prototyped with `nvim -l` (rendered = last OLD line `..` new suffix):

| file line | last OLD line | strategy | new `suffix` | rendered |
|---|---|---|---|---|
| `  return 1 + extra` | `return 1` | 3 | ` + extra` | `return 1 + extra` |
| `x  = 1;` | `x =` | 3 | ` 1;` | `x = 1;` |
| `line two = full content;` | `line two␣␣` | 2 | `= full content;` | `line two  = full content;` |
| `    foo` | `␣␣` | 2 | `  foo` | `    foo` |
| `a  b` | `a␣` | 2 | ` b` | `a  b` |

## Changes
`lua/agentic/utils/text_matcher.lua`
- New local functions next to `trim_space`, each with a docstring:
  - `stripped_prefix_end(str, prefix): integer|nil`: the byte index in `str` just after the shortest prefix whose `%s`-stripped form equals `prefix` (`prefix` has no whitespace). Nil if there is no such prefix. An empty `prefix` returns `1`. This is the walk above.
  - `skip_space(str, i, n_max): integer`: the index after up to `n_max` consecutive `%s` bytes in `str` from byte `i`.
- Rename each strategy's `starts_with` to `prefix_end`: `fun(file_line: string, target_line: string): integer|nil`. It returns the byte index in `file_line` just after the part that matches `target_line` under the strategy, or nil if the line does not match. The rename is needed because `starts_with` reads as a boolean. Below, `n = #target_line - #trim_trailing(target_line)`.
  - Exact: if `file_line:sub(1, #target_line) == target_line`, return `#target_line + 1`.
  - Trailing-trim: with `T = trim_trailing(target_line)`, if `file_line:sub(1, #T) == T`, return `skip_space(file_line, #T + 1, n)`.
  - All-space: `e = stripped_prefix_end(file_line, trim_space(target_line))`; if non-nil, return `skip_space(file_line, e, n)`.
- Update the `PREFIX_STRATEGIES` doc comment to describe `prefix_end`.
- `_try_find_prefix_boundary_matches`: rename param `starts_with_fn` to `prefix_end_fn` with the new type; `local i_end = prefix_end_fn(file_line, last_target)`; if non-nil, `suffix = file_line:sub(i_end)`. Its only caller is `find_all_prefix_boundary_matches`.
- `PrefixMatch.suffix` field doc: "file line text after the part that the last target line matched".

`lua/agentic/utils/text_matcher.test.lua`, in `describe("find_all_prefix_boundary_matches")`. Write these first and confirm the first three fail:
- Row 1 (indented file line, unindented last OLD line): suffix is ` + extra`. Strategies 1 and 2 reject the last line, so strategy 3 is used.
- Row 2 (extra inner space): suffix is ` 1;`.
- Row 3 (trailing whitespace on the last OLD line): suffix is `= full content;`.
- Whitespace-only last OLD line: file `{"a  ", "    foo"}`, OLD `{"a", "  "}`: suffix is `  foo`. This passes today; it guards the trailing-whitespace skip.

`lua/agentic/ui/tool_call_diff.lua`: no change; it still appends `match.suffix`.

## Expected outcome
For every strategy, `last OLD line .. suffix` equals the file line, apart from whitespace that the strategy ignores (rendered column of the prototype table). The rendered line keeps the target's whitespace where the file differs, for example row 3 shows the target's two spaces where the file has one. The diff does not show non-space text that is in neither version, and does not duplicate the target's trailing whitespace.

## Non-goals
- Rendering the last OLD line from the file line (exact file whitespace). Head OLD lines show as the provider sent them; the last line stays consistent with them.
- A separate suffix for NEW. `match_or_substring_fallback` appends the same suffix to NEW's last line, because a partial OLD last line implies NEW ends at the same file position. The text after it is unchanged by the edit. This behaviour stays.
- Changing strategy order or the full-line `MATCH_STRATEGIES`.
- Prefix ambiguity inherent to partial lines (`return 1` matches `return 10`).

## Open questions
None.

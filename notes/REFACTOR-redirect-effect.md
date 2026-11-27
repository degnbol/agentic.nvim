# Plan: one classifier for what a file redirect does
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/utils/shell_parse.lua` — `redirect_target`,
  `redirect_is_safe`, `redirect_write_dest`, the `M.redirect_is_safe` /
  `M.redirect_write_dest` exports; `redirect_record`, `WRITE_REDIRECT_OPS`,
  `file_effects` (read, not changed)
- `lua/agentic/utils/permission_rules.lua` — `redirect_writes`,
  `redirects_safe`, the tally's redirected-statement branch (`unsafe` list),
  the file-head locals `redirect_is_safe`/`redirect_write_dest`
- `lua/agentic/utils/permission_rules.test.lua` — "should_auto_approve with
  redirect", "bails on file-writing and unmodelled redirects", the
  `evaluate: … redirect` effect cases
- `lua/agentic/utils/shell_parse.test.lua` — new `redirect_effect` describe
- Skills: `permissions` (`references/parsing.md` § Pipeline, step 3
  "Classify"; names no function, no edit expected), `implement`

## Background
`redirect_is_safe(fr, src)` and `redirect_write_dest(fr, src)` take the same
node, call `redirect_target`, and test the same cases (no single target or a
substitution in it, `<`, descriptor duplication, `/dev/null`) with opposite
sense. `redirect_writes` calls the first and then the second on the same
redirect. A redirect has three outcomes: safe, a write to a destination, or
not modelled. One function returns them.

The two differ on `>&`/`<&` to `/dev/null`: `redirect_is_safe` returns on the
descriptor test for those operators before its `/dev/null` test, so it gives
false; `redirect_write_dest` reaches its `/dev/null` test and gives nil. The
redirect is therefore not modelled today, and `echo >& /dev/null` prompts while
`echo &> /dev/null` approves. `<& f` gives the write destination `f`, but it
writes nothing (zsh: "file number expected", bash: "ambiguous redirect").

`file_effects` with `WRITE_REDIRECT_OPS` is not a third copy: it reads the
`Redirect` record (resolved target, `target_fd`, `dynamic`), not the node,
and it counts clobber forms (`>! f`) as writes, which the permission
classifier refuses to pin because the shell is not known. It stays.

## Changes
### `shell_parse.lua`
Replace `redirect_is_safe` and `redirect_write_dest` with:
```lua
--- What a `file_redirect` does: `"safe"` for an input redirect (`<file`), a
--- write to /dev/null by any output operator (`>& /dev/null` included) or a
--- descriptor duplication (`2>&1`, `>&2`); `"write"` with its destination
--- node for an output redirect to anything else (a bare or quoted literal or
--- a variable, for the caller to resolve); nil when it cannot be modelled: no
--- single destination, words after it (`rm a 2>/dev/null b`), a substitution
--- in it (`> $(echo f)`), a clobber form (`>! f`), a closed descriptor
--- (`>&-`), or `<&` to a word that is not a descriptor (zsh: "file number
--- expected").
--- @param fr TSNode
--- @param src string
--- @return "safe"|"write"|nil effect
--- @return TSNode|nil dest nil unless effect is "write"
local function redirect_effect(fr, src)
```
Export `M.redirect_effect`; drop the two old exports.

### `permission_rules.lua` callers
- `redirect_writes`: `local effect, dest = redirect_effect(r, src)`; skip on
  `"safe"`; otherwise the existing resolution of `dest` (nil `dest` sets
  `resolved = false`, as today).
- `redirects_safe`: `redirect_effect(r, src) == "safe"`.
- Tally redirected-statement branch: `redirect_effect(r, src) ~= "safe"`.
- File-head locals: one `redirect_effect`.

No other callers: `rg 'redirect_is_safe|redirect_write_dest'` over the repo
and `~/dotfiles/config/claude` hits only these two files. Comments naming the
old functions are updated: the `redirect_write_dest` docstring (goes with
it), the `redirects_safe` and `walk_substitution_inner` docstrings, and the
tally-walk header comment in `permission_rules.lua`.

### Tests
The permission_rules redirect tests cover safe forms, literal and variable
targets, substitution, words after the target and clobber, and must pass
unchanged. None covers `>& /dev/null`, `<& f` or `>&-`. Add a
`ShellParse.redirect_effect` describe in `shell_parse.test.lua` with one case
per outcome: `< f`, `2>&1`, `> /dev/null` → `"safe"`; `> out`, `>> "$f"`,
`>& file` → `"write"` and the destination text; `> $(echo f)`, `>! f`,
`rm a 2>/dev/null b`, `>&-`, `<& f`, `<& /dev/null` → nil; `>& /dev/null` →
`"safe"`. In `permission_rules.test.lua`, written first: `echo hi >&
/dev/null` approves like `echo hi &> /dev/null`; `cat <& f` under a grant on
`f` prompts with no effect.

## Expected outcome
One function states what a redirect does. Two forms change, each to what the
shell does:
- `>& /dev/null` approves, as `&> /dev/null` does (zsh reads them alike).
- `<& word` (not a descriptor) prompts. Today it is a write effect on `word`
  that a grant can clear, though zsh refuses it and writes nothing.

## Non-goals
- `file_effects` and the `Redirect` record.
- The tally washing a pinnable write as `redirect` where the approve walk
  turns it into a grant-checked effect.

## Open questions
None.

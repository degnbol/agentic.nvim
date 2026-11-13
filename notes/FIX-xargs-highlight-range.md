# Plan: Clip wrapper-inner highlight ranges to the command
Status: reviewed spec

## Relevant files
- `lua/agentic/utils/shell_parse.lua` — `inner_source` (appends ` $__xargs_stdin` for `xargs`)
- `lua/agentic/utils/permission_rules.lua` — `translate_ranges` (one caller), `command_known_safe` (wrapper branch)
- `lua/agentic/utils/permission_rules.test.lua` — `describe("tally_unapproved")` (no `xargs` case yet)
- `lua/agentic/ui/permission_highlight.lua` — `wash`, the `nvim_buf_set_extmark` call that fails
- Skill: `permissions` (`references/parsing.md`)

## Background
An execute prompt for an `xargs` command fails with
`permission_highlight.lua:77: Invalid 'end_col': out of range`.

`inner_source` makes the `xargs` inner command from the `src` text between the
inner node and the end of the command node. Then it appends
` $__xargs_stdin`, a word that stands for the stdin items. That word is not in
`src`. `command_known_safe` maps the inner ranges back to `src` with
`translate_ranges`. A range that covers the whole inner command also covers
the appended word, so its end goes past the line.

Reproduced with `tally_unapproved` at tier `safe_write`:

| Command | Range | Line lengths |
|---|---|---|
| `printf x \| xargs sed -i s/a/b/` | `{0,17,0,45}` | 30 |
| `printf x \| xargs -I{} unzip -p z.zip {}` | `{0,22,0,54}` | 39 |
| `printf x \| xargs \`⏎`  sed -i s/a/b/` | `{1,2,1,30}` | 18, 15 |
| `timeout 5 xargs sed -i s/a/b/` | `{0,16,0,44}` | 29 |

Of 34,860 saved execute commands, 4 gave an out-of-range range. All 4 contain
`xargs`.

The fix belongs in the producer. `tally_unapproved` promises ranges relative
to the command's own lines. A clamp in `PermissionHighlight` would also hide
other producer bugs.

The clip bound is the end of the wrapper `command` node. This is correct
because the tally call to `inner_source` passes no `trailing`, so all real
inner text is inside the node. A single-quoted `-c` body is also inside the
node, so the clip has no effect there. In a nested wrapper
(`xargs timeout 5 …`) the outer clip fixes the range.

## Changes
`lua/agentic/utils/permission_rules.lua`:
- New local `clip_ranges(ranges, limit)`, where `limit` is a `(row, col)`
  position in `src`. Docstring: "Clamp each range's start and end to at most
  `limit`." Positions compare by row first, then by column. It returns new
  ranges and keeps each range's reason.
- `command_known_safe`: call
  `clip_ranges(translate_ranges(body_ranges, origin), { er, ec })`, with
  `er, ec` the end of `node:range()`. Add a one-line comment: the inner can
  extend past the node (the `xargs` stdin word), and the node end is the
  real end because this call passes no `trailing`.

`lua/agentic/utils/permission_rules.test.lua`, in `tally_unapproved`:
- For each command in the table above, every range is inside the command's
  lines: `start <= end`, and each end is at most `(row, #line)` of its row.
- `printf x | xargs sed -i s/a/b/` gives exactly `{0,17,0,30}`.

## Expected outcome
- Execute prompts for `xargs` commands open without an error. The wash on the
  unapproved inner command ends at its last real byte.
- Other wrappers do not change. Their inner text ends at the node end, so
  the clamp has no effect on them.

## Non-goals
- A defensive clamp in `PermissionHighlight.wash`.
- The prompt float that stays open without keys after a setup error.

## Open questions
None.

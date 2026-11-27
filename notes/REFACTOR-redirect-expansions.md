# Plan: the expanded part of each redirect in `RedirectedParts`
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/utils/shell_parse.lua` — `redirected_parts`,
  `agentic.utils.ShellParse.RedirectedParts`, `heredoc_body`,
  `collect_redirected`, `flow_redirected` (inside the cwd flow)
- `lua/agentic/utils/shell_parse.test.lua` — `describe("ShellParse.redirected_parts")`
- Skills: `permissions` (`references/parsing.md`), `implement`

## Background
`collect_redirected` and `flow_redirected` (inside the cwd flow) both loop over `parts.redirects` and take, for each, the node
the shell expands when the statement runs: a heredoc's `heredoc_body`, any
other redirect whole (a heredoc with no body gives nothing). The rest of a
heredoc's line is already split out by `redirected_parts` (`words`,
`redirects`, `rest`), so which part of a heredoc expands is a fact of that
split, and it belongs with it.

## Changes
1. `RedirectedParts` gains a field, filled by `redirected_parts` in source
   order. A heredoc without a body adds nothing, so it is not index-aligned
   with `redirects`:
   ```lua
   --- @field expanded TSNode[] what the shell expands of the redirects when the statement runs, in source order: a heredoc's `heredoc_body` (nothing for a heredoc without one), any other redirect whole
   ```
2. `collect_redirected`: `statement` is `{ parts.body }` extended with
   `parts.expanded`; the loop goes.
3. `flow_redirected`: `flow_substitutions(node, before)` over
   `parts.expanded`; the loop goes.

## Tests (`shell_parse.test.lua`, `ShellParse.redirected_parts`)
- `cat <<EOF > out` (body `x`): `expanded` holds the `heredoc_body` and the
  `file_redirect`, in that order.
- `echo hi 2>&1 > f`: `expanded` equals `redirects`.
No case for a heredoc without a `heredoc_body`: an empty heredoc
(`cat <<EOF\nEOF`) still has one, and an unterminated one does not parse.
The existing cases pass unchanged; so do the `commands`/cwd tests that cover
redirected statements.

## Expected outcome
No change in behaviour. One place states which part of a redirect expands.

## Non-goals
- `permission_rules.lua`'s redirect handling (`redirect_writes`, the tally's
  redirected branch): it reads the heredoc body for its content, not for
  substitutions.

## Open questions
None.

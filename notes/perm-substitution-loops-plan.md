# Treesitter walker — assignment-substitution + loop carve-outs

## Status

Phase 0 (`permissions.json` defence-in-depth) and Phase 1a (zsh treesitter
walker swap) have shipped on `main`. Phase 1b (structured command matcher) is
the precondition for this work and lives on the `phase-1b` branch — see
`notes/perm-treesitter-plan.md`.

This branch (`phase-2-substitution-loops`) carries the walker carve-outs that
let assignment-position command substitution and loops auto-approve. It is
based on `phase-1b` and must be rebased onto `main` after Phase 1b lands.

## Substitution safety — assignment position ONLY

**Allow command substitution as a `variable_assignment` value (or array
element); reject it in command-argument, command-name, for-list, and
redirect-target positions.**

Argument-position substitution **launders dangerous tokens past the deny/ask
layer** — the mechanism that makes broad allow patterns tolerable. A literal
`find . -exec rm {}` matches the `Bash(find * -exec *)` deny pattern and
prompts; `find $(echo '-exec rm')` does not — the matcher sees only `$(...)`,
but at runtime `find` receives `-exec rm` and executes the deletion. The
substitution converts a denied command into an approved one. Not unique to
`find`: any read-only-looking command with a write flag (`sort -o $(echo out)
in`) is a vector. So no allow entry is immune, and arg-position substitution
must continue to bail.

Assignment position is safe: `f=$(X)` puts X's output into a variable; this
statement runs only the assignment plus X as a side effect (the recursion
guards X — `f=$(rm x)` prompts because `rm` is not allowed; `f=$(foo > bar)`
prompts because the inner `file_redirect` fires). The dangerous expansion is
deferred to a later, separately-evaluated use site (`find $f`), which inherits
the **pre-existing** limitation that text-based deny patterns can't see
through any dynamic expansion (variables, globs, `~`) — already tolerated
today. Allowing the assignment doesn't widen that; it only avoids a spurious
prompt on the inert assignment.

Implementation in the walker:

- Whitelist `command_substitution` as a recurse target **only** when its parent
  is a statement-level `variable_assignment` value or an `array` element.
  Recurse `walk` over its inner `command`/`redirected_statement`/`pipeline`/
  `list` — every inner command must be auto-approvable, and a redirect inside
  (`f=$(foo > bar)`) is caught by the same `file_redirect` classification.
- Reached in any other position (arg, command name, command-prefix assignment,
  for-list, redirect target, here-string) → the existing subtree scan still
  bails before recursing here.

## Loop support

`for_statement`, `while_statement`, `until_statement` join the whitelist.

- `for_statement` list items must be literal/glob. Run the subtree-substitution
  scan over the list: a substitution anywhere (`for f in $(ls)`,
  `for f in a $(ls) b`) bails — its output becomes loop values that flow into
  body args (the same arg-position laundering, deferred through the loop var).
  A `glob_pattern` list (`for f in *.txt`) is allowed; the `$f` body expansion
  is opaque, same as any `$var`, so no new hole.
- `do_group` body: recurse `walk` over every command — bounded by allow
  patterns (`rm "$f"` only approves if `rm *` is allowed, which it is not).
- `while`/`until` condition is a `command` (`read l`) → recurse, must be
  auto-approvable.
- `if_statement`/`case_statement` stay rejected — natural follow-up, same
  machinery.

## Tests

- **Positives:** `f=$(echo hi)`, `for f in *.txt; do cat "$f"; done`.
- **Negatives:** `foo=$(rm x) ls`, `arr=($(rm x))`, `f=$(rm x)`,
  `f=$(foo > bar)`, `find $(echo '-exec rm')`, `for f in $(ls); do …`.

## Rebase notes

The walker functions land in `lua/agentic/utils/permission_rules.lua`:

- `walk_substitution_inner` — recurse over `command_substitution` inner
  statements.
- `walk_for`, `walk_while`, `walk_do_group` — loop variants.
- `walk_assignment` is expanded to recognise `command_substitution` /
  `array` value forms before falling back to the simple bail.
- `walk`'s dispatch grows three new branches (`for_statement`,
  `while_statement`, `do_group`).

`walk` calls into Phase 1b's structured matcher through the existing
`walk_command` path. The `WalkCtx` shape (cmd-keyed `structured_entries`
table + `auto_approve`) is inherited from Phase 1b — no extra carve-out
plumbing is needed for the structured matcher to see commands inside a
substitution or loop body.

The test corpus for the existing "bails on substitution anywhere" and
"bails on control flow and compound structure" `describe` blocks is updated
on this branch:

- `f=$(echo hi)` moves out of the substitution-bail list (now a positive
  in the new Phase 2 describe block).
- `for f in *.txt; do cat "$f"; done` and `while read l; do echo "$l"; done`
  move out of the control-flow-bail list (positives in the same block).

When rebasing onto post-Phase-1b `main`, the test-corpus subtractions
conflict with Phase 1b's "bails on substitution anywhere" describe (no
behavioural overlap, just adjacent edits to the same `for _, cmd in
ipairs({...})` blocks). Keep the Phase 2 deletions in both lists; the new
describe block stays as-is.

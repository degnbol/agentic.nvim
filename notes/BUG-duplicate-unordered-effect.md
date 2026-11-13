# Bug: an unordered walk lists a write effect twice
Status: draft

## Relevant files
- `lua/agentic/utils/permission_rules.lua` — `walk_unordered`, the `for`
  unroll (`walk_for`), where `ctx.effects` is appended
- `lua/agentic/ui/permission_manager.lua` — `_shell_verdict` (one `grant`
  cause per effect), `_bash_effects_clear`
- `lua/agentic/utils/permission_rules.test.lua`
- `notes/REFACTOR-one-shell-walk.md` — its item 3 keeps effects across the
  re-run "as `walk_unordered` does"

## Background
`walk_unordered` walks its statements once, and when that walk sets the
taint, walks them again with the taint set. The second walk appends its
effects to the same `ctx.effects`, so every effect of the first walk is
listed again. A write redirect sets the taint, so any unordered statement
with a write has its write twice.

Measured with `PermissionRules.evaluate` and empty rules:

| Command | Effects |
|---|---|
| `echo a > /tmp/f; echo b` | one write `/tmp/f` |
| `echo a > /tmp/f & echo b` | two writes `/tmp/f` |
| `echo a > /tmp/f \| cat` | two writes `/tmp/f` |
| `for i in 1; do echo a > /tmp/f; done` | one write `/tmp/f` |
| `for i in 1 2; do echo a > /tmp/f; done` | two writes `/tmp/f` (one per unrolled iteration) |

An approved verdict from `_shell_verdict` has one `grant` cause per effect,
so the prompt and the decision record list `grant /tmp/f` twice.
`_bash_effects_clear` gives the same answer for a duplicate, so approval
is not affected.

## Direction
Effects are a set: the code that appends to `ctx.effects` skips an effect
equal to one already in the list (same `kind` and `path`). Both readers
treat the list as a set already. Truncating `ctx.effects` before the
re-run (as `tally_unordered` does with leaves) would fix only the re-run,
not the unrolled loop. `REFACTOR-one-shell-walk.md` item 3 then keeps
effects across the re-run without duplicates.

# Plan: one branch for a `$(…)` argument word in `extract_args`
Status: spec
Priority: P3

## Relevant files
- `lua/agentic/utils/permission_rules.lua` — `extract_args`
- `lua/agentic/utils/permission_rules.test.lua` — the `$(…)` argument cases
  in "should_auto_approve (treesitter walker)" and "tally_unapproved"
- Skills: `permissions` (`references/parsing.md` § Pipeline), `implement`

## Background
`extract_args` handles a bare `$(cmd)` argument (its `command_substitution`
branch) and a quoted `"$(cmd)"` (the `string` branch after the `known`
lookup) with the same steps: vet the inner with
`inner_check`, splice the `$(…)` text as one dynamic word, keep the argument
node. The quoted branch's comment says "Like the bare form". The two differ
only in how the `command_substitution` is reached. The quoted branch sits
after the `known` lookup, but `resolved_var_name` gives nil for a string
whose child is a `command_substitution`, so the two tests are disjoint and
the quoted form can be read where the bare one is.

## Changes
1. New local above `extract_args`:
   ```lua
   --- The `command_substitution` an argument word is: the word itself when
   --- bare, its only child when a quoted `"$(…)"`; nil for any other word.
   --- @param node TSNode
   --- @return TSNode|nil
   local function word_substitution(node)
   ```
2. `extract_args`: the `t == "command_substitution"` branch becomes
   `elseif word_substitution(child) then`, vetting and splicing the returned
   node's text with `child` as the argument node. The quoted branch goes.
   The rule (vet, splice dynamic, quoting changes the split but not the
   wildcarding) is stated once, in `extract_args`'s docstring, which already
   holds it; the two inline comments go.

## Tests
Existing cases for `cmd $(…)` and `cmd "$(…)"` (approve and tally) pass
unchanged. Added, written first and passing on today's code, with `ls`
allowed and no rule for `rm`: `tally_unapproved('ls "$(rm x)"', …)` and
`tally_unapproved('ls $(rm x)', …)` each record one `no-allow` range whose
text is `rm x` (the byte columns differ by the quote).

## Expected outcome
No change in behaviour; one branch per argument form.

## Non-goals
- `string_subst_only` (a string mixing text and substitutions): it splices
  the whole string, not the inner.

## Dependencies
None. `REFACTOR-leaf-classification.md` and `REFACTOR-one-shell-walk.md`
call `extract_args` but do not change its branches; either order works.

## Open questions
None.

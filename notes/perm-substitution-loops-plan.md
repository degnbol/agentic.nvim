# Permission walker — deferred work

Loops, assignment-position command substitution, the use-site dynamic-token
gate, the git `-c` leading-option gate, the policy-free absorption matcher, and
`if`/`case` control flow have all shipped on this branch. Their design and
rationale now live in the `permissions` project skill § "Compound Bash
commands". This file holds the one remaining piece: intra-command value-tracing.

## Deferred — intra-command value-tracing

The use-site fix prompts on *any* unresolved dynamic token at a gated command,
including the benign `f=/safe/dir; find $f`. Recovering those requires resolving
the variable's literal value — intra-command constant propagation, or fuller
static expansion. It cannot help the runtime-computed case (`f=$(...); find $f`
stays a prompt — the value is genuinely dynamic), and it carries
quoting/reassignment/scope soundness edges, so it is its own focused work, not
part of the gate fix.

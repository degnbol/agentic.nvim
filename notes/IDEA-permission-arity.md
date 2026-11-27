# Idea: permission rules with arity

Consider making the permission system one step more advanced.
E.g. to be able to indicate arity, if term is first, last, if there's exactly n terms.
Brainstorm ideas for the simplest increase in code complexity and usage in
permissions.json complexity that generalises to the most useful use cases.

Concrete need: a gate field matching a pattern against any argument
(`any_positional: ["*;"]`). tmux chains commands with `;`/`\;` tokens at
any index (`tmux capture-pane -p \; run-shell …` runs the shell command),
so a read-only tmux entry is unsound until `ask` can catch them.

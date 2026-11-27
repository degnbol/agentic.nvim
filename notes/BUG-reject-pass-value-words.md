# Bug: the reject pass rejects on an ambiguous parse
Status: draft

## Relevant files
- `lua/agentic/utils/permission_structured.lua` — `deny_leaf`,
  `build_exist_ctx`, `flag_candidates`, `prefix_walk`, `some_stream_matches`
- `lua/agentic/utils/permission_rules.lua` — `should_auto_reject`
- `lua/agentic/permissions.json` — `awk`, `fd`, `rm` deny gates

## Background
`deny_leaf` rejects with no prompt: the command never runs and the user is
not asked.

The matcher does not know which options take a value. So each option may
take the next word as its value, or take nothing. A **parse** is one choice
for every option. `awk -F, '{print $1}' systems.csv` has two parses:
- `-F,` takes nothing: the program is `{print $1}`, the input is
  `systems.csv`;
- `-F,` takes `{print $1}`: the program is `systems.csv`.

`deny_leaf` rejects when a deny gate matches in **any** parse; here the
second, through awk's `*system*` gate. A match in only some parses is
ambiguous, and ambiguity should prompt, not reject. Measured with the
bundled defaults (`should_auto_reject` true):

| Command | Deny gate hit | Parse that matches |
|---|---|---|
| `awk -F, '{print $1}' systems.csv` | `*system*` | `-F,` takes the program: `systems.csv` is the program |
| `awk -v kind=system '{print kind}' log.txt` | `*system*` | `-v` takes nothing: `kind=system` is the program |
| `awk -f stats.awk /var/log/system.log` | `*system*` | `-f` takes `stats.awk`: `system.log` is the first positional, read as the program |
| `fd -tx` | `x` (exec) | `-t` takes nothing: `x` is a flag (really `-t`'s value: list executables) |

The approve walk reads the same match as "deny" and withholds approval, so
each of these prompts once the reject pass stops firing.

## Changes
The reject pass rejects only if the deny gate matches in every parse. A word
that may be an option's value (directly after an option, or a letter after
the first in a cluster) counts as a flag or a positional only in the parses
where it is not a value.
- The commands above prompt.
- `find . -exec rm {} \;`, `date -s 12:00`, `fd -e rs -x wc` still reject
  (measured today; each deny flag has no option before it, so it is a flag
  in every parse).
- A deny letter after the first in a cluster no longer rejects without arity
  data: `rm -rf x` would prompt, since `-r` might take `f` as its value.
  Boolean `arity` hints restore the reject for hinted letters.
- Code: the allow path's ∀ readers (`build_forall_ctx`,
  `every_stream_matches` in `permission_structured.lua`) serve the reject
  pass too.

## Expected outcome
A deny gate rejects only when every parse matches; an ambiguous match
prompts.

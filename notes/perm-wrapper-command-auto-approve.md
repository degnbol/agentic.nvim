# Auto-approving read-only commands behind a wrapper prefix

> **Sequencing.** Depends on the treesitter migration in
> `notes/perm-treesitter-plan.md` landing first. The mechanism below is a small
> structural rule inside that walker's `command` handler — not implementable
> cleanly against the current regex tokeniser, which is why it is deferred.
> Grounded in a zsh-grammar probe (2026-06-06).

## Goal

Make `timeout 5 grep foo`, `time grep foo`, and `stdbuf -oL grep foo`
auto-approve whenever the *wrapped* command (`grep foo`) would auto-approve on
its own. An exec-wrapper prefix governs only *how long*, *timed*, or *with what
buffering* the inner command runs — it does not change the inner command's
effect. So the safety decision should reduce to the wrapped command's safety.

Today none of these prefixes are in `permissions.json`, so a wrapped read-only
command falls through to a prompt. This is a missed approval (prompt fatigue),
not a safety hole — the same class `stdbuf` stripping already fixed in
`strip_wrapper_prefixes`. This plan generalises that single regex into one
structural rule covering the wrapper set.

## What counts as a wrapper (the initial set)

Only effect-neutral prefixes whose sole job is to launch the following command:

| Wrapper | Operand grammar before the wrapped command | Notes |
| --- | --- | --- |
| `timeout` | `[OPTION]... DURATION` | `-s/--signal`, `-k/--kill-after` take a value; `--preserve-status`, `--foreground`, `-v/--verbose` do not. DURATION is mandatory. |
| `time` | `[-p]` only | Shell reserved word; the bin form `/usr/bin/time` strips to `time` via `strip_command_path`. **`-o`/`--output`/`-a`/`-f` write a file — refuse them (see soundness §4).** |
| `stdbuf` | `(-i/-o/-e MODE \| --input/--output/--error=MODE)...` | Generalises today's `stdbuf -o<flag>` strip. All options take a buffering mode; none write. |

**Deliberately excluded**, each with the reason it is *not* effect-neutral:

- `nohup` — writes `./nohup.out` (or `$HOME/nohup.out`) when stdout is a tty. A
  side-effect file write with no `file_redirect` node to catch it.
- `env` — `env VAR=val cmd` can set an execution-hijacking var (`PATH`,
  `LD_PRELOAD`). Unwrapping it soundly means applying the `is_safe_env_name`
  hijacker check to env's assignment args first. Worthwhile follow-up, but it
  also intersects a pre-existing unsound `Bash(env *)` allow entry (see Out of
  scope). Defer.
- `command`, `builtin`, `exec` — not effect-neutral launchers; their
  allow-pattern semantics differ from the bare command. `exec` replaces the shell
  process (and bare `exec > out` mutates the current shell's fds), `command -p`
  resets `PATH`, `builtin` bypasses functions and aliases. They are plain
  `command` nodes whose name matches no allow pattern, so they already prompt by
  default — no unwrap, no guard. (The migration plan records the same decision in
  its § Explicitly rejected.)
- `xargs`, `parallel`, `setsid`, `chrt`, `taskset` — run a command per input or
  alter scheduling; either the input can inject arguments or the surface is
  larger than this change wants. Defer.

## Grammar grounding (zsh parser, verified by probe)

The grammar treats `time`/`timeout`/`stdbuf` as **plain `command` nodes** — the
wrapped command is *not* a nested `command`, it is flat argument tokens:

| Input | Tree (abbreviated) |
| --- | --- |
| `timeout 5 grep foo bar` | `command(command_name(word 'timeout'), number '5', word 'grep', word 'foo', word 'bar')` |
| `timeout -s KILL -k 1 5 grep foo` | `command(word 'timeout', '-s', 'KILL', '-k', number '1', number '5', 'grep', 'foo')` |
| `time grep foo` | `command(command_name(word 'time'), word 'grep', word 'foo')` |
| `time -p grep foo` | `command(word 'time', '-p', 'grep', 'foo')` |
| `/usr/bin/time -v grep foo` | `command(command_name(word '/usr/bin/time'), '-v', 'grep', 'foo')` |
| `timeout 5 $(echo rm) -rf /` | `command(word 'timeout', number '5', command_substitution(…), '-rf', '/')` |

Two consequences:

1. **No nested command node.** Reconstruct the wrapped leaf from the wrapper
   node's trailing children — do **not** rely on a child `command`.
2. **Substitutions sit inside the wrapper node.** `timeout 5 $(echo rm) -rf /`
   carries `command_substitution` as a child of the `timeout` node, so the
   rework's existing per-command subtree-substitution scan already bails on it
   *before* unwrap runs. The laundering vector is closed for free.

## Design — an unwrap step in the `command` handler

Inside the walker's `command` arm, after the literal-command-name check and the
subtree-substitution scan have run (both unchanged), but before the final
leaf-text pattern match:

1. **Detect a wrapper.** The command-name child is a literal `word` whose value,
   after `strip_command_path`, is in the wrapper set. If not → fall through to
   the normal leaf match unchanged.
2. **Skip the wrapper's own operands** using its grammar (table above). Walk the
   argument children left to right:
   - Consume recognised option tokens. For a value-taking option without `=`,
     consume the following token as its value. **Bail (→ prompt) on any
     unrecognised option** — strictness here guarantees we never skip the wrong
     tokens (see §1).
   - For `timeout`, then consume exactly one DURATION token. It must match a
     duration shape (`^[0-9]*%.?[0-9]+[smhd]?$`); otherwise we misparsed → bail.
3. **Identify the wrapped command.** The next child begins it. It must be a
   literal `word`/`string`/`raw_string` (reuse the command-name literal check) —
   else bail. If there is no remaining child, bail (empty wrapped command).
4. **Match the wrapped leaf.** Reconstruct the wrapped command's text by
   space-joining the node text of the remaining children, then feed it through
   the **same leaf function** the walker uses for an ordinary command —
   `strip_command_path` → `matches_any_pattern` against `allow`/`deny`/`ask`.
   The wrapper node's redirects (siblings at `redirected_statement` level) are
   classified by the existing redirect logic regardless of the wrapper.

No re-parse. Top-level operators (`&&`, `|`, `;`) cannot appear as flat children
of the wrapper node — the grammar splits them into sibling nodes
(`timeout 5 grep foo && rm x` → `list(command(timeout…), &&, command(rm x))`),
so the trailing children are guaranteed operator-free and reconstruct
unambiguously. This also sidesteps the leaf-text fidelity concern (re-parse
quoting/whitespace) that a re-parse approach would raise.

## Soundness

1. **A misparse fails safe.** Feeding the matcher the wrong slice yields a
   non-match → prompt. The only unsafe direction would be skipping enough
   tokens that a *dangerous* wrapped command reconstructs as a *different,
   allowed* read-only one — which the "bail on unrecognised option / bad
   duration shape" strictness in step 2 prevents. Incompleteness costs a prompt;
   it never approves.
2. **Deny/ask carve-outs survive the wrapper.** Because step 4 reuses the full
   leaf function, `timeout 5 sed -i 's/x/y/' f` reconstructs to `sed -i …`,
   matches the `Bash(sed -i*)` deny pattern, and prompts. An allow-only check
   here would be the bug — the wrapper must not launder a command past deny/ask.
3. **Substitution laundering is already closed.** `timeout 5 grep $(cat list)`
   bails on the subtree-substitution scan (the substitution is a child of the
   wrapper node) — consistent with the migration rejecting arg-position
   substitution for a bare `grep $(cat list)`.
4. **`time` write-option carve-out.** `/usr/bin/time -o FILE cmd` writes a file.
   The bin path strips to `time`, so without a guard it would be unwrapped as a
   neutral prefix. The `time` grammar therefore accepts only `-p` and bails on
   any other option — refusing `-o`/`--output`/`-a`/`-f`. (As a bare shell
   reserved word, `time -o …` is not the write form anyway, but the bin form
   makes the guard load-bearing.)
5. **Redirects are unaffected.** `timeout 5 grep foo > out` parses as
   `redirected_statement(command(timeout…), file_redirect(> out))`; the
   non-`/dev/null` target bails at the existing redirect classifier, above the
   wrapper.
6. **Nested wrappers are not supported — they prompt.** `timeout 5 nice grep
   foo` reconstructs the wrapped leaf as `nice grep foo`; `nice` is not in
   `allow`, so it prompts. Deliberate: no recursion into a second wrapper. Add
   later if it proves common, with a depth cap.

## Composition with the migration

After `notes/perm-treesitter-plan.md` lands, the walker's `command` arm already
runs the literal-command-name check and the subtree-substitution scan, and
`strip_command_path` plus the compiled-pattern matcher are kept verbatim. The
unwrap step is new logic in that arm: detect a wrapper, skip its operands,
reconstruct the wrapped leaf, and feed it through the same matcher. The migration
keeps the `stdbuf` branch in `strip_wrapper_prefixes` (only its env-prefix logic
is deleted); folding `stdbuf` into the wrapper table here makes that branch
redundant — remove it so there is one wrapper list, not two.

## Testing

Add to `permission_rules.test.lua`, asserting on `should_auto_approve`
end-to-end (grep/cat assumed in `allow`, rm/sed-i in deny):

- **Approve:** `timeout 5 grep foo`, `timeout -s KILL -k 1 5 grep foo`,
  `time grep foo`, `time -p grep foo`, `/usr/bin/time grep foo`,
  `stdbuf -oL grep foo`, `stdbuf -i0 -o0 grep foo`.
- **Prompt (wrapped command not allowed):** `timeout 5 rm -rf /`,
  `time rm x`, `timeout 5 nice grep foo` (nested wrapper).
- **Prompt (deny carve-out survives wrapper):** `timeout 5 sed -i 's/x/y/' f`.
- **Prompt (write-option / write-target):** `/usr/bin/time -o out grep foo`,
  `timeout 5 grep foo > out`.
- **Prompt (laundering / dynamic):** `timeout 5 grep $(cat list)`,
  `timeout 5 $(echo rm) -rf /`.
- **Prompt (misparse / malformed):** `timeout grep foo` (no duration),
  `timeout 5` (empty wrapped command), `timeout --unknown-opt 5 grep foo`.

Run `make validate` after each slice.

## Out of scope

- **`env` / the unsound `Bash(env *)` allow entry.** `env *` in `read_only`
  (`permissions.json:162-163`) auto-approves arbitrary commands behind `env`
  (`env PATH=/tmp/evil sh -c …`). A real layer-2 soundness gap, adjacent to this
  work but separate — flag for the user, do not fix here.
- Layer-2 bucket contents and any new verb sets.
- Supporting `nohup`, `command`, `exec`, `xargs`, and nested wrappers.

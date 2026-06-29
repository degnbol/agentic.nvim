# Walk into script files

> **Relationship.** This supersedes #2 ("walk into script *files*") in
> [perm-extend-auto-approve.md](perm-extend-auto-approve.md), which parked the idea
> on a bail-rate estimate that predates #5/#6 — it counted `source` as a wall when
> it is in fact a recursion point (see Bail surface). Two kinds of new value over
> that note: **content-based approval of named on-disk scripts** (sound, and not
> equivalent to a `Bash(...)` name allow), and the **in-block create-then-run**
> correlation (`cat > f.sh <<'EOF' … EOF; zsh f.sh`), which an allow rule cannot
> express because the file is generated and ephemeral. Builds on the shipped effects
> extractor (`M.evaluate` → `(ok, effects)`) and the inline `-c` body recursion
> (#5). Grounded in the walker as of 2026-06-29.

## The invariant (unchanged)

Over-match may only ever *over-prompt*, never *under-prompt*. Reading the wrong
bytes for a script is the one new way to under-prompt, so the whole design turns
on never judging content that differs from what the shell will run.

## Two execution forms to resolve

Both currently prompt:

- **`zsh ./file.sh`** (also `bash`/`sh`/`dash` with no `-c`) — `zsh` is in
  `SHELL_C_COMMANDS` only for the `-c` branch; a bare file argument falls through
  the structured `ask` (only the `c`/`i`/`s`/`f` *options* gate it) to the allow
  check, finds no rule, prompts.
- **`source ./file.sh`** / **`. ./file.sh`** — `source` and `.` are
  `CODE_TAKING_BUILTINS`, so `walk_command` bails unconditionally
  (`permission_rules.lua:1083`). The body runs in the current shell, but the
  safety analysis is identical to `zsh file.sh`: the file's commands run either
  way.

Resolve a literal script path for either form, read the bytes, `parse_zsh`, and
`walk` recursively at `ctx.depth + 1` — the same "extract a body, re-parse,
recurse" shape as the `-c` branch (`walk_command:1116-1132`), differing only in
where the body comes from (a file vs an arg token).

## The content question — which bytes does the shell run?

The Bash command has **not run** at permission-check time (the SDK applies
nothing before `request_permission`). So for a script *generated earlier in the
same command*, disk holds stale-or-absent content; reading it would judge bytes
the shell never executes. Source of truth, in order:

1. **Path written earlier in this command** → use the **reconstructed written
   content**, never disk. If it can't be reconstructed → bail.
2. **Otherwise** → read disk. ACP runs tool calls sequentially, but the read
   happens at approval-decision time and the shell `open()`s after the callback
   returns, so a `run_in_background` execute block or the user's editor could
   mutate the file in that window. Close it the way `/trust` already does (safety
   property #4): capture mtime+size at read time, re-stat just before approving,
   bail on any change. The `-c` body had no file, so this TOCTOU vector is new to
   the on-disk path.

### The taint interlock (the safety core)

Thread an ordered `written` map in `ctx` (sibling of `ctx.effects`), populated
where a write effect is emitted (`walk_redirected`, after `redirect_write_dest`
gives the destination node and `walk_redirected` resolves it to a literal path):

- first write to a path → `written[path] = <reconstructed content>` or
  `TAINTED`;
- any **second** write to the same path → `TAINTED` (the "bail if multiple
  writes" the task names).

At an executing leaf (`zsh file.sh`, `source file.sh`), resolve the script path
(literal, or #3-resolved `$var`) and consult `written[path]`:

| `written[path]` | action |
|---|---|
| absent | read disk + walk |
| reconstructed content | walk that content (no disk read) |
| `TAINTED` | **bail** (prompt) |

Ordering falls out of the left-to-right `walk_sequence` for free:
`echo x > f.sh; zsh f.sh` populates `written[f.sh]` on the first sibling before
the second sibling reads it; `zsh f.sh; echo x > f.sh` (write *after* execute)
leaves `written` empty at execute time → reads the real on-disk bytes the shell
runs. Threading `written` through nested sequences over-taints (shared table
reference, like `effects`) — over-prompt, safe.

### Content reconstruction scope (deliberately small)

A redirect's content is the producer command's **stdout**, not a literal. Pin it
only for the forms whose stdout is statically known from literal operands.

- **heredoc** (`cat > f.sh <<'EOF' … EOF`) — the **primary** case: an agent writing
  a multi-line script inline uses a heredoc, not `echo`. The body is a verbatim
  `heredoc_body` text leaf, so there is no escape/space-join semantics to model —
  cleaner than echo. Three structural gates:
  - **`heredoc_body:named_child_count() == 0`** — the body is pure text. A quoted
    delimiter (`<<'EOF'`) always parses this way; an unquoted `<<EOF` with a
    `$var`/`$(…)` carries the expansion as a *named child* (and that substitution
    runs at **write** time), so this single check rejects every expanding body.
    Free from the grammar.
  - **bare `cat`** (no operands) — only a verbatim stdin→stdout pass-through makes
    the body equal the file. `grep x > f <<'EOF'` has the identical tree but writes
    grep's *filtered* output → `TAINTED`.
  - **`>` truncate, single `file_redirect`** — target pinned by
    `redirect_write_dest` on the sibling `file_redirect`; `>>` or multiple
    redirects → `TAINTED` (see `>>` append below). `walk_redirected` must now
    correlate the `heredoc_redirect` body with that sibling target — today it bails
    on any non-`file_redirect` child.
- **`echo <literals> > f.sh`** — a later add-on, not the first cut: it only ever
  produces a *one-line* script, which overlaps with `zsh -c` (#5). content =
  operands joined by space + `\n`, gated on **no flag** (`-n`/`-e`/`-E`) **and no
  backslash in any operand** → else `TAINTED`. The backslash gate is load-bearing:
  zsh/sh/dash `echo` expand `\t`/`\n` while bash does not, so a backslash operand's
  written bytes are shell-dependent and must not be reconstructed.

Everything else — `printf` (format strings), `cat template > f.sh` (stdout is
another file's bytes), any pipeline, a dynamic producer — is `TAINTED`. This is
the task's "simple case of a single write" / "bail on multiple writes" split.

### `>>` append

In scope only as a **taint** signal, never a reconstruction source: an append
yields *base content + appended bytes*, and the base (prior disk content, or a
prior in-block write) is not reliably ours. So any `>>` to a path → `TAINTED`
for that path. A truncating `>` that fully defines the file is the only
reconstructable origin.

## Soundness

- The recursion only changes *which leaves are walked* (the script body's), never
  *whether a leaf is checked* — every body leaf still hits the same deny/ask
  gates and emits its own effects into the shared `ctx.effects` (so a script
  writing to `/tmp` composes with `/trust tmp` for free via `_bash_effects_clear`,
  and a script writing elsewhere bails).
- Same parser, same fail-closed-on-error (`parse_zsh` returns nil → bail), same
  `NESTED_MAX_DEPTH` cap (a script sourcing a script is depth+1) and 64 KB length
  cap as the `-c` path.
- A dynamic script path (`zsh $f` with `$f` unresolved) stays dynamic → bail.
- The only new under-prompt vector is judging wrong bytes; the taint interlock
  closes it (in-block writes never read disk; unreconstructable writes bail), the
  TOCTOU re-stat closes the read-then-exec window, and the `source`/`.` `.zwc` gate
  closes the compiled-form swap.
- The reject pass (`should_auto_reject`/`command_is_denied`) is **not** extended
  into files — only the approve and tally walks recurse. A script body holding a
  concrete deny (`rm -rf /`) therefore *prompts* rather than auto-rejecting (the
  approve walk hits the deny gate, fails to approve, falls through). Pure
  over-prompt; extending reject would duplicate the read+taint machinery on a walk
  that runs before `ctx.written` exists.

## Reading the file safely

`vim.uv.fs_stat` first: regular file only (a fifo/`/dev/*` would hang or mislead),
size under the existing 64 KB cap, then `vim.uv.fs_read`. Resolve relative paths
against cwd. Not a regular file, oversize, or unreadable → bail. Re-stat before
approving (TOCTOU, above).

**`source`/`.` resolution gates** (not needed for `zsh file.sh`):

- **Slash required.** A no-slash `source foo` searches `$path` (verified: zsh runs
  a `$path` hit even when cwd has no `foo`), and `PATH_DIRS` / the live `$path` are
  not knowable from the token. Bail unless the arg contains `/`.
- **No sibling `.zwc`.** With a newer `<path>.zwc` (zsh's compiled bytecode form)
  present, `source` runs the bytecode, not the `.sh` text we read — verified to
  execute a body differing from the file, even on a slash path. Bail if
  `<resolved>.zwc` exists (over-prompt-safe; precise mtime-compare buys nothing).
  `zsh file.sh` ignores `.zwc` (runs the text), so this gate is source/.-only.

## Bail surface (smaller than the parked #2 assumed)

The parked #2 listed `source other.sh` as a first-line bailer. It is not — Step A
**resolves and recurses into it** (depth+1, same machinery), so a script that
sources helpers is walked transitively. Combined with the already-shipped
function-call resolution (#6) and `-c` body walk (#5), a real script now clears as
far as its leaves do. What still bails: a non-allowlisted harness command
(`make`, `pytest`, `nvim --headless`) and a write redirect outside a trust scope —
both **user-extendable** (a structured allow rule, or `/trust tmp` for tmp
writes), not walls.

This is not equivalent to a one-line `Bash(zsh run-tests.sh)` allow. That blanket
rule approves the script *by name*, regardless of what it contains or later
becomes; the walk approves by **content**, so it stays sound if the script is
edited to do something the rule never anticipated. Content-based approval of a
named on-disk script is the value the allow rule can't give. The in-block
create-then-run case (`cat > f.sh <<'EOF' … EOF; zsh f.sh`) is value of a second
kind: a generated ephemeral script has no stable name to allowlist at all.

## Out of scope

- **Highlighting which *part* of a script caused the prompt.** The tally walk
  (`tally_unapproved`) maps ranges back to displayed command bytes via origins
  (`inner_source` returns an `Origin`); a file body has no representation in the
  chat buffer, so there is nothing to anchor ranges to. The script-file recursion
  runs in the decision walk only; on the tally side the leaf stays whole-leaf
  highlighted. No origin plumbing for file bodies.
- `echo`/`printf` reconstruction (follow-ons above; heredoc is the first cut).
- Recursing a `cat other > f.sh` producer into another file read.

## Build order

- **Step A — on-disk walk.** `script_file_source(cmd_name, node, args, …)` in
  `shell_parse.lua` returning the literal path for `zsh|bash|sh|dash <file>`
  (no `-c`) and `source|. <file>`; a branch in `walk_command` (mirrored in
  `command_known_safe`) that reads + `parse_zsh` + recurses, behind the
  `fs_stat`/size guards and the re-stat. Lift `source`/`.` out of the unconditional
  `CODE_TAKING_BUILTINS` bail *only* when a literal file arg resolves (`eval`
  stays bailing); `script_file_source` enforces the source/. gates (slash required,
  no sibling `.zwc`). The `collect_command` copy of the bail (`extract_commands`)
  is left as-is — it has no live caller. Non-destructive; no new state, no config.
- **Step B — taint + heredoc reconstruction.** `ctx.written` map; populate it in
  `walk_redirected` (which must now handle the `heredoc_redirect` child and
  correlate it with the sibling `file_redirect` target); consult it at the execute
  leaf; the heredoc reconstructor (echo a later add-on). This is what flips the
  `cat > f.sh <<'EOF' … EOF; zsh f.sh` example.

## Touches

`shell_parse.lua` (`script_file_source`; echo-literal content reconstructor);
`permission_rules.lua` (`walk_command` execute-leaf branch + `command_known_safe`
mirror; `ctx.written` threaded like `ctx.effects`; `walk_redirected` populates it;
`source`/`.` conditional un-bail); tests in `permission_rules.test.lua`.

## Decided

1. **Config gate — no flag.** The `-c` walk and the effects extractor shipped
   flagless; the file read is bounded (`fs_stat` regular-file + 64 KB) and
   read-only. Add `Config.permissions.walk_script_files` only if file reads on the
   permission path later prove unwanted.
2. **Resolve `source`'d files transitively — yes, no special-case.** A script that
   `source`s a sibling recurses (depth+1) on the same `script_file_source`
   machinery, bounded by the shared `NESTED_MAX_DEPTH = 3`. It composes for free;
   suppressing it would be more code for less behaviour.

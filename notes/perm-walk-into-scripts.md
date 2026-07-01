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
2. **Otherwise** → read disk. The window between read and the shell's `open()`
   is **not** closed by a re-stat (the plan originally proposed copying `/trust`
   safety property #4). `/trust`'s re-stat earns its keep because that flow has an
   *async* gap — the user can sit in a diff-preview tabpage between the safety
   check and the callback. The auto-approve path here is synchronous: `evaluate`
   reads, then `callback` fires with no await between, so the bytes read are the
   bytes judged. A re-stat would run microseconds after the read and could not
   touch the only residual window — the post-callback IPC to the shell's `open()`,
   which no client-side check can close. So no re-stat; `read_script` documents
   this at the read site.

### The taint interlock (the safety core)

This is the one new under-prompt vector and ships **with Step A**, not after it:
`echo evil > f.sh; zsh f.sh` (under a tmp `/trust` scope clearing the producer
write — and `echo`/`cat`/`printf` are bundled `read_only`, so this is reachable
out of the box) would otherwise walk disk's *stale* bytes, approve them, and run
the freshly-written `evil`. Step A without this bail is strictly worse than the
status quo, which prompted.

**Step A (bail only).** At an executing leaf (`zsh file.sh`, `source file.sh`),
resolve the script path (literal, or #3-resolved `$var`) and scan the already-
accumulated `ctx.effects` for a `write` to the same resolved path (compared via
the shared `resolve_against_cwd`, so the redirect target and the script path
normalise identically). A prior write → **bail** (prompt); otherwise read disk +
walk. No new `ctx` field — the ordered, shared `ctx.effects` already carries it.

Ordering falls out of the left-to-right `walk_sequence` for free:
`echo x > f.sh; zsh f.sh` has the write in `ctx.effects` before the second
sibling's read; `zsh f.sh; echo x > f.sh` (write *after* execute) has empty
effects at execute time → reads the real on-disk bytes the shell runs. The shared
`ctx.effects` reference over-taints through nested sequences — over-prompt, safe.

**Step B (reconstruction, shipped).** To turn the bail into an approval, the
execute leaf needs the *written content* to walk, which `ctx.effects` does not
carry (effects have a path, no bytes). Step B threads a `ctx.written` map
(cwd-resolved path → reconstructed content or `false` for taint), populated in
`walk_redirected` alongside the write effect: first write → content-or-taint, any
second write → taint. The leaf then consults `written[path]` (reconstructed →
walk it, no disk read; `false` → bail; absent → read disk), superseding Step A's
effects scan.

### Content reconstruction scope (deliberately small)

A redirect's content is the producer command's **stdout**, not a literal. Pin it
only for the forms whose stdout is statically known from literal operands.

- **heredoc** (`cat > f.sh <<'EOF' … EOF`) — the **primary** case: an agent writing
  a multi-line script inline uses a heredoc, not `echo`. The body is a verbatim
  `heredoc_body` text leaf, so there is no escape/space-join semantics to model —
  cleaner than echo. Three structural gates:
  - **`heredoc_body:named_child_count() == 0`** — the body is pure text
    (`heredoc_pure_body`). A quoted delimiter (`<<'EOF'`) always parses this way;
    an unquoted `<<EOF` with a `$var`/`$(…)` carries the expansion as a *named
    child* (and that substitution runs at **write** time), so this single check
    rejects every expanding body — and `walk_redirected` bails there, since the
    expansion runs regardless of any write. Free from the grammar.
  - **bare `cat`** (no operands, `is_bare_cat`) — only a verbatim stdin→stdout
    pass-through makes the body equal the file. `grep x > f <<'EOF'` has the
    identical tree but writes grep's *filtered* output → taint.
  - **`>` truncate, single `file_redirect`** (`redirect_is_truncate`) — target
    pinned by `redirect_write_dest` on the sibling `file_redirect`; `>>` or
    multiple redirects → taint (see `>>` append below). `walk_redirected` gathers
    the body command, all `file_redirect` targets, and the heredoc in one pass,
    then correlates them after the loop.
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
  closes it (a path written earlier in the command bails — Step B walks the
  reconstructed bytes instead), and the `source`/`.` `.zwc` gate closes the
  compiled-form swap. The read→approve path is synchronous, so there is no
  read-then-exec window a client-side re-stat could close (see content question
  point 2).
- The reject pass (`should_auto_reject`/`command_is_denied`) is **not** extended
  into files — only the approve and tally walks recurse. A script body holding a
  concrete deny (`rm -rf /`) therefore *prompts* rather than auto-rejecting (the
  approve walk hits the deny gate, fails to approve, falls through). Pure
  over-prompt; extending reject would duplicate the read+taint machinery on a walk
  that runs before any taint state (`ctx.effects` in Step A, `ctx.written` in
  Step B) is accumulated.

## Reading the file safely

`vim.uv.fs_stat` first: regular file only (a fifo/`/dev/*` would hang or mislead),
size under the existing 64 KB cap, then `vim.uv.fs_read` (`read_script`). Resolve
relative paths against cwd. Not a regular file, oversize, or unreadable → bail.
No re-stat (content question point 2).

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
- `echo`/`printf` reconstruction (follow-ons above; heredoc shipped, these deferred).
- Recursing a `cat other > f.sh` producer into another file read.

## Build order

- **Step A — on-disk walk + taint bail (shipped).**
  `script_file_source(cmd_name, args, args_dynamic)` in `shell_parse.lua` returns
  the cwd-resolved path for `zsh|bash|sh|dash <file>` (no `-c`) and
  `source|. <file>` (with the source/. gates: slash required, no sibling `.zwc`);
  `read_script` does the `fs_stat`/size-guarded read. A branch in `walk_command`
  (mirrored in `command_known_safe`) lifts `source`/`.` out of the
  `CODE_TAKING_BUILTINS` bail *only* when the file resolves (`eval` stays
  bailing), consults the taint state for the resolved path, then reads +
  `parse_zsh` + recurses. `resolve_against_cwd` is shared so the redirect target
  and script path normalise identically. The `collect_command` copy of the bail
  (`extract_commands`) is left as-is — it has no live caller. (Step A originally
  scanned `ctx.effects` for the taint bail; Step B superseded that with the
  `ctx.written` consult below.)
- **Step B — heredoc reconstruction (shipped).** `ctx.written` (cwd-resolved path
  → content or `false`) replaces Step A's effects scan, threaded like
  `ctx.effects` and populated in `walk_redirected`, which now gathers the body,
  every `file_redirect`, and the `heredoc_redirect` in one pass and correlates
  them after the loop. The `walk_command` execute leaf consults `written[path]`
  (string → walk it; `false` → bail; nil → read disk). This flips the
  `cat > f.sh <<'EOF' … EOF; zsh f.sh` example from a prompt to an approval; a
  non-pure-text heredoc bails in `walk_redirected` (the expansion runs at write
  time). `echo`/`printf` reconstruction stays deferred (out of scope above).

## Touches

Step A (shipped): `shell_parse.lua` (`script_file_source`, `resolve_against_cwd`);
`permission_rules.lua` (`read_script`; `walk_command` execute-leaf branch +
`command_known_safe` mirror; `source`/`.` conditional un-bail); tests in
`permission_rules.test.lua`.
Step B (shipped): `shell_parse.lua` (`redirect_is_truncate`, `heredoc_pure_body`,
`is_bare_cat`); `permission_rules.lua` (`ctx.written` map threaded like
`ctx.effects`; `walk_redirected` rewritten to gather + correlate body/redirects/
heredoc and populate `ctx.written`; `walk_command` execute leaf consults it;
`walk_function_definition` isolates a fresh `written`); tests in
`permission_rules.test.lua`.

## Decided

1. **Config gate — no flag.** The `-c` walk and the effects extractor shipped
   flagless; the file read is bounded (`fs_stat` regular-file + 64 KB) and
   read-only. Add `Config.permissions.walk_script_files` only if file reads on the
   permission path later prove unwanted.
2. **Resolve `source`'d files transitively — yes, no special-case.** A script that
   `source`s a sibling recurses (depth+1) on the same `script_file_source`
   machinery, bounded by the shared `NESTED_MAX_DEPTH = 3`. It composes for free;
   suppressing it would be more code for less behaviour.

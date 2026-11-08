# Plan: model the rest of a heredoc's line
Status: reviewed spec

## Relevant files
- `lua/agentic/utils/shell_parse.lua` — `heredoc_ends_line` (replaced),
  `redirect_target`, `redirect_is_safe`, `redirect_write_dest`,
  `redirect_record`, `heredoc_text`, `node_io`, `collect` (the
  `file_redirect`/`heredoc_redirect` child filters, pipeline `upstream`,
  `runs_in_child_shell`)
- `lua/agentic/utils/permission_rules.lua` — `walk_redirected`,
  `tally_redirected`, `redirect_writes`, `record_writes`, `collect_bindings`
  (`redirected_statement` → `recurse({ body = true })`), `walk_sequence`,
  `tally_sequence`, `walk`, `tally_walk`
- `lua/agentic/utils/permission_rules.test.lua`, `shell_parse.test.lua`
- Skill: `permissions` (§ Shell command parsing, § Grant scopes)
- `notes/FIX-walk-file-model.md` — `command_cwds` (see Changes)

## Background
tree-sitter-zsh puts everything on a heredoc's line after the delimiter
inside the `heredoc_redirect`, not in the statement:

| Source line | Children of the `heredoc_redirect` after `heredoc_start` |
|---|---|
| `sort <<'EOF' -o f` | `argument: word` ×2 |
| `cat <<'EOF' > f 2>/dev/null` | `redirect: file_redirect` ×2 |
| `cat <<'EOF' <<<y` | `redirect: herestring_redirect` |
| `cat <<'EOF' && a && b` | `operator: &&`, `right: list` |
| `cat <<'EOF' \|\| a > f` | `operator: \|\|`, `right: redirected_statement` |
| `cat <<'EOF' \| a \| b` | `pipeline` (`\|`, then one nested `pipeline` `a \| b`) |
| `cat <<'EOF' \|& sh` | `pipeline` (`\|&`, `sh`) |
| `cat > f <<'EOF' && zsh f` | `operator: &&`, `right: command` |
| `cat <<'EOF' && a \|\| b` | `operator: &&`, `right: list` `a \|\| b` |
| `cat <<'EOF' \| a && b` | `pipeline` (`\|`, `list` `a && b`) |
| `cat <<'EOF' &&⏎ls` | `operator: &&`, `right: command` `ls` from the body's first line |
| `cat <<'EOF' >$x; ls` | `file_redirect` with an `ERROR` (`;`) |

zsh reads the line as if the heredoc were not there, grouping `&&`/`||`
from the left: `cat && a || b` is `(cat && a) || b`, `cat | a && b` is
`(cat | a) && b`. The grammar nests the rest to the right, so it matches
zsh only when every operator in it is the same. With an operator at the end
of the line, zsh reads the next lines as the heredoc body, the grammar as
the command. A `;`, `&`, a second heredoc, or a word after a nested
redirect gives an `ERROR` node, which the fail-closed parse rejects.

The walk (`walk_redirected`, `tally_redirected`, `redirect_writes`,
`collect_bindings`) and `node_io` read only a statement's top-level
`redirect` children. `reject_walk` and `collect` recurse every named child,
so they already reach the rest of the line. To stay sound, the walk bails
on any heredoc with a child other than start, body and end
(`heredoc_ends_line`). So `cat <<'EOF' > /tmp/f` prompts under
`/grant /tmp`, and `cat > f.sh <<'EOF' && zsh f.sh` prompts instead of
walking the reconstructed script.

One shared decomposition of a `redirected_statement` lets both the walk and
`node_io` read the same redirects and the same rest of the line. Redirect
target values stay resolved in two places (see Non-goals).

## Changes
### `lua/agentic/utils/shell_parse.lua`
- New class:
  ```lua
  --- @class agentic.utils.ShellParse.RedirectedParts
  --- @field body TSNode the statement's `body`
  --- @field redirects TSNode[] redirects applied to `body`, in source order: the statement's `redirect` children, then the file and herestring redirects on a heredoc's line
  --- @field words TSNode[] words of `body`'s last command the grammar put on redirects: a file redirect's `redirect_operands(fr, src).dests` after the first, heredoc `argument` children
  --- @field rest TSNode[] statements the line continues into after a heredoc, in order: the elements of the `&&`/`||` chain or the pipeline
  --- @field rest_op? "&&"|"||"|"|" operator joining `body` and every `rest` element; nil when `rest` is empty
  ```
- New `M.redirected_parts(node, src) -> agentic.utils.ShellParse.RedirectedParts|nil`
  (`src` for `redirect_operands`).
  Returns nil (unmodelled) when a heredoc's line holds:
  - a child of a type not in the table above;
  - a mix of operators: a `&&`/`||` chain whose `list` spine has the other
    operator, or a pipeline whose element is a `list`;
  - `|&`;
  - a first `rest` element starting on a later row than `heredoc_start`.
  `rest` flattens the `list` spine (for `&&`/`||`) or the nested
  `pipeline`s (for `|`); a pipeline inside a `&&` chain stays one element.
  Replaces `heredoc_ends_line`.
- `node_io`: build `io` from `redirected_parts` (file and herestring
  redirects → `redirect_record`, heredoc → `stdin`, `words`).
- `collect`, for a `redirected_statement`:
  - nil parts → return false;
  - collect `body`, then each redirect: a file or herestring redirect as
    today (`redirect_operands(fr, src).dests[1]` only), a heredoc only through its
    `heredoc_body` (expansions), never by generic recursion;
  - then each `rest` element. With `rest_op == "|"` the body runs as a
    non-last pipeline element: in a child shell (as `runs_in_child_shell`),
    and its records are the `upstream` of the first element.
  - The `heredoc_redirect` argument filter goes away.

### `lua/agentic/utils/permission_rules.lua`
- `walk_redirected`: nil parts → false; `#parts.words > 0` → false; each
  redirect as today (heredoc needs a pure body; herestrings bail; file
  redirects go through `redirect_writes`). Record the writes, then walk each
  `rest` element with `walk`, so `cat > f <<'EOF' && zsh f` judges `zsh f`
  against the reconstructed `f`. With `rest_op == "||"` the writes record
  `false` content, not the heredoc body: the rest runs only when the write
  or `cat` failed, so the file holds its disk bytes.
- `redirect_writes(parts, src, known)`: iterate `parts.redirects` instead of
  the statement's children.
- `tally_redirected`: same parts. Record a file redirect that is not safe,
  a herestring, and a heredoc only when its body is not pure or `words` is
  non-empty; then `tally_walk` each `rest` element. (Today the whole
  `heredoc_redirect` is recorded, which spans the rest of the line.)
- `collect_bindings`: recurse `body` and each `rest` element, so an
  assignment after a heredoc (`cat <<'EOF' && f=/etc/x`) drops `known[f]`
  for later statements of the sequence. A function defined in `rest`
  shadows through `walk_function_definition`, which the `rest` walk
  reaches.

### `notes/FIX-walk-file-model.md`
- `command_cwds` reads a `redirected_statement` through `redirected_parts`:
  the body, then `rest` under `rest_op` (`&&`/`||` as in a list; `|` puts
  the body in a child shell).

### Tests
- `shell_parse.test.lua`:
  - `redirected_parts` for each row of the Background table: parts for the
    modelled rows, nil for `|&`, the mixed-operator rows and the
    operator-at-line-end row.
  - `extract_commands("cat <<'EOF' > /tmp/f 2>/dev/null\nx\nEOF")`: one
    `cat` record with both redirects.
  - `extract_commands("cat <<'EOF' | xargs rm\nx\nEOF")`: the `xargs`
    record's `pipe_from` is the `cat` record.
  - `extract_commands("cat <<EOF\n$(rm x)\nEOF")` still records `rm`.
- `permission_rules.test.lua`:
  - `evaluate("cat <<'EOF' > /tmp/f\nhi\nEOF")` → ok, one effect
    `write /tmp/f`.
  - `cat > /tmp/f.sh <<'EOF' && zsh /tmp/f.sh` with body `ls` approves;
    with body `rm -rf /tmp/x` it does not.
  - `cat > /tmp/f.sh <<'EOF' || zsh /tmp/f.sh` with body `ls` does not
    approve when `/tmp/f.sh` on disk holds `rm -rf /tmp/x`.
  - `cat <<'EOF' | sh`, `cat <<'EOF' && python3 -c 1`,
    `cat <<'EOF' > $(touch /tmp/pwn)`, `cat <<'EOF' && ls || rm a`
    stay not read-only.
  - `f=/tmp/a; cat <<'EOF' && f=/etc/x\nhi\nEOF\ncat > $f` does not resolve
    `$f` to `/tmp/a`.
  - `tally_unapproved` records only `rm a` for `cat <<'EOF' && rm a`.

## Expected outcome
- `cat <<'EOF' > /tmp/f` clears under `/grant /tmp` like
  `cat > /tmp/f <<'EOF'`, with its content recorded for a later script walk.
- Commands after a heredoc on its line are judged like any list or
  pipeline element; mixed operators after a heredoc prompt.
- `extract_commands` gives the redirects on a heredoc's line to the command
  they apply to, and pipes its output to the rest.

## Non-goals
- One resolver for redirect target values (`word_value` in
  `redirect_record`, `literal_token` + `known` in `redirect_writes`), and
  moving the walks onto `extract_commands` records — the root-cause
  unification.
- `known` and `funcs` threading into `rest`: it is walked with the generic
  `walk`, so a `$var` there is dynamic and a call to an earlier clean
  function prompts.
- `ctx.written` across a failed write in a sequence
  (`cat > f <<'EOF'⏎…⏎EOF⏎zsh f` when the open fails): `walk_sequence`
  trusts the reconstructed content whatever the earlier statement's exit.

## Open questions
None.

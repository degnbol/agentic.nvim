# Bug: a redirect with no space before a glob or brace target auto-approves

## Observed
`PermissionRules.should_auto_approve` (default settings) and `extract_commands`:

| Command | Approved | Tree | argv |
|---|---|---|---|
| `echo a >{a,b}` | **true** | `argument: (glob_pattern)` | `a`, `>{a,b}` |
| `ls >x*` | **true** | same | `>x*` |
| `ls >f?`, `ls >[ab]`, `ls >>{a,b}` | **true** | same | |
| `ls > x*` | false | `file_redirect destination: (glob_pattern)` | |
| `ls 2>{a,b}` | false | `file_redirect` | |
| `echo a >f` | false | `file_redirect` | |

zsh runs `echo a >{a,b}` as a write to files `a` and `b` (checked in zsh).
The command is approved with no prompt and no grant: a file write outside
every grant scope.

## Cause
The zsh grammar lexes `>` (or `>>`) glued to a word with glob or brace
characters as one `glob_pattern` argument, not a `file_redirect`. With a
space or a descriptor before the operator it parses correctly. Both the
walker and `extract_commands` then see a read-only command with an odd
argument.

## Fix direction
The grammar is upstream, so detect the misparse in `shell_parse.lua`: an
argument node whose raw text starts with an unquoted `>`, `<` or `&>`
(only a redirect starts that way unquoted) is unmodelled. The walker bails,
and `extract_commands` returns nil. One predicate, used by both, next to the
other token checks (`token_is_dynamic`, `literal_token`).

## Related
`redirect_operands` in `lua/agentic/utils/shell_parse.lua` (same family:
grammar gaps around redirect operators). `echo a >!*.txt` takes the same path.

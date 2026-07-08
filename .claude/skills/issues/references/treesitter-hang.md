# The "editor freezes and gets SIGKILLed" symptom

A tree-sitter grammar bug can send the parser's C loop non-terminating. The
whole editor freezes (100% CPU, growing RSS) and is eventually SIGKILLed — no
crash, so no core dump and no `.ips`. **Rule out tree-sitter parsing before any
other hypothesis** — this has been misdiagnosed repeatedly.

## Observed

- Editor fully unresponsive mid-operation; no redraw, no input.
- One core pinned at 100%, memory climbing.
- Process ends via SIGKILL (exit 137), not a crash report.
- Fine in the Claude TUI, which never tree-sitter-parses the content.

## Missing (distinguishes it from a slow-but-terminating stall)

- No recovery on its own — the loop never ends, so it is not "slow", it is
  infinite. `pcall`, `timeout`'s SIGTERM, and neovim's async-parse chunk timeout
  (`parse(range, on_parse)`) all fail to interrupt it: the C reduce loop never
  reaches a cancellation checkpoint.

## Ruled out by observation

Two misdiagnoses that keep recurring — both falsified for the known case:

- **Permission-decision deadlock** (`pm:decide`, a re-entrant `session/update`
  "deadlock triangle"). The Bash permission walk has no event-loop-pump
  primitive, so it cannot host a re-entrant update. A missing `Bash → allow`
  log line is a *symptom* of the already-hung main thread, not its site.
- **Render / conceal stall** (`nvim_win_text_height → decor_conceal_line →
  ts_query_cursor`). The confirmed frozen stack is in `ts_parser_parse_string`
  (the parse), not the query cursor. There is a *separate* real render perf bug
  (`notes/bug-autoscroll-conceal-perf.md`) — do not conflate.

## Known trigger

The confirmed grammar bug: an unescaped close-paren inside a bracket class within
a `${var/pat}` / `${var//pat}` substitution (`c=${x//[^)]}`) loops the
tree-sitter-zsh GLR reduce. Any bare `)` in a bracket class inside a substitution
hangs; escaped `\)`, open-paren `[^(]`, and paren-in-class outside a substitution
are safe. Bug is in `georgeharker/tree-sitter-zsh` (no fixed upstream release as
of 2026-07-08).

## Entry points and current guards

Three paths feed untrusted content to the zsh grammar; all now bail before the
hanging `parse()` (see `notes/bug-zsh-parser-hang.md` § 4):

- Permission walk / walk-into-scripts (`shell_parse.parse_zsh`, and
  `parse_zsh_untrusted` for sourced-file bodies).
- Diff syntax highlight (`ui/diff_preview.lua`).
- Context-aware highlight reconstruct (`utils/treesitter.lua`).

`utils/zsh_parse_guard.lua` (`contains_hang_trigger`) is the cheap in-process
tripwire for the known shape; `parse_zsh_untrusted` adds a killable-subprocess
termination oracle for *unknown* grammar bugs on untrusted file bodies.

## Do not fix this with

- Chasing the permission decision or the render/conceal path first — both are
  ruled out above for the freeze class.
- `pcall`, `timeout`, or neovim async parse as an interrupt — none can stop a C
  parse loop (all tested).
- Assuming it is neovim core — confirm with `nvim --clean` first; a grammar is a
  plugin-layer dependency.

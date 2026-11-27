---
name: issues
description: Debugging specialised to agentic.nvim and the nvim it runs in — load for any bug, regression or unintended behaviour in this plugin. Covers where plugin and editor-core behaviour is read, how to reach the user's live nvim state, and recurring misdiagnosed bug-classes. Use when the user reports the editor hanging, freezing, going unresponsive, or SIGKILLed (exit 137, no crash dump); chat display out of sync, content appearing late, streaming chunks or tool-call frames missing; scrolling, cursor, conceal or fold misbehaving in an Agentic buffer; or any symptom they call a regression or "the same thing as before / we've had this many times".
---

# agentic.nvim — debugging

## Where to read

- **Plugin:** the project skills map each area (`rendering`, `follow`,
  `session-lifecycle`, `provider-system`, `permissions`, `subagents`).
- **Editor core:** what the redraw does to topline, cursor, `scrolloff`,
  conceal and folds is C code in neovim's `src/nvim/` (`move.c`,
  `drawscreen.c`, `plines.c`), not `:help`. Read it at the tag of
  `nvim --version`.

## Live state

The agent runs inside the user's nvim, so the nvim that shows the bug is
reachable: walk the parent processes to the nvim pid; its socket is
`$TMPDIR/nvim.$USER/*/nvim.<pid>.0`. Read window and buffer state from it with
`--remote-expr`. That state, taken while the symptom is on screen, is the
faithful reproducer; a replica of it is an experiment.

## Known recurring issues

Bug-classes (in `references/`, listed under Index below) that have been
misdiagnosed across multiple sessions. When the user signals a recurring
symptom, after searching git history for earlier fixes:

1. **Read the matching reference file** if one exists. Match the user's
   description against the "Observed" and "Missing" lists line-by-line before
   proposing anything.
2. **Do not** propose fixes listed under the reference's "Do not fix this
   with" section. Those are the misdiagnoses previous sessions already made.

## Index

- `references/treesitter-hang.md` — editor freezes and is SIGKILLed (exit 137,
  no crash dump). A tree-sitter grammar bug spins the parser's C loop forever;
  uninterruptible. Repeatedly misdiagnosed as a permission deadlock or render
  stall. Rule this out before any other freeze/hang hypothesis.
- `references/chunk-flush.md` — chat content (agent_message_chunks, tool
  call frames) is missing while the agent responds and appears all at once
  when the user submits a new prompt. NOT a redraw issue. A symptom family
  with distinct causes: the fixed variants were parallel tool calls and
  per-turn state leaks; the open variant, auto-continue after a usage-limit
  reset, is a stall inside the bridge, not plugin state.

## Adding a new entry

When the user reports a recurring symptom that previous sessions keep
getting wrong:

1. Write a new `references/<short-symptom-name>.md` using the same structure:
   Observed / Missing / Release trigger / Ruled out by observation / Known
   triggers / Code-path asymmetry (if applicable) / Do not fix this with.
2. Add one line to the index above.
3. Keep descriptions verbose enough that a session coming in fresh cannot
   conflate it with a superficially similar symptom.

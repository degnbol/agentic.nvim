---
name: issues
description: Debugging agentic.nvim at runtime, plus its recurring misdiagnosed bug-classes. Use when adding logging or diagnostics (Logger.debug, debug_to_file, temporary io.open), or when the user reports the editor hanging, freezing, going unresponsive, or SIGKILLed (exit 137, no crash dump); chat display out of sync, content appearing late, streaming chunks or tool-call frames missing; or any symptom they call "the same thing as before / we've had this many times". Read it BEFORE diagnosing any freeze/hang or adding debug output. Match the user's report against a reference file's "Observed"/"Missing" lists before proposing a fix; do not propose fixes under "Do not fix this with".
---

# Agentic.nvim — debugging and known recurring issues

## Runtime debugging

`Logger.debug()` (prints to `:messages`) is gated by `Config.debug`.
`Logger.debug_to_file()` (appends to `~/.cache/nvim/agentic_debug.log`) is
gated by `Config.log`. Both default to `false` and are independent — enable
`log` alone for file logging without screen distraction. For temporary
diagnostics that must fire unconditionally, use `io.open` directly:

```lua
do
    local f = io.open("/tmp/agentic_diag.log", "a")
    if f then
        f:write(string.format("%s %s\n", os.date("%H:%M:%S"), msg))
        f:close()
    end
end
```

Remove before committing. Never leave `io.open` debug logging in production code.

## Known recurring issues

Bug-class descriptions (in `references/`, listed under Index below) that have
been misdiagnosed across multiple sessions. For a freeze/hang, read the matching
reference first.

When the user signals a *recurring* symptom — "same thing as before", "we've had
this many times", "this keeps happening", "we've seen this before", "recurring",
or similar language pointing at prior sessions' work — the **mandatory first
step** is:

1. **Search git history** before touching anything. The phrase means the user
   expects you to find what was already tried. Run:
   ```bash
   git log --all --oneline --grep="<symptom-keyword>" -i
   ```
   with several keywords drawn from the symptom (e.g. `sync`, `stuck`,
   `behind`, `flush`, `stream`, `appears`, `redraw`, `schedule`). Inspect
   both fix commits AND revert commits — a symptom returning after a
   "cleanup" revert is a strong signal.
2. **Read the matching reference file** in this skill's `references/` dir if
   one exists. Match the user's description against the "Observed" and
   "Missing" lists line-by-line before proposing anything.
3. **Do not** propose fixes listed under the reference's "Do not fix this
   with" section. Those are the misdiagnoses previous sessions already made.

Skipping the git search and jumping to a hypothesis has been the repeated
failure mode. Do the search even if you think you recognise the symptom.

## Index

- `references/treesitter-hang.md` — editor freezes and is SIGKILLed (exit 137,
  no crash dump). A tree-sitter grammar bug spins the parser's C loop forever;
  uninterruptible. Repeatedly misdiagnosed as a permission deadlock or render
  stall. Rule this out before any other freeze/hang hypothesis.
- `references/chunk-flush.md` — chat content
  (agent_message_chunks, tool call frames) is missing during the wait and only
  appears when the user submits a new prompt. NOT a redraw issue. NOT the
  per-turn state leak class. Symptom family — most variants fixed
  (parallel-tool-calls, rejection-buffer, per-turn-state-leak). Last open
  variant: auto-continue after usage-limit reset.

## Adding a new entry

When the user reports a recurring symptom that previous sessions keep
getting wrong:

1. Write a new `references/<short-symptom-name>.md` using the same structure:
   Observed / Missing / Release trigger / Ruled out by observation / Known
   triggers / Code-path asymmetry (if applicable) / Do not fix this with.
2. Add one line to the index above.
3. Keep descriptions verbose enough that a session coming in fresh cannot
   conflate it with a superficially similar symptom.

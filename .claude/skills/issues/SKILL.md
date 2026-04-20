---
name: issues
description: Recurring agentic.nvim bug-class descriptions that keep being misdiagnosed. Use when the user reports chat display out of sync, content appearing late, streaming chunks missing, tool call frames missing, or any recurring agentic.nvim UI symptom they describe as "the same thing as before / we've had this many times". Read the matching symptom file in references/ and match the user's description against the "Observed" and "Missing" lists before proposing a fix. Do not propose fixes that appear under "Do not fix this with".
---

# Agentic.nvim — known recurring issues

Collection of bug-class descriptions that have been misdiagnosed multiple
times across sessions.

## When the user signals a recurring issue

Phrases to watch for: "same thing as before", "we've had this many times",
"this keeps happening", "we've seen this before", "recurring", or similar
language pointing at prior sessions' work.

**Mandatory first step when triggered by that phrasing:**

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

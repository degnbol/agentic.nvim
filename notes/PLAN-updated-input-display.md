# PLAN: show when a hook rewrote a tool call's input

Status: **draft — not investigated.** Written from a single observation while
working on `notes/PLAN-hooks_in_chat.md`; nothing below has been verified beyond
the counts in "What prompted this". Do not implement from this as-is.

Out of scope for the hook-surfacing work — that plan renders hook *activity*.
This one is about the tool call's own displayed input being wrong.

## Problem

A `PreToolUse` hook can return `hookSpecificOutput.updatedInput`, which replaces
the tool input before the tool runs. The chat buffer renders the input the model
sent, so after a rewrite **the command shown is not the command that ran.**

Silent display divergence, not a hook-visibility gap — which is why it is its own
note.

## What prompted this

While classifying hook records in this project's transcript history: 56
`hook_success` records carry `updatedInput`, all from one script
(`shell-guard.sh`), all on Bash. That is the entire evidence base.

## Hypothesis (unverified)

The rewrite is usually **additive** — a prepended prefix (an env assignment, a
wrapper, a flag), leaving the model's command intact as a substring.

If that holds, the display can stay minimal: keep the rendered command as-is and
mark the inserted span with an extmark highlight linked to the existing diff
"added" colouring. No second command line, no diff block, no layout change.

## Open questions

- **Is it always additive?** Needs checking against the 56 records: prefix-only,
  suffix, or arbitrary rewrite. A non-additive rewrite has no "inserted span" to
  highlight and needs a different treatment (two lines, or a real diff).
- **Which fields get rewritten?** Only Bash `command` in the sample, but
  `updatedInput` is a whole input object — an Edit's `old_string`/`new_string`
  rewrite would not fit a single-span highlight at all.
- **Where does the rewritten input arrive over ACP?** Unknown. If the bridge
  sends the *rewritten* input as `rawInput` then the chat already shows what ran
  and there is no bug — only the *original* would be missing. **Check this first:
  it decides whether this note describes a real problem or an inverted one.**
- Which highlight group to link to (needs a look at `theme.lua`), and whether an
  extmark on a fenced execute command survives treesitter priority — the
  `rendering` skill covers that interaction.

## Not decided

Whether this is worth surfacing at all. A hook the user wrote themselves,
rewriting their own commands predictably, may not need chat real estate. Revisit
once the first open question above is answered.

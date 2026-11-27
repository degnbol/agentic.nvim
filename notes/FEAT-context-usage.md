# Plan: tell the agent its context usage past a threshold
Status: spec
Priority: P3
Depends:

## Relevant files
- `pi/agentic.ts` — the plugin's own pi extension (model for a pi extension
  in this repo)
- `lua/agentic/pi/pi_client.lua` — `EXTENSION` and the `--extension`
  arguments in `PiClient:_open`, `_send_usage` (the header figure)
- `REFACTOR-pi-only.md` step 10 — the plugin's pi package (`pi/package.json`)
- pi docs `extensions.md`: § `before_agent_start`, § `ctx.getContextUsage()`,
  § `pi.registerFlag`; `ContextUsage` in `dist/core/extensions/types.d.ts`
- `~/dotfiles/config/pi/extensions/doc-hints/` — `node --test` setup to copy

## Background
Agent performance degrades past ~200k tokens of context, whatever the
model's window. An agent that knows its usage can choose at decision
points: hand new work to a subagent, write a plan or handover instead of
implementing, or wrap up. Below the threshold the number is noise.

pi has the number: `ctx.getContextUsage().tokens`, from the last assistant
usage plus an estimate of the messages after it. `tokens` is `null` right
after compaction, until the next response; `getContextUsage()` returns
`undefined` when the model has no known context window. The chat header shows it to the
user (`PiClient:_send_usage`); the model never sees it.

This is harness work, so it is a pi extension and works in every pi
client. A `before_agent_start` handler returns a `message`; pi stores it
in the session and sends it to the model with the run. The handler skips
runs with `messageType` `"custom"` (started by an extension message);
extension commands start no run.

The guidance is sent once per crossing; later prompts carry only the
number. A prompt sent below the threshold re-arms the guidance, so after
compaction the next crossing gets it again, as the compaction summary may
have dropped the earlier copy.

The guidance states only that usage is past the configured threshold, not
where performance degrades, so it stays true for any flag value.

## Changes
- New `pi/context-usage.ts` (pi extension):
  - `pi.registerFlag("context-usage-threshold", { type: "string", default: "150000" })`:
    used-token count from which user prompts carry `<context_usage>`; `0`
    disables. Parsed to an integer in `session_start`; a value that is not a
    non-negative integer gives an error through `ctx.ui.notify` and disables
    the extension for the session.
  - `export function usageText(used: number, threshold: number, guidance: boolean): string`
    — `<context_usage>Context usage: 172k tokens.</context_usage>`; with
    `guidance`, adds: `Context is past <threshold>k tokens. Before starting new work, prefer handing it to a subagent, writing a
    plan or handover doc instead of implementing, or wrapping up.`
  - Extension state `guidanceSent: boolean`, cleared in `session_start`.
  - `before_agent_start`: return nothing when `messageType !== "user"`,
    the threshold is `0`, or `ctx.getContextUsage()?.tokens` is `null` or
    `undefined`. When `tokens` is below
    the threshold, clear `guidanceSent` and return nothing. Else return
    `{ message: { customType: "context-usage", content: usageText(tokens, threshold, !guidanceSent), display: false } }`
    and set `guidanceSent`.
- `pi/package.json` (the plugin's pi package; new if step 9 of
  `REFACTOR-pi-only.md` has not created it): lists the extension.
- `pi_client.lua`: pass `--extension` for `pi/context-usage.ts`, next to
  `agentic.ts`. The user sets the threshold in the pi provider's `args`.
- `doc/agentic.txt`: the flag, in the pi provider section.
- Tests: `pi/context-usage.test.ts` (`node --test`): `usageText` with and
  without guidance, threshold rendered in `k`; the handler with a stub
  `ctx`: below threshold → none; first crossing → guidance; next prompt
  → number only; below then above → guidance again; `"custom"` run →
  none; `tokens` `null` or usage `undefined` → none; threshold `0` → none; threshold `abc` → error notification, none.

## Expected outcome
User prompts sent at or above 150k carry `<context_usage>`: with the
guidance on the first, the number alone after that. Below 150k, and for
runs that extension messages start, nothing changes. The chat does not
show the message (`display: false`).

Accepted gaps: no `<context_usage>` on the first prompt after compaction
(`tokens` is `null`); the guidance goes out again once after a pi restart
or session switch, as `guidanceSent` is process state.

## Non-goals
- Mid-turn updates. The `context` event could add the number before each
  provider request; one message at run start covers the decision points.

# Bug: a provider's `unknown` subagent state ends the subagent

`Subagents:update` handles `state = "unknown"` like `idle`: it calls
`end_agent`, which drains and drops the subagent's held side-record fields,
stamps its unfinished tool calls `cancelled`, writes a `subagent_end` row with
state `unknown`, and shows the end in the transcript header.

The ACP schema (`@agentclientprotocol/sdk` `schema/v1/schema.unstable.json`,
`UnknownStateUpdate`) says `unknown` means the agent cannot currently observe
foreground activity: it "is not a task outcome or session closure. It does
not cancel work, resolve pending requests, or revoke capabilities", and a
later state replaces it normally. The client must stop presenting the
previous state as confirmed, but may keep it as last known.

Consequence:
- From any provider: a subagent reported `unknown` and then `running` again
  keeps calls marked `cancelled` and an end row for an end that never
  happened. `_start_agent` then reopens it under that end row.
- From claude-agent-acp: `rfdEndState` in `dist/native-subagents.js` sends
  `unknown` for its `disconnected` terminal state, after which `route()` drops
  the child's updates. No later state comes, so the close itself fits. But
  the `cancelled` stamps still claim an outcome the bridge says it does not
  know.

Not affected: the client's own `close_all({ state = "unknown" })` on a
disconnect and on `_refresh`. There nothing more will arrive, so an end-like
close is wanted. Those calls reach `end_agent` directly, not through `update`.

Found by reading the schema and the bridge source; not observed in a session.

Reproduce: unit test on `Subagents:update` with a running subagent holding a
pending tool call, then `{ state = "unknown" }`; check the call's status and
the history for a `subagent_end` row.

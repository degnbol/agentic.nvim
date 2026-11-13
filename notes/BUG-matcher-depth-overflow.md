# Bug: a long command overflows the permission matchers' stack

## Mechanism
The gate matchers recurse once per word. `ZshParse.MAX_SOURCE_BYTES` (65536
chars, checked in `ZshParse.parse_command`) bounds the source length, not the
depth. Measured with `-a` flags before `safe file`:
- `decide_leaf` overflows the Lua stack at about 4000 words, in
  `every_stream_matches` through `vim.iter`, even for a one-element allow gate.
- `deny_leaf` overflows at about 20000 words.

## Effect
- ACP path (`ACPClient:__handle_request_permission`): an error is notified and
  the request is answered `cancelled`. This fails closed.
- Hook path (`permission_hook.lua` `M.evaluate`): the error goes only to
  `debug_to_file`, and the hook returns undecided. In auto mode the SDK
  classifier then decides, and it can approve. The deterministic deny gates
  do not run for that command.

## Where
- `lua/agentic/utils/permission_rules.lua`: `decide_leaf`, `deny_leaf`,
  `every_stream_matches`, `some_stream_matches`.
- `lua/agentic/acp/permission_hook.lua`: `M.evaluate`.

## What to check
- Whether the hook path should fail closed (deny or ask) on an evaluation error
  instead of returning undecided. This does not depend on the depth fix.
- Whether the matchers can walk iteratively, or whether a word-count bound
  before the walk is enough.
- `FIX-deny-gate-flag-cap.md` § Non-goals has the measurements.

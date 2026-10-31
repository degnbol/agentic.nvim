# Plan: stop a subagent with `session/cancel` on its session
Status: reviewed spec

## Relevant files
- `lua/agentic/session_manager.lua`: `agentic.SessionManager.Agent`, `_on_subagent_update`, `_stop_agent`, `_bind_agent_keymaps`, `_open_input` (its stop keymap), `_relay`, `HOLD_CAUSE`
- `lua/agentic/acp/acp_client.lua`: `subagent_stop_instruction`, `stop_generation`
- `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua`, `claude_utils.lua`: `subagent_stop_instruction`, `task_stop_instruction`
- Tests: `tests/integration/test_subagent_inputs.lua` (the `<C-c>` cases), `lua/agentic/session_manager.test.lua` (`refusing_session`, the "refusal" case that calls `_stop_agent`), `acp_client.test.lua`, `claude_agent_acp_adapter.test.lua`, `claude_utils.test.lua`
- `doc/agentic.txt` § `agentic-subagents`; `notes/feature-scoped-cancel-subagents.md`; `notes/bug-unknown-jsonrpc-method-handling.md` (`$/cancel_request`)
- Plans that describe the stop relay: `notes/PLAN-usage-limit-queue.md`, `notes/PLAN-split-subagents.md`
- Bridge 0.97.0 (`~/.local/share/npm/lib/node_modules/@agentclientprotocol/claude-agent-acp/dist`): `acp-agent.js` `cancel`/`cancelChildSession`, `publishCurrentSubagentStates`, `requestPermissionFromClient`; `native-subagents.js` `cancelChild`, `announceNativeSubagent`; `subagent-replay.js` `RfdSubagentReplay.currentStates`
- Skills: `provider-system` § Subagents are child sessions, `permissions` (the gate `_relay` waits on)

## Background
The plugin talks to claude-agent-acp on its RFD form of subagents: each subagent is a child session, announced by `subagent_update`.

`_stop_agent` asks the main agent to stop a background subagent: it sends the adapter's `subagent_stop_instruction` (Claude: "Call TaskStop …") as a user prompt through `_relay`. That costs a main-agent turn, and the gate can hold it (`HOLD_CAUSE`). A blocking subagent stops only with the whole turn (`stop_generation`).

A child that the client may cancel is announced with `capabilities.cancel` (`announceNativeSubagent`). A replayed announce omits `capabilities`. After the load response, the bridge sends each replayed child's state again, with `capabilities.cancel` only for a child still live in the bridge process (`publishCurrentSubagentStates` → `currentStates`). `session/cancel` with the child's session id reaches `cancelChildSession` → `cancelChild` → `query.stopTask(taskId)`. The parent's turn goes on, and the child reports its own `idle`/`cancelled`, which `_end_agent` already handles.

So a subagent that is live in the bridge can be stopped directly, background or blocking, with no prompt to the main agent and no gate. The TaskStop relay has no case left: the Claude adapter is the only one that gives a stop instruction, and its bridge grants `cancel` to every live child.

Two limits:
- When a child stops, Claude Code withdraws its open permission requests, and the bridge sends `$/cancel_request`. The plugin does not handle that notification (`notes/bug-unknown-jsonrpc-method-handling.md`), so a stopped child's permission float stays open until answered. That bug is the fix; this plan does not work around it.
- A stopped background child's task notification may start a model cycle of the main agent that Claude Code starts by itself. Not measured.

## Changes
1. `session_manager.lua`
   - `agentic.SessionManager.Agent`: `--- @field cancellable? boolean The provider lets the client cancel the agent's work (\`capabilities.cancel\`)`.
   - `_on_subagent_update`: when `update.capabilities ~= nil`, set `agent.cancellable` to whether `Json.present(update.capabilities)` holds a present `cancel` (`vim.tbl_get` cannot index `vim.NIL`; patch semantics: omitted keeps, `null` clears).
   - `_stop_agent(child_id)` acts on that subagent only:
     - not open → nothing (today's "has finished" notice goes);
     - `agent.cancellable` → `self.agent:stop_generation(child_id)`;
     - blocking (`_confirmed_blocking`) → `self:stop_generation()`: the turn waits on the agent, so stopping the turn is how it stops;
     - else notify `"<provider> cannot stop subagent <label>"` (WARN).

     The relay branch and its `HOLD_CAUSE` notice go. Docstring: "Stop a working subagent: through the provider's cancel when it grants one, else by stopping the main agent's turn for a blocking one. No-op for an agent that is not working."
   - `_bind_agent_keymaps`: `<C-c>` in a transcript calls `_stop_agent`. Today it stops the main agent's turn for an agent without a message input, whether or not the agent works.
2. `acp_client.lua` `stop_generation` docstring: "Send `session/cancel` for a session: the main session's turn, or a subagent's work." (drop "The session stays subscribed", which says nothing about a child).
3. Delete `ACPClient:subagent_stop_instruction`, the Claude override and `ClaudeUtils.task_stop_instruction`, with their tests. The adapter test "gives the TaskStop and SendMessage instructions" keeps its SendMessage half.
4. `doc/agentic.txt` § `agentic-subagents`: `<C-c>` in a subagent's transcript or message input stops that subagent while it works, and the main agent's turn goes on, when the provider can cancel it; a blocking one it cannot cancel stops with the turn. Drop "asks the main agent to stop the subagent" and "`<C-c>` stops the turn".
5. `provider-system` skill: a message input needs only `subagent_message_instruction`; drop `subagent_stop_instruction` and "implement both or neither".
6. `notes/feature-scoped-cancel-subagents.md`: §1, §2 and §4 describe the AIR-era bridge. On the RFD form the bridge sets `perTaskStopAffordance` itself, and one subagent can be stopped (`cancelChildSession`). Rewrite those sections to that.
7. Other plans: `PLAN-usage-limit-queue.md` (`_relay_to_agent` "as in `_stop_agent`", `HOLD_CAUSE` uses) and `PLAN-split-subagents.md` (`_stop_agent` via `host.relay`, the "returns nothing for a subagent stop" test, `subagent_stop_instruction` in `refusing_session`) drop the stop relay.

## Tests
- `test_subagent_inputs.lua`: SETUP records no notification, so stub `_G.s.agent.stop_generation` to record its session id. In the `<C-c>` cases each press sends one `session/cancel` with `sessionId = "c1"` and no prompt (the SETUP `spawn` sends `capabilities.cancel`). New:
  - an announce with `capabilities = vim.NIL` and a background record, then `<C-c>`: notifies and sends nothing;
  - the same with a blocking record: stops the turn;
  - "stopping a finished agent notifies and sends nothing" becomes "`<C-c>` on a finished agent does nothing": no notice, nothing sent, the turn not stopped.
- `session_manager.test.lua`: drop the `_stop_agent` refusal case and `subagent_stop_instruction` from `refusing_session`.
- `test_native_subagents.lua`: a replayed announce without capabilities, then a post-load `running` state with `capabilities.cancel`, leaves the agent cancellable.
- `make validate`.

## Expected outcome
- `<C-c>` in a working subagent's transcript or input stops that subagent at once, background or blocking, when the provider can cancel it; the main agent's turn goes on.
- Stopping no longer sends a prompt to the main agent, so the gate never holds it.

## Non-goals
- `<C-c>` in the chat sparing running subagents (`feature-scoped-cancel-subagents.md` §2).
- Closing a stopped child's permission float (`$/cancel_request`, see Background).

## Open questions
None.

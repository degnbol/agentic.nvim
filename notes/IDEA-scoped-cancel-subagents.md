# Scoping `<C-c>` — sparing subagents from the interrupt

The ask: `<C-c>` in the chat **stops the main agent while background subagents
keep running**. Bridge 0.97.0 sets the SDK option for it on the RFD form,
  but its own `parentCancelled` docstring says the interrupt "currently" stops
  background children too (§2). Not measured on the RFD form.

On 0.75.1 the price of the second was a reporting blackout until the next
prompt (§3): a spared subagent kept working and spending, and surfaced only
permission requests.

## 1. What `<C-c>` does today

`keymaps.widget.stop_generation` (`<C-c>` in n and i) in the chat and input
runs `SessionManager:stop_generation`: `session/cancel` with the main session
id. In a subagent's transcript or message input it sends `session/cancel` with
the child session id. Focus alone picks the target: no agent state changes it.

## 2. Sparing them: `perTaskStopAffordance`

On the RFD form, bridge 0.97.0 sets `perTaskStopAffordance: true` itself
(`acp-agent.js` session options, before `userProvidedOptions`), meant to make
a main-turn cancel spare background subagents. `NativeSubagentRuntime.parentCancelled`
(`native-subagents.js`) says the interrupt still stops them. The rest of this
section is the 0.75.1 measurement, with the option set by the client.

`@anthropic-ai/claude-agent-sdk` declares the option on `Options`
(`sdk.d.ts:1672`) and on the control-initialize shape (`:3968`):

> When declared, an interrupt on an open-input (interactive stream-json)
> session **spares running background agents/workflows** — Stop only aborts the
> current turn… The CLI also **fails closed on absence**: without the
> declaration, an interrupt kills background tasks, because a spared runaway
> task would otherwise be unstoppable from this consumer short of ending the
> session. First-attached-client wins on multi-client sessions.

Measured by driving the bridge over stdio with the plugin's own client
capabilities and a subagent whose only job was one Bash call per heartbeat (no
shell loop, so a continuing heartbeat proves the subagent's own loop is alive),
cancelling 8s after its first tool call and watching for 75s:

| `run_in_background` | `perTaskStopAffordance` | heartbeats after cancel |
| --- | --- | --- |
| `true` | unset | **0** — killed |
| `true` | `true` | **13–14 over 75s** — survived, ran to completion |
| `false` | unset | 0 — killed |
| `false` | `true` | 0 — killed |

### Only background subagents can be spared

`run_in_background` is a parameter of the Agent tool, and it decides whether
the *parent's* Task tool call stays open for the subagent's whole life. Both
modes are the same kind of thing — a nested agent loop with its own context —
and the difference is visible in the tool-call lifecycle:

| | Agent tool call | at cancel |
| --- | --- | --- |
| `false` | still `pending` 17s later | the interrupt aborts the turn whose tool call is awaiting the subagent |
| `true` | `completed` after 2.5s | the subagent outlives its own spawning call and is tracked as a task |

So there is nothing for the declaration to spare in the `false` case: no
independently tracked task exists, only a tool call belonging to the aborted
turn. (That reading is inference; only the death itself was measured.)

**Which mode a spawn uses is the model's per-call choice, not a setting.** Told
*not* to set `run_in_background`, the model twice set it explicitly to `false`
(`~/.claude/projects/-private-tmp-acp-cancel-probe-work/*.jsonl`); only a
mandatory instruction produced a background spawn. A feature built on this is
therefore "your subagent *may* survive `<C-c>`", which is a hard thing to put
in a keymap description.

## 3. The blackout while the gate is closed

Measured on 0.75.1, before subagents were child sessions; line numbers are
0.75.1's. `cancel()` sets `session.cancelled` (`acp-agent.js:4388`); the next prompt
clears it (`:2020`). In between, the consumer's `case "user": case "assistant":`
returns early at `:3997`, dropping every consolidated message.

That gate is total for subagent content, because **subagent content only ever
arrives consolidated.** The evidence is chunk granularity in the same run: main
agent text arrives as stream fragments (`"I"`, `"'ll sp"`, `"awn the
background"`), subagent text as whole sentences (`"About to emit beat 11."`) —
one chunk per message, i.e. from the consolidated `assistant`, never from
`stream_event`. So while `stream_event` (`:3770`) and the `sendUpdate`
chokepoint (`:1878`) carry no cancelled guard at all, that buys subagents
nothing: they put nothing on that path.

What a survivor could still show, measured over 40s of blackout:

| Arrives | Silent |
| --- | --- |
| `session/request_permission` (7 of them) | subagent text and thinking |
| one `tool_call` per permission, tagged `parentToolUseId` | every `tool_call_update` — calls stick at `pending` |
| `usage_update` | tool results, the subagent's final report |

The tool calls arrive *because* of the permissions, not alongside them: the
bridge eagerly emits the call it is asking about, and `canUseTool` is a
separate control channel `session.cancelled` does not gate. A survivor doing
work that needs no permission (`Read`, `Grep`, an allow-always `Bash`) would be
completely invisible.

So the sharp edge is not silence, it is **a permission float popping up over an
idle-looking chat, for a tool call the subagents window shows as pending
forever.**

### The next prompt heals it, with one seam

After the follow-up prompt the survivor's output resumed in full — text,
`tool_call`/`completed` pairs, all correctly tagged. One straddling case,
observed once: the call in flight across the gate clear had its `completed`
update delivered with an **empty `_meta.claudeCode`**, so nothing carried
`parentToolUseId`. Since `SessionManager` routes on that meta
(`session_manager.lua:532`), that completion lands on the main chat rather than
the subagents window.

## 4. A sparing cancel and turn state

If a main-turn cancel spares a background subagent,
`SessionManager:stop_generation` is wrong for it twice: it cancels every open
permission request (`permission_manager:cancel_requests()`), the survivor's
included, and it marks the session idle (`_set_generating(false)`), which opens
`_drain_queue` to dispatch the next queued block while the subagent works.

## Verified

§1 and the opening of §2 are source reads of bridge **0.97.0**. The
measurements in §2 and §3 ran on bridge **0.75.1**, `@agentclientprotocol/sdk`
**1.4.0** and `@anthropic-ai/claude-agent-sdk` **0.3.257**, with the CLI the
bridge spawns, `node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude`
**2.1.257**, not `~/.local/bin/claude`, unless `CLAUDE_CODE_EXECUTABLE` is set.

Bridge `dist/` is unminified and commented; read at
`~/.local/share/npm/lib/node_modules/@agentclientprotocol/claude-agent-acp/`.

The 0.75.1 measurements are four runs of a stdio ACP
client that mirrors the plugin's `initialize` capabilities (including
`_meta["subagent-transcript"]`) and its `_meta.claudeCode.options` blob, sends
the same bare `session/cancel` the `<C-c>` path sends, auto-approves
permissions, and samples both the heartbeat file and every inbound frame. The
harness lived in `/tmp` and is not kept.

---
name: subagents
description:
  Subagents in agentic.nvim — child sessions, their launch blocks, transcripts
  and message inputs, the blocking/background mode (predicted vs confirmed),
  and how they differ from background sessions. Use when editing
  `subagents.lua`, `ui/subagent_transcript.lua`, `ui/subagent_input.lua`,
  `background_session.lua`, `SubagentInfo`/`SubagentMode` in
  `message_writer.lua`, the adapters' subagent overrides (`subagent_*`,
  `launch_reply_task`), or when designing or discussing any subagent UI
  ("running subagents", "background subagent", "blocking subagent",
  "foreground", "transcript", "child session", "SendMessage",
  `force_background`).
---

# Subagents

Per-function contracts live in the docstrings of `lua/agentic/subagents.lua`
(`Subagents`, one per session) and the files below. This skill is the
vocabulary and the cross-file map.

## Vocabulary

| Term | Meaning | Defined at |
| --- | --- | --- |
| subagent | An agent the main agent (or another subagent) spawned with its Agent/Task tool, run as an ACP child session | `agentic.Subagents` |
| child id | The child session id; the key of `Subagents._agents` | `agentic.Subagents.Agent` |
| task id | The id of the tool call that gave a subagent its work (spawn or resume). The spawning one keys its history rows (`agent_key`) | `ACPClient:subagent_task_id`, `Subagents:agent_key` |
| launch block | The `SubAgent` tool call block in the parent's view (the chat, or the spawning subagent's transcript) | `Subagents:_open_agent` |
| transcript | A subagent's own chat-style buffer | `agentic.ui.SubagentTranscript` |
| message input | A background subagent's input buffer; text goes to the main agent as a relay instruction (claude: SendMessage) | `agentic.ui.SubagentInput`, `ACPClient:subagent_message_instruction` |
| mode | `blocking` or `background`, the only two values | `agentic.ui.MessageWriter.SubagentMode` |
| predicted / confirmed | `SubagentInfo.confirmed`: false while the mode is the adapter's guess (`subagent_predicted_mode`, set by provider config `subagents.force_background`), true once `Subagents:read_record` reads the SDK's record | `agentic.ui.MessageWriter.SubagentInfo` |
| open (running) | The subagent is working. A turn's end does not close it | `Subagents:update`, `close_all`, `forget` |

"foreground" is not a plugin mode. It is the SDK's word for blocking (the
`requestShape` of its spawn record, global `acp` skill →
`references/claude-agent.md` § Mode sidecar). Plugin code and docs say
`blocking`, except `Subagents:mark_foreground_stopped`. A test on
`mode ~= "background"` covers blocking, predicted or confirmed. Engine-side
differences between the two modes (abort linkage, tool set, permission
prompts): `claude` skill → `references/subagents.md`.

User-facing behaviour of modes, transcripts and inputs: `:h agentic-subagents`
in `doc/agentic.txt`.

## Background sessions are not subagents

`BackgroundSession` (`background_session.lua`) is a top-level session the
plugin itself drives unattended (e.g. the skeptic reviewer), on the
provider's separate unattended process (`AgentInstance.get_instance`), with no
spawning agent. It reuses `SubagentTranscript` for its buffer and a fixed
`SubagentInfo` with `mode = "background"` only for the heading. Never route
background-session code through `Subagents`, and never read "background" in a
subagent context as a `BackgroundSession`.

## Providers

The plugin advertises `clientCapabilities.subagents` to every provider; only
claude-agent-acp announces child sessions over ACP (wire format: global `acp`
skill → `references/claude-agent.md` § Native subagent sessions). opencode and
mistral-vibe subagent calls are plain `SubAgent` blocks, with no transcript.
Override points: `provider-system` skill § Adapter override points.

## Event flow

`ACPClient` records each announced child under its root session; every update
then reaches the root's subscriber with the session it arrived on as
`source_session_id`.

| Event | Handler |
| --- | --- |
| `subagent_update` | `Subagents:update` (announce, relabel, start, end) |
| `session_message` | `Subagents:message` |
| A child's tool calls | `Subagents:claim_tool_call` → its transcript |
| A child's chunks | `Subagents:agent_of_chunk` → its transcript |

Which calls a stop or an end marks: `provider-system` skill § Tool call
lifecycle.

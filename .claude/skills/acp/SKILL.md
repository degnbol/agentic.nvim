---
name: acp
description:
  Agent Client Protocol — JSON-RPC over stdio between editor frontends and AI
  agents (Claude Code via claude-agent-acp, Codex, Gemini, opencode, etc.). Use
  when working with ACP message flow (initialize, session lifecycle, tool_call,
  request_permission), debugging ACP frontends, or investigating
  provider-specific bridge quirks. For Claude Code's own config and built-in
  tool semantics, see the claude skill.
---

# Agent Client Protocol (ACP)

Reference for the ACP specification. Based on protocol version 1.

> **Scope:** ACP protocol and external bridge/SDK behaviour only. Plugin-internal
> patterns (MessageWriter, SessionManager, adapter base class, the `/trust` layer)
> live in `@lua/agentic/acp/AGENTS.md` — don't add them here.

Full spec: https://agentclientprotocol.com/protocol/overview.md

For claude-agent-acp / claude-agent-sdk internals (session _meta passthrough,
permission flow, known SDK bugs), see @references/claude-agent.md.

For opencode-specific bridge behaviour (Edit tool sequence, fuzzy match cascade,
permission timing), see @references/opencode.md.

## Communication model

JSON-RPC 2.0 over stdio (required) or streamable HTTP (optional). Two message
types: **methods** (request-response) and **notifications** (fire-and-forget).

## Lifecycle

```
1. Client -> Agent:  initialize        (negotiate version + capabilities)
2. Client -> Agent:  authenticate       (if agent requires it)
3. Client -> Agent:  session/new        (create session)
   -- or --          session/load       (resume session, requires loadSession cap)
4. Client -> Agent:  session/prompt     (send user message)
   Agent  -> Client: session/update     (notifications: chunks, tool calls, plans)
   Agent  -> Client: session/request_permission  (method, blocks until response)
   Client -> Agent:  session/cancel     (notification, optional)
   Agent  -> Client: session/prompt response  (stopReason ends the turn)
5. Repeat from step 4
```

## Initialization

`initialize` request exchanges:
- **protocolVersion** (integer, required) — major version, incremented on breaking changes
- **clientCapabilities** — `fs.readTextFile`, `fs.writeTextFile` (booleans), `terminal` (boolean)
- **agentCapabilities** — `loadSession`, `promptCapabilities` (`image`, `audio`, `embeddedContext`), `mcpCapabilities` (`http`, `sse`), `sessionCapabilities`
- **clientInfo** / **agentInfo** — `name`, `title`, `version`
- **authMethods** — array of authentication methods (agent response only)

Version negotiation: client sends latest supported version. Agent echoes it if
supported, otherwise responds with its own latest. Client disconnects if it
cannot support the agent's version.

All capabilities are optional. Omitted = unsupported. New capabilities are NOT
breaking changes.

## Session setup

### session/new

```json
{ "method": "session/new", "params": { "cwd": "/abs/path", "mcpServers": [] } }
```
Response: `{ "sessionId": "sess_..." }`

- `cwd` MUST be absolute. Serves as filesystem boundary for tool operations.
- `mcpServers`: stdio (required support), HTTP (`mcpCapabilities.http`), SSE (`mcpCapabilities.sse`, deprecated by MCP spec).

### session/load

Requires `agentCapabilities.loadSession = true`. Sends `sessionId`, `cwd`,
`mcpServers`. Agent replays entire conversation as `session/update`
notifications (`user_message_chunk`, `agent_message_chunk`, `tool_call`, etc.),
then responds to the request.

## Prompt turn

### session/prompt

```json
{ "method": "session/prompt", "params": { "sessionId": "...", "prompt": "ContentBlock array" } }
```

Baseline content: `text` and `resource_link`. Optional: `image`, `audio`,
`resource` (embedded) — gated by prompt capabilities.

### session/update (notification, agent -> client)

The `sessionUpdate` field determines the update type:

| sessionUpdate             | Purpose                                    |
| ------------------------- | ------------------------------------------ |
| `agent_message_chunk`     | Streamed text/content from the LLM         |
| `agent_thought_chunk`     | Internal reasoning (thinking)              |
| `user_message_chunk`      | Replayed user message (session/load only)  |
| `tool_call`               | New tool call created                      |
| `tool_call_update`        | Progress/completion of existing tool call   |
| `plan`                    | Agent's task plan with entries              |
| `available_commands_update` | Slash commands the agent supports         |
| `mode_update`             | Agent mode change                          |
| `usage_update`            | Token usage information                    |

### Stop reasons

`session/prompt` resolves with a response carrying `stopReason` (required) and
optional `usage`. The five reasons defined by the schema fall into two
categories:

| `stopReason`        | Origin            | Typical meaning                                          |
| ------------------- | ----------------- | -------------------------------------------------------- |
| `end_turn`          | provider (normal) | LLM finished its turn cleanly                            |
| `max_tokens`        | provider          | Output token limit hit mid-stream                        |
| `max_turn_requests` | provider          | Per-turn API request budget exhausted                    |
| `refusal`           | provider          | Agent declined to continue (safety, policy)              |
| `cancelled`         | **user**          | Resolution of an in-flight prompt after `session/cancel` |

**`cancelled` is not a failure.** The protocol uses `cancelled` as the
*expected acknowledgement* that the agent honoured a `session/cancel`
notification and tore down the in-flight turn. It is the same resolution path
the client triggers itself, so treating it as an error condition (logging,
surfacing as a fault, retrying) misrepresents the user's action. Anything that
distinguishes "successful turn" from "failed turn" should treat `cancelled`
alongside `end_turn` — not alongside `refusal`/`max_*`.

**Provider-initiated reasons are informational, not JSON-RPC errors.** They
arrive on the success path (`result`, not `error`), so client code that only
inspects `err` from `session/prompt` will silently miss them. Surface
`max_tokens`, `max_turn_requests`, and `refusal` to the user explicitly,
since the chat may otherwise look like a normal short reply.

**`usage` is optional and provider-defined.** All-zero `usage` from a
provider that normally populates it can signal upstream rejection before
tokenisation (auth failure, quota wall), but it also appears in legitimate
flows — stalled generators reusing the prompt loop, cancelled turns,
models that returned nothing. Without a protocol-level distinguisher,
treating zero usage as an error produces false positives. See
`lua/agentic/acp/AGENTS.md` § "Silent upstream failure" for a documented
provider example and one client's resulting surfacing rule.

### Cancellation

Client sends `session/cancel` notification. Agent SHOULD stop all model
requests and tool invocations, send pending updates, then respond to
`session/prompt` with `stopReason: "cancelled"`. Client MUST respond
`"cancelled"` to all pending `session/request_permission` requests.

## Tool calls

### tool_call (creation)

```json
{
  "sessionUpdate": "tool_call",
  "toolCallId": "call_001",
  "title": "Reading configuration file",
  "kind": "read",
  "status": "pending",
  "content": "ToolCallContent array",
  "locations": "ToolCallLocation array",
  "rawInput": {},
  "rawOutput": {}
}
```

**ToolKind** values: `read`, `edit`, `delete`, `move`, `search`, `execute`,
`think`, `fetch`, `other` (default).

**ToolCallStatus** values: `pending` -> `in_progress` -> `completed` | `failed`.

### tool_call_update

Same structure but only `toolCallId` is required. All other fields are optional
— only include what changed.

```json
{
  "sessionUpdate": "tool_call_update",
  "toolCallId": "call_001",
  "status": "completed",
  "content": "ToolCallContent array"
}
```

### Tool call content types

Each entry in the `content` array has a `type` field:

- **`"content"`** — standard ContentBlock (text, image, etc.) in nested `content` field
- **`"diff"`** — file modification: `path` (required, absolute), `oldText`, `newText` (required)
- **`"terminal"`** — live terminal output: `terminalId` referencing a `terminal/create` terminal

### Tool call locations

```json
{ "path": "/abs/path/to/file.py", "line": 42 }
```

Enables "follow-along" features in the client.

## Permissions

### session/request_permission (method, agent -> client)

```json
{
  "method": "session/request_permission",
  "params": {
    "sessionId": "...",
    "toolCall": { "toolCallId": "call_001" },
    "options": [
      { "optionId": "allow-once", "name": "Allow once", "kind": "allow_once" },
      { "optionId": "reject-once", "name": "Reject", "kind": "reject_once" }
    ]
  }
}
```

**PermissionOptionKind** values:
- `allow_once` — allow this operation only
- `allow_always` — allow and remember
- `reject_once` — reject this operation only
- `reject_always` — reject and remember

Client response:
```json
{ "result": { "outcome": { "outcome": "selected", "optionId": "allow-once" } } }
```
Or on cancellation:
```json
{ "result": { "outcome": { "outcome": "cancelled" } } }
```

**Important:** `optionId` is an opaque provider-assigned string, NOT the same as
`kind`. To determine the kind of a selected option, look up by `optionId` in the
original `options` array.

Clients MAY auto-approve/reject based on user settings.

## Content blocks

Used in prompts, agent messages, and tool call content.

| type            | Required cap           | Key fields                              |
| --------------- | ---------------------- | --------------------------------------- |
| `text`          | baseline               | `text`                                  |
| `resource_link` | baseline               | `uri`, `name`, `mimeType?`, `size?`     |
| `image`         | `promptCapabilities.image` | `data` (base64), `mimeType`         |
| `audio`         | `promptCapabilities.audio` | `data` (base64), `mimeType`         |
| `resource`      | `promptCapabilities.embeddedContext` | `resource.uri`, `resource.text` or `resource.blob` |

All content blocks support optional `annotations` metadata.

## Client methods (agent -> client)

| Method               | Capability             | Purpose                          |
| -------------------- | ---------------------- | -------------------------------- |
| `session/request_permission` | baseline        | Request user authorisation       |
| `fs/read_text_file`  | `fs.readTextFile`      | Read file contents               |
| `fs/write_text_file` | `fs.writeTextFile`     | Write file contents              |
| `terminal/create`    | `terminal`             | Create terminal                  |
| `terminal/output`    | `terminal`             | Get terminal output/exit status  |
| `terminal/release`   | `terminal`             | Release terminal                 |
| `terminal/wait_for_exit` | `terminal`         | Wait for command exit            |
| `terminal/kill`      | `terminal`             | Kill terminal command            |

## Agent methods (client -> agent)

| Method            | Required | Purpose                          |
| ----------------- | -------- | -------------------------------- |
| `initialize`      | yes      | Negotiate version + capabilities |
| `authenticate`    | yes      | Authenticate (if required)       |
| `session/new`     | yes      | Create session                   |
| `session/prompt`  | yes      | Send user message                |
| `session/load`    | optional | Resume session (loadSession cap) |
| `session/set_mode`| optional | Switch operating mode            |

## Agent notifications (client -> agent)

| Notification     | Purpose                    |
| ---------------- | -------------------------- |
| `session/cancel` | Cancel ongoing prompt turn |

## Protocol rules

- All file paths MUST be absolute
- Line numbers are 1-based
- JSON-RPC 2.0 error handling: `result` on success, `error` object on failure
- Notifications never receive responses
- Extensibility: `_meta` fields for custom metadata, `_`-prefixed methods for custom methods

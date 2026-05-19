# Pi coding agent support in agentic.nvim

## Overview

[Pi](https://pi.dev) is a minimal terminal coding harness. It has its own RPC
protocol (JSONL over stdio), not ACP. Supporting Pi in agentic.nvim means
writing a new transport + event adapter comparable in scope to the existing
opencode adapter.

## Pi's RPC protocol

- `pi --mode rpc` runs in headless mode, communicating via JSONL over stdio
- Commands (stdin): `prompt`, `steer`, `follow_up`, `abort`, `new_session`,
  `set_model`, `bash`, etc.
- Events (stdout): `agent_start`, `agent_end`, `message_update`,
  `tool_execution_start`, `tool_execution_update`, `tool_execution_end`,
  `turn_start`, `turn_end`, etc.
- Extension UI protocol for user interaction: `extension_ui_request` (select,
  confirm, input) via stdout, `extension_ui_response` via stdin
- Responses: `{"type": "response", "command": "...", "success": true/false}`

Documentation: https://pi.dev/docs/latest/rpc

## Effort estimate

### New files

| File | Lines | Purpose |
|---|---|---|
| `lua/agentic/acp/adapters/pi_adapter.lua` | ~300-400 | Maps Pi events to agentic.nvim internals |
| `lua/agentic/acp/pi_transport.lua` | ~200-300 | JSONL transport for Pi's RPC protocol |

### What the adapter needs to map

| Pi event | agentic.nvim equivalent |
|---|---|
| `message_update` (text_delta) | `agent_message_chunk` |
| `message_update` (toolcall_*) | Tool call start/update |
| `tool_execution_start` | Tool call block creation |
| `tool_execution_update` | Streaming tool output update |
| `tool_execution_end` | Tool call completed/failed |
| `extension_ui_request` (select/confirm) | `request_permission` + user response |
| `agent_end` | Turn complete → clear generating indicator |
| `turn_start` / `turn_end` | Turn boundary tracking |

### What the adapter doesn't need to handle

- Session lifecycle (Pi manages sessions internally)
- Mode switching (Pi has modes but they're extension-defined)
- Compaction (Pi handles this internally)

### Config entry (~10 lines)

Add to the provider config table (`config_default.lua` or user config):

```lua
["pi"] = {
    name = "Pi",
    command = "pi",
    args = { "--mode", "rpc", "--no-session" },
}
```

### Known differences from ACP providers

1. **No `request_permission` concept** — Pi has no permission popups
   (listed as "what we didn't build"). Instead, extensions use `ctx.ui.select()`
   / `ctx.ui.confirm()` which map to `extension_ui_request` in RPC mode.
   The adapter would need to intercept these and present them as permission
   prompts in the agentic.nvim UI.

2. **Tool execution events are separate** — Pi emits distinct
   `tool_execution_start`/`update`/`end` events rather than reusing the
   message streaming for tool state changes. This is cleaner for the adapter
   but requires separate event routing.

3. **No SubAgents built-in** — same gap as opencode. Would need custom
   extension or tmux-based spawning.

4. **No built-in slash commands** — Pi uses prompt templates (`.md` files)
   and extensions for custom commands. The adapter would need to either
   forward `/` commands via `prompt` or intercept them locally.

5. **No plan/todo update** — Pi doesn't emit plan events. The todos panel
   would be unused with Pi.

## Next steps

1. Install Pi: `npm install -g @earendil-works/pi-coding-agent`
2. Test basic RPC interaction: `pi --mode rpc --no-session` with manual
   JSONL input
3. Prototype the transport layer — parse Pi's JSONL framing, dispatch events
4. Prototype the adapter — map each Pi event type to agentic.nvim's
   subscriber callbacks
5. Test with agentic.nvim in a headless session
6. Document provider setup in README
# Pi coding agent support in agentic.nvim

## Overview

[Pi](https://pi.dev) is a minimal terminal coding harness. It has its own RPC
protocol (JSONL over stdio), not ACP. Supporting Pi in agentic.nvim means
writing a new transport + event adapter comparable in scope to the existing
opencode adapter.

## Pi's RPC protocol

- `pi --mode rpc` runs in headless mode, communicating via JSONL over stdio
- Commands (stdin): `prompt`, `steer`, `follow_up`, `abort`, `new_session`,
  `set_model`, `bash`, etc.
- Events (stdout): `agent_start`, `agent_end`, `message_update`,
  `tool_execution_start`, `tool_execution_update`, `tool_execution_end`,
  `turn_start`, `turn_end`, etc.
- Extension UI protocol for user interaction: `extension_ui_request` (select,
  confirm, input) via stdout, `extension_ui_response` via stdin
- Responses: `{"type": "response", "command": "...", "success": true/false}`

Documentation: https://pi.dev/docs/latest/rpc

## Effort estimate

### New files

| File | Lines | Purpose |
|---|---|---|
| `lua/agentic/acp/adapters/pi_adapter.lua` | ~300-400 | Maps Pi events to agentic.nvim internals |
| `lua/agentic/acp/pi_transport.lua` | ~200-300 | JSONL transport for Pi's RPC protocol |

### What the adapter needs to map

| Pi event | agentic.nvim equivalent |
|---|---|
| `message_update` (text_delta) | `agent_message_chunk` |
| `message_update` (toolcall_*) | Tool call start/update |
| `tool_execution_start` | Tool call block creation |
| `tool_execution_update` | Streaming tool output update |
| `tool_execution_end` | Tool call completed/failed |
| `extension_ui_request` (select/confirm) | `request_permission` + user response |
| `agent_end` | Turn complete → clear generating indicator |
| `turn_start` / `turn_end` | Turn boundary tracking |

### What the adapter doesn't need to handle

- Session lifecycle (Pi manages sessions internally)
- Mode switching (Pi has modes but they're extension-defined)
- Compaction (Pi handles this internally)

### Config entry (~10 lines)

Add to the provider config table (`config_default.lua` or user config):

```lua
["pi"] = {
    name = "Pi",
    command = "pi",
    args = { "--mode", "rpc", "--no-session" },
}
```

### Known differences from ACP providers

1. **No `request_permission` concept** — Pi has no permission popups
   (listed as "what we didn't build"). Instead, extensions use `ctx.ui.select()`
   / `ctx.ui.confirm()` which map to `extension_ui_request` in RPC mode.
   The adapter would need to intercept these and present them as permission
   prompts in the agentic.nvim UI.

2. **Tool execution events are separate** — Pi emits distinct
   `tool_execution_start`/`update`/`end` events rather than reusing the
   message streaming for tool state changes. This is cleaner for the adapter
   but requires separate event routing.

3. **No SubAgents built-in** — same gap as opencode. Would need custom
   extension or tmux-based spawning.

4. **No built-in slash commands** — Pi uses prompt templates (`.md` files)
   and extensions for custom commands. The adapter would need to either
   forward `/` commands via `prompt` or intercept them locally.

5. **No plan/todo update** — Pi doesn't emit plan events. The todos panel
   would be unused with Pi.

## Next steps

1. Install Pi: `npm install -g @earendil-works/pi-coding-agent`
2. Test basic RPC interaction: `pi --mode rpc --no-session` with manual
   JSONL input
3. Prototype the transport layer — parse Pi's JSONL framing, dispatch events
4. Prototype the adapter — map each Pi event type to agentic.nvim's
   subscriber callbacks
5. Test with agentic.nvim in a headless session
6. Document provider setup in README

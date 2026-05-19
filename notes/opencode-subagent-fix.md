# Fixing opencode SubAgent deadlock

## Problem

When opencode spawns a SubAgent via the `task` tool, the ACP bridge silently
drops `permission.asked` events from the subagent session, deadlocking the
entire prompt chain.

## Root cause

`packages/opencode/src/acp/agent.ts:195-198`:

```ts
case "permission.asked": {
    const permission = event.properties
    const session = this.sessionManager.tryGet(permission.sessionID)
    if (!session) return  // ← subagent session not in ACP session manager
```

The subagent session is created internally by the SDK at `task.ts:71`
(`sessions.create({ parentID })`), not through the ACP bridge's
`session/new`. When the subagent tool tries to execute any tool that needs
permission, the SDK emits `permission.asked`, the ACP bridge skips it
because `tryGet` returns null, and the permission is never replied to.

### Deadlock chain

1. Subagent tool execution blocks waiting for permission response
2. Subagent LLM turn never completes (blocked on tool result)
3. `ops.prompt()` at `session/prompt.ts:126` never returns
4. `task.execute()` at `task.ts:136-152` never returns
5. Parent SDK can't send tool result back to parent LLM
6. Parent `this.sdk.session.prompt()` at `agent.ts:1495` never returns
7. ACP bridge never sends the `session/prompt` response
8. agentic.nvim's `is_generating` stays `true` forever

## Fix

Auto-approve permissions for subagent sessions whose parent ACP session has
already approved the task tool invocation. The parent session implicitly
trusts the subagent by virtue of spawning it, so auto-approving its
permissions is safe — they would have been automatically handled by the
internal permission system during CLI use anyway.

### Changes (3 locations, ~15 lines)

**File: `packages/opencode/src/acp/agent.ts`**

#### 1. New field

Add a `Map<string, string>` mapping subagent session IDs to parent ACP
session IDs.

```ts
private subagentParents = new Map<string, string>()
```

#### 2. Populate mapping at task tool completion

When the `task` tool's completed update arrives (`message.part.updated`,
`case "completed"`), the subagent session ID is available in
`part.state.metadata.sessionId`. Store it mapped to the current ACP session
(`sessionId`).

Insert at line ~405, after `rawOutput` is constructed:

```ts
if (part.state.metadata?.sessionId) {
    this.subagentParents.set(part.state.metadata.sessionId, sessionId)
}
```

The task tool pushes this metadata at `task.ts:112-118` via
`ctx.metadata({ metadata: { sessionId: nextSession.id, ... } })`.

#### 3. Auto-approve in permission.asked handler

In the `permission.asked` handler, when `session` is null and a parent
session is found in the map, auto-approve with `"once"` using the parent
session's cwd.

Change lines 195-198 (currently `if (!session) return`) to:

```ts
if (!session) {
    const parentId = this.subagentParents.get(permission.sessionID)
    if (parentId) {
        const parent = this.sessionManager.tryGet(parentId)
        if (parent) {
            await this.sdk.permission.reply({
                requestID: permission.id,
                reply: "once",
                directory: parent.cwd,
            })
        }
    }
    return
}
```

### What this does NOT do

- **No forwarding of subagent streaming** — `message.part.delta` and
  `message.part.updated` events from the subagent are still dropped. The
  subagent's output arrives bundled as the `completed` tool_call_update's
  body, same as today. The subagent's intermediate tool calls (if any)
  are not surfaced in the parent chat.

- **No forwarding of subagent permission prompts to the ACP client** —
  the agentic.nvim user never sees the subagent's permission requests
  in the chat. The fix auto-approves them silently. This matches the
  intent of "the parent trusts the subagent."

### Safety

- The permission is only auto-approved when a parent→child mapping exists.
- Unrelated SDK sessions (no parent) are not affected.
- `"once"` is used rather than `"always"` so each subagent tool call
  independently requires a mapping entry — no stale approvals accumulate.

## Caveat: incomplete vs "once" semantics

The tool's `ctx.ask()` call at `task.ts:45-54` uses `always: ["*"]` which
in the CLI means "cache this decision for the session." With our fix, every
permission asks the bridge, which checks the mapping. The permission is
replied `"once"` so the tool executes once. The tool reports success to the
LLM, the LLM continues. If the tool calls `ctx.ask` again (e.g. the next
tool), a new `permission.asked` event fires, and the mapping check fires
again.

This is semantically equivalent to "allow once per tool call" which is the
ACP client's default anyway. No divergence from how the normal ACP flow
works.

## Testing

Manual test with agentic.nvim:

1. Set provider to opencode
2. Send a prompt that causes a SubAgent spawn:
   ```
   Use the task tool to search the codebase for all references to SessionManager
   ```
3. Verify the SubAgent block renders in the chat
4. Verify the SubAgent transitions from `pending` → `generating` → `completed`
5. Verify the generating indicator clears
6. Verify the parent agent continues with the subagent's results

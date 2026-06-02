# Plan: render PreToolUse-hook-blocked tool calls as `blocked`, not `failed`

## Goal

A tool call denied by a **PreToolUse** hook never ran. Today it renders
identically to a tool that ran and exited non-zero: `failed` status + red
`console` failure body. Distinguish it: a new `blocked` status (icon `⊘`,
error-red highlight) and a dimmed, folded `markdown` reason body, with a
`Blocked by PreToolUse hook` lead line.

## Verified facts (do not re-litigate)

Source references are by function/section name rather than line number — the
upstream files are large and the numbers drift between versions. Find the named
function to confirm.

- **No structured ACP signal.** The bridge maps every `is_error` tool result to
  `status: "failed"` + `rawOutput: chunk.content` (claude-agent-acp
  `dist/acp-agent.js`, the `toolUpdateFromToolResult` path —
  `chunk.is_error ? "failed" : "completed"`). Verified on the installed
  `@agentclientprotocol/claude-agent-acp` v0.39.0. Hook-block vs ran-and-failed
  are indistinguishable except by the text.
- **The reliable, specific marker.** Claude Code's
  `getPreToolHookBlockingMessage` (`claude-code-private/src/utils/hooks.ts`)
  emits exactly:
  `` `${hookName} hook error: ${blockingError.blockingError}` `` where
  `hookName ∈ {PreToolUse:Bash, PreToolUse:Write, PreToolUse:Edit, PreToolUse:<Tool>}`.
  Fallback when the hook gave no message (`toolExecution.ts`, the
  `Execution stopped by PreToolUse hook` branch building
  `tool_result{is_error: true, content: errorMessage}`):
  `Execution stopped by PreToolUse hook[: <reason>]`.
- **PreToolUse exit 2 / JSON `deny` is the only "never ran" case**
  (`hooks.ts`, exit-2 = the hook protocol's block code). Other non-zero exits
  show stderr to the *user only* and the tool *still runs* — they don't produce
  a failed tool_result, so they never reach this path. **Caveat:** a
  *misconfigured* hook (missing script) also exits 2 and is indistinguishable
  from a deliberate block — it will render as `blocked` with the hook's stderr
  (e.g. a traceback) in the reason body. Acceptable: the body is
  self-explanatory.
- **PostToolUse blocks must NOT match.** `PostToolUse:<Tool> hook error:` means
  the tool *already ran* (different formatter, `getStopHookMessage`-family).
  Anchor the match on `PreToolUse:` specifically.
- **The hook script path is not available.** `hookName` is `PreToolUse:Bash`
  (event:tool), not a script path. The `[~/.config/.../foo.sh]:` prefix in the
  motivating example is *that hook's own stderr text*, not metadata. So the lead
  line is the generic `Blocked by PreToolUse hook`; any path lives inside the
  reason body verbatim.
- **Claude providers only.** Other providers' guards use different text.
  Detection belongs in the claude adapter, not the generic renderer. **Two
  Claude providers share this text:** `claude-agent-acp` (default, what we use)
  and `claude-acp` (command `claude-code-acp`, the older bridge). This plan
  scopes to `claude-agent-acp`. `claude-acp` does not override
  `__build_tool_call_update`, so it would still render hook-blocks as `failed`;
  since the detection helper lives in shared `claude_utils.lua`, adopting
  `claude-acp` later means adding the same one-method override there. Out of
  scope now (we don't use `claude-acp`).

## Design decisions (settled with user)

- New `blocked` status, icon `⊘`, highlight reuses error red (`STATUS_FAILED`).
- Reason body is folded (`markdown-fold` when multi-line, `markdown` when single)
  and dimmed (`AgenticDimmedBlock`) — mirrors the fetch/WebSearch/SubAgent
  sidecar treatment.

## Status-type: option B (decided)

`agentic.acp.ToolCallStatus` (the `@alias` in `acp_client.lua`) aliases the
*protocol* statuses (pending/in_progress/completed/failed). `blocked` is a
client invention, so it does NOT go there.

Add a plugin alias
`agentic.ui.ToolCallDisplayStatus = agentic.acp.ToolCallStatus | "blocked"`,
retype the `@field status` on `ToolCallBlock` in
`lua/agentic/ui/message_writer.lua` and the status→icon/hl tables to it. Keeps the ACP alias honest; consistent with the
plugin already inventing client-side *kinds* (`SubAgent`, `Skill`). The protocol
status genuinely *was* `failed` on the wire — this preserves that truth while
letting the display say `blocked`.

## Changes

### 1. `lua/agentic/acp/adapters/claude_utils.lua` — detection helper

Add:

```lua
--- Detect a blocking PreToolUse hook denial in a failed tool's output and
--- return the reason text with the Claude-added prefix stripped.
--- Claude formats these as "PreToolUse:<Tool> hook error: <reason>"
--- (utils/hooks.ts getPreToolHookBlockingMessage) or, with no hook message,
--- "Execution stopped by PreToolUse hook[: <reason>]" (toolExecution.ts).
--- Both mean the tool never ran. PostToolUse blocks (tool already ran) are
--- deliberately NOT matched.
--- @param reason_lines string[] failure reason split into lines
--- @return string[]|nil reason stripped reason lines, or nil if not a PreToolUse block
function M.pretool_block_reason(reason_lines)
```

(The module table in `claude_utils.lua` is the local `M` — define as
`function M.pretool_block_reason`, NOT `ClaudeUtils.…` which would assign a nil
global and silently fail. The *caller* in the adapter uses `ClaudeUtils.…`
because the adapter binds `require(...)` as `ClaudeUtils`.)

Logic:
- Empty input → nil.
- First line matches `^PreToolUse:%S+ hook error:%s*` → strip that prefix from
  line 1, keep remaining lines. Drop a now-empty leading line.
- Else first line matches `^Execution stopped by PreToolUse hook:?%s*` → strip;
  may yield empty body (header-line-only render is fine).
- Else → nil.
- Return the (possibly empty) line array on match; the caller treats empty as
  "blocked, no reason body".

### 2. `lua/agentic/acp/adapters/claude_agent_acp_adapter.lua` — flip status

In `ClaudeAgentACPAdapter:__build_tool_call_update`, replace the existing
`if update.status == "failed" then message.failure_reason = ... end` block with:

```lua
if update.status == "failed" then
    local reason = self:extract_failure_reason(update.rawOutput)
    local block_reason = ClaudeUtils.pretool_block_reason(reason or {})
    if block_reason then
        message.status = "blocked"
        message.failure_reason = block_reason  -- may be {}
    else
        message.failure_reason = reason
    end
end
```

`failure_reason` already carries the reason body for both paths — no new field.

### 3. `lua/agentic/ui/tool_call_renderer.lua` — `blocked` render branch

In the public `M.prepare_block_lines`, add a branch **before** the existing
`tool_call_block.status == "failed" and failure_reason ...` branch:

```lua
if tool_call_block.status == "blocked" then
    table.insert(lines, "Blocked by PreToolUse hook")
    table.insert(highlight_ranges, { type = "comment", line_index = #lines - 1 })
    if failure_reason and #failure_reason > 0 then
        local wrapped = TextWrap.wrap_prose(failure_reason, wrap_width)
        local fence = safe_fence(wrapped)
        local use_fold = #wrapped > 1
        table.insert(lines, fence .. (use_fold and "markdown-fold" or "markdown"))
        local body_start = #lines
        if use_fold then fold_anchor = body_start end
        vim.list_extend(lines, wrapped)
        dim_range = { body_start, #lines - 1 }
        table.insert(lines, fence)
    end
elseif tool_call_block.status == "failed" and failure_reason and #failure_reason > 0 then
    ... (unchanged)
```

Notes:
- For `execute`, the `### Execute` heading + command fence still render above
  (unchanged) — the command stays visible; only the *body* becomes the blocked
  reason. Matches the mockup.
- `TextWrap` + `wrap_width` are already in scope (the `dim_range`/`fold_anchor`
  pattern copied here mirrors the fetch/WebSearch/SubAgent branch verbatim).
- The execute-body-range locator (the block keyed on `kind == "execute" and
  tool_call_block.body`) is unaffected — a blocked block has no `body`, only
  `failure_reason`.

### 4. `lua/agentic/config_default.lua` — icon

In the `status_icons` table: add `blocked = "⊘"`.

### 5. `lua/agentic/theme.lua` — highlight

In the `status_hl` table: add `blocked = Theme.HL_GROUPS.STATUS_FAILED` (error
red). `Theme.get_status_hl_group` already falls back via `status_hl[status]`, so
the generic footer path (`apply_status_footer`) renders the new status without
further change. No new highlight group → no README change.

### 6. Type alias (per decision B)

- `acp_client.lua`: leave the `agentic.acp.ToolCallStatus` `@alias` untouched;
  add `--- @alias agentic.ui.ToolCallDisplayStatus agentic.acp.ToolCallStatus | "blocked"`.
- `lua/agentic/ui/message_writer.lua`: retype the `@field status` on
  `ToolCallBlock` to the new alias.

## Tests

- `claude_utils` (new or existing test file): `pretool_block_reason`
  - positive: `PreToolUse:Bash hook error: foo` → `{"foo"}`;
    multi-line reason preserved; `Execution stopped by PreToolUse hook` →
    `{}`.
  - negative: `PostToolUse:Bash hook error: x` → nil; normal bash stderr → nil;
    `{}` → nil.
- `claude_agent_acp_adapter.test.lua`: a `failed` update whose `rawOutput` is a
  PreToolUse block → `message.status == "blocked"` + stripped `failure_reason`;
  a normal `failed` update → status stays `failed`, full reason.
- `tool_call_renderer.test.lua`: a `blocked` block → lines contain
  `Blocked by PreToolUse hook`, a `markdown`/`markdown-fold` fence, and
  `dim_range` set; assert no `console` red body. Extend the existing
  `describe("failure_reason rendering", ...)` block rather than a parallel one
  (repo testing convention).

## Validation

`make validate` after each Lua change (luals + selene + tests). Read the log
file on failure (`.local/agentic_{luals,selene,test}_output.log`) with `tail`/`rg`.

## Out of scope / explicitly not doing

- Showing the hook *script path* in the header (not available — see facts).
- Detecting PostToolUse/Stop/UserPromptSubmit blocks (different "did it run"
  semantics; PostToolUse already ran).
- Cross-provider hook-block detection (text formats differ).
```
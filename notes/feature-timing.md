# Plan: tool-call execution timing

## Problem

Slow tool calls give no signal — a 2-minute build and a 2-second linter
render identically. Slow runs are how regressions and accidental scale
problems surface, and nothing today nudges the user or the model to
notice.

A prior PreToolUse → PostToolUse hook approach in dotfiles over-counted
permission-prompt wait time (the user being AFK on an `ask` prompt was
attributed to the command), and was removed.

## What agentic.nvim sees that a generic hook can't

The ACP client mediates permission itself, so the timeline separates
wait from work:

1. **`on_tool_call` (status=`pending`)** — `acp_client.lua:597`. The
   provisional start, used when no permission request follows.
2. **Permission request arrives** (if needed) — queued in
   `permission_manager.lua`.
3. **Permission response sent.** Five sites:
   - read-only ACP kinds auto-approve, `permission_manager.lua:276`
   - compound Bash auto-approve, `:297` — matches each segment against
     the merged allow-pattern list resolved by `PermissionRules`. The
     allow list is `read_only` patterns plus, when
     `Config.permissions.auto_approve == "allow"`, `safe_write` patterns
     (commands that mutate but in known-safe ways). With
     `"read-only"`, only `read_only` patterns. Single callback site
     either way.
   - allow_always cache hit, `:310`
   - trust-scope auto-approve, `:334`
   - manual user selection, `:776`
   Each calls `callback(option_id)`. This is when execution actually
   starts.
4. **SDK invokes the tool.** After `await this.client.requestPermission`
   returns inside `canUseTool` (`dist/acp-agent.js:788` in
   `@agentclientprotocol/claude-agent-acp`), control returns to the SDK
   and `tool.call` runs.
5. **`on_tool_call_update` (status=`completed`|`failed`)** —
   `acp_client.lua:623`. The end.

`t_step5 − t_step3` is the execution duration. Permission wait time is
never counted.

## Goal

- Compute duration for every tool call from `t_pending` or
  `t_perm_resolved` (whichever applies) to terminal status.
- Render `[took 5s]` inline on every completed tool-call block in the
  chat UI. Dim short durations so fast calls aren't noisy.
- Inject timing into the next user prompt for tool calls that exceeded
  a slower threshold, so the model sees runtime context for slow runs.
- Flag very slow calls more prominently for the user.

## State location

Per-call timing lives as fields on `MessageWriter.tool_call_blocks[id]`,
not in a separate module-level map. This:

- Inherits per-session ownership — cleanup comes for free when a
  SessionManager is destroyed (provider switch, `/new`, tabpage close).
- Avoids leaks from cancelled turns and stalled generators (see
  CLAUDE.md "Prompt loop stall").
- Keeps timing alongside the data it annotates.

Tracker entry gains:

```
started_at: number      -- vim.uv.now() at on_pending OR on_permission_resolved
perm_resolved: boolean  -- true if started_at was overwritten by perm callback
duration_ms: number?    -- set on terminal status, used by the renderer
```

## Wire-up

1. **`acp/acp_client.lua` `__handle_tool_call`** — set
   `tracker.started_at = vim.uv.now()` before notifying the subscriber.
2. **`ui/permission_manager.lua`** — at each of the five callback sites
   (`:276`, `:297`, `:310`, `:334`, `:776`), look up the tracker by
   `tool_call_id` and overwrite `started_at = vim.uv.now()` (unless the
   decision is a reject — then drop the entry). Set
   `perm_resolved = true`.
3. **`acp/acp_client.lua` `__handle_tool_call_update`** — on `completed`
   or `failed`, compute `duration_ms = vim.uv.now() - started_at` and
   stash it on the tracker. Pass through to the renderer.
4. **`ui/tool_call_renderer.lua`** — render `[took Ns]` as a trailing
   footer fragment (dimmed under `user_show_threshold_ms`).
5. **Prompt submit path** (`session_manager.lua` input handling) — when
   composing the next user prompt, walk `tool_call_blocks` for the
   previous turn and prepend a synthetic prefix
   (`[meta: Bash took 2m 14s; Read /etc/foo took 5s]`) for any call
   above `model_threshold_ms`. Clear the tracker entry's flag after
   reading so the same timing isn't repeated next turn.

The model-prompt injection is the only path that actually reaches the
model. The rendered chat buffer is UI — on session resume the SDK
replays its own conversation history, not the plugin's buffer, so
timing text rendered into the block is invisible to the model.

## Thresholds

- `user_show_threshold_ms = 0` — always render, dim if below
  `user_emphasis_threshold_ms`.
- `user_emphasis_threshold_ms = 3000` — bold / `[slow]` tag for runs
  above this; default colour otherwise.
- `model_threshold_ms = 3000` — inject into next user prompt for runs
  above this. Below this, model never sees the timing.
- `very_slow_threshold_ms = 60000` — additional emphasis for the user
  (e.g. warn-coloured `[took 2m 14s]`).

All under `config.timing = { ... }`.

## Edge cases

- **`run_in_background: true`** — the tool returns a `backgroundTaskId`
  almost immediately; the terminal status fires in milliseconds, not at
  process exit. Detect via the tracker's accumulated `rawInput`
  (`tool_call_blocks[id].raw_input.run_in_background`, not the
  `tool_call_update` — `rawInput` arrives only on the initial
  `tool_call`). Skip rendering for these.
- **Parallel tool calls.** Keyed by `toolCallId`, concurrency is fine.
- **Rejected calls.** Drop the tracker's timing fields on the rejection
  callback. No execution to time.
- **Cancelled long-running calls** (`<C-c>` hard abort, `4` reject-all
  on subsequent items in a batch). The original turn was already
  in-flight; render the partial duration up to the cancel point — the
  reason for cancelling is often *because* it was long, so the partial
  number is useful signal. Mark visibly as cancelled.
- **`failed` status.** Render duration with the failure label — a
  90-second typecheck that errors out is exactly the kind of signal
  this feature exists for.

## Out of scope

- Replacing the dotfiles bash-time hook for non-agentic frontends
  (claude TUI, headless, other ACP clients). Those can't see permission
  resolution accurately without source patches.
- Cross-tool aggregate timing ("you've spent N minutes in Bash this
  session"). Possible follow-up.
- Persisting timings across sessions / regression detection across
  runs. The signal is "is this run slower than I'd expect", judged
  in-context.

# Plan: inject a context-usage notice past a threshold

> **Scope.** Tell the *model* how full its context window is, but only when it
> crosses a usage threshold — so it can adjust behaviour near a handover
> boundary (plan instead of implement, checkpoint a handoff to disk before
> compaction). Pull-on-demand (an MCP tool the model calls) was rejected: the
> model has no trigger to ask, so it never would. This is push, gated to fire
> only when the number becomes decision-relevant. Provider-agnostic in
> principle, but built in the plugin because the authoritative `used`/`size`
> already arrives via `usage_update` — a Claude hook would have to reparse the
> transcript JSONL and hardcode the window size per model.

## What we already have

- `usage_update` is handled in `SessionManager:_handle_session_update`
  (`session_manager.lua:421`). It stores
  `self._usage = { used, size, cost }` — `used` = tokens currently in
  context, `size` = window size — and refreshes the chat header.
- The same numbers are already shown to the *user* via the intercepted
  `/context` command (`:461`) and the header footer (`:1203`). The model
  never sees them.
- Prompt context is assembled in `SessionManager:_build_environment_info`
  (returns the `<environment_info>` block, `:2181`). This is the natural
  injection site — it already carries cwd, git status, recent commits,
  project root, and is sent with the prompt.

## Design

Two small pieces, plus config.

### 1. Threshold detection in the `usage_update` handler

Track which 10%-bucket (configurable step) the usage has reached. When it
advances to a new bucket *and* is at/above the floor threshold, set a pending
flag. Bucket state lives on the per-tabpage `SessionManager` instance
(`self._usage_bucket`) — correct under multi-tabpage isolation, where a global
hook could not cleanly track per-session state.

```lua
elseif update.sessionUpdate == "usage_update" then
    self._usage = { used = update.used, size = update.size, cost = update.cost }

    local pct = update.size and update.size > 0 and update.used / update.size or 0
    local step = Config.context_notice_step or 0.1
    local floor = Config.context_notice_threshold or 0.5
    local bucket = math.floor(pct / step)
    if pct >= floor and bucket > (self._usage_bucket or 0) then
        self._usage_bucket = bucket
        self._pending_usage_notice = true
    end

    self:_update_chat_header()
```

Notes:
- Bucket only ever advances, so the notice fires once per crossing, never
  every turn → no spam below the line, no repeat within a band.
- A new session starts with `_usage_bucket = nil` → first crossing fires.
- After compaction `used` drops; the bucket falls, and the *next* crossing
  upward re-arms naturally. (If we want an explicit "context was compacted"
  notice later, that's a separate follow-up — out of scope.)

### 2. Emit the line in `_build_environment_info`

Append one line, then clear the flag, just before the `<environment_info>`
wrap (`:2181`):

```lua
if self._pending_usage_notice and self._usage and self._usage.size > 0 then
    res = res .. string.format(
        "\n- Context: %.0fk/%.0fk tokens (%.0f%% full) — near a handover"
            .. " boundary; consider checkpointing a plan/handoff to disk.",
        self._usage.used / 1000,
        self._usage.size / 1000,
        self._usage.used / self._usage.size * 100
    )
    self._pending_usage_notice = false
end
```

Consuming the flag here (not in the handler) couples the notice to an actual
prompt send — if several `usage_update`s arrive before the next prompt, the
user still sees exactly one line, reflecting the latest usage.

### 3. Config

In `config_default.lua`:

```lua
--- Inject a context-usage notice into environment_info when usage first
--- crosses this fraction of the window, and again at each `context_notice_step`
--- band above it. Set to false to disable.
context_notice_threshold = 0.5,
--- Band width for repeat notices above the threshold (0.1 = every 10%).
context_notice_step = 0.1,
```

Gate both reads on `Config.context_notice_threshold ~= false` so a single
`false` disables the feature.

## Field declarations

Add to the `SessionManager` class block (LuaCATS, contiguous):

```lua
--- @field _usage? { used: number, size: number, cost?: number }   -- if not already typed
--- @field _usage_bucket? number Highest usage band already announced this session
--- @field _pending_usage_notice? boolean Emit a context notice on the next prompt
```

(`_usage` may already be implicitly typed — check before adding.)

## Test

`session_manager.test.lua` (or a focused new spec): drive
`_handle_session_update` with synthetic `usage_update`s and assert
`_pending_usage_notice`:

- below threshold (e.g. 0.4 with floor 0.5) → not set
- first crossing (0.55) → set; `_build_environment_info` contains "Context:"
  and clears the flag
- second `usage_update` in the same band (0.58) → not re-set
- next band up (0.65) → set again
- drop after compaction (0.30) then back up across floor → re-arms

Mock `Config` values in the test so it doesn't depend on defaults.

## Out of scope

- MCP `context_usage()` tool for explicit mid-task queries. Add only if a
  workflow ever instructs the model to poll its own context.
- A distinct post-compaction notice.
- Surfacing cost (`self._usage.cost`) to the model — the user already sees it.

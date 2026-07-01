# Plan: handle the `session_info_update` session update

> **Scope.** Stop the `⚠️ Unknown session update: session_info_update` warning
> and adopt the title the provider pushes. Not a local regression — the
> `else`/warn branch (`session_manager.lua:429`) has always been there; the
> `@agentclientprotocol/claude-agent-acp` bridge started emitting a new update
> type. We just don't have a branch for it.

## Origin

`claude-agent-acp` ≥ 0.54 added `maybeUpdateSessionTitle`
(`dist/acp-agent.js:507`): at turn-end the bridge reads the SDK-maintained
session info and, when the title changed, pushes

```
{ sessionUpdate = "session_info_update", title = <string>, updatedAt = <ISO8601> }
```

`title` is `customTitle` (a `/rename` inside the SDK) if set, else `summary`
(the SDK's auto-generated title, or the first prompt). The SDK has no push
event for the background-generated title, so the bridge pulls it once per turn.

## Design

Prefer the SDK's auto-summary over the first-prompt title, but never over a
user `/rename`. Track whether the title was user-set and gate on that.

### 1. Flag the user rename

`_rename_session` (`:497`) is the only user-driven title path. Set a flag there:

```lua
self._title_user_set = true
```

The first-prompt title set (`:1371`) leaves the flag false, so the summary can
still override that placeholder.

### 2. The `session_info_update` branch

One `elseif`, before the `else`:

```lua
elseif update.sessionUpdate == "session_info_update" then
    -- Provider pushes the SDK's background-generated title at turn-end.
    -- Adopt it unless the user has chosen a title via /rename.
    if update.title and update.title ~= "" and not self._title_user_set then
        self.chat_history.title = update.title
        self.widget:set_chat_title(update.title)
        self:_sync_history_context()
        self.chat_history:save()
    end
```

Not `_rename_session`: that writes a `"Session renamed to…"` chat message and
calls `finalize_turn` — wrong for a silent background update. (And it would set
`_title_user_set`, wrongly locking out later summaries.)

### Why a flag, not an empty-title check

The plugin's `/rename` is client-side only — it never reaches the SDK's
`customTitle`, so the bridge always sends its `summary`. An empty-title guard
would either lose the summary (the first-prompt path already filled the title)
or clobber a `/rename` (both are non-empty and indistinguishable). The
`_title_user_set` flag is the only thing that separates "user chose this" from
"placeholder we're happy to replace".

`_title_user_set` also needs restoring on `session/load` — a restored session
whose title came from a past `/rename` must stay locked. Set it in the restore
paths (`:1878`, `:2256`) when the restored title is non-empty. (Can't perfectly
distinguish a restored auto-title from a restored rename; treating any restored
title as locked is the safe default — a stale auto-title just stops updating.)

## Type annotation

Add the update shape to `acp_client.lua` (near the other
`SessionUpdateMessage` variants, `:1238`+):

```lua
--- @class agentic.acp.SessionInfoUpdateMessage
--- @field sessionUpdate "session_info_update"
--- @field title string
--- @field updatedAt string
```

and add it to the `SessionUpdateMessage` union alias if one exists.

## Test

`session_manager.test.lua`: drive `_on_session_update` with a synthetic
`session_info_update`.

- empty title on the manager → adopts: `chat_history.title` becomes the pushed
  title, `set_chat_title` called, `save` called.
- non-empty title already set → ignored: title unchanged, no `save`.
- empty pushed `title` → ignored.

Stub `widget:set_chat_title`, `_sync_history_context`, `chat_history:save`.

## Out of scope

- Propagating client `/rename` into the SDK's `customTitle` so the bridge
  prefers it (would need an SDK-side rename channel).
- Replacing the first-prompt title with the SDK summary.
- Using `updatedAt` for anything (session cache mtime is separate).

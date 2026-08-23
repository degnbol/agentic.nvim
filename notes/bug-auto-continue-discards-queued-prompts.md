# Bug: auto-continue discards every message queued during a usage-limit pause

Line numbers against `bbbfe7e`. Filed in `TODO.md` as "Auto-continue queued
messages not shown in chat", which understates it: the message is never sent, not
merely never displayed.

## Mechanism

The retry timer's callback reads `_queued_prompts` *after* clearing it:

```lua
vim.schedule_wrap(function()
    M.cancel_retry_timer(sm, false)   -- session_recovery.lua:432
    ...
    local queued = sm._queued_prompts -- :446 — always nil
    sm._queued_prompts = nil
    if queued then
        sm:_handle_input_submit(table.concat(queued, "\n\n"))
    else
        sm:_handle_input_submit("continue")
    end
end)
```

`cancel_retry_timer`'s `sm._queued_prompts = nil` (`:276`) sits **outside** the
`if reset_attempts ~= false` conditional, so passing `false` does not spare it. The
read at `:446` is therefore always `nil`, the `if queued` branch is unreachable,
and auto-continue always sends the literal `"continue"`.

Everything the user typed during the pause is dropped, having already been taken
out of the input buffer at `:1663` and acknowledged with "Message queued — will
send when usage resets." A usage-limit pause can last hours, so the window for
accumulating discarded messages is wide.

Untested: the only `_queued_prompts` test (`session_manager.test.lua:1061-1119`)
exercises `switch_provider`, which reads the field *before* calling
`cancel_retry_timer` and so passes regardless.

## Fix

Capture before cancelling, mirroring what `switch_provider` already does at
`:2317-2319`:

```lua
local queued = sm._queued_prompts
M.cancel_retry_timer(sm, false)
```

Leave `cancel_retry_timer`'s unconditional clear as it is. Every other caller
(`:380`, `:416`, `session_manager.lua:2148`, `:2287`) wants the queue dropped, and
making the clear conditional on `reset_attempts` would overload one parameter with
two unrelated meanings.

## Test

Assert at the behaviour level — a message queued during a usage-limit pause is
sent when the timer fires, and `"continue"` is not — rather than against
`_queued_prompts` directly.
[`refactor-unify-message-queues.md`](refactor-unify-message-queues.md) deletes that
field, so a storage-level test would be thrown away with it, while a
behaviour-level one keeps guarding the same property through the migration.

Fix this before that refactor rather than folding it in: it is live data loss, and
the refactor's correctness rests on knowing what the current behaviour actually is.

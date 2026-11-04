--- Seconds after the reported reset that the timer fires, so it does not race
--- the reset moment.
local RESET_MARGIN_S = 120
--- Least wait before a lift after a repeat: the reported reset was wrong.
local RETRY_BACKOFF_S = 300
--- Least wait before any lift.
local MIN_WAIT_S = 10

--- A provider account's usage limit: whether it holds prompts back, and the
--- timer that calls `on_lift` after it lifts.
--- @class agentic.acp.UsageLimit
--- @field resets_at? number Epoch seconds the provider reports the limit lifts at, or nil when not held
--- @field lifts_at? number Epoch seconds the timer fires at, or nil when no timer runs
--- @field attempt integer Limits hit in a row, counted once per reset
--- @field _timer? uv.uv_timer_t
--- @field _on_lift fun()
local UsageLimit = {}
UsageLimit.__index = UsageLimit

--- Hits after which a lift no longer backs off.
UsageLimit.MAX_ATTEMPTS = 3

--- @param on_lift fun() Called on the main loop when the timer fires
--- @return agentic.acp.UsageLimit
function UsageLimit:new(on_lift)
    return setmetatable({ attempt = 0, _on_lift = on_lift }, self)
end

--- Hold prompts back until `resets_at`, and call `on_lift` a margin after it.
--- A hit while held is the same limit and only moves the times later. Any
--- other hit is an attempt. A repeat waits at least a fixed backoff, until
--- `MAX_ATTEMPTS` hits.
--- @param resets_at number Epoch seconds the provider reports the limit lifts at
function UsageLimit:hold(resets_at)
    local now = os.time()
    if not self:is_held() then
        self.attempt = self.attempt + 1
    end
    self.resets_at = math.max(self.resets_at or 0, resets_at)

    local is_repeat = self.attempt > 1
        and self.attempt <= UsageLimit.MAX_ATTEMPTS
    local wait = is_repeat and RETRY_BACKOFF_S or MIN_WAIT_S
    local lifts_at = math.max(
        self.lifts_at or 0,
        self.resets_at + RESET_MARGIN_S,
        now + wait
    )
    if lifts_at == self.lifts_at then
        return
    end
    self.lifts_at = lifts_at
    self._timer = self._timer or assert(vim.uv.new_timer())
    -- `start` on a running timer restarts it.
    self._timer:start(
        (lifts_at - now) * 1000,
        0,
        vim.schedule_wrap(function()
            self:_lift()
        end)
    )
end

--- Whether the provider's reported reset time is still ahead.
--- @return boolean held
function UsageLimit:is_held()
    return self.resets_at ~= nil and os.time() < self.resets_at
end

--- Whether automatic sends must still wait: until the timer fires, or until
--- `resets_at` when no timer runs.
--- @return boolean
function UsageLimit:holds_drain()
    return os.time() < (self.lifts_at or self.resets_at or 0)
end

--- Forget earlier attempts, so the next hit is not a repeat.
function UsageLimit:clear_attempts()
    self.attempt = 0
end

--- Stop the timer without lifting.
function UsageLimit:stop()
    if self._timer then
        self._timer:stop()
        self._timer:close()
        self._timer = nil
    end
    self.lifts_at = nil
end

--- End the hold and call `on_lift`. Attempts stay, so a hit right after the
--- lift counts as a repeat.
function UsageLimit:_lift()
    self:stop()
    self.resets_at = nil
    self._on_lift()
end

return UsageLimit

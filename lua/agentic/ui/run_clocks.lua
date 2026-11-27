--- @class agentic.ui.RunClocks.Clock
--- @field started? number `vim.uv.hrtime()` the run started at; nil while it waits
--- @field report? boolean A finish at or above the threshold is queued for `take_reports`

--- @class agentic.ui.RunClocks.Report
--- @field id string Tool call id
--- @field ms integer How long the call ran

--- How long each tool call runs, on the editor's clock. A clock runs from
--- its start or last restart, or waits, showing no time. While any clock
--- runs, a 1 s tick passes `on_tick` the clocks at or above the threshold.
--- @class agentic.ui.RunClocks
--- @field _clocks table<string, agentic.ui.RunClocks.Clock>
--- @field _reports agentic.ui.RunClocks.Report[]
--- @field threshold_ms integer The shortest run that is reported and ticked
--- @field _on_tick fun(ids: string[])
--- @field _timer uv.uv_timer_t
local RunClocks = {}
RunClocks.__index = RunClocks

--- @param threshold_ms integer The shortest run that is reported and ticked
--- @param on_tick fun(ids: string[]) Called each second with the running clocks at or above `threshold_ms`
--- @return agentic.ui.RunClocks
function RunClocks:new(threshold_ms, on_tick)
    return setmetatable({
        _clocks = {},
        _reports = {},
        threshold_ms = threshold_ms,
        _on_tick = on_tick,
        _timer = assert(vim.uv.new_timer()),
    }, self)
end

--- Start the tick unless it runs.
function RunClocks:_tick_while_running()
    if self._timer:is_active() then
        return
    end
    self._timer:start(
        1000,
        1000,
        vim.schedule_wrap(function()
            if not self._timer:is_closing() then
                self:_tick()
            end
        end)
    )
end

--- Call `on_tick` with the running clocks at or above the threshold, or
--- stop the tick when no clock runs.
function RunClocks:_tick()
    local running = false
    local ids = {}
    for id, clock in pairs(self._clocks) do
        if clock.started then
            running = true
            if self:elapsed(id) >= self.threshold_ms then
                table.insert(ids, id)
            end
        end
    end
    if not running then
        self._timer:stop()
        return
    end
    self._on_tick(ids)
end

--- Create a running clock. An existing clock keeps its state and only
--- takes `report`.
--- @param id string Tool call id
--- @param report boolean Queue the finish for `take_reports`
function RunClocks:start(id, report)
    local clock = self._clocks[id]
    if clock then
        clock.report = report
        return
    end
    self._clocks[id] = { started = vim.uv.hrtime(), report = report }
    self:_tick_while_running()
end

--- Set a clock waiting, creating it when absent.
--- @param id string
function RunClocks:wait(id)
    local clock = self._clocks[id] or {}
    clock.started = nil
    self._clocks[id] = clock
end

--- Run a clock from now, dropping the time before. No-op for an unknown
--- clock.
--- @param id string
function RunClocks:restart(id)
    local clock = self._clocks[id]
    if clock then
        clock.started = vim.uv.hrtime()
        self:_tick_while_running()
    end
end

--- Milliseconds since a clock started.
--- @param id string
--- @return integer|nil ms nil for an unknown or waiting clock
function RunClocks:elapsed(id)
    local clock = self._clocks[id]
    if not (clock and clock.started) then
        return nil
    end
    return math.floor((vim.uv.hrtime() - clock.started) / 1e6)
end

--- Remove a clock. A reporting one at or above the threshold is queued for
--- `take_reports`.
--- @param id string
--- @return integer|nil ms How long it ran; nil for an unknown or waiting clock
function RunClocks:finish(id)
    local ms = self:elapsed(id)
    local clock = self._clocks[id]
    self._clocks[id] = nil
    if ms and clock.report and ms >= self.threshold_ms then
        table.insert(self._reports, { id = id, ms = ms })
    end
    return ms
end

--- Remove a clock without a report.
--- @param id string
function RunClocks:drop(id)
    self._clocks[id] = nil
end

--- The reports queued since the last call.
--- @return agentic.ui.RunClocks.Report[]
function RunClocks:take_reports()
    local reports = self._reports
    self._reports = {}
    return reports
end

--- Remove every clock and queued report, and stop the tick.
function RunClocks:clear()
    self._clocks = {}
    self._reports = {}
    self._timer:stop()
end

--- Stop the tick and close its timer. Call no other method after.
function RunClocks:destroy()
    if not self._timer:is_closing() then
        self._timer:stop()
        self._timer:close()
    end
end

return RunClocks

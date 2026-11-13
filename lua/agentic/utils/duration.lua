--- @class agentic.utils.Duration
local M = {}

--- A duration in its largest units: "2h15m", "45m" or "30s".
--- @param seconds number Non-negative; the fraction of a second is dropped
--- @return string
function M.format(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return string.format("%dh%02dm", h, m)
    elseif m > 0 then
        return string.format("%dm", m)
    end
    return string.format("%ds", math.floor(seconds))
end

--- A run time: "250 ms", "2.8 s", "3m12s" or "1h05m". Each unit is rounded
--- down, so 59999 ms is "59.9 s", never "60.0 s".
--- @param ms number Non-negative milliseconds
--- @return string
function M.format_ms(ms)
    if ms < 1000 then
        return string.format("%d ms", math.floor(ms))
    elseif ms < 60000 then
        return string.format("%.1f s", math.floor(ms / 100) / 10)
    end
    local seconds = math.floor(ms / 1000)
    if seconds < 3600 then
        return string.format("%dm%02ds", math.floor(seconds / 60), seconds % 60)
    end
    return string.format(
        "%dh%02dm",
        math.floor(seconds / 3600),
        math.floor((seconds % 3600) / 60)
    )
end

return M

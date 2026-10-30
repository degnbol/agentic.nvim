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

return M

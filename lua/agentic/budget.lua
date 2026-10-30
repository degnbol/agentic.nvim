local Glyphs = require("agentic.glyphs")
local Theme = require("agentic.theme")

--- The account's usage budget, published editor-wide, and the values that
--- depend on the current time, computed when read.
--- @class agentic.Budget
local Budget = {}

local STATE_HL = {
    warning = Theme.HL_GROUPS.BUDGET_WARNING,
    exhausted = Theme.HL_GROUPS.BUDGET_EXHAUSTED,
}

--- Publish the windows as `vim.g.agentic_budget` and fire `User AgenticBudgetChanged`.
--- @param windows agentic.acp.BudgetWindow[]
function Budget.publish(windows)
    vim.g.agentic_budget = windows
    vim.api.nvim_exec_autocmds("User", { pattern = "AgenticBudgetChanged" })
end

--- Projected use of the window at its reset, at the average rate so far:
--- utilization ÷ fraction of `window_s` passed. Above 1 the limit is hit
--- before the reset. Nil below 5 % passed, where the ratio is noise.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return number|nil pace
function Budget.pace(window, now)
    local passed = 1 - (window.resets_at - now) / window.window_s
    if passed < 0.05 then
        return nil
    end
    return window.utilization / math.min(passed, 1)
end

--- Seconds until the window refills, 0 once `resets_at` has passed.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return integer
function Budget.resets_in(window, now)
    return math.max(0, math.floor(window.resets_at - now))
end

--- The gauge glyph for a fraction used: empty at 0, else one of 8 slices.
--- @param utilization number
--- @return string glyph
function Budget.gauge(utilization)
    return Glyphs.GAUGE[1 + math.min(math.max(math.ceil(utilization * 8), 0), 8)]
end

--- A duration as hours and minutes, e.g. "1h05m", or minutes alone under an hour.
--- @param seconds integer
--- @return string
local function hours_minutes(seconds)
    local mins = math.floor(seconds / 60)
    if mins < 60 then
        return string.format("%dm", mins)
    end
    return string.format("%dh%02dm", math.floor(mins / 60), mins % 60)
end

--- @class agentic.Budget.StatuslineOpts
--- @field pace? boolean Colour a window as warning when its pace is above 1
--- @field reset? boolean Add the time to reset after each gauge, e.g. "1h05m"
--- @field now? integer Epoch seconds, default `os.time()`

--- Statusline text: `<label> <gauge>` per window, joined by a space, each
--- wrapped in `%#AgenticBudgetWarning#`/`%#AgenticBudgetExhausted#` when not
--- ok. A window whose `resets_at` has passed shows as empty. "" without a
--- budget. For a `%{%…%}` statusline item.
--- @param opts agentic.Budget.StatuslineOpts|nil
--- @return string
function Budget.statusline(opts)
    opts = opts or {}
    local now = opts.now or os.time()
    --- @type agentic.acp.BudgetWindow[]
    local windows = vim.g.agentic_budget or {}
    local items = {}
    for _, window in ipairs(windows) do
        local resets_in = Budget.resets_in(window, now)
        local refilled = resets_in == 0
        local item = window.label
            .. " "
            .. Budget.gauge(refilled and 0 or window.utilization)
        if opts.reset then
            item = item .. " " .. hours_minutes(resets_in)
        end
        local state = refilled and "ok" or window.state
        if
            state == "ok"
            and opts.pace
            and (Budget.pace(window, now) or 0) > 1
        then
            state = "warning"
        end
        local hl = STATE_HL[state]
        table.insert(items, hl and ("%#" .. hl .. "#" .. item .. "%*") or item)
    end
    return table.concat(items, " ")
end

return Budget

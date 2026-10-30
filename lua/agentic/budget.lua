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

--- Fraction of `window_s` passed at `now`, clamped to 0-1.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return number
function Budget.elapsed(window, now)
    local passed = 1 - (window.resets_at - now) / window.window_s
    return math.min(math.max(passed, 0), 1)
end

--- Projected use of the window at its reset, at the average rate so far:
--- utilization ÷ fraction of `window_s` passed. Above 1 the limit is hit
--- before the reset.
--- Nil below 5 % passed, where the ratio is noise.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return number|nil pace
function Budget.pace(window, now)
    local passed = Budget.elapsed(window, now)
    if passed < 0.05 then
        return nil
    end
    return window.utilization / passed
end

--- Seconds until the window refills, 0 once `resets_at` has passed.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return integer
function Budget.resets_in(window, now)
    return math.max(0, math.floor(window.resets_at - now))
end

--- A fraction in eighths, rounded up and clamped to 0-8.
--- @param fraction number
--- @return integer
local function eighths(fraction)
    return math.min(math.max(math.ceil(fraction * 8), 0), 8)
end

--- The pie glyph for a fraction: empty at 0, else one of 8 slices.
--- @param fraction number
--- @return string glyph
function Budget.pie(fraction)
    return Glyphs.PIE[1 + eighths(fraction)]
end

--- The bar glyph for a fraction: 1 to 8 eighths high, the lowest for 0 too.
--- @param fraction number
--- @return string glyph
function Budget.bar(fraction)
    return Glyphs.BAR[math.max(eighths(fraction), 1)]
end

--- The window's state at `now`: "ok" once `resets_at` has passed, else the
--- provider's state, raised from "ok" to "warning" when the pace is above 1.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return "ok"|"warning"|"exhausted"
function Budget.state(window, now)
    if Budget.resets_in(window, now) == 0 then
        return "ok"
    end
    if window.state == "ok" and (Budget.pace(window, now) or 0) > 1 then
        return "warning"
    end
    return window.state
end

--- Highlight group of a state, nil for "ok".
--- @param state "ok"|"warning"|"exhausted"
--- @return string|nil
function Budget.hl(state)
    return STATE_HL[state]
end

--- @class agentic.Budget.StatuslineOpts
--- @field now? integer Epoch seconds, default `os.time()`

--- Text in 'statusline' format: `<label> <pie>  <bar>` per window, joined by a
--- space. The pie fills with the fraction of the window passed, the bar with
--- the fraction used. The bar is wrapped in `%#AgenticBudgetWarning#` when the
--- provider warns or the pace is above 1, `%#AgenticBudgetExhausted#` when
--- exhausted. A window whose `resets_at` has passed shows as empty and
--- uncoloured. "" without a budget.
--- @param opts agentic.Budget.StatuslineOpts|nil
--- @return string
function Budget.statusline(opts)
    opts = opts or {}
    local now = opts.now or os.time()
    --- @type agentic.acp.BudgetWindow[]
    local windows = vim.g.agentic_budget or {}
    local items = {}
    for _, window in ipairs(windows) do
        local refilled = Budget.resets_in(window, now) == 0
        local bar = Budget.bar(refilled and 0 or window.utilization)
        local hl = Budget.hl(Budget.state(window, now))
        -- The space after the pie is the cell a wide-aspect glyph expands into
        -- (see `agentic.Glyphs`). The bar is one cell wide and needs none.
        table.insert(
            items,
            window.label
                .. " "
                .. Budget.pie(refilled and 0 or Budget.elapsed(window, now))
                .. "  "
                .. (hl and ("%#" .. hl .. "#" .. bar .. "%*") or bar)
        )
    end
    return table.concat(items, " ")
end

return Budget

local BudgetHistory = require("agentic.budget_history")
local FileSystem = require("agentic.utils.file_system")
local Glyphs = require("agentic.glyphs")
local Intervals = require("agentic.utils.intervals")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

--- The account's usage budget, shared by all Neovim instances through a file,
--- and the values that depend on the current time, computed when read. Each
--- change is published as `vim.g.agentic_budget`, shortest window first, with
--- `User AgenticBudgetChanged`.
--- @class agentic.Budget
local Budget = {}

local STATE_HL = {
    warning = Theme.HL_GROUPS.BUDGET_WARNING,
    exhausted = Theme.HL_GROUPS.BUDGET_EXHAUSTED,
}

-- The budget is the account's, not a session's, so one history per process.
local history = BudgetHistory.empty()
--- @type string|nil
local path

--- The history in a file: empty when the file is missing, or unreadable
--- (with a warning).
--- @param file_path string
--- @return agentic.BudgetHistory
local function read_history(file_path)
    if not FileSystem.is_file(file_path) then
        return BudgetHistory.empty()
    end
    local value, err = FileSystem.read_json(file_path)
    if
        type(value) ~= "table"
        or type(value.windows) ~= "table"
        or type(value.blocked) ~= "table"
    then
        Logger.notify(
            "Agentic: ignoring the budget file: "
                .. (err or ("unexpected content in " .. file_path))
        )
        return BudgetHistory.empty()
    end
    return value --[[@as agentic.BudgetHistory]]
end

--- Make `next_history` the history and publish it.
--- @param next_history agentic.BudgetHistory
local function apply(next_history)
    history = next_history
    --- @type agentic.acp.BudgetWindow[]
    local windows = {}
    for _, entry in pairs(history.windows) do
        table.insert(windows, entry.window)
    end
    table.sort(windows, function(a, b)
        return a.window_s < b.window_s
    end)
    vim.g.agentic_budget = windows
    vim.api.nvim_exec_autocmds("User", { pattern = "AgenticBudgetChanged" })
end

--- Merge `other` into the history, pruned as `record` prunes, and apply the
--- result if it changed.
--- @param other agentic.BudgetHistory
local function adopt(other)
    local merged =
        BudgetHistory.prune(BudgetHistory.merge(history, other), os.time())
    if not vim.deep_equal(merged, history) then
        apply(merged)
    end
end

--- Share the history through `file_path`: merge the file's history now and on
--- each change of the file, and write each later report to it. Only the first
--- call has an effect.
--- @param file_path string
function Budget.start(file_path)
    if path then
        return
    end
    path = file_path
    adopt(read_history(file_path))
    local _, err = FileSystem.watch(file_path, function(watch_err)
        if watch_err then
            Logger.notify("Agentic: budget file watch failed: " .. watch_err)
            return
        end
        adopt(read_history(file_path))
    end)
    if err then
        Logger.notify("Agentic: cannot watch the budget file: " .. err)
    end
end

--- Record a report of the windows at `now`: merge it into the history, and
--- into the shared file if there is one. Rewrites the file whenever it lacks
--- part of the result, so samples lost to a concurrent write are restored.
--- @param windows agentic.acp.BudgetWindow[]
--- @param now integer Epoch seconds
function Budget.record(windows, now)
    local merged =
        BudgetHistory.merge(history, BudgetHistory.from_windows(windows, now))
    local on_disk = path and read_history(path)
    if on_disk then
        merged = BudgetHistory.merge(on_disk, merged)
    end
    merged = BudgetHistory.prune(merged, now)
    if on_disk and not vim.deep_equal(merged, on_disk) then
        local ok, err = FileSystem.write_atomic(
            path --[[@as string]],
            vim.json.encode(merged)
        )
        if not ok then
            Logger.notify(
                "Agentic: cannot write the budget file: " .. tostring(err)
            )
        end
    end
    if not vim.deep_equal(merged, history) then
        apply(merged)
    end
end

--- Fraction of `window_s` passed at `now`, clamped to 0-1.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return number
function Budget.elapsed(window, now)
    local passed = 1 - (window.resets_at - now) / window.window_s
    return math.min(math.max(passed, 0), 1)
end

--- Seconds until the window refills, 0 once `resets_at` has passed.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return integer
function Budget.resets_in(window, now)
    return math.max(0, math.floor(window.resets_at - now))
end

--- Projected use of the window at its reset, extrapolating linearly at the
--- usage rate over the trailing span `[now − window_s, now]`:
---
---     utilization + usage ÷ known × resets_in
---
--- `utilization` is the window's, `resets_in` the seconds until its reset.
--- `usage` is the window's utilization plus the part of `previous`'s that
--- falls in the span. `known` is the span's length without the time that is
--- blocked, or whose usage is unknown: before the window's start without a
--- `previous`, or before `previous`'s first sample. Above 1 the limit is hit
--- before the reset.
--- @param window agentic.acp.BudgetWindow
--- @param previous agentic.BudgetHistory.Span|nil The window that reset before `window`, ignored unless it reset at or before `window`'s start
--- @param blocked agentic.Interval[] Times when the account could not be used
--- @param now integer Epoch seconds
--- @return number|nil pace Nil when less than 5 % of the span is known, where the rate is noise
function Budget.trailing_pace(window, previous, blocked, now)
    local length = window.window_s
    local span_start = now - length
    local window_start = window.resets_at - length
    if previous and previous.resets_at > window_start then
        previous = nil
    end

    local unknown = vim.deepcopy(blocked)
    local previous_usage = 0
    if not previous then
        table.insert(
            unknown,
            { span_start, math.max(span_start, window_start) }
        )
    elseif previous.resets_at > span_start then
        local samples = previous.samples
        if samples[1].t > span_start then
            table.insert(unknown, { span_start, samples[1].t })
        end
        local at_start = samples[1]
        for _, sample in ipairs(samples) do
            if sample.t <= span_start then
                at_start = sample
            end
        end
        previous_usage = samples[#samples].utilization - at_start.utilization
    end

    local known = length - Intervals.covered(unknown, span_start, now)
    if known < 0.05 * length then
        return nil
    end
    local usage = window.utilization + previous_usage
    return window.utilization + usage / known * Budget.resets_in(window, now)
end

--- `trailing_pace` of the window with the recorded history.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return number|nil pace
function Budget.pace(window, now)
    local entry = history.windows[window.label]
    return Budget.trailing_pace(
        window,
        entry and entry.previous,
        history.blocked,
        now
    )
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

local Intervals = require("agentic.utils.intervals")

--- Observed usage of the budget windows: samples of the current and the
--- previous window per label, and the times when a window was exhausted.
--- Pure functions.
--- @class agentic.BudgetHistoryModule
local BudgetHistory = {}

--- @class agentic.BudgetHistory.Sample
--- @field t integer Epoch seconds when the value was received
--- @field utilization number

--- @class agentic.BudgetHistory.Span
--- @field resets_at number
--- @field samples agentic.BudgetHistory.Sample[] Ascending `t`

--- @class agentic.BudgetHistory.Entry
--- @field window agentic.acp.BudgetWindow Newest report of the current window
--- @field samples agentic.BudgetHistory.Sample[] Of the current window, ascending `t`
--- @field previous? agentic.BudgetHistory.Span The window that reset before the current one

--- @class agentic.BudgetHistory
--- @field windows table<string, agentic.BudgetHistory.Entry> By `label`
--- @field blocked agentic.Interval[] Disjoint, ascending: times when a window was exhausted

local SEVERITY = { ok = 1, warning = 2, exhausted = 3 }

--- @return agentic.BudgetHistory
function BudgetHistory.empty()
    --- @type agentic.BudgetHistory
    local history = { windows = {}, blocked = {} }
    return history
end

--- The history of one report.
--- @param windows agentic.acp.BudgetWindow[]
--- @param now integer Epoch seconds
--- @return agentic.BudgetHistory history One sample per window, blocked from `now` until the reset of each exhausted window
function BudgetHistory.from_windows(windows, now)
    local history = BudgetHistory.empty()
    for _, window in ipairs(windows) do
        history.windows[window.label] = {
            window = window,
            samples = { { t = now, utilization = window.utilization } },
        }
        if window.state == "exhausted" then
            table.insert(history.blocked, { now, window.resets_at })
        end
    end
    history.blocked = Intervals.union(history.blocked)
    return history
end

--- Samples sorted by `t`, then `utilization`, without each sample whose
--- utilization equals the one before it.
--- @param samples agentic.BudgetHistory.Sample[]
--- @return agentic.BudgetHistory.Sample[]
local function changes(samples)
    local sorted = vim.deepcopy(samples)
    table.sort(sorted, function(a, b)
        if a.t ~= b.t then
            return a.t < b.t
        end
        return a.utilization < b.utilization
    end)
    --- @type agentic.BudgetHistory.Sample[]
    local kept = {}
    for _, sample in ipairs(sorted) do
        local last = kept[#kept]
        if not last or last.utilization ~= sample.utilization then
            table.insert(kept, sample)
        end
    end
    return kept
end

--- Whether report `a` ranks above report `b` of the same window: higher
--- utilization, then the more severe state.
--- @param a agentic.acp.BudgetWindow
--- @param b agentic.acp.BudgetWindow
--- @return boolean
local function ranks_above(a, b)
    if a.utilization ~= b.utilization then
        return a.utilization > b.utilization
    end
    return SEVERITY[a.state] > SEVERITY[b.state]
end

--- Join two entries of the same label.
--- @param entries agentic.BudgetHistory.Entry[] One or two
--- @return agentic.BudgetHistory.Entry
local function merge_entries(entries)
    --- @type table<number, agentic.BudgetHistory.Sample[]>
    local by_reset = {}
    --- @param resets_at number
    --- @param samples agentic.BudgetHistory.Sample[]
    local function add(resets_at, samples)
        by_reset[resets_at] =
            vim.list_extend(by_reset[resets_at] or {}, samples)
    end
    for _, entry in ipairs(entries) do
        add(entry.window.resets_at, entry.samples)
        if entry.previous then
            add(entry.previous.resets_at, entry.previous.samples)
        end
    end

    local resets = vim.tbl_keys(by_reset)
    table.sort(resets, function(a, b)
        return a > b
    end)

    --- @type agentic.acp.BudgetWindow|nil
    local window
    for _, entry in ipairs(entries) do
        local candidate = entry.window
        if
            candidate.resets_at == resets[1]
            and (not window or ranks_above(candidate, window))
        then
            window = candidate
        end
    end
    --- @cast window -nil

    --- @type agentic.BudgetHistory.Entry
    local merged = {
        window = vim.deepcopy(window),
        samples = changes(by_reset[resets[1]]),
    }
    if resets[2] then
        merged.previous = {
            resets_at = resets[2],
            samples = changes(by_reset[resets[2]]),
        }
    end
    return merged
end

--- Join two histories: per label, the union of the samples of each window,
--- the newest window as the current one and the window before it as
--- `previous`. The union of the blocked intervals. Commutative.
--- @param a agentic.BudgetHistory
--- @param b agentic.BudgetHistory
--- @return agentic.BudgetHistory
function BudgetHistory.merge(a, b)
    local merged = BudgetHistory.empty()
    for label in pairs(vim.tbl_extend("force", {}, a.windows, b.windows)) do
        merged.windows[label] = merge_entries(
            vim.tbl_values({ a.windows[label], b.windows[label] })
        )
    end
    merged.blocked =
        Intervals.union(vim.list_extend(vim.deepcopy(a.blocked), b.blocked))
    return merged
end

--- The history without blocked intervals that end more than the longest
--- `window_s` before `now`.
--- @param history agentic.BudgetHistory
--- @param now integer Epoch seconds
--- @return agentic.BudgetHistory
function BudgetHistory.prune(history, now)
    local longest = 0
    for _, entry in pairs(history.windows) do
        longest = math.max(longest, entry.window.window_s)
    end
    --- @type agentic.BudgetHistory
    local pruned = {
        windows = history.windows,
        blocked = vim.tbl_filter(function(interval)
            return interval[2] >= now - longest
        end, history.blocked),
    }
    return pruned
end

return BudgetHistory

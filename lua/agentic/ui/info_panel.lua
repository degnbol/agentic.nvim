local BufHelpers = require("agentic.utils.buf_helpers")
local Budget = require("agentic.budget")

local DAY = 24 * 3600

--- Context use in tokens, and the session cost when reported.
--- @class agentic.ui.InfoPanel.Usage
--- @field used number
--- @field size number
--- @field cost? { amount: number, currency: string }

--- Values the info panel shows. A nil field is left out, except a nil `auth`,
--- which shows as unknown.
--- @class agentic.ui.InfoPanel.Snapshot
--- @field provider string
--- @field model? string
--- @field mode? string
--- @field auth? agentic.acp.AuthStatus
--- @field usage? agentic.ui.InfoPanel.Usage
--- @field budget? agentic.acp.BudgetWindow[]

--- A session's agent, account, context usage and usage-limit windows as a
--- markdown list.
--- @class agentic.ui.InfoPanel
local InfoPanel = {}

--- Context totals, e.g. "12.3k / 200k · 6%". Nil without usage or with a size
--- of 0.
--- @param usage { used: number, size: number }|nil
--- @return string|nil
function InfoPanel.context_totals(usage)
    if not usage or usage.size <= 0 then
        return nil
    end
    return string.format(
        "%.1fk / %.0fk · %d%%",
        usage.used / 1000,
        usage.size / 1000,
        math.floor(usage.used / usage.size * 100)
    )
end

--- Session cost, e.g. "$0.1234 USD". Nil when not reported.
--- @param usage { cost?: { amount: number, currency: string } }|nil
--- @return string|nil
function InfoPanel.cost(usage)
    local cost = usage and usage.cost
    if not cost then
        return nil
    end
    return string.format("$%.4f %s", cost.amount, cost.currency)
end

--- The non-nil arguments, joined by " · ".
--- @param ... string|nil
--- @return string
local function join(...)
    local known = {}
    for i = 1, select("#", ...) do
        local part = select(i, ...)
        if part then
            table.insert(known, part)
        end
    end
    return table.concat(known, " · ")
end

--- The account line, followed by an indented line of the identity parts the
--- account reports.
--- @param auth agentic.acp.AuthStatus|nil
--- @return string[]
local function account_lines(auth)
    if not auth then
        return { "- Account: unknown" }
    end
    if auth.kind == "none" then
        return { "- Account: not logged in" }
    end
    local lines = {
        "- Account: "
            .. auth.label
            .. (auth.detail and (" (" .. auth.detail .. ")") or ""),
    }
    local account = auth.account or {}
    local identity = join(account.email, account.organization, account.plan)
    if identity ~= "" then
        table.insert(lines, "  - " .. identity)
    end
    return lines
end

--- A window's line: its use, reset time and pace. Once the reset has passed,
--- its label and 0% only.
--- @param window agentic.acp.BudgetWindow
--- @param now integer Epoch seconds
--- @return string
local function window_line(window, now)
    local resets_in = Budget.resets_in(window, now)
    if resets_in == 0 then
        return "- " .. window.label .. " 0%"
    end
    local percent = math.floor(window.utilization * 100 + 0.5)
    local reset =
        os.date(resets_in > DAY and "%a %H:%M" or "%H:%M", window.resets_at) --[[@as string]]
    local pace = Budget.pace(window, now)
    local pace_text = pace
        and string.format("pace %.1f%s", pace, pace > 1 and " ⚠" or "")
    return "- "
        .. join(
            string.format("%s %d%%", window.label, percent),
            "resets " .. reset,
            pace_text
        )
end

--- The panel's lines for a snapshot.
--- @param snap agentic.ui.InfoPanel.Snapshot
--- @param now integer Epoch seconds
--- @return string[]
function InfoPanel.lines(snap, now)
    local lines = {
        "- Agent: " .. join(snap.provider, snap.model, snap.mode),
    }
    vim.list_extend(lines, account_lines(snap.auth))
    -- Cost only with the totals, as `/context` shows them.
    local totals = InfoPanel.context_totals(snap.usage)
    if totals then
        table.insert(
            lines,
            "- Context: " .. join(totals, InfoPanel.cost(snap.usage))
        )
    end
    for _, window in ipairs(snap.budget or {}) do
        table.insert(lines, window_line(window, now))
    end
    return lines
end

--- Replace `bufnr`'s lines with the lines for `snap`. Keeps its 'modifiable'.
--- @param bufnr integer
--- @param snap agentic.ui.InfoPanel.Snapshot
--- @param now integer Epoch seconds
function InfoPanel.render(bufnr, snap, now)
    BufHelpers.with_modifiable(bufnr, function(buf)
        vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            InfoPanel.lines(snap, now)
        )
    end)
end

return InfoPanel

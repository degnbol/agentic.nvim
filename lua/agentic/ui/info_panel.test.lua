local MiniTest = require("mini.test")
local assert = require("tests.helpers.assert")

local Chunks = require("agentic.ui.chunks")
local InfoPanel = require("agentic.ui.info_panel")

local NOW = 1000000
local HOUR = 3600

--- A five-hour window resetting `reset_in` seconds after `NOW`.
--- @param utilization number
--- @param reset_in number
--- @return agentic.acp.BudgetWindow
local function five_hour(utilization, reset_in)
    return {
        label = "5h",
        utilization = utilization,
        resets_at = NOW + reset_in,
        window_s = 5 * HOUR,
        state = "ok",
    }
end

--- The panel's lines for `snap` as plain text.
--- @param snap agentic.ui.InfoPanel.Snapshot
--- @return string[]
local function texts(snap)
    return vim.tbl_map(Chunks.text, InfoPanel.lines(snap, NOW))
end

--- @param snap agentic.ui.InfoPanel.Snapshot
--- @param prefix string
--- @return agentic.ui.Chunk[]|nil chunks The first line starting with `prefix`
local function chunks_starting(snap, prefix)
    for _, chunks in ipairs(InfoPanel.lines(snap, NOW)) do
        if vim.startswith(Chunks.text(chunks), prefix) then
            return chunks
        end
    end
    return nil
end

--- @param snap agentic.ui.InfoPanel.Snapshot
--- @param prefix string
--- @return string|nil line The first line starting with `prefix`
local function line_starting(snap, prefix)
    local chunks = chunks_starting(snap, prefix)
    return chunks and Chunks.text(chunks)
end

--- @param chunks agentic.ui.Chunk[]
--- @return table<string, string> hl_by_text Highlight group of each highlighted chunk
local function highlighted(chunks)
    local hl_by_text = {}
    for _, chunk in ipairs(chunks) do
        if chunk[2] then
            hl_by_text[chunk[1]] = chunk[2]
        end
    end
    return hl_by_text
end

describe("agentic.ui.InfoPanel", function()
    describe("context_totals", function()
        it("formats used and size in tokens with the percent", function()
            assert.equal(
                "12.3k / 200k tokens (6%)",
                InfoPanel.context_totals({ used = 12345, size = 200000 })
            )
        end)

        it("is nil for a size of 0 or no usage", function()
            assert.is_nil(InfoPanel.context_totals({ used = 5, size = 0 }))
            assert.is_nil(InfoPanel.context_totals(nil))
        end)
    end)

    describe("cost", function()
        it("formats the amount and currency", function()
            assert.equal(
                "0.1234 USD",
                InfoPanel.cost({ cost = { amount = 0.1234, currency = "USD" } })
            )
        end)

        it("is nil when not reported", function()
            assert.is_nil(InfoPanel.cost({}))
            assert.is_nil(InfoPanel.cost(nil))
        end)
    end)

    describe("lines", function()
        it("joins the known agent values", function()
            assert.equal(
                "- Agent: Claude · Opus · Plan",
                line_starting(
                    { provider = "Claude", model = "Opus", mode = "Plan" },
                    "- Agent:"
                )
            )
            assert.equal(
                "- Agent: Claude",
                line_starting({ provider = "Claude" }, "- Agent:")
            )
        end)

        it("shows the account with its detail and identity", function()
            local lines = texts({
                provider = "Claude",
                auth = {
                    kind = "account",
                    label = "Claude Team",
                    detail = "oauth",
                    account = {
                        email = "a@b.c",
                        organization = "Org",
                        plan = "Max",
                    },
                },
            })
            local i = vim.fn.index(lines, "- Account: Claude Team (oauth)") + 1
            assert.is_true(i > 0)
            assert.equal("  - a@b.c · Org · Max", lines[i + 1])
        end)

        it("shows the account without the missing parts", function()
            local lines = texts({
                provider = "Claude",
                auth = { kind = "api_key", label = "API key" },
            })
            assert.same({ "- Agent: Claude", "- Account: API key" }, lines)
        end)

        it("joins only the identity parts the account reports", function()
            local lines = texts({
                provider = "Claude",
                auth = {
                    kind = "account",
                    label = "Claude Pro",
                    account = { email = "a@b.c", plan = "Pro" },
                },
            })
            assert.same({
                "- Agent: Claude",
                "- Account: Claude Pro",
                "  - a@b.c · Pro",
            }, lines)
        end)

        it("tells an unreported account from no login", function()
            assert.equal(
                "- Account: unknown",
                line_starting({ provider = "Claude" }, "- Account:")
            )
            assert.equal(
                "- Account: not logged in",
                line_starting({
                    provider = "Claude",
                    auth = { kind = "none", label = "Not logged in" },
                }, "- Account:")
            )
        end)

        it("shows the context totals and cost", function()
            assert.equal(
                "- Context: 12.3k / 200k tokens (6%) · 0.5000 USD",
                line_starting({
                    provider = "Claude",
                    usage = {
                        used = 12345,
                        size = 200000,
                        cost = { amount = 0.5, currency = "USD" },
                    },
                }, "- Context:")
            )
        end)

        it("leaves out the context without usage or a size", function()
            assert.is_nil(line_starting({ provider = "Claude" }, "- Context:"))
            assert.is_nil(line_starting({
                provider = "Claude",
                usage = {
                    used = 1,
                    size = 0,
                    cost = { amount = 0.5, currency = "USD" },
                },
            }, "- Context:"))
        end)

        it("rounds the window percent and shows the reset time", function()
            local window = five_hour(0.026, HOUR)
            assert.equal(
                "- 5h: 3% used · resets "
                    .. os.date("%H:%M", window.resets_at)
                    .. " (in 1h00m) · on pace for 3%",
                line_starting(
                    { provider = "Claude", budget = { window } },
                    "- 5h"
                )
            )
        end)

        it("names the weekday of a reset more than a day away", function()
            local window = five_hour(0.5, 2 * 24 * HOUR)
            window.window_s = 7 * 24 * HOUR
            local line = line_starting(
                { provider = "Claude", budget = { window } },
                "- 5h"
            ) or ""
            assert.truthy(
                line:find(
                    "resets " .. os.date("%a %H:%M", window.resets_at),
                    1,
                    true
                )
            )
        end)

        it("shows the pace as a percent", function()
            -- 3 of 5 hours passed.
            local slow = five_hour(0.3, 2 * HOUR)
            local fast = five_hour(0.9, 2 * HOUR)
            assert.truthy(
                line_starting(
                    { provider = "Claude", budget = { slow } },
                    "- 5h"
                ):find("· on pace for 50%%$")
            )
            assert.truthy(
                line_starting(
                    { provider = "Claude", budget = { fast } },
                    "- 5h"
                ):find("· on pace for 150%%$")
            )
        end)

        it("colours a pace above 100% only", function()
            local slow = five_hour(0.3, 2 * HOUR)
            local fast = five_hour(0.9, 2 * HOUR)
            assert.same(
                {},
                highlighted(
                    chunks_starting(
                        { provider = "Claude", budget = { slow } },
                        "- 5h"
                    ) or {}
                )
            )
            assert.same(
                { ["on pace for 150%"] = "AgenticBudgetWarning" },
                highlighted(
                    chunks_starting(
                        { provider = "Claude", budget = { fast } },
                        "- 5h"
                    ) or {}
                )
            )
        end)

        it("colours the use by the provider state", function()
            local warned = five_hour(0.3, 2 * HOUR)
            warned.state = "warning"
            local exhausted = five_hour(0.3, 2 * HOUR)
            exhausted.state = "exhausted"
            assert.same(
                { ["5h: 30% used"] = "AgenticBudgetWarning" },
                highlighted(
                    chunks_starting(
                        { provider = "Claude", budget = { warned } },
                        "- 5h"
                    ) or {}
                )
            )
            assert.same(
                { ["5h: 30% used"] = "AgenticBudgetExhausted" },
                highlighted(
                    chunks_starting(
                        { provider = "Claude", budget = { exhausted } },
                        "- 5h"
                    ) or {}
                )
            )
        end)

        it("leaves out a pace that is not known yet", function()
            local fresh = five_hour(0.01, 5 * HOUR - 60)
            local line = line_starting(
                { provider = "Claude", budget = { fresh } },
                "- 5h"
            ) or ""
            assert.is_nil(line:find("on pace", 1, true))
        end)

        it("shows a passed reset as 0% with no reset", function()
            assert.equal(
                "- 5h: 0% used",
                line_starting(
                    { provider = "Claude", budget = { five_hour(0.8, -60) } },
                    "- 5h"
                )
            )
        end)
    end)

    describe("render", function()
        it("writes the lines and leaves the buffer unmodifiable", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            MiniTest.finally(function()
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end)
            vim.bo[bufnr].modifiable = false
            local snap = { provider = "Claude" }

            InfoPanel.render(bufnr, snap, NOW)

            assert.same(
                texts(snap),
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            assert.is_false(vim.bo[bufnr].modifiable)
        end)

        it("highlights the coloured chunks, replacing earlier ones", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            MiniTest.finally(function()
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end)
            local window = five_hour(0.9, 2 * HOUR)
            window.state = "warning"
            local snap = { provider = "Claude", budget = { window } }
            local ns = vim.api.nvim_create_namespace("agentic_info_panel")

            InfoPanel.render(bufnr, snap, NOW)
            InfoPanel.render(bufnr, snap, NOW)

            local marks = vim.api.nvim_buf_get_extmarks(
                bufnr,
                ns,
                0,
                -1,
                { details = true }
            )
            -- Below the agent and account lines.
            local line = vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1]
            local spans = vim.tbl_map(function(mark)
                return {
                    mark[2],
                    line:sub(mark[3] + 1, mark[4].end_col),
                    mark[4].hl_group,
                }
            end, marks)
            assert.same({
                { 2, "5h: 90% used", "AgenticBudgetWarning" },
                { 2, "on pace for 150%", "AgenticBudgetWarning" },
            }, spans)
        end)
    end)
end)

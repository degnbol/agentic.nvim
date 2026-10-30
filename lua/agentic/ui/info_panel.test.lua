local MiniTest = require("mini.test")
local assert = require("tests.helpers.assert")

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

--- @param snap agentic.ui.InfoPanel.Snapshot
--- @param prefix string
--- @return string|nil line The first line starting with `prefix`
local function line_starting(snap, prefix)
    for _, line in ipairs(InfoPanel.lines(snap, NOW)) do
        if vim.startswith(line, prefix) then
            return line
        end
    end
    return nil
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
            local lines = InfoPanel.lines({
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
            }, NOW)
            local i = vim.fn.index(lines, "- Account: Claude Team (oauth)") + 1
            assert.is_true(i > 0)
            assert.equal("  - a@b.c · Org · Max", lines[i + 1])
        end)

        it("shows the account without the missing parts", function()
            local lines = InfoPanel.lines({
                provider = "Claude",
                auth = { kind = "api_key", label = "API key" },
            }, NOW)
            assert.same({ "- Agent: Claude", "- Account: API key" }, lines)
        end)

        it("joins only the identity parts the account reports", function()
            local lines = InfoPanel.lines({
                provider = "Claude",
                auth = {
                    kind = "account",
                    label = "Claude Pro",
                    account = { email = "a@b.c", plan = "Pro" },
                },
            }, NOW)
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

        it("shows the pace as a percent, marked above 100%", function()
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
                ):find("· on pace for 150%% ⚠$")
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
                InfoPanel.lines(snap, NOW),
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            assert.is_false(vim.bo[bufnr].modifiable)
        end)
    end)
end)

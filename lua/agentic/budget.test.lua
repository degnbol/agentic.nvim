local assert = require("tests.helpers.assert")

local Budget = require("agentic.budget")
local Glyphs = require("agentic.glyphs")

local NOW = 1000000
local HOUR = 3600

--- A five-hour window resetting `reset_in` seconds after `NOW`.
--- @param utilization number
--- @param reset_in number
--- @param state "ok"|"warning"|"exhausted"|nil
--- @return agentic.acp.BudgetWindow
local function five_hour(utilization, reset_in, state)
    return {
        label = "5h",
        utilization = utilization,
        resets_at = NOW + reset_in,
        window_s = 5 * HOUR,
        state = state or "ok",
    }
end

describe("agentic.Budget", function()
    after_each(function()
        vim.g.agentic_budget = nil
    end)

    describe("pace", function()
        it("is 1 when on pace at half the window", function()
            local pace = Budget.pace(five_hour(0.5, 2.5 * HOUR), NOW) --[[@as number]]
            assert.is_true(math.abs(pace - 1) < 0.01)
        end)

        it("is above 1 when 90 % is used at 20 % passed", function()
            local pace = Budget.pace(five_hour(0.9, 4 * HOUR), NOW) --[[@as number]]
            assert.is_true(pace > 1)
        end)

        it("is nil below 5 % of the window passed", function()
            assert.is_nil(Budget.pace(five_hour(0.1, 5 * HOUR - 1), NOW))
        end)

        it("caps the fraction passed at 1 after the reset", function()
            assert.equal(0.5, Budget.pace(five_hour(0.5, -HOUR), NOW))
        end)
    end)

    describe("resets_in", function()
        it("counts the seconds before the reset", function()
            assert.equal(HOUR, Budget.resets_in(five_hour(0.5, HOUR), NOW))
        end)

        it("is 0 once the reset has passed", function()
            assert.equal(0, Budget.resets_in(five_hour(0.5, -HOUR), NOW))
        end)
    end)

    describe("gauge", function()
        it("is empty at 0", function()
            assert.equal(Glyphs.GAUGE[1], Budget.gauge(0))
        end)

        it("shows the first slice for any use", function()
            assert.equal(Glyphs.GAUGE[2], Budget.gauge(0.01))
        end)

        it("shows half at 0.5", function()
            assert.equal(Glyphs.GAUGE[5], Budget.gauge(0.5))
        end)

        it("is full at 1 and above", function()
            assert.equal(Glyphs.GAUGE[9], Budget.gauge(1))
            assert.equal(Glyphs.GAUGE[9], Budget.gauge(1.3))
        end)
    end)

    describe("statusline", function()
        it("is empty without a budget", function()
            assert.equal("", Budget.statusline({ now = NOW }))
        end)

        it("shows each window with its gauge", function()
            vim.g.agentic_budget = {
                five_hour(0.5, 2.5 * HOUR),
                {
                    label = "wk",
                    utilization = 1,
                    resets_at = NOW + HOUR,
                    window_s = 7 * 24 * HOUR,
                    state = "ok",
                },
            }
            assert.equal(
                "5h " .. Glyphs.GAUGE[5] .. " wk " .. Glyphs.GAUGE[9],
                Budget.statusline({ now = NOW })
            )
        end)

        it("colours a window that is not ok", function()
            vim.g.agentic_budget = { five_hour(0.5, 2.5 * HOUR, "warning") }
            assert.equal(
                "%#AgenticBudgetWarning#5h " .. Glyphs.GAUGE[5] .. "%*",
                Budget.statusline({ now = NOW })
            )
        end)

        it("shows a window past its reset as empty and ok", function()
            vim.g.agentic_budget = { five_hour(1, -HOUR, "exhausted") }
            assert.equal(
                "5h " .. Glyphs.GAUGE[1],
                Budget.statusline({ now = NOW })
            )
        end)

        it("colours a window over pace with pace = true", function()
            vim.g.agentic_budget = { five_hour(0.9, 4 * HOUR) }
            assert.equal(
                "5h " .. Glyphs.GAUGE[9],
                Budget.statusline({ now = NOW })
            )
            assert.equal(
                "%#AgenticBudgetWarning#5h " .. Glyphs.GAUGE[9] .. "%*",
                Budget.statusline({ now = NOW, pace = true })
            )
        end)

        it("adds the time to reset with reset = true", function()
            vim.g.agentic_budget = {
                five_hour(0.5, HOUR + 5 * 60),
                five_hour(0.5, 42 * 60),
            }
            assert.equal(
                "5h "
                    .. Glyphs.GAUGE[5]
                    .. " 1h05m 5h "
                    .. Glyphs.GAUGE[5]
                    .. " 42m",
                Budget.statusline({ now = NOW, reset = true })
            )
        end)
    end)

    describe("publish", function()
        it(
            "sets vim.g.agentic_budget and fires AgenticBudgetChanged once",
            function()
                local fired = 0
                local id = vim.api.nvim_create_autocmd("User", {
                    pattern = "AgenticBudgetChanged",
                    callback = function()
                        fired = fired + 1
                    end,
                })
                local windows = { five_hour(0.5, HOUR) }

                Budget.publish(windows)
                vim.api.nvim_del_autocmd(id)

                assert.same(windows, vim.g.agentic_budget)
                assert.equal(1, fired)
            end
        )
    end)
end)

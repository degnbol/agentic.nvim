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

    describe("elapsed", function()
        it("is 0 at the window start", function()
            assert.equal(0, Budget.elapsed(five_hour(0, 5 * HOUR), NOW))
        end)

        it("is 0 when the reset is further away than the window", function()
            assert.equal(0, Budget.elapsed(five_hour(0, 6 * HOUR), NOW))
        end)

        it("is 0.5 halfway", function()
            assert.equal(0.5, Budget.elapsed(five_hour(0, 2.5 * HOUR), NOW))
        end)

        it("is 1 after the reset", function()
            assert.equal(1, Budget.elapsed(five_hour(0, -HOUR), NOW))
        end)
    end)

    describe("pie", function()
        it("is empty at 0", function()
            assert.equal(Glyphs.PIE[1], Budget.pie(0))
        end)

        it("shows the first slice for any fraction", function()
            assert.equal(Glyphs.PIE[2], Budget.pie(0.01))
        end)

        it("shows half at 0.5", function()
            assert.equal(Glyphs.PIE[5], Budget.pie(0.5))
        end)

        it("is full at 1 and above", function()
            assert.equal(Glyphs.PIE[9], Budget.pie(1))
            assert.equal(Glyphs.PIE[9], Budget.pie(1.3))
        end)
    end)

    describe("bar", function()
        it("is lowest at 0 and up to an eighth", function()
            assert.equal(Glyphs.BAR[1], Budget.bar(0))
            assert.equal(Glyphs.BAR[1], Budget.bar(0.1))
        end)

        it("is half high at 0.5", function()
            assert.equal(Glyphs.BAR[4], Budget.bar(0.5))
        end)

        it("is full at 1 and above", function()
            assert.equal(Glyphs.BAR[8], Budget.bar(1))
            assert.equal(Glyphs.BAR[8], Budget.bar(1.3))
        end)
    end)

    describe("state", function()
        it("keeps the provider state", function()
            assert.equal(
                "exhausted",
                Budget.state(five_hour(0.5, 2.5 * HOUR, "exhausted"), NOW)
            )
            assert.equal("ok", Budget.state(five_hour(0.5, 2.5 * HOUR), NOW))
        end)

        it("raises ok to warning over pace", function()
            assert.equal(
                "warning",
                Budget.state(five_hour(0.9, 4 * HOUR), NOW)
            )
        end)

        it("is ok past the reset", function()
            assert.equal(
                "ok",
                Budget.state(five_hour(1, -HOUR, "exhausted"), NOW)
            )
        end)
    end)

    describe("statusline", function()
        it("is empty without a budget", function()
            assert.equal("", Budget.statusline({ now = NOW }))
        end)

        it("shows each window with its pie and bar", function()
            vim.g.agentic_budget = {
                five_hour(0.5, 2.5 * HOUR),
                -- 1 h left of 7 d at full use: pace just above 1.
                {
                    label = "7d",
                    utilization = 1,
                    resets_at = NOW + HOUR,
                    window_s = 7 * 24 * HOUR,
                    state = "ok",
                },
            }
            assert.equal(
                "5h "
                    .. Glyphs.PIE[5]
                    .. "  "
                    .. Glyphs.BAR[4]
                    .. " 7d "
                    .. Glyphs.PIE[9]
                    .. "  %#AgenticBudgetWarning#"
                    .. Glyphs.BAR[8]
                    .. "%*",
                Budget.statusline({ now = NOW })
            )
        end)

        it("colours the bar of a window that is not ok", function()
            vim.g.agentic_budget = { five_hour(0.5, 2.5 * HOUR, "exhausted") }
            assert.equal(
                "5h "
                    .. Glyphs.PIE[5]
                    .. "  %#AgenticBudgetExhausted#"
                    .. Glyphs.BAR[4]
                    .. "%*",
                Budget.statusline({ now = NOW })
            )
        end)

        it("colours the bar of a window over pace", function()
            vim.g.agentic_budget = { five_hour(0.9, 4 * HOUR) }
            assert.equal(
                "5h "
                    .. Glyphs.PIE[3]
                    .. "  %#AgenticBudgetWarning#"
                    .. Glyphs.BAR[8]
                    .. "%*",
                Budget.statusline({ now = NOW })
            )
        end)

        it("shows a window past its reset as empty and ok", function()
            vim.g.agentic_budget = { five_hour(1, -HOUR, "exhausted") }
            assert.equal(
                "5h " .. Glyphs.PIE[1] .. "  " .. Glyphs.BAR[1],
                Budget.statusline({ now = NOW })
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

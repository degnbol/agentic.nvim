local assert = require("tests.helpers.assert")

local BudgetHistory = require("agentic.budget_history")

local HOUR = 3600

--- A five-hour window.
--- @param utilization number
--- @param resets_at number
--- @param state "ok"|"warning"|"exhausted"|nil
--- @return agentic.acp.BudgetWindow
local function five_hour(utilization, resets_at, state)
    return {
        label = "5h",
        utilization = utilization,
        resets_at = resets_at,
        window_s = 5 * HOUR,
        state = state or "ok",
    }
end

describe("agentic.BudgetHistory", function()
    describe("from_windows", function()
        it("holds one sample per window", function()
            local window = five_hour(0.2, 100)

            assert.same({
                windows = {
                    ["5h"] = {
                        window = window,
                        samples = { { t = 10, utilization = 0.2 } },
                    },
                },
                blocked = {},
            }, BudgetHistory.from_windows({ window }, 10))
        end)

        it("blocks until the reset of an exhausted window only", function()
            local history = BudgetHistory.from_windows({
                five_hour(1, 100, "exhausted"),
                {
                    label = "7d",
                    utilization = 0.5,
                    resets_at = 900,
                    window_s = 7 * 24 * HOUR,
                    state = "warning",
                },
            }, 10)

            assert.same({ { 10, 100 } }, history.blocked)
        end)
    end)

    describe("merge", function()
        it("unions the samples of the same window", function()
            local merged = BudgetHistory.merge(
                BudgetHistory.from_windows({ five_hour(0.1, 100) }, 10),
                BudgetHistory.from_windows({ five_hour(0.2, 100) }, 20)
            )

            assert.same({
                { t = 10, utilization = 0.1 },
                { t = 20, utilization = 0.2 },
            }, merged.windows["5h"].samples)
        end)

        it(
            "collapses a run of equal utilization to its first sample",
            function()
                local merged = BudgetHistory.merge(
                    BudgetHistory.merge(
                        BudgetHistory.from_windows({ five_hour(0.1, 100) }, 10),
                        BudgetHistory.from_windows({ five_hour(0.1, 100) }, 20)
                    ),
                    BudgetHistory.from_windows({ five_hour(0.2, 100) }, 30)
                )

                assert.same({
                    { t = 10, utilization = 0.1 },
                    { t = 30, utilization = 0.2 },
                }, merged.windows["5h"].samples)
            end
        )

        it("rolls the current window to previous on a newer reset", function()
            local merged = BudgetHistory.merge(
                BudgetHistory.from_windows({ five_hour(0.6, 100) }, 10),
                BudgetHistory.from_windows({ five_hour(0.1, 200) }, 150)
            )
            local entry = merged.windows["5h"]

            assert.same(five_hour(0.1, 200), entry.window)
            assert.same({ { t = 150, utilization = 0.1 } }, entry.samples)
            assert.same({
                resets_at = 100,
                samples = { { t = 10, utilization = 0.6 } },
            }, entry.previous)
        end)

        it("drops windows older than previous", function()
            local merged = BudgetHistory.merge(
                BudgetHistory.merge(
                    BudgetHistory.from_windows({ five_hour(0.6, 100) }, 10),
                    BudgetHistory.from_windows({ five_hour(0.3, 200) }, 150)
                ),
                BudgetHistory.from_windows({ five_hour(0.1, 300) }, 250)
            )

            assert.equal(200, merged.windows["5h"].previous.resets_at)
        end)

        it("keeps the window of higher utilization on a tie", function()
            local merged = BudgetHistory.merge(
                BudgetHistory.from_windows({ five_hour(0.3, 100) }, 10),
                BudgetHistory.from_windows({ five_hour(0.2, 100) }, 20)
            )

            assert.equal(0.3, merged.windows["5h"].window.utilization)
        end)

        it("keeps the more severe state on a utilization tie", function()
            local merged = BudgetHistory.merge(
                BudgetHistory.from_windows(
                    { five_hour(0.3, 100, "warning") },
                    10
                ),
                BudgetHistory.from_windows({ five_hour(0.3, 100) }, 20)
            )

            assert.equal("warning", merged.windows["5h"].window.state)
        end)

        it("joins the blocked intervals", function()
            local merged = BudgetHistory.merge(
                BudgetHistory.from_windows(
                    { five_hour(1, 100, "exhausted") },
                    10
                ),
                BudgetHistory.from_windows(
                    { five_hour(1, 100, "exhausted") },
                    50
                )
            )

            assert.same({ { 10, 100 } }, merged.blocked)
        end)

        it("does not depend on the order of its arguments", function()
            local a = BudgetHistory.merge(
                BudgetHistory.from_windows(
                    { five_hour(0.6, 100, "warning") },
                    10
                ),
                BudgetHistory.from_windows({ five_hour(0.1, 200) }, 150)
            )
            local b = BudgetHistory.merge(
                BudgetHistory.from_windows({ five_hour(0.6, 100) }, 20),
                BudgetHistory.from_windows(
                    { five_hour(0.2, 200, "exhausted") },
                    160
                )
            )

            assert.same(BudgetHistory.merge(a, b), BudgetHistory.merge(b, a))
        end)

        it("keeps windows that only one side has", function()
            local merged = BudgetHistory.merge(
                BudgetHistory.empty(),
                BudgetHistory.from_windows({ five_hour(0.1, 100) }, 10)
            )

            assert.same(
                BudgetHistory.from_windows({ five_hour(0.1, 100) }, 10),
                merged
            )
        end)
    end)

    describe("prune", function()
        it(
            "drops blocked intervals that end before the longest window",
            function()
                local history =
                    BudgetHistory.from_windows({ five_hour(0.1, 100) }, 10)
                history.blocked = { { 0, 5 }, { 20, 30 } }

                local pruned = BudgetHistory.prune(history, 30 + 5 * HOUR - 1)

                assert.same({ { 20, 30 } }, pruned.blocked)
                assert.same(history.windows, pruned.windows)
            end
        )
    end)
end)

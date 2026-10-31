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
            assert.equal("warning", Budget.state(five_hour(0.9, 4 * HOUR), NOW))
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

    describe("trailing_pace", function()
        local L = 5 * HOUR

        --- A previous window resetting `reset_ago` seconds before `NOW`.
        --- @param reset_ago number
        --- @param samples agentic.BudgetHistory.Sample[]
        --- @return agentic.BudgetHistory.Span
        local function previous(reset_ago, samples)
            return { resets_at = NOW - reset_ago, samples = samples }
        end

        --- @param expected number
        --- @param actual number|nil
        local function near(expected, actual)
            assert.is_true(
                actual ~= nil and math.abs(actual - expected) < 1e-9,
                vim.inspect({ expected = expected, actual = actual })
            )
        end

        it(
            "is utilization ÷ fraction passed without previous or block",
            function()
                local window = five_hour(0.2, 4 * HOUR)

                near(
                    0.2 / Budget.elapsed(window, NOW),
                    Budget.trailing_pace(window, nil, {}, NOW)
                )
            end
        )

        it(
            "counts a previous window that ended before the span as idle",
            function()
                local window = five_hour(0.2, 4 * HOUR)
                local ended = previous(6 * HOUR, {
                    { t = NOW - 8 * HOUR, utilization = 0.9 },
                })

                near(
                    0.2 + 0.2 / L * 4 * HOUR,
                    Budget.trailing_pace(window, ended, {}, NOW)
                )
            end
        )

        it("adds the previous window's usage inside the span", function()
            local window = five_hour(0.1, 4 * HOUR)
            local span_start = NOW - L
            local prior = previous(HOUR, {
                { t = span_start - HOUR, utilization = 0.2 },
                { t = span_start + HOUR, utilization = 0.4 },
                { t = NOW - 2 * HOUR, utilization = 0.6 },
            })

            near(
                0.1 + (0.1 + 0.4) / L * 4 * HOUR,
                Budget.trailing_pace(window, prior, {}, NOW)
            )
        end)

        it(
            "leaves out time before the previous window's first sample",
            function()
                local window = five_hour(0.1, 4 * HOUR)
                local prior = previous(HOUR, {
                    { t = NOW - 3 * HOUR, utilization = 0.5 },
                    { t = NOW - 2 * HOUR, utilization = 0.6 },
                })

                near(
                    0.1 + (0.1 + 0.1) / (3 * HOUR) * 4 * HOUR,
                    Budget.trailing_pace(window, prior, {}, NOW)
                )
            end
        )

        it("ignores a previous window that is not before the window", function()
            local window = five_hour(0.2, 4 * HOUR)
            local overlapping = previous(-HOUR, {
                { t = NOW - HOUR, utilization = 0.9 },
            })

            assert.equal(
                Budget.trailing_pace(window, nil, {}, NOW),
                Budget.trailing_pace(window, overlapping, {}, NOW)
            )
        end)

        it("is the utilization past the reset", function()
            assert.equal(
                0.5,
                Budget.trailing_pace(five_hour(0.5, -HOUR), nil, {}, NOW)
            )
        end)

        it("is higher with a block inside the span", function()
            local window = five_hour(0.2, 2 * HOUR)
            local unblocked = Budget.trailing_pace(window, nil, {}, NOW) --[[@as number]]
            local blocked = Budget.trailing_pace(
                window,
                nil,
                { { NOW - 2 * HOUR, NOW - HOUR } },
                NOW
            ) --[[@as number]]

            assert.is_true(blocked > unblocked)
        end)

        it("is nil when less than 5 % of the span is known", function()
            assert.is_nil(
                Budget.trailing_pace(
                    five_hour(0.2, 2 * HOUR),
                    nil,
                    { { NOW - 3 * HOUR, NOW - 0.04 * L } },
                    NOW
                )
            )
        end)
    end)

    describe("record", function()
        local spy = require("tests.helpers.spy")
        local BudgetHistory = require("agentic.budget_history")
        local FileSystem = require("agentic.utils.file_system")
        local Logger = require("agentic.utils.logger")

        --- @type agentic.Budget
        local Fresh
        --- @type TestSpy
        local write_spy
        --- @type TestStub
        local watch_stub
        --- @type TestStub
        local notify_stub
        --- @type string
        local path
        --- @type integer
        local fired
        --- @type integer
        local autocmd

        --- @return agentic.BudgetHistory
        local function read_file()
            return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
        end

        before_each(function()
            -- Module-level history and file path, fresh per case.
            package.loaded["agentic.budget"] = nil
            Fresh = require("agentic.budget")
            write_spy = spy.on(FileSystem, "write_atomic")
            watch_stub = spy.stub(FileSystem, "watch")
            notify_stub = spy.stub(Logger, "notify")
            path = vim.fs.joinpath(vim.fn.tempname(), "budget.json")
            fired = 0
            autocmd = vim.api.nvim_create_autocmd("User", {
                pattern = "AgenticBudgetChanged",
                callback = function()
                    fired = fired + 1
                end,
            })
        end)

        after_each(function()
            package.loaded["agentic.budget"] = Budget
            write_spy:revert()
            watch_stub:revert()
            notify_stub:revert()
            vim.api.nvim_del_autocmd(autocmd)
        end)

        it("publishes the windows and fires once per change", function()
            local windows = { five_hour(0.5, HOUR) }

            Fresh.record(windows, NOW)
            Fresh.record(windows, NOW + 10)

            assert.same(windows, vim.g.agentic_budget)
            assert.equal(1, fired)
        end)

        it("publishes windows shortest first", function()
            local week = {
                label = "7d",
                utilization = 0.1,
                resets_at = NOW + HOUR,
                window_s = 7 * 24 * HOUR,
                state = "ok",
            }

            Fresh.record({ week, five_hour(0.5, HOUR) }, NOW)

            assert.same(
                { "5h", "7d" },
                vim.tbl_map(function(window)
                    return window.label
                end, vim.g.agentic_budget)
            )
        end)

        it("paces with the previous window it recorded", function()
            Fresh.record({ five_hour(0.8, -2 * HOUR) }, NOW - 3 * HOUR)
            local window = five_hour(0.1, 4 * HOUR)
            Fresh.record({ window }, NOW)

            assert.is_true(
                Fresh.pace(window, NOW)
                    ~= Fresh.trailing_pace(window, nil, {}, NOW)
            )
        end)

        it(
            "writes the file once for the same windows reported twice",
            function()
                Fresh.start(path)
                Fresh.record({ five_hour(0.5, HOUR) }, NOW)
                Fresh.record({ five_hour(0.5, HOUR) }, NOW + 10)

                assert.equal(1, write_spy.call_count)
                assert.equal(1, watch_stub.call_count)
            end
        )

        it("writes again when the file lost its samples", function()
            Fresh.start(path)
            Fresh.record({ five_hour(0.5, HOUR) }, NOW)
            vim.fn.writefile({ vim.json.encode(BudgetHistory.empty()) }, path)

            Fresh.record({ five_hour(0.5, HOUR) }, NOW + 10)

            assert.equal(2, write_spy.call_count)
            assert.same(
                { { t = NOW, utilization = 0.5 } },
                read_file().windows["5h"].samples
            )
        end)

        it("publishes the file's windows on start", function()
            local history =
                BudgetHistory.from_windows({ five_hour(0.3, HOUR) }, NOW)
            FileSystem.write_atomic(path, vim.json.encode(history))

            Fresh.start(path)

            assert.same({ five_hour(0.3, HOUR) }, vim.g.agentic_budget)
            assert.equal(1, fired)
        end)

        it("publishes once when another instance writes the file", function()
            Fresh.start(path)
            local on_change = watch_stub.calls[1][2]
            local other =
                BudgetHistory.from_windows({ five_hour(0.3, HOUR) }, NOW)
            FileSystem.write_atomic(path, vim.json.encode(other))

            on_change(nil)
            on_change(nil)

            assert.same({ five_hour(0.3, HOUR) }, vim.g.agentic_budget)
            assert.equal(1, fired)
        end)

        it("does not publish again for its own write", function()
            Fresh.start(path)
            local on_change = watch_stub.calls[1][2]
            Fresh.record({ five_hour(0.5, HOUR) }, NOW)

            on_change(nil)

            assert.equal(1, fired)
        end)

        it("ignores a second start", function()
            Fresh.start(path)
            Fresh.start(vim.fn.tempname())

            assert.equal(1, watch_stub.call_count)
        end)

        it("reads a missing file as empty", function()
            Fresh.start(path)

            assert.is_nil(vim.g.agentic_budget)
            assert.equal(0, notify_stub.call_count)
        end)

        it("reads invalid JSON as empty and replaces it", function()
            vim.fn.mkdir(vim.fs.dirname(path), "p")
            vim.fn.writefile({ "not json {{{" }, path)

            Fresh.start(path)
            assert.equal(1, notify_stub.call_count)

            Fresh.record({ five_hour(0.5, HOUR) }, NOW)
            assert.is_not_nil(read_file().windows["5h"])
        end)
    end)
end)

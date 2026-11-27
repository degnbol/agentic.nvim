--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local RunClocks = require("agentic.ui.run_clocks")

describe("agentic.ui.RunClocks", function()
    local now_ms
    local hrtime_stub
    --- @type agentic.ui.RunClocks
    local clocks

    before_each(function()
        now_ms = 0
        hrtime_stub = spy.stub(vim.uv, "hrtime")
        hrtime_stub:invokes(function()
            return now_ms * 1e6
        end)
        clocks = RunClocks:new(5000, function() end)
    end)

    after_each(function()
        clocks:destroy()
        hrtime_stub:revert()
    end)

    it("measures from the start", function()
        clocks:start("a", true)
        now_ms = 1234
        assert.equal(1234, clocks:elapsed("a"))
    end)

    it("drops the time before a restart", function()
        clocks:start("a", true)
        now_ms = 3000
        clocks:restart("a")
        now_ms = 7500
        assert.equal(4500, clocks:finish("a"))
    end)

    it("ignores a restart of an unknown clock", function()
        clocks:restart("a")
        assert.is_nil(clocks:elapsed("a"))
    end)

    it("keeps a clock that waits before its start waiting", function()
        clocks:wait("a")
        clocks:start("a", true)
        now_ms = 6000
        assert.is_nil(clocks:elapsed("a"))
        clocks:restart("a")
        now_ms = 12000
        assert.equal(6000, clocks:elapsed("a"))
    end)

    it("gives no time for a waiting clock's finish", function()
        clocks:start("a", true)
        clocks:wait("a")
        now_ms = 9000
        assert.is_nil(clocks:finish("a"))
        assert.same({}, clocks:take_reports())
    end)

    it("reports a finish at or above the threshold only", function()
        clocks:start("short", true)
        clocks:start("long", true)
        clocks:start("child", false)
        now_ms = 4999
        clocks:finish("short")
        now_ms = 5000
        clocks:finish("long")
        clocks:finish("child")
        assert.same({ { id = "long", ms = 5000 } }, clocks:take_reports())
    end)

    it("sets the report flag on a clock that exists", function()
        clocks:wait("a")
        clocks:start("a", true)
        clocks:restart("a")
        now_ms = 6000
        clocks:finish("a")
        assert.same({ { id = "a", ms = 6000 } }, clocks:take_reports())
    end)

    it("empties the reports it takes", function()
        clocks:start("a", true)
        now_ms = 6000
        clocks:finish("a")
        clocks:take_reports()
        assert.same({}, clocks:take_reports())
    end)

    it("ticks the running clocks at or above the threshold", function()
        local on_tick = spy.new(function() end)
        clocks:destroy()
        clocks = RunClocks:new(5000, on_tick)
        clocks:start("long", true)
        now_ms = 6000
        clocks:start("short", true)
        clocks:start("waiting", true)
        clocks:wait("waiting")
        clocks:_tick()
        assert.same({ { { "long" }, n = 1 } }, on_tick.calls)
    end)

    it("stops the tick when no clock runs, and a restart resumes it", function()
        clocks:start("a", true)
        assert.is_true(clocks._timer:is_active())
        clocks:wait("a")
        clocks:_tick()
        assert.is_false(clocks._timer:is_active())
        clocks:restart("a")
        assert.is_true(clocks._timer:is_active())
    end)

    it("clears every clock and report and stops the tick", function()
        clocks:start("a", true)
        clocks:start("b", true)
        now_ms = 6000
        clocks:finish("b")
        clocks:clear()
        assert.is_nil(clocks:elapsed("a"))
        assert.same({}, clocks:take_reports())
        assert.is_false(clocks._timer:is_active())
    end)

    it("forgets a dropped clock without a report", function()
        clocks:start("a", true)
        now_ms = 6000
        clocks:drop("a")
        assert.is_nil(clocks:finish("a"))
        assert.same({}, clocks:take_reports())
    end)
end)

--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local UsageLimit = require("agentic.acp.usage_limit")

describe("agentic.acp.UsageLimit", function()
    local NOW = 1000000
    --- @type integer
    local now
    --- @type TestStub
    local time_stub
    --- @type TestSpy
    local on_lift
    --- @type agentic.acp.UsageLimit
    local limit

    before_each(function()
        now = NOW
        time_stub = spy.stub(os, "time")
        time_stub:invokes(function()
            return now
        end)
        on_lift = spy.new()
        limit = UsageLimit:new(function()
            on_lift()
        end)
    end)

    after_each(function()
        limit:stop()
        time_stub:revert()
    end)

    it("is held until resets_at, and not after it with no timer", function()
        limit:hold(NOW + 600)
        assert.is_true(limit:is_held())
        limit:stop()
        now = NOW + 600
        assert.is_false(limit:is_held())
        assert.is_false(limit:holds_drain())
    end)

    it("fires the first attempt a margin after resets_at", function()
        limit:hold(NOW + 600)
        assert.equal(1, limit.attempt)
        assert.equal(NOW + 600 + 120, limit.lifts_at)
    end)

    it("waits the minimum when the reset is already past", function()
        limit:hold(NOW - 3600)
        assert.equal(NOW + 10, limit.lifts_at)
    end)

    it(
        "counts no attempt for a hit while held and moves times later",
        function()
            limit:hold(NOW + 600)
            limit:hold(NOW + 300)
            assert.equal(1, limit.attempt)
            assert.equal(NOW + 600, limit.resets_at)
            assert.equal(NOW + 720, limit.lifts_at)

            limit:hold(NOW + 900)
            assert.equal(1, limit.attempt)
            assert.equal(NOW + 900, limit.resets_at)
            assert.equal(NOW + 1020, limit.lifts_at)
        end
    )

    it("backs off a repeat after resets_at", function()
        limit:hold(NOW + 60)
        now = NOW + 61
        limit:hold(NOW + 61)
        assert.equal(2, limit.attempt)
        assert.equal(now + 300, limit.lifts_at)
    end)

    it("follows the reported reset only after MAX_ATTEMPTS", function()
        for i = 1, UsageLimit.MAX_ATTEMPTS + 1 do
            limit:_lift()
            now = NOW + i * 1000
            limit:hold(now - 200)
        end
        assert.equal(UsageLimit.MAX_ATTEMPTS + 1, limit.attempt)
        assert.equal(now + 10, limit.lifts_at)
    end)

    it(
        "clears both times on lift, keeps attempt, calls on_lift once",
        function()
            limit:hold(NOW + 600)
            limit:_lift()
            assert.is_nil(limit.resets_at)
            assert.is_nil(limit.lifts_at)
            assert.equal(1, limit.attempt)
            assert.equal(1, on_lift.call_count)
        end
    )

    it("clear_attempts forgets earlier attempts", function()
        limit:hold(NOW + 600)
        limit:clear_attempts()
        assert.equal(0, limit.attempt)
    end)

    it("stop does not lift", function()
        limit:hold(NOW + 600)
        limit:stop()
        assert.equal(0, on_lift.call_count)
        assert.is_nil(limit.lifts_at)
        assert.is_true(limit:is_held())
    end)

    it("starts a new timer after a lift closed the last one", function()
        limit:hold(NOW + 600)
        limit:_lift()
        limit:hold(NOW + 600)
        assert.is_not_nil(limit._timer)
        assert.equal(NOW + 720, limit.lifts_at)
    end)

    describe("holds_drain", function()
        it("holds until lifts_at while a timer runs", function()
            limit:hold(NOW + 600)
            now = NOW + 650
            assert.is_false(limit:is_held())
            assert.is_true(limit:holds_drain())
            now = NOW + 720
            assert.is_false(limit:holds_drain())
        end)

        it("holds until resets_at when no timer runs", function()
            limit:hold(NOW + 600)
            limit:stop()
            assert.is_true(limit:holds_drain())
            now = NOW + 600
            assert.is_false(limit:holds_drain())
        end)
    end)
end)

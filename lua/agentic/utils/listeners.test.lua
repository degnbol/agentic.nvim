local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local Listeners = require("agentic.utils.listeners")
local Logger = require("agentic.utils.logger")

describe("agentic.utils.Listeners", function()
    --- @type TestStub
    local notify_stub

    before_each(function()
        notify_stub = spy.stub(Logger, "notify")
    end)

    after_each(function()
        notify_stub:revert()
    end)

    it("calls listeners in order with the arguments", function()
        local listeners = Listeners:new()
        local calls = {}
        listeners:add(function(a, b)
            table.insert(calls, { "first", a, b })
        end)
        listeners:add(function(a, b)
            table.insert(calls, { "second", a, b })
        end)

        listeners:call(1, 2)

        assert.same({ { "first", 1, 2 }, { "second", 1, 2 } }, calls)
    end)

    it("removes a listener", function()
        local listeners = Listeners:new()
        local listener = spy.new(function() end)
        local remove = listeners:add(listener --[[@as function]])

        remove()
        remove()
        listeners:call()

        assert.equal(0, listener.call_count)
    end)

    it("reports an error and runs the rest", function()
        local listeners = Listeners:new()
        local after = spy.new(function() end)
        listeners:add(function()
            error("boom")
        end)
        listeners:add(after --[[@as function]])

        listeners:call()

        assert.equal(1, after.call_count)
        assert.equal(1, notify_stub.call_count)
    end)

    it("runs a listener removed during the run to the end of it", function()
        local listeners = Listeners:new()
        local second = spy.new(function() end)
        local remove_second
        listeners:add(function()
            remove_second()
        end)
        remove_second = listeners:add(second --[[@as function]])

        listeners:call()
        listeners:call()

        assert.equal(1, second.call_count)
    end)
end)

--- @diagnostic disable: invisible, assign-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.ACPClient", function()
    --- @type agentic.acp.ACPClient
    local ACPClient

    before_each(function()
        ACPClient = require("agentic.acp.acp_client")
    end)

    describe("_fail_pending_callbacks", function()
        it("invokes all pending callbacks with transport error", function()
            local cb1 = spy.new(function() end)
            local cb2 = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = { [1] = cb1, [2] = cb2 },
                state = "disconnected",
            }, { __index = ACPClient })

            client:_fail_pending_callbacks("disconnected")

            -- Callbacks are vim.schedule'd — flush the event loop
            vim.wait(50, function()
                return cb1.call_count > 0 and cb2.call_count > 0
            end)

            assert.spy(cb1).was.called(1)
            assert.spy(cb2).was.called(1)

            -- Both receive nil result and an error
            local args1 = cb1.calls[1]
            assert.is_nil(args1[1])
            assert.is_not_nil(args1[2])
            assert.equal(ACPClient.ERROR_CODES.TRANSPORT_ERROR, args1[2].code)

            local args2 = cb2.calls[1]
            assert.is_nil(args2[1])
            assert.equal(ACPClient.ERROR_CODES.TRANSPORT_ERROR, args2[2].code)
        end)

        it("clears the callbacks table", function()
            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = { [1] = function() end },
                state = "disconnected",
            }, { __index = ACPClient })

            client:_fail_pending_callbacks("disconnected")

            assert.same({}, client.callbacks)
        end)

        it("is a no-op when no callbacks are pending", function()
            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = {},
                state = "disconnected",
            }, { __index = ACPClient })

            -- Should not error
            client:_fail_pending_callbacks("error")
            assert.same({}, client.callbacks)
        end)
    end)

    describe("_set_state", function()
        it("calls _fail_pending_callbacks on disconnected", function()
            local fail_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = {},
                state = "ready",
            }, { __index = ACPClient })

            client._fail_pending_callbacks = fail_spy --[[@as function]]

            client:_set_state("disconnected")

            assert.equal("disconnected", client.state)
            assert.spy(fail_spy).was.called(1)
            assert.is_true(fail_spy:called_with(client, "disconnected"))
        end)

        it("calls _fail_pending_callbacks on error", function()
            local fail_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = {},
                state = "ready",
            }, { __index = ACPClient })

            client._fail_pending_callbacks = fail_spy --[[@as function]]

            client:_set_state("error")

            assert.spy(fail_spy).was.called(1)
            assert.is_true(fail_spy:called_with(client, "error"))
        end)

        it("does not call _fail_pending_callbacks for other states", function()
            local fail_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = {},
                state = "disconnected",
            }, { __index = ACPClient })

            client._fail_pending_callbacks = fail_spy --[[@as function]]

            for _, state in ipairs({
                "connecting",
                "connected",
                "initializing",
                "ready",
            }) do
                client:_set_state(state)
            end

            assert.spy(fail_spy).was.called(0)
        end)
    end)

    describe("_send_request", function()
        it("invokes callback with error when transport is nil", function()
            local cb = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = {},
                transport = nil,
                id_counter = 0,
                state = "disconnected",
            }, { __index = ACPClient })

            client:_send_request("test/method", {}, cb --[[@as function]])

            -- Callback should NOT be registered
            assert.same({}, client.callbacks)

            -- Callback is vim.schedule'd
            vim.wait(50, function()
                return cb.call_count > 0
            end)

            assert.spy(cb).was.called(1)
            local args = cb.calls[1]
            assert.is_nil(args[1])
            assert.equal(ACPClient.ERROR_CODES.TRANSPORT_ERROR, args[2].code)
        end)

        it(
            "invokes callback with error when transport:send returns false",
            function()
                local cb = spy.new(function() end)
                local send_stub = spy.new(function()
                    return false
                end)

                --- @type agentic.acp.ACPClient
                local client = setmetatable({
                    callbacks = {},
                    transport = { send = send_stub },
                    id_counter = 0,
                    state = "connected",
                }, { __index = ACPClient })

                client:_send_request("test/method", {}, cb --[[@as function]])

                -- Callback should NOT be registered
                assert.same({}, client.callbacks)

                -- send was called
                assert.spy(send_stub).was.called(1)

                -- Callback is vim.schedule'd
                vim.wait(50, function()
                    return cb.call_count > 0
                end)

                assert.spy(cb).was.called(1)
                local args = cb.calls[1]
                assert.is_nil(args[1])
                assert.equal(
                    ACPClient.ERROR_CODES.TRANSPORT_ERROR,
                    args[2].code
                )
            end
        )

        it("registers callback only after successful send", function()
            local cb = spy.new(function() end)
            local send_stub = spy.new(function()
                return true
            end)

            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = {},
                transport = { send = send_stub },
                id_counter = 0,
                state = "connected",
            }, { __index = ACPClient })

            client:_send_request("test/method", {}, cb --[[@as function]])

            -- send was called
            assert.spy(send_stub).was.called(1)

            -- Callback IS registered (id = 1 since id_counter starts at 0)
            assert.is_not_nil(client.callbacks[1])

            -- Callback NOT invoked yet (waiting for response)
            assert.spy(cb).was.called(0)
        end)
    end)
end)

--- @diagnostic disable: invisible, assign-type-mismatch, missing-fields, return-type-mismatch
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

    --- See .claude/skills/issues/references/chunk-flush.md and
    --- tests/integration/auto_continue_chunk_flush.test.lua. This block
    --- targets the ACPClient dispatch layer: after a prompt-response
    --- cycle ends with an error, a subsequent prompt's session/update
    --- notifications must reach the subscriber.
    describe("dispatch after error response (auto-continue path)", function()
        --- Build a minimal client wired to a stub transport. `id_counter`
        --- counts up as `_send_request` is called; `_handle_message` is
        --- used directly to simulate inbound traffic.
        --- @return agentic.acp.ACPClient client
        --- @return TestSpy send_stub
        local function make_client()
            local send_stub = spy.new(function()
                return true
            end)
            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = {},
                subscribers = {},
                id_counter = 0,
                state = "ready",
                transport = { send = send_stub },
                _loading_sessions = {},
                provider_config = { name = "test-provider" },
            }, { __index = ACPClient })
            return client, send_stub
        end

        --- Recording subscriber for a single session_id.
        local function make_recorder()
            local recorded = {
                session_updates = {},
                tool_calls = {},
                tool_call_updates = {},
                permissions = 0,
            }
            --- @type agentic.acp.ClientHandlers
            local handlers = {
                on_error = function() end,
                on_session_update = function(update)
                    table.insert(recorded.session_updates, update)
                end,
                on_tool_call = function(tc)
                    table.insert(recorded.tool_calls, tc)
                end,
                on_tool_call_update = function(tcu)
                    table.insert(recorded.tool_call_updates, tcu)
                end,
                on_request_permission = function(_, cb)
                    recorded.permissions = recorded.permissions + 1
                    cb(nil)
                end,
                on_stdout_text = function() end,
            }
            return handlers, recorded
        end

        it(
            "session/update notifications after a usage_limit error response still reach the subscriber",
            function()
                local client, send_stub = make_client()
                local session_id = "sess-123"
                local handlers, recorded = make_recorder()

                client:_subscribe(session_id, handlers)

                -- Prompt #1 — sent, reply is a usage_limit error.
                local prompt_1_cb = spy.new(function() end)
                client:_send_request(
                    "session/prompt",
                    { sessionId = session_id },
                    prompt_1_cb --[[@as function]]
                )

                client:_handle_message({
                    jsonrpc = "2.0",
                    id = 1,
                    error = {
                        code = -32000,
                        message = '{"type":"error","error":{"type":"usage_limit_error","message":"Claude AI usage limit reached|1800000000"}}',
                    },
                })

                vim.wait(50, function()
                    return prompt_1_cb.call_count > 0
                end)

                assert.spy(prompt_1_cb).was.called(1)

                -- Prompt #2 — the auto-continue "continue" prompt.
                local prompt_2_cb = spy.new(function() end)
                client:_send_request(
                    "session/prompt",
                    { sessionId = session_id },
                    prompt_2_cb --[[@as function]]
                )

                -- Provider streams: prose chunk, tool_call, tool_call_update,
                -- then the final end-of-turn response to prompt #2.
                client:_handle_message({
                    jsonrpc = "2.0",
                    method = "session/update",
                    params = {
                        sessionId = session_id,
                        update = {
                            sessionUpdate = "agent_message_chunk",
                            content = {
                                type = "text",
                                text = "Picking up where I left off.",
                            },
                        },
                    },
                })

                client:_handle_message({
                    jsonrpc = "2.0",
                    method = "session/update",
                    params = {
                        sessionId = session_id,
                        update = {
                            sessionUpdate = "tool_call",
                            toolCallId = "tc-after-continue",
                            kind = "read",
                            title = "/tmp/file.txt",
                            status = "pending",
                        },
                    },
                })

                client:_handle_message({
                    jsonrpc = "2.0",
                    method = "session/update",
                    params = {
                        sessionId = session_id,
                        update = {
                            sessionUpdate = "tool_call_update",
                            toolCallId = "tc-after-continue",
                            status = "completed",
                        },
                    },
                })

                client:_handle_message({
                    jsonrpc = "2.0",
                    id = 2,
                    result = { stopReason = "end_turn" },
                })

                vim.wait(50, function()
                    return prompt_2_cb.call_count > 0
                        and #recorded.session_updates > 0
                        and #recorded.tool_calls > 0
                        and #recorded.tool_call_updates > 0
                end)

                assert.spy(prompt_2_cb).was.called(1)
                -- agent_message_chunk must reach subscriber
                assert.equal(1, #recorded.session_updates)
                -- tool_call must reach subscriber
                assert.equal(1, #recorded.tool_calls)
                -- tool_call_update must reach subscriber
                assert.equal(1, #recorded.tool_call_updates)

                -- Transport received two outbound `session/prompt` sends
                -- plus however many `_send_request` happens to issue; the
                -- important invariant is that neither prompt clobbered
                -- the subscriber table.
                assert.is_not_nil(client.subscribers[session_id])
                assert.is_true(send_stub.call_count >= 2)
            end
        )

        it(
            "permission request sandwiched between chunks still dispatches to subscriber",
            function()
                local client, _send_stub = make_client()
                local session_id = "sess-456"
                local handlers, recorded = make_recorder()

                client:_subscribe(session_id, handlers)

                -- Prompt hits usage_limit first.
                local prompt_1_cb = spy.new(function() end)
                client:_send_request(
                    "session/prompt",
                    { sessionId = session_id },
                    prompt_1_cb --[[@as function]]
                )
                client:_handle_message({
                    jsonrpc = "2.0",
                    id = 1,
                    error = {
                        code = -32000,
                        message = '{"type":"error","error":{"type":"usage_limit_error","message":"reset|1800000000"}}',
                    },
                })

                vim.wait(50, function()
                    return prompt_1_cb.call_count > 0
                end)

                -- Auto-continue prompt.
                local prompt_2_cb = spy.new(function() end)
                client:_send_request(
                    "session/prompt",
                    { sessionId = session_id },
                    prompt_2_cb --[[@as function]]
                )

                -- Chunk before permission.
                client:_handle_message({
                    jsonrpc = "2.0",
                    method = "session/update",
                    params = {
                        sessionId = session_id,
                        update = {
                            sessionUpdate = "agent_message_chunk",
                            content = {
                                type = "text",
                                text = "Before permission.",
                            },
                        },
                    },
                })

                -- Permission request mid-turn (id=99 so it doesn't
                -- collide with the prompt-response id allocator).
                client:_handle_message({
                    jsonrpc = "2.0",
                    id = 99,
                    method = "session/request_permission",
                    params = {
                        sessionId = session_id,
                        toolCall = {
                            toolCallId = "tc-perm",
                            kind = "edit",
                            title = "/tmp/x.txt",
                        },
                        options = {
                            {
                                kind = "allow_once",
                                name = "Allow",
                                optionId = "allow-once",
                            },
                        },
                    },
                })

                -- Chunk after permission.
                client:_handle_message({
                    jsonrpc = "2.0",
                    method = "session/update",
                    params = {
                        sessionId = session_id,
                        update = {
                            sessionUpdate = "agent_message_chunk",
                            content = {
                                type = "text",
                                text = "After permission.",
                            },
                        },
                    },
                })

                vim.wait(50, function()
                    return #recorded.session_updates >= 2
                        and recorded.permissions > 0
                end)

                -- Both chunks must dispatch; permission must not swallow them
                assert.equal(2, #recorded.session_updates)
                -- Permission request must dispatch to subscriber
                assert.equal(1, recorded.permissions)
            end
        )
    end)
end)

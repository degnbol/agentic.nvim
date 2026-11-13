--- @diagnostic disable: invisible, assign-type-mismatch, missing-fields, return-type-mismatch, param-type-mismatch
local Logger = require("agentic.utils.logger")
local MiniTest = require("mini.test")
local assert = require("tests.helpers.assert")
local Deferred = require("tests.helpers.deferred")
local RecordingHandlers = require("tests.helpers.recording_handlers")
local spy = require("tests.helpers.spy")
local ToolCallKinds = require("agentic.acp.tool_call_kinds")
local UsageLimit = require("agentic.acp.usage_limit")

describe("agentic.acp.ACPClient", function()
    --- @type agentic.acp.ACPClient
    local ACPClient

    before_each(function()
        ACPClient = require("agentic.acp.acp_client")
    end)

    describe("subagent defaults", function()
        it("predict blocking and give no message instruction", function()
            local client = setmetatable({}, { __index = ACPClient })

            assert.equal("blocking", client:subagent_predicted_mode())
            assert.is_nil(client:subagent_message_instruction("a1", "x", "m"))
        end)
    end)

    it("drains no hook records by default", function()
        local client = setmetatable({}, { __index = ACPClient })
        assert.same({}, client:drain_side_records("s-1"))
    end)

    it("names no plan file by default", function()
        local client = setmetatable({}, { __index = ACPClient })
        assert.is_nil(client:plan_file({
            sessionId = "s-1",
            toolCall = { toolCallId = "tc-1" },
            options = {},
        }))
    end)

    describe("exec shell", function()
        it("is unknown by default", function()
            local client = setmetatable({}, { __index = ACPClient })
            assert.is_nil(client:exec_shell())
        end)

        it("stamps the shell on every tool call message", function()
            local client = setmetatable({}, { __index = ACPClient })
            function client:exec_shell()
                return "zsh"
            end
            local msg = client:__build_tool_call_message({
                toolCallId = "tc-1",
                kind = "read",
                status = "pending",
                title = "f.lua",
            })
            assert.equal("zsh", msg.shell)
        end)
    end)

    describe("_on_process_output", function()
        local Config = require("agentic.config")

        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local file_stub
        --- @type boolean|nil
        local original_log

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            file_stub = spy.stub(Logger, "debug_to_file")
            original_log = Config.log
            Config.log = false
        end)

        after_each(function()
            notify_stub:revert()
            file_stub:revert()
            Config.log = original_log
        end)

        --- @param provider_config agentic.acp.ACPProviderConfig|nil
        --- @return agentic.acp.ACPClient
        local function make_client(provider_config)
            return setmetatable({
                provider_config = provider_config
                    or { name = "Provider", command = "provider-cmd" },
                agent_info = { name = "p", version = "1.0" },
                _notified_output = {},
            }, { __index = ACPClient })
        end

        it("notifies once per summary and logs every line", function()
            local client = make_client()

            client:_on_process_output("stderr", 'Unexpected case: {"a":1}')
            client:_on_process_output("stderr", 'Unexpected case: {"b":2}')

            assert.spy(notify_stub).was.called(1)
            assert.spy(file_stub).was.called(2)
        end)

        it("notifies again for a different summary", function()
            local client = make_client()

            client:_on_process_output("stderr", "first problem")
            client:_on_process_output("stderr", "second problem")

            assert.spy(notify_stub).was.called(2)
        end)

        it("logs an ignored line without notifying", function()
            local client = make_client()

            client:_on_process_output("stderr", "Session not found: s-1")

            assert.spy(file_stub).was.called(1)
            assert.spy(notify_stub).was.called(0)
        end)

        it("warns with the provider name, version and stream", function()
            make_client():_on_process_output("stdout", "oops")

            local args = notify_stub.calls[1]
            assert.equal("Provider 1.0 stdout: oops", args[1])
            assert.equal(vim.log.levels.WARN, args[2])
        end)

        it("names the provider by command when it has no name", function()
            make_client({ command = "provider-cmd" }):_on_process_output(
                "stderr",
                "oops"
            )

            assert.equal(
                "provider-cmd 1.0 stderr: oops",
                notify_stub.calls[1][1]
            )
        end)

        it("points at the log folder only while logging", function()
            Config.log = true
            make_client():_on_process_output("stderr", "oops")
            assert.equal(
                "Provider 1.0 stderr: oops (logs in " .. Logger.LOG_DIR .. ")",
                notify_stub.calls[1][1]
            )
        end)
    end)

    describe("_fail_pending_callbacks", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        it("invokes all pending callbacks with transport error", function()
            local cb1 = spy.new(function() end)
            local cb2 = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = { [1] = cb1, [2] = cb2 },
                state = "disconnected",
            }, { __index = ACPClient })

            client:_fail_pending_callbacks("disconnected")

            -- Callbacks are vim.schedule'd
            deferred.drain()

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
                subscribers = {},
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
                subscribers = {},
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

    describe("_broadcast", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        it(
            "calls the handler on each subscriber that has it, on the main loop",
            function()
                local lifted_a = spy.new(function() end)
                local lifted_b = spy.new(function() end)
                --- @type agentic.acp.ACPClient
                local client = setmetatable({
                    subscribers = {
                        a = { on_usage_lifted = lifted_a },
                        b = { on_usage_lifted = lifted_b },
                        c = {},
                    },
                    _children = {},
                }, { __index = ACPClient })

                client:_broadcast("on_usage_lifted")
                assert.spy(lifted_a).was.called(0)
                deferred.drain()

                assert.spy(lifted_a).was.called(1)
                assert.spy(lifted_b).was.called(1)
            end
        )
    end)

    describe("usage_limit", function()
        it("gives each client its own limit, whose lift broadcasts", function()
            local connect_stub = spy.stub(ACPClient, "_connect")
            local transport_stub = spy.stub(ACPClient, "_setup_transport")
            local first = ACPClient:new({}, function() end)
            local second = ACPClient:new({}, function() end)
            connect_stub:revert()
            transport_stub:revert()
            local broadcast = spy.stub(first, "_broadcast")

            first.usage_limit:_lift()

            assert.are_not.equal(first.usage_limit, second.usage_limit)
            assert.is_true(broadcast:called_with(first, "on_usage_lifted"))
        end)
    end)

    describe("_send_request", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

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
            deferred.drain()

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
                deferred.drain()

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
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

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
                _children = {},
                _session_roots = {},
                _unanswered = {},
                _tool_call_kinds = ToolCallKinds:new(),
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
                        code = -32603,
                        message = '{"type":"error","error":{"type":"usage_limit_error","message":"Claude AI usage limit reached|1800000000"}}',
                    },
                })

                deferred.drain()

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

                deferred.drain()

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
                        code = -32603,
                        message = '{"type":"error","error":{"type":"usage_limit_error","message":"reset|1800000000"}}',
                    },
                })

                deferred.drain()

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

                deferred.drain()

                -- Both chunks must dispatch; permission must not swallow them
                assert.equal(2, #recorded.session_updates)
                -- Permission request must dispatch to subscriber
                assert.equal(1, recorded.permissions)
            end
        )
    end)

    describe("send_prompt on ACP v1", function()
        --- @type tests.helpers.Deferred
        local deferred
        --- @type table[] Decoded JSON of each message sent
        local sent

        before_each(function()
            deferred = Deferred.capture()
            sent = {}
        end)

        after_each(function()
            deferred.revert()
        end)

        --- A ready v1 client with `handlers` subscribed to session "s".
        --- @param handlers agentic.acp.ClientHandlers
        --- @return agentic.acp.ACPClient client
        local function make_client(handlers)
            --- @type agentic.acp.ACPClient
            local client = setmetatable({
                callbacks = {},
                subscribers = { s = handlers },
                id_counter = 0,
                protocol_version = 1,
                state = "ready",
                transport = {
                    send = function(_self, data)
                        table.insert(sent, vim.json.decode(data))
                        return true
                    end,
                },
                _loading_sessions = {},
                _children = {},
                _session_roots = {},
                _unanswered = {},
                _tool_call_kinds = ToolCallKinds:new(),
                provider_config = { name = "test-provider" },
            }, { __index = ACPClient })
            return client
        end

        --- Answer the `n`th request sent.
        --- @param client agentic.acp.ACPClient
        --- @param n integer
        --- @param result table|nil
        --- @param err table|nil
        local function answer(client, n, result, err)
            client:_handle_message({
                jsonrpc = "2.0",
                id = sent[n].id,
                result = result,
                error = err,
            })
            deferred.drain()
        end

        it("takes the prompt in at send and starts a turn", function()
            local handlers, calls = RecordingHandlers.new()
            local client = make_client(handlers)

            client:send_prompt("s", {}, function() end)

            assert.same({
                { "on_prompt_taken" },
                { "on_turn_state", { state = "running" } },
            }, calls)
        end)

        it("ends the turn idle with the answer's stop reason", function()
            local handlers, calls = RecordingHandlers.new()
            local client = make_client(handlers)
            local answers = {}
            client:send_prompt("s", {}, function(result)
                table.insert(answers, result)
            end)

            local usage = { inputTokens = 3 }
            answer(client, 1, { stopReason = "max_tokens", usage = usage })

            assert.same({
                "on_turn_state",
                {
                    state = "idle",
                    stop_reason = "max_tokens",
                    usage = usage,
                    more = false,
                },
            }, calls[3])
            assert.equal(3, #calls)
            assert.same(
                { { stopReason = "max_tokens", usage = usage } },
                answers
            )
        end)

        it("ends the turn idle with an error answer", function()
            local handlers, calls = RecordingHandlers.new()
            local client = make_client(handlers)
            client:send_prompt("s", {}, function() end)

            answer(client, 1, nil, { code = -32603, message = "boom" })

            local state = calls[3][2]
            assert.equal("idle", state.state)
            assert.equal("error", state.stop_reason)
            assert.equal("boom", state.error.message)
        end)

        it(
            "starts the next turn while a second prompt is unanswered",
            function()
                local handlers, calls = RecordingHandlers.new()
                local client = make_client(handlers)
                client:send_prompt("s", {}, function() end)
                client:send_prompt("s", {}, function() end)

                answer(client, 1, { stopReason = "end_turn" })

                assert.same(
                    {
                        "on_prompt_taken",
                        "on_turn_state",
                        "on_prompt_taken",
                        "on_turn_state",
                        "on_turn_state",
                    },
                    vim.tbl_map(function(call)
                        return call[1]
                    end, calls)
                )
                assert.is_true(calls[4][2].more)
                assert.same({ state = "running" }, calls[5][2])

                answer(client, 2, { stopReason = "end_turn" })

                assert.equal(6, #calls)
                assert.is_false(calls[6][2].more)
            end
        )

        it("calls back a subscriber without turn handlers", function()
            local client = make_client({
                on_session_update = function() end,
                on_request_permission = function() end,
                on_tool_call = function() end,
                on_tool_call_update = function() end,
            })
            local done = spy.new(function() end)

            client:send_prompt("s", {}, done --[[@as function]])
            answer(client, 1, { stopReason = "end_turn" })

            assert.equal(1, done.call_count)
        end)
    end)

    describe("_apply_initialize_result", function()
        local client
        before_each(function()
            client = setmetatable({}, { __index = ACPClient })
        end)

        it("captures the agent-reported version", function()
            client:_apply_initialize_result({
                protocolVersion = 1,
                agentInfo = {
                    name = "@agentclientprotocol/claude-agent-acp",
                    title = "Claude Agent",
                    version = "0.66.0",
                },
            })

            assert.equal("0.66.0", client.agent_info.version)
        end)

        it("leaves agent_info nil when the agent reports none", function()
            client:_apply_initialize_result({
                protocolVersion = 1,
                agentCapabilities = { loadSession = true },
            })

            assert.is_nil(client.agent_info)
            assert.same({}, client.auth_methods)
        end)
    end)

    describe("auth at startup", function()
        local notify_stub
        --- @type TestSpy
        local on_ready
        --- @type { method: string, params: table }[]
        local requests
        --- Answer to `authenticate`; overridden per case.
        --- @type agentic.acp.ACPError|nil
        local authenticate_err

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            authenticate_err = nil
        end)

        after_each(function()
            notify_stub:revert()
        end)

        --- Connect a client whose agent advertises `methods`.
        --- @param auth_method string|nil Configured `auth_method`
        --- @param methods agentic.acp.AuthMethod[]
        --- @return agentic.acp.ACPClient client
        local function connect(auth_method, methods)
            requests = {}
            on_ready = spy.new(function() end)
            --- @type agentic.acp.ACPClient
            local client
            client = setmetatable({
                state = "disconnected",
                callbacks = {},
                capabilities = {},
                provider_config = { auth_method = auth_method },
                _connection = 0,
                _ready_waiters = {},
                transport = {
                    start = function()
                        client.state = "connected"
                    end,
                },
            }, { __index = ACPClient }) --[[@as agentic.acp.ACPClient]]
            client._send_request = function(_self, method, params, cb)
                table.insert(requests, { method = method, params = params })
                if method == "initialize" then
                    cb({ protocolVersion = 1, authMethods = methods }, nil)
                elseif method == "authenticate" then
                    cb({}, authenticate_err)
                end
            end
            client:when_ready(on_ready)
            client:_connect()
            return client
        end

        --- @return string[] methods
        local function sent_methods()
            return vim.tbl_map(function(r)
                return r.method
            end, requests)
        end

        it("declares terminal auth", function()
            local setup_stub = spy.stub(ACPClient, "_setup_transport")
            local connect_stub = spy.stub(ACPClient, "_connect")
            MiniTest.finally(function()
                setup_stub:revert()
                connect_stub:revert()
            end)

            local client = ACPClient:new({ command = "x" }, function() end)

            assert.is_true(client.capabilities.auth.terminal)
        end)

        it("advertises its class's capability_meta", function()
            local setup_stub = spy.stub(ACPClient, "_setup_transport")
            local connect_stub = spy.stub(ACPClient, "_connect")
            MiniTest.finally(function()
                setup_stub:revert()
                connect_stub:revert()
            end)
            local Child = ACPClient.extend()
            function Child:capability_meta()
                return { vendor = true }
            end

            local base = ACPClient:new({ command = "x" }, function() end)
            local child = ACPClient.new(
                Child,
                { command = "x" },
                function() end
            )

            assert.is_nil(base.capabilities._meta)
            assert.same({ vendor = true }, child.capabilities._meta)
        end)

        it("authenticates a configured agent method", function()
            local client = connect("key", {
                { id = "key", name = "Key" },
                { id = "other", name = "Other", type = "agent" },
            })

            assert.same({ "initialize", "authenticate" }, sent_methods())
            assert.equal("key", requests[2].params.methodId)
            assert.equal("ready", client.state)
            assert.spy(on_ready).was.called(1)
        end)

        for label, methods in pairs({
            terminal = {
                { id = "login", name = "L", type = "terminal", args = {} },
            },
            ["unknown-type"] = {
                { id = "login", name = "L", type = "env_var" },
            },
            unadvertised = { { id = "other", name = "O" } },
        }) do
            it("does not act on a " .. label .. " method", function()
                local client = connect("login", methods)

                assert.same({ "initialize" }, sent_methods())
                assert.equal("ready", client.state)
                assert.spy(notify_stub).was.called(0)
            end)
        end

        it("goes ready after an authenticate error", function()
            authenticate_err = { code = -32603, message = "nope" }
            local client = connect("key", { { id = "key", name = "Key" } })

            assert.equal("ready", client.state)
            assert.spy(on_ready).was.called(1)
            assert.spy(notify_stub).was.called(1)
            assert.truthy(notify_stub.calls[1][1]:find("nope", 1, true))
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)

    describe("restart", function()
        local notify_stub
        --- @type tests.helpers.Deferred
        local deferred
        --- Methods sent, by request id.
        --- @type table<integer, string>
        local sent

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            deferred = Deferred.capture()
        end)

        after_each(function()
            notify_stub:revert()
            deferred.revert()
        end)

        --- A client connected with `on_ready`. Its transport stops by
        --- reporting `disconnected`, which fails the pending requests as a
        --- real stop does.
        --- @param auth_method string|nil Configured `auth_method`
        --- @param on_ready fun(client: agentic.acp.ACPClient)
        --- @return agentic.acp.ACPClient client
        local function connect(auth_method, on_ready)
            sent = {}
            --- @type agentic.acp.ACPClient
            local client
            client = setmetatable({
                state = "disconnected",
                callbacks = {},
                subscribers = {},
                id_counter = 0,
                capabilities = {},
                provider_config = { auth_method = auth_method },
                _connection = 0,
                _on_ready = on_ready,
                _ready_waiters = {},
                _session_roots = {},
                _unanswered = {},
                _children = {},
                _tool_call_kinds = ToolCallKinds:new(),
                transport = {
                    start = function()
                        client.state = "connected"
                    end,
                    stop = function()
                        client:_set_state("disconnected")
                    end,
                    send = function(_self, data)
                        local message = vim.json.decode(data)
                        sent[message.id] = message.method
                        return true
                    end,
                },
            }, { __index = ACPClient }) --[[@as agentic.acp.ACPClient]]
            client:when_ready(on_ready)
            client:_connect()
            return client
        end

        --- Answer request `id` with `result`.
        --- @param client agentic.acp.ACPClient
        --- @param id integer
        --- @param result table
        local function answer(client, id, result)
            client.callbacks[id](result, nil)
            client.callbacks[id] = nil
        end

        local KEY = {
            protocolVersion = 1,
            authMethods = { { id = "key", name = "K" } },
        }

        it("gives the new subprocess's ready to the passed callback", function()
            local creator = spy.new(function() end)
            local client = connect(nil, creator)
            answer(client, 1, { protocolVersion = 1 })
            local replacement = spy.new(function() end)

            client:restart(replacement)
            answer(client, 2, { protocolVersion = 1 })

            assert.equal("ready", client.state)
            assert.spy(creator).was.called(1)
            assert.spy(replacement).was.called(1)
        end)

        it("unsubscribes every session after their disconnect", function()
            local client = connect(nil, function() end)
            answer(client, 1, { protocolVersion = 1 })
            local on_disconnect = spy.new(function() end)
            client.subscribers.s1 = { on_disconnect = on_disconnect }

            client:restart(function() end)
            deferred.drain()

            assert.spy(on_disconnect).was.called(1)
            assert.is_nil(client.subscribers.s1)
        end)

        it("keeps the usage limit", function()
            local client = connect(nil, function() end)
            answer(client, 1, { protocolVersion = 1 })
            local limit = UsageLimit:new(function() end)
            client.usage_limit = limit

            client:restart(function() end)

            assert.equal(limit, client.usage_limit)
        end)

        -- The creator waits for the client, not for a connection, and
        -- waiters run before the passed callback.
        it("ignores a failed initialize of the old connection", function()
            local order = {}
            local client = connect(nil, function()
                table.insert(order, "creator")
            end)

            client:restart(function()
                table.insert(order, "replacement")
            end)
            deferred.drain()

            assert.equal("initializing", client.state)
            assert.equal("initialize", sent[2])
            answer(client, 2, { protocolVersion = 1 })
            assert.equal("ready", client.state)
            assert.same({ "creator", "replacement" }, order)
        end)

        it("ignores the startup authenticate of the old connection", function()
            local creator = spy.new(function() end)
            local client = connect("key", creator)
            answer(client, 1, KEY)
            assert.equal("authenticate", sent[2])
            local replacement = spy.new(function() end)

            client:restart(replacement)
            deferred.drain()

            assert.equal("initializing", client.state)
            assert.spy(creator).was.called(0)
            assert.spy(replacement).was.called(0)
            assert.spy(notify_stub).was.called(0)
        end)

        it("restart(A) then restart(B) before ready runs only B", function()
            local client = connect(nil, function() end)
            answer(client, 1, { protocolVersion = 1 })
            local a = spy.new(function() end)
            local b = spy.new(function() end)

            client:restart(a)
            client:restart(b)
            deferred.drain()
            answer(client, 3, { protocolVersion = 1 })

            assert.spy(a).was.called(0)
            assert.spy(b).was.called(1)
        end)

        it(
            "runs a waiter queued before a failed initialize at the restart's ready",
            function()
                local order = {}
                local client = connect(nil, function()
                    table.insert(order, "creator")
                end)
                local initialize_cb = client.callbacks[1]
                client.callbacks[1] = nil
                initialize_cb(nil, { code = -32603, message = "boom" })
                assert.equal("error", client.state)

                client:restart(function()
                    table.insert(order, "replacement")
                end)
                deferred.drain()
                answer(client, 2, { protocolVersion = 1 })
                client:restart(function() end)
                deferred.drain()
                answer(client, 3, { protocolVersion = 1 })

                assert.same({ "creator", "replacement" }, order)
            end
        )

        it("keeps a waiter across a restart that replaces another", function()
            local order = {}
            local client = connect(nil, function() end)
            answer(client, 1, { protocolVersion = 1 })

            client:restart()
            client:when_ready(function()
                table.insert(order, "waiter")
            end)
            client:restart(function()
                table.insert(order, "restart")
            end)
            deferred.drain()
            answer(client, 3, { protocolVersion = 1 })

            assert.same({ "waiter", "restart" }, order)
        end)

        describe("when_ready", function()
            it("calls at once on a ready client", function()
                local client = connect(nil, function() end)
                answer(client, 1, { protocolVersion = 1 })
                local waiter = spy.new(function() end)

                client:when_ready(waiter)

                assert.spy(waiter).was.called(1)
                assert.equal(client, waiter.calls[1][1])
            end)

            it(
                "runs the waiters queued while initializing once, in order",
                function()
                    local order = {}
                    local client = connect(nil, function()
                        table.insert(order, 1)
                    end)
                    client:when_ready(function()
                        table.insert(order, 2)
                    end)
                    client:when_ready(function()
                        table.insert(order, 3)
                    end)

                    answer(client, 1, { protocolVersion = 1 })
                    client:restart(function() end)
                    deferred.drain()
                    answer(client, 2, { protocolVersion = 1 })

                    assert.same({ 1, 2, 3 }, order)
                end
            )

            it("keeps the waiters after one that stops the client", function()
                local order = {}
                local client = connect(nil, function(c)
                    c:stop()
                end)
                client:when_ready(function()
                    table.insert(order, "later")
                end)

                answer(client, 1, { protocolVersion = 1 })
                deferred.drain()
                assert.equal("disconnected", client.state)
                assert.same({}, order)

                client:restart(function()
                    table.insert(order, "restart")
                end)
                answer(client, 2, { protocolVersion = 1 })
                assert.same({ "later", "restart" }, order)
            end)
        end)

        describe("process death during startup", function()
            it("stays disconnected when it dies during authenticate", function()
                local waiter = spy.new(function() end)
                local client = connect("key", waiter)
                answer(client, 1, KEY)
                assert.equal("authenticate", sent[2])

                client.transport:stop()
                deferred.drain()

                assert.equal("disconnected", client.state)
                assert.spy(waiter).was.called(0)
                assert.spy(notify_stub).was.called(1)
                assert.truthy(
                    notify_stub.calls[1][1]:find(
                        "Authentication with K",
                        1,
                        true
                    )
                )
            end)

            it("stays disconnected when it dies during initialize", function()
                local client = connect(nil, function() end)

                client.transport:stop()
                deferred.drain()

                assert.equal("disconnected", client.state)
                assert.spy(notify_stub).was.called(1)
                assert.truthy(
                    notify_stub.calls[1][1]:find(
                        "Failed to initialize",
                        1,
                        true
                    )
                )
            end)
        end)

        it(
            "runs _on_ready once over a failed then a successful reconnect",
            function()
                local transport_module = require("agentic.acp.acp_transport")
                --- @type agentic.acp.TransportCallbacks
                local callbacks
                local on_ready = spy.new(function() end)
                local client = connect(nil, on_ready)
                local transport = client.transport
                local create_stub =
                    spy.stub(transport_module, "create_stdio_transport")
                create_stub:invokes(function(_config, cbs)
                    callbacks = cbs
                    return transport
                end)
                MiniTest.finally(function()
                    create_stub:revert()
                end)
                client:_setup_transport()
                answer(client, 1, { protocolVersion = 1 })
                on_ready:reset()

                transport:stop()
                deferred.drain()
                callbacks.on_reconnect()
                transport:stop()
                deferred.drain()
                callbacks.on_reconnect()
                answer(client, 3, { protocolVersion = 1 })

                assert.equal("ready", client.state)
                assert.spy(on_ready).was.called(1)
            end
        )
    end)

    describe("close_session", function()
        local notify_stub
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            deferred = Deferred.capture()
        end)

        after_each(function()
            notify_stub:revert()
            deferred.revert()
        end)

        --- A client subscribed to `s1`, recording what it sends.
        --- @param capabilities table|nil `agent_capabilities`
        --- @return agentic.acp.ACPClient client
        --- @return { method: string, params: table, cb: function|nil }[] sent
        local function make_client(capabilities)
            local sent = {}
            local client = setmetatable({
                agent_capabilities = capabilities,
                subscribers = { s1 = {} },
                _session_roots = {},
                _unanswered = {},
                _children = {},
                _tool_call_kinds = ToolCallKinds:new(),
                _v2_states = {},
            }, { __index = ACPClient }) --[[@as agentic.acp.ACPClient]]
            client._send_request = function(_self, method, params, cb)
                table.insert(
                    sent,
                    { method = method, params = params, cb = cb }
                )
            end
            client._send_notification = function(_self, method, params)
                table.insert(sent, { method = method, params = params })
            end
            return client, sent
        end

        local CAN_CLOSE = { sessionCapabilities = { close = {} } }

        it("sends session/close and calls back after its answer", function()
            local client, sent = make_client(CAN_CLOSE)
            local on_closed = spy.new(function() end)

            client:close_session("s1", on_closed)

            assert.is_nil(client.subscribers.s1)
            assert.equal(1, #sent)
            assert.equal("session/close", sent[1].method)
            assert.same({ sessionId = "s1" }, sent[1].params)
            assert.spy(on_closed).was.called(0)
            sent[1].cb({}, nil)
            assert.spy(on_closed).was.called(1)
            assert.spy(notify_stub).was.called(0)
        end)

        it("reports an error answer and still calls back", function()
            local client, sent = make_client(CAN_CLOSE)
            local on_closed = spy.new(function() end)

            client:close_session("s1", on_closed)
            sent[1].cb(nil, { code = -32603, message = "boom" })

            assert.spy(notify_stub).was.called(1)
            assert.truthy(notify_stub.calls[1][1]:find("boom", 1, true))
            assert.spy(on_closed).was.called(1)
        end)

        it("cancels without the capability", function()
            local client, sent = make_client({ loadSession = true })
            local on_closed = spy.new(function() end)

            client:close_session("s1", on_closed)

            assert.is_nil(client.subscribers.s1)
            assert.equal(1, #sent)
            assert.equal("session/cancel", sent[1].method)
            assert.same({ sessionId = "s1" }, sent[1].params)
            assert.spy(on_closed).was.called(0)
            deferred.drain()
            assert.spy(on_closed).was.called(1)
        end)
    end)

    describe("fork_session", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        --- A client recording what it sends, whose provider can cut a fork
        --- unless `meta` is false.
        --- @param capabilities table|nil `agent_capabilities`
        --- @param meta boolean|nil
        --- @return agentic.acp.ACPClient client
        --- @return { method: string, params: table, cb: function }[] sent
        local function make_client(capabilities, meta)
            local sent = {}
            local client = setmetatable({
                agent_capabilities = capabilities,
                provider_config = {},
                subscribers = {},
                _session_roots = {},
                _unanswered = {},
                _children = {},
                _tool_call_kinds = ToolCallKinds:new(),
            }, { __index = ACPClient }) --[[@as agentic.acp.ACPClient]]
            client._send_request = function(_self, method, params, cb)
                table.insert(
                    sent,
                    { method = method, params = params, cb = cb }
                )
            end
            if meta ~= false then
                client.fork_point_meta = function(_self, response_id)
                    return { cut = response_id }
                end
            end
            return client, sent
        end

        local CAN_FORK = { sessionCapabilities = { fork = {} } }

        --- Fork `s1` at `r1` and return what the callback got.
        --- @param client agentic.acp.ACPClient
        --- @return table got `{ result, err }` once called, else empty
        local function fork(client)
            local got = {}
            client:fork_session("s1", "/p", "r1", {}, function(result, err)
                got.result, got.err, got.called = result, err, true
            end)
            return got
        end

        it("sends nothing and errors without the capability", function()
            local client, sent = make_client({ loadSession = true })

            assert.is_false(client:can_fork("r1"))
            local got = fork(client)
            deferred.drain()

            assert.equal(0, #sent)
            assert.is_true(got.called)
            assert.is_nil(got.result)
            assert.truthy(got.err)
        end)

        it("sends nothing and errors without fork point meta", function()
            local client, sent = make_client(CAN_FORK, false)

            assert.is_false(client:can_fork("r1"))
            local got = fork(client)
            deferred.drain()

            assert.equal(0, #sent)
            assert.truthy(got.err)
        end)

        it("cuts after the response and subscribes the new id", function()
            local client, sent = make_client(CAN_FORK)
            local handlers = {}

            assert.is_true(client:can_fork("r1"))
            local got = {}
            client:fork_session(
                "s1",
                "/p",
                "r1",
                handlers,
                function(result, err)
                    got = { result = result, err = err }
                end
            )

            assert.equal(1, #sent)
            assert.equal("session/fork", sent[1].method)
            assert.equal("s1", sent[1].params.sessionId)
            assert.equal("/p", sent[1].params.cwd)
            assert.same({ cut = "r1" }, sent[1].params._meta)
            sent[1].cb({ sessionId = "s2" }, nil)

            assert.equal(handlers, client.subscribers.s2)
            assert.truthy(client._session_roots.s2)
            assert.same({ sessionId = "s2" }, got.result)
            assert.is_nil(got.err)
        end)

        it("passes an error on and subscribes nothing", function()
            local client, sent = make_client(CAN_FORK)
            local got = fork(client)

            sent[1].cb(nil, { code = -32602, message = "bad id" })

            assert.same({}, client.subscribers)
            assert.equal(-32602, got.err.code)
        end)
    end)

    describe("terminal_auth_invocation", function()
        --- @param provider_config table
        --- @return agentic.acp.ACPClient
        local function make_client(provider_config)
            return setmetatable(
                { provider_config = provider_config },
                { __index = ACPClient }
            )
        end

        it("appends the method args to the configured command", function()
            local client =
                make_client({ command = "agent", args = { "--acp" } })

            local inv = client:terminal_auth_invocation({
                id = "login",
                name = "L",
                type = "terminal",
                args = { "--cli", "auth", "login" },
            })

            assert.same({ "agent", "--acp", "--cli", "auth", "login" }, inv.cmd)
        end)

        it("layers the method env over the provider env", function()
            local client = make_client({
                command = "agent",
                env = { A = "provider", B = "provider" },
            })

            local inv = client:terminal_auth_invocation({
                id = "login",
                name = "L",
                type = "terminal",
                env = { B = "method", C = "method" },
            })

            assert.same({ "agent" }, inv.cmd)
            assert.same({ A = "provider", B = "method", C = "method" }, inv.env)
        end)
    end)

    describe("_auth/status_update", function()
        local client
        local notify_stub

        local account_status = {
            kind = "account",
            label = "Claude Team",
            account = {
                email = "name@example.com",
                organization = "Example Org",
                plan = "team",
            },
        }

        before_each(function()
            client = setmetatable(
                { callbacks = {}, subscribers = {} },
                { __index = ACPClient }
            )
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        --- @param status agentic.acp.AuthStatus
        local function push_status(status)
            client:_handle_notification(
                nil,
                "_auth/status_update",
                { authStatus = status }
            )
        end

        it("leaves the status nil until the agent pushes one", function()
            assert.is_nil(client.auth_status)
        end)

        it("stores the pushed status on the client", function()
            push_status(account_status)

            assert.same(account_status, client.auth_status)
        end)

        it("does not reach the unknown-method fallback", function()
            push_status(account_status)

            assert.spy(notify_stub).was.called(0)
        end)

        it("replaces the previous status wholesale", function()
            push_status(account_status)
            push_status({ kind = "none", label = "Not logged in" })

            assert.equal("none", client.auth_status.kind)
            assert.is_nil(client.auth_status.account)
        end)

        for _, state in ipairs({ "disconnected", "error" }) do
            it("drops the status on " .. state, function()
                push_status(account_status)

                client:_set_state(state)

                assert.is_nil(client.auth_status)
            end)
        end
    end)

    describe("extract_failure_reason", function()
        local client
        before_each(function()
            client = setmetatable({}, { __index = ACPClient })
        end)

        it("returns nil for nil, empty string, or empty table", function()
            assert.is_nil(client:extract_failure_reason(nil))
            assert.is_nil(client:extract_failure_reason(""))
            assert.is_nil(client:extract_failure_reason({}))
        end)

        it("splits a plain string into lines", function()
            local body = client:extract_failure_reason("line1\nline2")
            assert.same({ "line1", "line2" }, body)
        end)

        it("joins text blocks from a content-block array", function()
            local body = client:extract_failure_reason({
                { type = "text", text = "Read hooks.md first." },
            })
            assert.same({ "Read hooks.md first." }, body)
        end)

        it("ignores non-text blocks in the array", function()
            local body = client:extract_failure_reason({
                { type = "image", data = "..." },
                { type = "text", text = "denied" },
            })
            assert.same({ "denied" }, body)
        end)
    end)

    describe("_handle_fs_write", function()
        it("answers, then reloads the loaded buffer of the path", function()
            local deferred = Deferred.capture()
            MiniTest.finally(deferred.revert)
            local path = vim.fn.tempname()
            local bufnr = vim.api.nvim_create_buf(false, false)
            vim.api.nvim_buf_set_name(bufnr, path)
            local client = setmetatable({}, { __index = ACPClient })
            local send_result = spy.new(function() end)
            client.__send_result = send_result

            client:_handle_fs_write(7, { path = path, content = "new" })
            deferred.drain()

            assert.spy(send_result).was.called_with(client, 7, {})
            assert.same(
                { "new" },
                vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            )
            vim.api.nvim_buf_delete(bufnr, { force = true })
            os.remove(path)
        end)
    end)

    describe("__build_tool_call_update", function()
        local client
        before_each(function()
            client = setmetatable({}, { __index = ACPClient })
        end)

        it(
            "populates failure_reason from rawOutput on status=failed",
            function()
                local msg = client:__build_tool_call_update({
                    toolCallId = "tc-1",
                    status = "failed",
                    rawOutput = {
                        { type = "text", text = "Read hooks.md first." },
                    },
                })
                assert.equal("failed", msg.status)
                assert.same({ "Read hooks.md first." }, msg.failure_reason)
            end
        )

        it("leaves failure_reason nil for non-failed statuses", function()
            local msg = client:__build_tool_call_update({
                toolCallId = "tc-1",
                status = "completed",
                rawOutput = { { type = "text", text = "ok" } },
            })
            assert.is_nil(msg.failure_reason)
        end)
    end)

    describe("session_meta", function()
        --- Params of each request a client sends, given its `session_meta`.
        --- @param meta table|nil What the client's `session_meta` returns, or nil for the default
        --- @return agentic.acp.ACPClient client
        --- @return table<string, table> params Request method -> params
        local function make_client(meta)
            local params = {}
            local client = setmetatable({
                subscribers = {},
                _children = {},
                _loading_sessions = {},
                _session_roots = {},
                _unanswered = {},
                provider_config = {},
                agent_capabilities = { loadSession = true },
                _send_request = function(_this, method, p)
                    params[method] = p
                end,
            }, { __index = ACPClient })
            if meta then
                client.session_meta = function()
                    return meta
                end
            end
            return client, params
        end

        it("is nil by default, so no _meta is sent", function()
            local client, params = make_client(nil)

            client:create_session("/proj", {}, function() end)
            client:load_session("s-1", "/proj", nil, {}, function() end)

            assert.is_nil(params["session/new"]._meta)
            assert.is_nil(params["session/load"]._meta)
        end)

        it("is sent on session/new and session/load", function()
            local meta = { vendor = { x = 1 } }
            local client, params = make_client(meta)

            client:create_session("/proj", {}, function() end)
            client:load_session("s-1", "/proj", nil, {}, function() end)

            assert.equal(meta, params["session/new"]._meta)
            assert.equal(meta, params["session/load"]._meta)
        end)
    end)

    it("answers a load the agent cannot do on a later tick", function()
        local deferred = Deferred.capture()
        MiniTest.finally(deferred.revert)
        local client = setmetatable({}, { __index = ACPClient })
        local err

        client:load_session("s-1", "/proj", nil, {}, function(_, e)
            err = e
        end)

        assert.is_nil(err)
        deferred.drain()
        assert.equal(client.ERROR_CODES.PROTOCOL_ERROR, err.code)
    end)

    for _, case in ipairs({
        { outcome = "an error", err = { code = -32603, message = "x" } },
        { outcome = "a success", err = nil },
    }) do
        it("keeps the load's subscriber only after " .. case.outcome, function()
            local respond
            local client = setmetatable({
                subscribers = {},
                _children = {},
                _loading_sessions = {},
                _session_roots = {},
                _unanswered = {},
                _tool_call_kinds = { forget_session = function() end },
                provider_config = {},
                agent_capabilities = { loadSession = true },
                _send_request = function(_, _, _, cb)
                    respond = cb
                end,
            }, { __index = ACPClient })

            client:load_session("s-1", "/proj", nil, {}, function() end)
            assert.is_not_nil(client.subscribers["s-1"])
            respond(not case.err and {} or nil, case.err)

            assert.equal(case.err == nil, client.subscribers["s-1"] ~= nil)
        end)
    end

    it(
        "neither reports budget windows nor auto-continues by default",
        function()
            local client = setmetatable({}, { __index = ACPClient })
            assert.is_nil(client:budget_windows({
                sessionUpdate = "usage_update",
                used = 0,
                size = 0,
            }))
            assert.is_false(client:auto_continue_on_usage_limit())
        end
    )

    describe("session roots", function()
        --- @param overrides table
        --- @return agentic.acp.ACPClient
        local function make_client(overrides)
            return setmetatable(
                vim.tbl_extend("force", {
                    subscribers = {},
                    _children = {},
                    _loading_sessions = {},
                    _session_roots = {},
                    _unanswered = {},
                    _tool_call_kinds = ToolCallKinds:new(),
                    provider_config = {},
                }, overrides),
                { __index = ACPClient }
            )
        end

        -- The bridge replays a loaded session's tool calls as notifications,
        -- which resolve skill names against these roots. Populating them after
        -- the request would let the replay outrun them.
        it("records them before session/load is sent", function()
            --- @type string[]|nil
            local roots_at_send

            local client = make_client({
                agent_capabilities = { loadSession = true },
                _send_request = function(this)
                    roots_at_send = this:session_roots("s-load")
                end,
            })

            client:load_session(
                "s-load",
                "/tmp/project",
                nil,
                {},
                function() end
            )

            assert.is_not_nil(roots_at_send)
            --- @cast roots_at_send -nil
            assert.equal("/tmp/project", roots_at_send[1])
        end)

        it("records them for a created session", function()
            local client = make_client({
                _send_request = function(_this, _method, _params, callback)
                    callback({ sessionId = "s-new" }, nil)
                end,
            })

            client:create_session("/proj", {}, function() end)

            assert.equal("/proj", client:session_roots("s-new")[1])
        end)

        it("drops them with the subscriber", function()
            local client = make_client({
                _session_roots = { ["s-1"] = { "/tmp/project" } },
                _unanswered = {},
                subscribers = { ["s-1"] = {} },
            })

            client:unsubscribe("s-1")

            assert.same({}, client:session_roots("s-1"))
            assert.is_nil(client.subscribers["s-1"])
        end)

        it(
            "forgets the session's tool-call kinds with the subscriber",
            function()
                local client = make_client({ subscribers = { ["s-1"] = {} } })
                client._tool_call_kinds:apply("s-1", {
                    sessionUpdate = "tool_call",
                    toolCallId = "t",
                    kind = "edit",
                })

                client:unsubscribe("s-1")

                local update =
                    { sessionUpdate = "tool_call_update", toolCallId = "t" }
                client._tool_call_kinds:apply("s-1", update)
                assert.is_nil(update.kind)
            end
        )

        it("records no kinds for an unsubscribed session", function()
            local client = make_client({
                __handle_tool_call = function() end,
            })

            client:__handle_session_update({
                sessionId = "s-1",
                update = {
                    sessionUpdate = "tool_call",
                    toolCallId = "t",
                    kind = "edit",
                },
            })

            assert.same({}, client._tool_call_kinds._kinds)
        end)
    end)

    describe("child sessions", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        --- @param overrides table|nil
        --- @return agentic.acp.ACPClient
        local function make_client(overrides)
            return setmetatable(
                vim.tbl_extend("force", {
                    subscribers = {},
                    _children = {},
                    _loading_sessions = {},
                    _session_roots = {},
                    _unanswered = {},
                    _tool_call_kinds = ToolCallKinds:new(),
                }, overrides or {}),
                { __index = ACPClient }
            )
        end

        --- @param client agentic.acp.ACPClient
        --- @param parent string
        --- @param child string
        local function spawn(client, parent, child)
            client:__handle_session_update({
                sessionId = parent,
                update = {
                    sessionUpdate = "subagent_update",
                    sessionId = child,
                    title = "n",
                    capabilities = { cancel = {} },
                    state = { state = "running" },
                },
            })
        end

        local recording_handlers = RecordingHandlers.new

        it("routes a child's update to the root with the raw id", function()
            local handlers, calls = recording_handlers()
            local client = make_client({ subscribers = { root = handlers } })

            spawn(client, "root", "child")
            client:__handle_session_update({
                sessionId = "child",
                update = {
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "hi" },
                },
            })
            deferred.drain()

            assert.equal(2, #calls)
            assert.equal("root", calls[1][3])
            assert.equal("subagent_update", calls[1][2].sessionUpdate)
            assert.equal("child", calls[2][3])
            assert.equal("hi", calls[2][2].content.text)
        end)

        it("routes a grandchild to the root", function()
            local client = make_client({ subscribers = { root = {} } })

            spawn(client, "root", "child")
            spawn(client, "child", "grandchild")

            assert.equal("root", client:__root_session("grandchild"))
        end)

        it("routes a child's tool calls with the raw id", function()
            local handlers, calls = recording_handlers()
            local client = make_client({ subscribers = { root = handlers } })

            spawn(client, "root", "child")
            client:__handle_session_update({
                sessionId = "child",
                update = {
                    sessionUpdate = "tool_call",
                    toolCallId = "t1",
                    kind = "read",
                    title = "Read",
                    status = "pending",
                },
            })
            deferred.drain()

            assert.equal("on_tool_call", calls[2][1])
            assert.equal("child", calls[2][3])
        end)

        it("hands a child's permission request to the root", function()
            local handlers, calls = recording_handlers()
            local client = make_client({ subscribers = { root = handlers } })
            spawn(client, "root", "child")

            client:__handle_request_permission(7, {
                sessionId = "child",
                toolCall = { toolCallId = "t1" },
                options = {},
            })
            deferred.drain()

            assert.equal("on_request_permission", calls[2][1])
            assert.equal("child", calls[2][2].sessionId)
        end)

        describe("a resolved permission request", function()
            --- @param option_id string|nil
            --- @return table[] events `{ "send", result }` or `{ "hook", option_id }` in order
            local function resolve(option_id)
                local events = {}
                local handlers, calls = recording_handlers()
                local client = make_client({
                    subscribers = { root = handlers },
                    __send_result = function(_, _, result)
                        table.insert(events, { "send", result })
                    end,
                    __on_permission_resolved = function(_, _, id)
                        table.insert(events, { "hook", id })
                    end,
                })

                client:__handle_request_permission(7, {
                    sessionId = "root",
                    toolCall = { toolCallId = "t1" },
                    options = {},
                })
                deferred.drain()
                calls[1][3](option_id)
                return events
            end

            it("sends cancelled, then calls the hook with nil", function()
                local events = resolve(nil)

                assert.same({
                    { "send", { outcome = { outcome = "cancelled" } } },
                    { "hook" },
                }, events)
            end)

            it("sends selected, then calls the hook with the id", function()
                local events = resolve("allow")

                assert.same({
                    {
                        "send",
                        {
                            outcome = {
                                outcome = "selected",
                                optionId = "allow",
                            },
                        },
                    },
                    { "hook", "allow" },
                }, events)
            end)
        end)

        it("resolves the root's session roots for a child", function()
            local client = make_client({
                subscribers = { root = {} },
                _session_roots = { root = { "/tmp/project" } },
                _unanswered = {},
            })

            spawn(client, "root", "child")

            assert.same({ "/tmp/project" }, client:session_roots("child"))
        end)

        it(
            "forwards a child's replayed user chunk while the root loads",
            function()
                local handlers, calls = recording_handlers()
                local client = make_client({
                    subscribers = { root = handlers },
                    _loading_sessions = { root = true },
                })
                spawn(client, "root", "child")

                client:__handle_session_update({
                    sessionId = "child",
                    update = {
                        sessionUpdate = "user_message_chunk",
                        content = { type = "text", text = "p" },
                    },
                })
                deferred.drain()

                assert.equal(2, #calls)
            end
        )

        it("drops a root's children with its subscriber", function()
            local client =
                make_client({ subscribers = { root = {}, other = {} } })
            spawn(client, "root", "child")
            spawn(client, "other", "other-child")

            client:unsubscribe("root")

            assert.same({ ["other-child"] = "other" }, client._children)
        end)

        it("records no session as its own child", function()
            local client = make_client({ subscribers = { root = {} } })

            spawn(client, "root", "root")

            assert.same({}, client._children)
        end)

        it("records no child of an unsubscribed session", function()
            local client = make_client()

            spawn(client, "gone", "child")

            assert.same({}, client._children)
        end)

        it("knows no spawn record or spawning task id", function()
            local client = make_client()

            assert.is_nil(client:subagent_record("root", "child"))
            assert.is_nil(client:subagent_task_id({
                sessionUpdate = "agent_message_chunk",
                content = { type = "text", text = "x" },
            }))
        end)

        it("knows no replay-only prompt", function()
            assert.is_false(
                make_client():is_replay_only_prompt(
                    "[Request interrupted by user]"
                )
            )
        end)

        it("reports a disconnect to every subscriber", function()
            local reached = {}
            local client = make_client({
                callbacks = {},
                subscribers = {
                    a = {
                        on_disconnect = function()
                            table.insert(reached, "a")
                        end,
                    },
                    b = {
                        on_disconnect = function()
                            table.insert(reached, "b")
                        end,
                    },
                },
            })

            client:_set_state("disconnected")
            deferred.drain()

            table.sort(reached)
            assert.same({ "a", "b" }, reached)
        end)
    end)

    describe("on ACP v2", function()
        --- @type tests.helpers.Deferred
        local deferred
        --- @type table[] Decoded JSON of each message sent
        local sent

        before_each(function()
            deferred = Deferred.capture()
            sent = {}
        end)

        after_each(function()
            deferred.revert()
        end)

        local ClaudeV2Codec = require("agentic.acp.adapters.claude_v2_codec")

        --- A connected client of a class that asks for v2.
        --- @return agentic.acp.ACPClient client
        local function make_client()
            local Child = ACPClient.extend()
            Child.v2_codec = ClaudeV2Codec
            --- @type agentic.acp.ACPClient
            local client
            client = setmetatable({
                state = "disconnected",
                callbacks = {},
                subscribers = {},
                id_counter = 0,
                protocol_version = 2,
                client_info = { name = "n", version = "1" },
                capabilities = { auth = { terminal = true } },
                provider_config = { name = "test-provider" },
                agent_capabilities = { loadSession = true },
                transport = {
                    start = function()
                        client.state = "connected"
                    end,
                    send = function(_self, data)
                        table.insert(sent, vim.json.decode(data))
                        return true
                    end,
                },
                _connection = 0,
                _ready_waiters = {},
                _loading_sessions = {},
                _children = {},
                _session_roots = {},
                _unanswered = {},
                _tool_call_kinds = ToolCallKinds:new(),
                _v2_states = {},
            }, { __index = Child }) --[[@as agentic.acp.ACPClient]]
            return client
        end

        --- Deliver `update` as a v2 `session/update` of `session_id`.
        --- @param client agentic.acp.ACPClient
        --- @param session_id string
        --- @param update table
        local function notify(client, session_id, update)
            client:_handle_message({
                jsonrpc = "2.0",
                method = "session/update",
                params = { sessionId = session_id, update = update },
            })
        end

        it("asks for v2 when its class has a v2 codec", function()
            local setup_stub = spy.stub(ACPClient, "_setup_transport")
            local connect_stub = spy.stub(ACPClient, "_connect")
            MiniTest.finally(function()
                setup_stub:revert()
                connect_stub:revert()
            end)
            local Child = ACPClient.extend()
            Child.v2_codec = ClaudeV2Codec

            local client = Child:new({ command = "x" }, function() end)
            local v1_client = ACPClient:new({ command = "x" }, function() end)

            assert.equal(2, client.protocol_version)
            assert.equal(1, v1_client.protocol_version)
        end)

        it("sends protocolVersion 2 in a v2 initialize", function()
            local client = make_client()
            client:_connect()

            assert.equal("initialize", sent[1].method)
            assert.equal(2, sent[1].params.protocolVersion)
            assert.same({ name = "n", version = "1" }, sent[1].params.info)
        end)

        it("fails a v2 initialize answered with v1", function()
            local notify_stub = spy.stub(Logger, "notify")
            MiniTest.finally(function()
                notify_stub:revert()
            end)
            local client = make_client()
            client:_connect()
            client:_handle_message({
                jsonrpc = "2.0",
                id = sent[1].id,
                result = { protocolVersion = 1 },
            })
            deferred.drain()

            assert.equal("error", client.state)
        end)

        it("encodes session/load as session/resume", function()
            local client = make_client()
            client:load_session(
                "s",
                "/c",
                nil,
                RecordingHandlers.new(),
                function() end
            )

            assert.equal("session/resume", sent[1].method)
            assert.same({ type = "start" }, sent[1].params.replayFrom)
        end)

        it("dispatches the decoded updates of one update in order", function()
            local client = make_client()
            local handlers, calls = RecordingHandlers.new()
            client:_subscribe("s", handlers)

            -- A replayed start is held until the next update.
            notify(client, "s", {
                sessionUpdate = "tool_call_update",
                toolCallId = "t1",
                kind = "read",
                status = "completed",
                _meta = vim.NIL,
            })
            notify(
                client,
                "s",
                { sessionUpdate = "state_update", state = "idle" }
            )
            deferred.drain()

            assert.same(
                { "on_tool_call", "on_turn_state" },
                vim.tbl_map(function(call)
                    return call[1]
                end, calls)
            )
            assert.equal("t1", calls[1][2].tool_call_id)
        end)

        it("reports a state_update as the turn state", function()
            local client = make_client()
            local handlers, calls = RecordingHandlers.new()
            client:_subscribe("s", handlers)
            local err = { code = -32000, message = "auth" }

            notify(client, "s", {
                sessionUpdate = "state_update",
                state = "idle",
                stopReason = "error",
                usage = { inputTokens = 1 },
                error = err,
            })
            deferred.drain()

            assert.same({
                {
                    "on_turn_state",
                    {
                        state = "idle",
                        stop_reason = "error",
                        usage = { inputTokens = 1 },
                        error = err,
                    },
                },
            }, calls)
        end)

        it("reports a user_message as a prompt taken in", function()
            local client = make_client()
            local handlers, calls = RecordingHandlers.new()
            client:_subscribe("s", handlers)

            notify(client, "s", {
                sessionUpdate = "user_message",
                messageId = "m1",
                content = { { type = "text", text = "hi" } },
            })
            deferred.drain()

            assert.same({ { "on_prompt_taken" } }, calls)
        end)

        it("gives send_prompt's callback the answer alone", function()
            local client = make_client()
            local handlers, calls = RecordingHandlers.new()
            client:_subscribe("s", handlers)
            local answers = {}

            client:send_prompt("s", {}, function(result, err)
                table.insert(answers, { result, err })
            end)
            client:_handle_message({
                jsonrpc = "2.0",
                id = sent[1].id,
                result = { messageId = "m1" },
            })
            deferred.drain()

            assert.same({ { { messageId = "m1" } } }, answers)
            assert.same({}, calls)
        end)

        it("drops a child's state_update", function()
            local client = make_client()
            local handlers, calls = RecordingHandlers.new()
            client:_subscribe("s", handlers)
            client._children["child"] = "s"

            notify(
                client,
                "child",
                { sessionUpdate = "state_update", state = "idle" }
            )
            deferred.drain()

            assert.same({}, calls)
        end)

        it("emits a setup result's commands after attaching", function()
            local client = make_client()
            local handlers, calls = RecordingHandlers.new()
            local commands = { { name = "review", description = "d" } }
            local done = spy.new(function() end)

            client:create_session("/c", handlers, done --[[@as function]])
            client:_handle_message({
                jsonrpc = "2.0",
                id = sent[1].id,
                result = { sessionId = "s", availableCommands = commands },
            })
            deferred.drain()

            assert.equal(1, done.call_count)
            assert.same({
                {
                    "on_session_update",
                    {
                        sessionUpdate = "available_commands_update",
                        availableCommands = commands,
                    },
                    "s",
                },
            }, calls)
        end)
    end)
end)

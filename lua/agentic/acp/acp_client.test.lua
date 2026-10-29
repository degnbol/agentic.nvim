--- @diagnostic disable: invisible, assign-type-mismatch, missing-fields, return-type-mismatch
local Logger = require("agentic.utils.logger")
local MiniTest = require("mini.test")
local assert = require("tests.helpers.assert")
local Deferred = require("tests.helpers.deferred")
local spy = require("tests.helpers.spy")
local ToolCallKinds = require("agentic.acp.tool_call_kinds")

describe("agentic.acp.ACPClient", function()
    --- @type agentic.acp.ACPClient
    local ACPClient

    before_each(function()
        ACPClient = require("agentic.acp.acp_client")
    end)

    describe("subagent defaults", function()
        it("predict blocking and give no instructions", function()
            local client = setmetatable({}, { __index = ACPClient })

            assert.equal("blocking", client:subagent_predicted_mode())
            assert.is_nil(client:subagent_stop_instruction("a1", "x"))
            assert.is_nil(client:subagent_message_instruction("a1", "x", "m"))
        end)
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
            make_client({ command = "provider-cmd" })
                :_on_process_output("stderr", "oops")

            assert.equal(
                "provider-cmd 1.0 stderr: oops",
                notify_stub.calls[1][1]
            )
        end)

        it("points at the log file only while logging", function()
            Config.log = true
            make_client():_on_process_output("stderr", "oops")
            assert.equal(
                "Provider 1.0 stderr: oops (full output in "
                    .. Logger.LOG_FILE_PATH
                    .. ")",
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
                _on_ready = on_ready,
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

    it("neither displays a budget nor auto-continues by default", function()
        local client = setmetatable({}, { __index = ACPClient })
        assert.is_false(client:budget_display())
        assert.is_false(client:auto_continue_on_usage_limit())
    end)

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
                    _tool_call_kinds = ToolCallKinds:new(),
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
                subscribers = { ["s-1"] = {} },
            })

            client:unsubscribe("s-1")

            assert.same({}, client:session_roots("s-1"))
            assert.is_nil(client.subscribers["s-1"])
        end)

        it("forgets the session's tool-call kinds with the subscriber", function()
            local client = make_client({ subscribers = { ["s-1"] = {} } })
            client._tool_call_kinds:apply(
                "s-1",
                { sessionUpdate = "tool_call", toolCallId = "t", kind = "edit" }
            )

            client:unsubscribe("s-1")

            local update = { sessionUpdate = "tool_call_update", toolCallId = "t" }
            client._tool_call_kinds:apply("s-1", update)
            assert.is_nil(update.kind)
        end)

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

        --- @return agentic.acp.ClientHandlers handlers
        --- @return table[] calls `{ method, payload, source }` per call
        local function recording_handlers()
            local calls = {}
            local function record(method)
                return function(payload, source)
                    table.insert(calls, { method, payload, source })
                end
            end
            return {
                on_session_update = record("on_session_update"),
                on_tool_call = record("on_tool_call"),
                on_tool_call_update = record("on_tool_call_update"),
                on_request_permission = record("on_request_permission"),
            },
                calls
        end

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

            assert.equal("root", client:_root_session("grandchild"))
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

        it("resolves the root's session roots for a child", function()
            local client = make_client({
                subscribers = { root = {} },
                _session_roots = { root = { "/tmp/project" } },
            })

            spawn(client, "root", "child")

            assert.same({ "/tmp/project" }, client:session_roots("child"))
        end)

        it("forwards a child's replayed user chunk while the root loads", function()
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
        end)

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

        it("knows no spawn record and addresses a child by its id", function()
            local client = make_client()

            assert.is_nil(client:subagent_record("root", "child"))
            assert.is_nil(client:subagent_task_id({
                sessionUpdate = "agent_message_chunk",
                content = { type = "text", text = "x" },
            }))
            local agent_id, generation = client:subagent_id("child")
            assert.equal("child", agent_id)
            assert.equal(1, generation)
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
end)

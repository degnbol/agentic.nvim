--- @diagnostic disable: invisible, missing-fields
local assert = require("tests.helpers.assert")
local Deferred = require("tests.helpers.deferred")
local RecordingHandlers = require("tests.helpers.recording_handlers")
local ToolCallKinds = require("agentic.acp.tool_call_kinds")

describe("agentic.acp.adapters.GeminiACPAdapter", function()
    local GeminiACPAdapter = require("agentic.acp.adapters.gemini_acp_adapter")

    it("ignores its own and the base process output patterns", function()
        local adapter = setmetatable({}, { __index = GeminiACPAdapter })
        assert.is_true(adapter:ignores_output("Experiments loaded {}"))
        assert.is_true(adapter:ignores_output("Session not found"))
        assert.is_false(adapter:ignores_output("Unexpected case"))
    end)

    describe("__handle_request_permission", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        --- @return table[] calls `{ method, payload, source }` per handler call
        --- @return table[] results each result sent to the provider
        --- @return agentic.acp.GeminiACPAdapter adapter
        local function make_adapter()
            local handlers, calls = RecordingHandlers.new()
            local results = {}
            local adapter = setmetatable({
                subscribers = { root = handlers },
                _children = {},
                _loading_sessions = {},
                _session_roots = {},
                _tool_call_kinds = ToolCallKinds:new(),
                __send_result = function(_, _, result)
                    table.insert(results, result)
                end,
            }, { __index = GeminiACPAdapter })
            return calls, results, adapter
        end

        --- @param reject_id string|nil Id of the `reject_once` option. Default "cancel"
        --- @param kind string|nil Tool call kind. Default "execute"
        --- @param session_id string|nil Default "root"
        --- @return agentic.acp.GeminiRequestPermission
        local function request(reject_id, kind, session_id)
            return {
                sessionId = session_id or "root",
                toolCall = {
                    toolCallId = "t1",
                    kind = kind or "execute",
                    title = "ls",
                },
                options = {
                    {
                        optionId = "proceed_once",
                        name = "Allow",
                        kind = "allow_once",
                    },
                    {
                        optionId = reject_id or "cancel",
                        name = "Reject",
                        kind = "reject_once",
                    },
                },
            }
        end

        --- @param calls table[]
        --- @param method string
        --- @return table[] matching
        local function calls_of(calls, method)
            return vim.tbl_filter(function(call)
                return call[1] == method
            end, calls)
        end

        --- Answer the first permission prompt with `option_id`, then drain
        --- scheduled callbacks.
        --- @param calls table[]
        --- @param option_id string|nil
        local function answer(calls, option_id)
            calls_of(calls, "on_request_permission")[1][3](option_id)
            deferred.drain()
        end

        it("sends cancelled and no update for a nil option", function()
            local calls, results, adapter = make_adapter()

            adapter:__handle_request_permission(1, request())
            deferred.drain()
            answer(calls, nil)

            assert.same({ { outcome = { outcome = "cancelled" } } }, results)
            assert.equal(0, #calls_of(calls, "on_tool_call_update"))
        end)

        it("ends the call failed after the cancel option", function()
            local calls, results, adapter = make_adapter()

            adapter:__handle_request_permission(1, request())
            deferred.drain()
            answer(calls, "cancel")

            assert.same({
                { outcome = { outcome = "selected", optionId = "cancel" } },
            }, results)
            local updates = calls_of(calls, "on_tool_call_update")
            assert.equal(1, #updates)
            assert.equal("t1", updates[1][2].tool_call_id)
            assert.equal("failed", updates[1][2].status)
        end)

        it("detects a reject by the option's kind, not its id", function()
            local calls, _, adapter = make_adapter()

            adapter:__handle_request_permission(1, request("deny"))
            deferred.drain()
            answer(calls, "deny")

            assert.equal(1, #calls_of(calls, "on_tool_call_update"))
        end)

        it("sends selected and no update for the allow option", function()
            local calls, results, adapter = make_adapter()

            adapter:__handle_request_permission(1, request())
            deferred.drain()
            answer(calls, "proceed_once")

            assert.same({
                {
                    outcome = {
                        outcome = "selected",
                        optionId = "proceed_once",
                    },
                },
            }, results)
            assert.equal(0, #calls_of(calls, "on_tool_call_update"))
        end)

        it("delivers a synthetic tool call before the prompt", function()
            local calls, _, adapter = make_adapter()

            adapter:__handle_request_permission(1, request(nil, "edit"))
            deferred.drain()

            assert.equal("on_tool_call", calls[1][1])
            assert.equal("t1", calls[1][2].tool_call_id)
            assert.equal("on_request_permission", calls[2][1])
        end)

        it("hands a child session's request to the root", function()
            local calls, results, adapter = make_adapter()
            adapter._children = { child = "root" }

            adapter:__handle_request_permission(1, request(nil, nil, "child"))
            deferred.drain()

            assert.equal(1, #calls_of(calls, "on_request_permission"))
            assert.same({}, results)

            answer(calls, "cancel")

            local updates = calls_of(calls, "on_tool_call_update")
            assert.equal(1, #updates)
            assert.equal("child", updates[1][3])
        end)
    end)
end)

--- @diagnostic disable: invisible, assign-type-mismatch, missing-fields, return-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Deferred = require("tests.helpers.deferred")

describe("agentic.acp.adapters.OpenCodeACPAdapter", function()
    --- @type table
    local OpenCodeACPAdapter

    before_each(function()
        OpenCodeACPAdapter =
            require("agentic.acp.adapters.opencode_acp_adapter")
    end)

    describe("__handle_tool_call_update", function()
        --- @type tests.helpers.Deferred
        local deferred

        before_each(function()
            deferred = Deferred.capture()
        end)

        after_each(function()
            deferred.revert()
        end)

        it("handles completed SubAgent update", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
                _children = {},
                subscribers = {
                    ["sess-1"] = {
                        on_tool_call_update = sub_spy,
                    },
                },
            }, { __index = OpenCodeACPAdapter })

            adapter:__handle_tool_call_update("sess-1", {
                toolCallId = "tc-task-1",
                status = "completed",
                kind = "other",
                rawInput = {
                    subagent_type = "general",
                    description = "explore codebase",
                    prompt = "Find all references to X",
                },
                content = {
                    {
                        type = "content",
                        content = {
                            type = "text",
                            text = "SubAgent completed.\nFound 5 references.",
                        },
                    },
                },
            })

            deferred.drain()

            assert.spy(sub_spy).was.called(1)

            local msg = sub_spy.calls[1][1]
            assert.equal("SubAgent", msg.kind)
            assert.equal("completed", msg.status)
            assert.equal("tc-task-1", msg.tool_call_id)
            assert.same(
                { "SubAgent completed.", "Found 5 references." },
                msg.body
            )
        end)

        it(
            "handles completed SubAgent with multi-line body via rawOutput",
            function()
                local sub_spy = spy.new(function() end)

                --- @type agentic.acp.ACPClient
                local adapter = setmetatable({
                    _children = {},
                    subscribers = {
                        ["sess-1"] = {
                            on_tool_call_update = sub_spy,
                        },
                    },
                }, { __index = OpenCodeACPAdapter })

                adapter:__handle_tool_call_update("sess-1", {
                    toolCallId = "tc-task-2",
                    status = "completed",
                    kind = "other",
                    rawInput = {
                        subagent_type = "explore",
                        description = "search codebase",
                    },
                    content = {
                        {
                            type = "content",
                            content = {
                                type = "text",
                                text = "task_id: sess_abc (for resuming)\n\n<task_result>\nFound matching patterns in 3 files.\n</task_result>",
                            },
                        },
                    },
                })

                deferred.drain()

                assert.spy(sub_spy).was.called(1)

                local msg = sub_spy.calls[1][1]
                assert.equal("SubAgent", msg.kind)
                assert.equal("tc-task-2", msg.tool_call_id)
                assert.same({
                    "task_id: sess_abc (for resuming)",
                    "",
                    "<task_result>",
                    "Found matching patterns in 3 files.",
                    "</task_result>",
                }, msg.body)
            end
        )

        it("skips update when status is nil", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
                _children = {},
                subscribers = {
                    ["sess-1"] = {
                        on_tool_call_update = sub_spy,
                    },
                },
            }, { __index = OpenCodeACPAdapter })

            adapter:__handle_tool_call_update("sess-1", {
                toolCallId = "tc-task-3",
                kind = "other",
                rawInput = {
                    subagent_type = "general",
                },
            })

            -- The nil-status early return schedules no subscriber call. Drain
            -- so that a queued call would show.
            deferred.drain()
            assert.spy(sub_spy).was.called(0)
        end)

        it("relabels in_progress to pending for SubAgent", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
                _children = {},
                subscribers = {
                    ["sess-1"] = {
                        on_tool_call_update = sub_spy,
                    },
                },
            }, { __index = OpenCodeACPAdapter })

            adapter:__handle_tool_call_update("sess-1", {
                toolCallId = "tc-task-4",
                status = "in_progress",
                kind = "other",
                rawInput = {
                    subagent_type = "general",
                    description = "test task",
                },
            })

            deferred.drain()

            assert.spy(sub_spy).was.called(1)

            local msg = sub_spy.calls[1][1]
            assert.equal("SubAgent", msg.kind)
            assert.equal("pending", msg.status)
        end)
    end)

    describe("unattended_env", function()
        local ASK = { action = "*", resource = "*", effect = "ask" }

        --- @type string|nil
        local saved_env

        before_each(function()
            saved_env = vim.env.OPENCODE_CONFIG_CONTENT
            vim.env.OPENCODE_CONFIG_CONTENT = nil
        end)

        after_each(function()
            vim.env.OPENCODE_CONFIG_CONTENT = saved_env
        end)

        --- @param env table<string, string>
        --- @return table config Decoded `OPENCODE_CONFIG_CONTENT`
        local function config_of(env)
            local result, err = OpenCodeACPAdapter:unattended_env(env)
            assert.is_nil(err)
            return vim.json.decode(result.OPENCODE_CONFIG_CONTENT)
        end

        it("asks for every call without a base config", function()
            assert.same({ permissions = { ASK } }, config_of({}))
        end)

        it("appends the rule to the base's rules and keeps its keys", function()
            local allow = { action = "shell", resource = "*", effect = "allow" }
            local config = config_of({
                OPENCODE_CONFIG_CONTENT = vim.json.encode({
                    model = "a/b",
                    permissions = { allow },
                }),
            })

            assert.same({ model = "a/b", permissions = { allow, ASK } }, config)
        end)

        it("reads the base from the editor's env", function()
            vim.env.OPENCODE_CONFIG_CONTENT = '{"model":"a/b"}'

            assert.same({ model = "a/b", permissions = { ASK } }, config_of({}))
        end)

        it("rejects a base that is not a JSON object", function()
            for _, base in ipairs({
                "{",
                "[]",
                '"x"',
                "1",
                "null",
                '{"permissions":{}}',
                '{"permissions":{"edit":"ask"}}',
            }) do
                local result, err = OpenCodeACPAdapter:unattended_env({
                    OPENCODE_CONFIG_CONTENT = base,
                })
                assert.is_nil(result)
                assert.truthy(err:find("OPENCODE_CONFIG_CONTENT", 1, true))
            end
        end)
    end)
end)

--- @diagnostic disable: invisible, assign-type-mismatch, missing-fields, return-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.adapters.OpenCodeACPAdapter", function()
    --- @type table
    local OpenCodeACPAdapter

    before_each(function()
        OpenCodeACPAdapter =
            require("agentic.acp.adapters.opencode_acp_adapter")
    end)

    describe("__handle_tool_call_update", function()
        it("handles completed SubAgent update", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
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

            vim.wait(50, function()
                return sub_spy.call_count > 0
            end)

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

        it("handles completed SubAgent with multi-line body via rawOutput", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
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

            vim.wait(50, function()
                return sub_spy.call_count > 0
            end)

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
        end)

        it("skips update when status is nil", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
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

            -- No vim.wait needed since it's synchronous (no vim.schedule for
            -- the nil-status early return path)
            assert.spy(sub_spy).was.called(0)
        end)

        it("relabels in_progress to pending for SubAgent", function()
            local sub_spy = spy.new(function() end)

            --- @type agentic.acp.ACPClient
            local adapter = setmetatable({
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

            vim.wait(50, function()
                return sub_spy.call_count > 0
            end)

            assert.spy(sub_spy).was.called(1)

            local msg = sub_spy.calls[1][1]
            assert.equal("SubAgent", msg.kind)
            assert.equal("pending", msg.status)
        end)
    end)
end)

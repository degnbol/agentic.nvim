local assert = require("tests.helpers.assert")
local AgentConfigOptions = require("agentic.acp.agent_config_options")
local AgentView = require("agentic.ui.agent_view")
local ChatBuffer = require("agentic.ui.chat_buffer")
local ChatHistory = require("agentic.ui.chat_history")

describe("agentic.ui.AgentView", function()
    --- @type integer
    local bufnr
    --- @type agentic.ui.AgentView
    local view

    before_each(function()
        bufnr = vim.api.nvim_create_buf(false, true)
        ChatBuffer.setup(bufnr)
        view = AgentView:new(bufnr)
    end)

    after_each(function()
        vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    --- @return string[]
    local function lines()
        return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end

    --- Options offering `models`, running `current` at an `Effort: High`
    --- thought level.
    --- @param models agentic.acp.ConfigOption.Option[]
    --- @param current string|nil
    --- @return agentic.acp.AgentConfigOptions
    local function offering(models, current)
        local noop = function() end
        local options = AgentConfigOptions:new(noop, noop, noop, function()
            return true
        end)
        options:set_options({
            {
                id = "model",
                category = "model",
                currentValue = current or "",
                description = "",
                name = "Model",
                options = models,
            },
            {
                id = "effort",
                category = "thought_level",
                currentValue = "high",
                description = "",
                name = "Effort",
                options = { { value = "high", name = "High" } },
            },
        })
        return options
    end

    describe("announce_model", function()
        it("writes bold name · id and the description", function()
            local options = offering({
                { value = "m", name = "M", description = "M's description" },
            })

            view:announce_model(options, "m")

            assert.truthy(vim.tbl_contains(lines(), "**Loaded M** · m"))
            assert.truthy(vim.tbl_contains(lines(), "M's description"))
        end)

        it("adds the thought level of the current model", function()
            local options =
                offering({ { value = "m", name = "M", description = "" } }, "m")

            view:announce_model(options, "m")

            assert.truthy(
                vim.tbl_contains(lines(), "**Loaded M** · m · Effort: High")
            )
        end)

        it("writes nothing for a nil model", function()
            local before = lines()

            view:announce_model(offering({}), nil)

            assert.same(before, lines())
        end)
    end)

    describe("tool calls", function()
        --- @type agentic.ui.ChatHistory
        local history

        before_each(function()
            history = ChatHistory:new()
        end)

        --- @type agentic.PermissionCause[]
        local causes = { { code = "kind", subject = "read" } }

        --- Write call `t1` without a status.
        --- @param kind string
        --- @param argument string
        --- @param call_causes agentic.PermissionCause[]|nil
        --- @return agentic.ui.MessageWriter.ToolCallBlock written
        local function write(kind, argument, call_causes)
            local call =
                { tool_call_id = "t1", kind = kind, argument = argument }
            return view:write_tool_call(
                history,
                call --[[@as agentic.ui.MessageWriter.ToolCallBlock]],
                call_causes,
                nil
            )
        end

        it("writes a call as pending, with its causes", function()
            local written = write("read", "/a.lua", causes)

            assert.equal("pending", written.status)
            assert.equal("pending", view.writer.tool_call_blocks.t1.status)
            assert.same(causes, view.writer.tool_call_blocks.t1.causes)
            assert.equal("pending", history:tool_call("t1").status)
            assert.same(causes, history:tool_call("t1").causes)
        end)

        it("records a call under its agent key", function()
            view:write_tool_call(history, {
                tool_call_id = "t1",
                kind = "read",
                argument = "/a.lua",
                status = "completed",
            }, nil, "child")

            assert.equal(0, #history.messages)
            assert.equal("child", history:tool_call("t1").agent_key)
        end)

        it("normalises a read's line range out of its argument", function()
            local written = write("read", "/a.lua (1 - 10)", nil)

            assert.equal("/a.lua", written.argument)
            assert.equal("/a.lua", history:tool_call("t1").argument)
        end)

        it("normalises an update with the block's kind", function()
            write("execute", "ls", nil)

            local applied = view:update_tool_call(history, {
                tool_call_id = "t1",
                status = "completed",
                body = { "```", "out", "```" },
            })

            assert.same({ "out" }, applied.body)
            assert.equal("completed", history:tool_call("t1").status)
            assert.same({ "out" }, history:tool_call("t1").body)
        end)

        it("keeps the block's first rejection line", function()
            write("execute", "ls", nil)
            view:update_tool_call(
                history,
                { tool_call_id = "t1", status = "failed", rejection = "first" }
            )

            local applied = view:update_tool_call(
                history,
                { tool_call_id = "t1", status = "failed", rejection = "second" }
            )

            assert.is_nil(applied.rejection)
            assert.equal("first", view.writer.tool_call_blocks.t1.rejection)
            assert.equal("first", history:tool_call("t1").rejection)
        end)

        it("shows causes on the block and in the history", function()
            write("read", "/a.lua", nil)

            assert.is_true(view:show_causes(history, "t1", causes))
            assert.same(causes, view.writer.tool_call_blocks.t1.causes)
            assert.same(causes, history:tool_call("t1").causes)
        end)

        it("does not show causes the block already shows", function()
            write("read", "/a.lua", causes)

            assert.is_false(view:show_causes(history, "t1", causes))
        end)

        it("does not show causes for a call without a block", function()
            assert.is_false(view:show_causes(history, "t1", causes))
        end)

        describe("merge_tool_call_fields", function()
            it("merges into the block and the record", function()
                write("read", "/a.lua", nil)

                AgentView.merge_tool_call_fields(
                    view.writer,
                    history,
                    { tool_call_id = "t1", causes = causes }
                )

                assert.same(causes, view.writer.tool_call_blocks.t1.causes)
                assert.same(causes, history:tool_call("t1").causes)
            end)

            it("keeps fields the update leaves out", function()
                write("read", "/a.lua", nil)

                AgentView.merge_tool_call_fields(
                    view.writer,
                    history,
                    { tool_call_id = "t1", causes = causes }
                )

                assert.equal("pending", view.writer.tool_call_blocks.t1.status)
                assert.equal("pending", history:tool_call("t1").status)
            end)

            it("merges into the record only for a nil writer", function()
                write("read", "/a.lua", nil)

                AgentView.merge_tool_call_fields(
                    nil,
                    history,
                    { tool_call_id = "t1", causes = causes }
                )

                assert.is_nil(view.writer.tool_call_blocks.t1.causes)
                assert.same(causes, history:tool_call("t1").causes)
            end)

            it(
                "merges into the record only for a writer that does not track the call",
                function()
                    history:add_message(ChatHistory.tool_call_record({
                        tool_call_id = "t2",
                        status = "pending",
                    }))

                    AgentView.merge_tool_call_fields(
                        view.writer,
                        history,
                        { tool_call_id = "t2", causes = causes }
                    )

                    assert.is_nil(view.writer.tool_call_blocks.t2)
                    assert.same(causes, history:tool_call("t2").causes)
                end
            )
        end)
    end)
end)

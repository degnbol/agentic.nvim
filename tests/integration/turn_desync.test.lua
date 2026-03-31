--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, param-type-mismatch
--- Integration test: simulate the full ACP message flow to detect display desync.
---
--- Reproduces the "stuck 1 message behind" bug:
--- 1. Turn 1: SubAgent tool call, turn ends
--- 2. Turn 2: user asks status, provider sends message chunks + response
--- 3. Verify buffer contains turn 2 response content
local assert = require("tests.helpers.assert")

local Config = require("agentic.config")
local MessageWriter = require("agentic.ui.message_writer")

--- @param text string
--- @return agentic.acp.SessionUpdateMessage
local function chunk(text)
    return {
        sessionUpdate = "agent_message_chunk",
        content = { type = "text", text = text },
    }
end

--- @param id string
--- @param status agentic.acp.ToolCallStatus
--- @param kind? agentic.acp.ToolKind
--- @param argument? string
--- @return agentic.ui.MessageWriter.ToolCallBlock
local function tool_call(id, status, kind, argument)
    return {
        tool_call_id = id,
        status = status,
        kind = kind or "SubAgent",
        argument = argument or "background task",
    }
end

--- @param id string
--- @param status agentic.acp.ToolCallStatus
--- @param body? string[]
--- @return agentic.ui.MessageWriter.ToolCallBase
local function tool_update(id, status, body)
    return {
        tool_call_id = id,
        status = status,
        body = body,
    }
end

--- Helper: get all non-empty lines from buffer
--- @param bufnr integer
--- @return string[]
local function buf_text(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Helper: check if any line in the buffer contains the given text
--- @param bufnr integer
--- @param text string
--- @return boolean
local function buf_contains(bufnr, text)
    for _, line in ipairs(buf_text(bufnr)) do
        if line:find(text, 1, true) then
            return true
        end
    end
    return false
end

describe("turn desync (stuck 1 message behind)", function()
    --- @type agentic.ui.MessageWriter
    local writer
    --- @type integer
    local bufnr
    --- @type integer
    local winid

    local original_auto_scroll
    local original_tool_call_display

    before_each(function()
        Config = require("agentic.config")
        original_auto_scroll = Config.auto_scroll
        original_tool_call_display = vim.deepcopy(Config.tool_call_display)
        Config.tool_call_display.execute_formatter = false

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 30,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        Config.tool_call_display = original_tool_call_display
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    describe("baseline: normal turn flow", function()
        it("message chunks are visible in buffer immediately", function()
            writer:write_message_chunk(chunk("Hello from turn 1"))
            assert.is_true(buf_contains(bufnr, "Hello from turn 1"))
        end)

        it("tool call + message chunks + separator all present", function()
            -- Turn 1: tool call then message
            writer:write_tool_call_block(
                tool_call("tc-1", "pending", "read", "/tmp/file.txt")
            )
            writer:update_tool_call_block(
                tool_update("tc-1", "completed", { "file contents" })
            )
            writer:write_message_chunk(chunk("Here are the results."))
            writer:append_separator()

            assert.is_true(buf_contains(bufnr, "Here are the results."))
        end)
    end)

    describe("SubAgent turn then follow-up", function()
        it(
            "turn 2 message chunks are present in buffer after turn 1 with SubAgent",
            function()
                -- Turn 1: SubAgent tool call, agent says "running in background"
                writer:write_tool_call_block(tool_call("sub-1", "in_progress"))
                writer:write_message_chunk(
                    chunk(
                        "The batch is running in the background. I'll let you know when it finishes."
                    )
                )
                -- Turn 1 ends (SubAgent still in_progress — no update)
                writer:append_separator()

                assert.is_true(
                    buf_contains(bufnr, "running in the background"),
                    "Turn 1 text should be visible"
                )

                -- Turn 2: user asks for status, provider responds
                writer:write_message_chunk(
                    chunk(
                        "The background task has completed. Here are the results:"
                    )
                )
                writer:write_message_chunk(chunk("\n\nResult data line 1"))
                writer:append_separator()

                assert.is_true(
                    buf_contains(bufnr, "background task has completed"),
                    "Turn 2 response should be in buffer immediately.\n"
                        .. "Buffer contents:\n"
                        .. table.concat(buf_text(bufnr), "\n")
                )
            end
        )
    end)

    describe("rejection suppression across turns", function()
        it(
            "does not suppress message chunks in the next turn after rejection",
            function()
                -- Turn 1: tool call with permission rejection
                writer:write_tool_call_block(
                    tool_call("perm-1", "pending", "edit", "/tmp/file.txt")
                )

                -- User rejects → suppress_next_rejection is called
                writer:suppress_next_rejection()

                -- Provider sends rejection boilerplate
                writer:write_message_chunk(
                    chunk("The user doesn't want to proceed with this change.")
                )
                -- More rejection text
                writer:write_message_chunk(
                    chunk(" I'll respect that decision and find another way.")
                )

                -- Turn 1 ends (no further tool calls)
                writer:append_separator()

                -- Turn 2: user sends a new prompt, provider responds normally
                -- Note: no tool call between turns — this is the edge case
                writer:write_message_chunk(
                    chunk("Sure, let me try a different approach instead.")
                )

                local found = buf_contains(bufnr, "try a different approach")
                assert.is_true(
                    found,
                    "Turn 2 response should NOT be suppressed.\n"
                        .. "Suppression flag: "
                        .. tostring(writer._suppressing_rejection)
                        .. "\nRejection buffer: '"
                        .. writer._rejection_buffer
                        .. "'\nBuffer contents:\n"
                        .. table.concat(buf_text(bufnr), "\n")
                )
            end
        )

        it(
            "rejection suppression resets when next turn starts with a tool call",
            function()
                writer:write_tool_call_block(
                    tool_call("perm-2", "pending", "edit", "/tmp/a.txt")
                )
                writer:suppress_next_rejection()
                writer:write_message_chunk(
                    chunk(
                        "The user doesn't want to proceed with this operation."
                    )
                )
                writer:append_separator()

                -- Turn 2 starts with a tool call → clears _suppressing_rejection
                writer:write_tool_call_block(
                    tool_call("read-1", "completed", "read", "/tmp/b.txt")
                )
                writer:write_message_chunk(chunk("Here's the file content."))

                assert.is_true(
                    buf_contains(bufnr, "file content"),
                    "Chunks after tool call should not be suppressed"
                )
            end
        )
    end)

    describe("rapid turn submission (race condition)", function()
        it("turn 2 cleanup does not clobber turn 3 content", function()
            -- Simulate the double vim.schedule race:
            -- Turn 1 messages
            writer:write_message_chunk(chunk("Turn 1 response text"))
            writer:append_separator()

            -- Turn 2 messages
            writer:write_message_chunk(chunk("Turn 2 response text"))
            writer:append_separator()

            -- Turn 3 messages (submitted quickly)
            writer:write_message_chunk(chunk("Turn 3 response text"))
            writer:append_separator()

            -- All three turns should be visible
            assert.is_true(
                buf_contains(bufnr, "Turn 1 response"),
                "Turn 1 should be in buffer"
            )
            assert.is_true(
                buf_contains(bufnr, "Turn 2 response"),
                "Turn 2 should be in buffer"
            )
            assert.is_true(
                buf_contains(bufnr, "Turn 3 response"),
                "Turn 3 should be in buffer"
            )
        end)
    end)
end)

--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, param-type-mismatch
--- Integration test: reproduce the chunk-flush symptom in the auto-continue
--- after usage-limit reset path.
---
--- Symptom (see .claude/skills/issues/references/chunk-flush.md):
--- After auto-continue fires, permission prompts appear fine but
--- agent_message_chunk prose and entire tool call frames are missing from
--- the chat buffer. All missing content appears at once when the user
--- submits the next prompt.
---
--- This test drives MessageWriter through the exact sequence that runs in
--- production after auto-continue fires. If MessageWriter's per-turn state
--- is corrupted by the error-then-continue flow, chunks written here will
--- fail to appear in the buffer — reproducing the bug at this layer.
---
--- If this test PASSES, MessageWriter is not at fault and the bug is
--- upstream (ACPClient dispatch or transport/subprocess). The remaining
--- narrowing step is the runtime-state diagnostic command (option b).
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
        kind = kind or "read",
        argument = argument or "/tmp/file.txt",
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

--- @param text string
--- @return agentic.acp.SessionUpdateMessage
local function user_message(text)
    return {
        sessionUpdate = "user_message_chunk",
        content = { type = "text", text = text },
    }
end

--- Synthetic usage-limit ACPError matching what claude-agent-acp sends.
--- Only the `message` field is inspected by write_error_message.
--- @return agentic.acp.ACPError
local function usage_limit_err()
    return {
        code = -32000,
        message = '{"type":"error","error":{"type":"usage_limit_error","message":"Claude AI usage limit reached|1800000000"}}',
    }
end

--- @param bufnr integer
--- @return string[]
local function buf_text(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

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

describe("auto-continue chunk flush", function()
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
        Config.auto_scroll = original_auto_scroll
        Config.tool_call_display = original_tool_call_display
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it(
        "chunks streamed after usage_limit error + continue prompt are in buffer",
        function()
            -- Turn 1: user prompt, provider streams a short response, then
            -- the follow-up prompt hits usage_limit.
            writer:write_message(user_message("First prompt."))
            writer:write_message_chunk(chunk("Working on it."))
            writer:append_separator()

            -- Turn 2: user prompt hits usage_limit. send_prompt's response
            -- callback in SessionManager runs write_error_message then
            -- append_separator (line 1467 in session_manager.lua).
            writer:write_message(user_message("Second prompt."))
            writer:write_error_message(usage_limit_err())
            writer:write_error_action(
                "Auto-continuing at 17:00 (in 5h 30m). Press [c] to cancel."
            )
            writer:append_separator()

            -- Auto-continue timer fires hours later. _handle_input_submit
            -- writes the "## continue" user message, starts the thinking
            -- spinner, and calls send_prompt.
            writer:write_message(user_message("continue"))

            -- Provider streams response: prose, then a Read tool call that
            -- completes, then more prose.
            writer:write_message_chunk(chunk("Picking up where I left off."))

            writer:write_tool_call_block(
                tool_call(
                    "tc-after-continue",
                    "pending",
                    "read",
                    "/tmp/data.txt"
                )
            )
            writer:update_tool_call_block(
                tool_update(
                    "tc-after-continue",
                    "completed",
                    { "line 1", "line 2" }
                )
            )

            writer:write_message_chunk(
                chunk("Here's what I found in the file.")
            )
            writer:append_separator()

            local dump = table.concat(buf_text(bufnr), "\n")

            -- Core assertions: the chunk-flush symptom would manifest as
            -- these strings being ABSENT from the buffer.
            assert.is_true(
                buf_contains(bufnr, "Picking up where I left off"),
                "Post-continue prose chunk must be in buffer.\n"
                    .. "Buffer:\n"
                    .. dump
            )
            assert.is_true(
                buf_contains(bufnr, "Read"),
                "Tool call header must be in buffer.\n" .. "Buffer:\n" .. dump
            )
            assert.is_true(
                buf_contains(bufnr, "Here's what I found"),
                "Second post-continue prose chunk must be in buffer.\n"
                    .. "Buffer:\n"
                    .. dump
            )

            -- MessageWriter per-turn state must be clean after the full
            -- flow, otherwise the NEXT turn would get corrupted.
            assert.is_false(writer._suppressing_rejection)
            assert.equal("", writer._rejection_buffer)
            assert.is_nil(writer._chunk_start_line)
        end
    )

    it(
        "rejection suppression from the pre-limit turn does not eat post-continue chunks",
        function()
            -- Edge case: user rejected a permission in the turn that hit
            -- the usage limit. suppress_next_rejection() was called, and
            -- we need to confirm the state resets across the error +
            -- auto-continue boundary.
            writer:write_message(user_message("Rejected-then-limit prompt."))
            writer:write_tool_call_block(
                tool_call("tc-rejected", "pending", "edit", "/tmp/thing.txt")
            )
            writer:suppress_next_rejection()
            writer:write_message_chunk(
                chunk("The user doesn't want to proceed with this change.")
            )

            -- Usage limit fires before the rejection boilerplate completes.
            writer:write_error_message(usage_limit_err())
            writer:append_separator()

            -- Auto-continue fires.
            writer:write_message(user_message("continue"))
            writer:write_message_chunk(
                chunk("OK, picking a different approach.")
            )
            writer:append_separator()

            local dump = table.concat(buf_text(bufnr), "\n")

            assert.is_true(
                buf_contains(bufnr, "picking a different approach"),
                "Post-continue chunk must NOT be swallowed by stale rejection suppression.\n"
                    .. "Buffer:\n"
                    .. dump
            )
        end
    )
end)

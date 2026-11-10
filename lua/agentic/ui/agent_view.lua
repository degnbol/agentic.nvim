local ACPPayloads = require("agentic.acp.acp_payloads")
local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
local ChatBuffer = require("agentic.ui.chat_buffer")
local ChatHistory = require("agentic.ui.chat_history")
local MessageWriter = require("agentic.ui.message_writer")
local ResponseBoundary = require("agentic.acp.response_boundary")
local StatusIndicator = require("agentic.ui.status_indicator")

--- One agent's chat-style buffer, with what writes to it.
--- @class agentic.ui.AgentView
--- @field bufnr integer
--- @field writer agentic.ui.MessageWriter
--- @field status_indicator agentic.ui.StatusIndicator
--- @field response_boundary agentic.acp.ResponseBoundary
local AgentView = {}
AgentView.__index = AgentView

--- @param bufnr integer A chat-style buffer
--- @return agentic.ui.AgentView
function AgentView:new(bufnr)
    return setmetatable({
        bufnr = bufnr,
        status_indicator = StatusIndicator:new(bufnr),
        writer = MessageWriter:new(bufnr),
        response_boundary = ResponseBoundary:new(),
    }, self)
end

--- Forget all that was written and start the buffer again as a chat buffer,
--- ready for its text to be rewritten whole. The text stays.
function AgentView:restart()
    self.writer:reset()
    ChatBuffer.start(self.bufnr)
end

--- Write `**Loaded <name>** · <id>`, plus ` · <thought level>` for the current
--- model, and the model's description: a marker whose place in the scrollback shows
--- from where on the model runs. Buffer only, so a replay does not restore it.
--- @param options agentic.acp.AgentConfigOptions
--- @param model_id string|nil Nil writes nothing
--- @param fallback agentic.acp.AgentConfigOptions|nil Names and describes a model `options` lists without a description
function AgentView:announce_model(options, model_id, fallback)
    if not model_id then
        return
    end

    local name, description = options:model_display(model_id, fallback)

    local lines = {
        options:model_title(string.format("**Loaded %s**", name), model_id),
    }
    if description and description ~= "" then
        table.insert(lines, description)
    end

    self.writer:write_message(ACPPayloads.generate_agent_message(lines))
end

--- Write a new tool call's block and record it in `history`.
--- @param history agentic.ui.ChatHistory
--- @param call agentic.ui.MessageWriter.ToolCallBlock
--- @param causes agentic.PermissionCause[]|nil
--- @param agent_key string|nil History key of the agent that sent it, nil for the main agent
--- @return agentic.ui.MessageWriter.ToolCallBlock written The normalised block, pending when `call` has no status
function AgentView:write_tool_call(history, call, causes, agent_key)
    local written = CanonicalToolCall.normalise(call, call.kind)
    -- ACP leaves `status` optional on a new call, defaulting to pending
    -- (https://agentclientprotocol.com/protocol/v2/tool-calls#status).
    written.status = written.status or "pending"
    written.causes = causes
    self.writer:write_tool_call_block(written)
    self.status_indicator:reposition()

    local record = ChatHistory.tool_call_record(written)
    record.agent_key = agent_key
    history:add_message(record)
    return written
end

--- Apply an update to its call's block and record it in `history`. An update
--- without a kind is normalised as the block's kind. A block keeps its first
--- rejection line.
--- @param history agentic.ui.ChatHistory
--- @param update agentic.ui.MessageWriter.ToolCallBase
--- @return agentic.ui.MessageWriter.ToolCallBase applied The normalised update
function AgentView:update_tool_call(history, update)
    local existing = self.writer.tool_call_blocks[update.tool_call_id]
    local applied = CanonicalToolCall.normalise(
        update,
        update.kind or (existing and existing.kind)
    )
    -- A provider reports the most specific reason first.
    if existing and existing.rejection then
        applied.rejection = nil
    end
    self.writer:update_tool_call_block(applied)
    self.status_indicator:reposition()
    history:update_tool_call(
        applied.tool_call_id,
        ChatHistory.tool_call_record(applied)
    )
    return applied
end

--- Show what decided a tool call's permission on its block and in `history`.
--- @param history agentic.ui.ChatHistory
--- @param tool_call_id string
--- @param causes agentic.PermissionCause[]
--- @return boolean changed False when the call has no block or already shows `causes`
function AgentView:show_causes(history, tool_call_id, causes)
    local tracker = self.writer.tool_call_blocks[tool_call_id]
    if not tracker or vim.deep_equal(tracker.causes, causes) then
        return false
    end
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local update = {
        tool_call_id = tool_call_id,
        status = tracker.status,
        causes = causes,
    }
    self.writer:update_tool_call_block(update)
    history:update_tool_call(tool_call_id, ChatHistory.tool_call_record(update))
    return true
end

return AgentView

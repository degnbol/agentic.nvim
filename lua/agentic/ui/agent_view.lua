local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatBuffer = require("agentic.ui.chat_buffer")
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

return AgentView

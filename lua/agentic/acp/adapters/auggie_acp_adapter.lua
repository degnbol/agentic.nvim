local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

--- Auggie-specific adapter that extends ACPClient with Auggie-specific behaviors
--- @class agentic.acp.AuggieACPAdapter : agentic.acp.ACPClient
local AuggieACPAdapter = ACPClient.extend()

--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallMessage
function AuggieACPAdapter:__handle_tool_call(session_id, update)
    -- Skip empty tool calls
    if not update.rawInput or vim.tbl_isempty(update.rawInput) then
        return
    end

    local kind = update.kind

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    if kind == "read" or kind == "edit" then
        local file_path = update.rawInput.file_path
        if file_path and file_path ~= "" then
            message.argument = FileSystem.to_smart_path(file_path)
        else
            message.argument = update.title or ""
        end

        if kind == "edit" then
            message.diff = {
                new = self:safe_split(update.rawInput.new_string),
                old = self:safe_split(update.rawInput.old_string),
                all = update.rawInput.replace_all or false,
            }
        end
    elseif kind == "fetch" then
        self:__resolve_fetch_fields(message, update.rawInput)
    else
        message.argument = self:__ensure_command_string(update.rawInput.command)
            or update.title
            or ""
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

return AuggieACPAdapter

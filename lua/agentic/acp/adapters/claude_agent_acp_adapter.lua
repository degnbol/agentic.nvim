local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic.acp.ClaudeAgentRawInput : agentic.acp.RawInput
--- @field content? string For creating new files instead of new_string
--- @field subagent_type? string For sub-agent tasks (Task tool)
--- @field model? string Model used for sub-agent tasks
--- @field skill? string Skill name
--- @field args? string Arguments for the skill

--- claude-agent-acp sends rawInput/title/kind on tool_call_update, not just tool_call
--- @class agentic.acp.ClaudeAgentToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field rawInput? agentic.acp.ClaudeAgentRawInput
--- @field title? string
--- @field kind? agentic.acp.ToolKind

--- @class agentic.acp.ClaudeAgentACPAdapter : agentic.acp.ACPClient
local ClaudeAgentACPAdapter = setmetatable({}, { __index = ACPClient })
ClaudeAgentACPAdapter.__index = ClaudeAgentACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.ClaudeAgentACPAdapter
function ClaudeAgentACPAdapter:new(config, on_ready)
    self = ACPClient.new(ACPClient, config, on_ready)
    self = setmetatable(self, ClaudeAgentACPAdapter) --[[@as agentic.acp.ClaudeAgentACPAdapter]]
    return self
end

--- Mode-switching tools: maps ACP tool_call title to a short display label.
--- Body contains internal instructions, not user-facing content.
local MODE_SWITCH_TOOLS = {
    EnterPlanMode = "Plan",
    ExitPlanMode = "Normal",
    EnterWorktree = "Normal",
}

--- Resolve mode-switch label from a tool_call title.
--- ACP has no stable tool-name field — `title` is the only identifier, and
--- the provider may send a user-facing string (e.g. "Ready to code?",
--- "Ready for implementation") instead of the internal tool name.
--- @param title string
--- @return string|nil label "Plan" or "Normal", or nil if not a mode switch
local function mode_switch_label(title)
    local label = MODE_SWITCH_TOOLS[title]
    if label then
        return label
    end
    -- Provider exit-plan titles start with "Ready" (e.g. "Ready to code?")
    if title:match("^Ready%s") then
        return "Normal"
    end
    return nil
end

--- Intercept mode-switching tools at the initial tool_call level before the
--- base class renders the body (which contains internal instructions).
--- @protected
--- @param session_id string
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
function ClaudeAgentACPAdapter:__handle_tool_call(session_id, update)
    -- Provider sends kind="other" for EnterPlanMode but kind="switch_mode"
    -- for ExitPlanMode ("Ready to code?"). Check both.
    local mode_label = (update.kind == "other" or update.kind == "switch_mode")
        and mode_switch_label(update.title)
    if mode_label then
        --- @type agentic.ui.MessageWriter.ToolCallBlock
        local message = {
            tool_call_id = update.toolCallId,
            kind = "switch_mode",
            status = update.status,
            argument = mode_label,
        }

        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_tool_call(message)
        end)
        return
    end

    ACPClient.__handle_tool_call(self, session_id, update)
end

--- Build enriched update from rawInput fields that claude-agent-acp
--- sends on tool_call_update instead of tool_call.
--- @protected
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase message
function ClaudeAgentACPAdapter:__build_tool_call_update(update)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
        body = self:extract_content_body(update),
    }

    local rawInput = update.rawInput
    if not rawInput or vim.tbl_isempty(rawInput) then
        return message
    end

    local kind = update.kind

    if kind == "read" or kind == "edit" then
        message.argument = FileSystem.to_smart_path(rawInput.file_path)

        if kind == "edit" then
            local new_string = rawInput.content or rawInput.new_string
            local old_string = rawInput.old_string

            message.diff = {
                new = self:safe_split(new_string),
                old = self:safe_split(old_string),
                all = rawInput.replace_all or false,
            }
        end
    elseif kind == "fetch" then
        if rawInput.query then
            message.kind = "WebSearch"
            message.argument = rawInput.query
        elseif rawInput.url then
            message.argument = rawInput.url

            if rawInput.prompt then
                message.argument =
                    string.format("%s %s", message.argument, rawInput.prompt)
            end
        else
            message.argument = "unknown fetch"
        end
    elseif kind == "think" and rawInput.subagent_type then
        message.kind = "SubAgent"
    elseif
        kind == "SubAgent" or (kind == "other" and rawInput.subagent_type)
    then
        message.kind = "SubAgent"
        message.argument = string.format(
            "%s, %s: %s",
            rawInput.model or "default",
            rawInput.subagent_type or "",
            rawInput.description or ""
        )

        if rawInput.prompt then
            message.body = self:safe_split(rawInput.prompt)
        end
    elseif kind == "other" or kind == "switch_mode" then
        if update.title == "SlashCommand" then
            message.kind = "SlashCommand"
        elseif update.title == "Skill" then
            message.kind = "Skill"
            message.argument = rawInput.skill or "unknown skill"

            if rawInput.args then
                message.body = self:safe_split(rawInput.args)
            end
        else
            local ml = mode_switch_label(update.title)
            if ml then
                message.kind = "switch_mode"
                message.argument = ml
            end
        end
    else
        local command = rawInput.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end

        message.argument = command or update.title or ""

        if not message.body then
            message.body = self:extract_content_body(update)
        end

        if kind == "search" and rawInput.pattern then
            message.search_pattern = rawInput.pattern
        end
    end

    return message
end

--- Claude-agent-acp sends tool call updates without status, so we need to overload to handle it
--- @protected
--- @param session_id string
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
function ClaudeAgentACPAdapter:__handle_tool_call_update(session_id, update)
    if
        not update.status
        and (not update.rawInput or vim.tbl_isempty(update.rawInput))
    then
        return
    end

    local message = self:__build_tool_call_update(update)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return ClaudeAgentACPAdapter

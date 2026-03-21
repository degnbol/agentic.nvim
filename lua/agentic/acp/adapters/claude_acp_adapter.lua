local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

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

--- @class agentic.acp.ClaudeRawInput : agentic.acp.RawInput
--- @field content? string For creating new files instead of new_string
--- @field subagent_type? string For sub-agent tasks (Task tool)
--- @field model? string Model used for sub-agent tasks
--- @field skill? string Skill name
--- @field args? string Arguments for the skill

--- @class agentic.acp.ClaudeToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? agentic.acp.ClaudeRawInput

--- Claude-specific adapter that extends ACPClient with Claude-specific behaviors
--- @class agentic.acp.ClaudeACPAdapter : agentic.acp.ACPClient
local ClaudeACPAdapter = setmetatable({}, { __index = ACPClient })
ClaudeACPAdapter.__index = ClaudeACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.ClaudeACPAdapter
function ClaudeACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, ClaudeACPAdapter) --[[@as agentic.acp.ClaudeACPAdapter]]

    return self
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.ClaudeToolCallMessage
function ClaudeACPAdapter:__handle_tool_call(session_id, update)
    -- expected state, claude is sending an empty content first, followed by the actual content
    if not update.rawInput or vim.tbl_isempty(update.rawInput) then
        return
    end

    local kind = update.kind

    -- Detect sub-agent tasks: Claude sends these as "think" with subagent_type in rawInput
    if kind == "think" and update.rawInput.subagent_type then
        kind = "SubAgent"
    end

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    if kind == "read" or kind == "edit" then
        message.argument = FileSystem.to_smart_path(update.rawInput.file_path)

        if kind == "edit" then
            -- Write tool sends full file content in rawInput.content (new or existing files)
            local new_string = update.rawInput.content
                or update.rawInput.new_string
            local old_string = update.rawInput.old_string

            message.diff = {
                new = self:safe_split(new_string),
                old = self:safe_split(old_string),
                all = update.rawInput.replace_all or false,
            }
        end
    elseif kind == "fetch" then
        if update.rawInput.query then
            -- To keep consistency with all other ACP providers
            message.kind = "WebSearch"
            message.argument = update.rawInput.query
        elseif update.rawInput.url then
            message.argument = update.rawInput.url

            if update.rawInput.prompt then
                message.argument = string.format(
                    "%s %s",
                    message.argument,
                    update.rawInput.prompt
                )
            end
        else
            message.argument = "unknown fetch"
        end
    elseif kind == "SubAgent" then
        message.argument = string.format(
            "%s, %s: %s",
            update.rawInput.model or "default",
            update.rawInput.subagent_type or "",
            update.rawInput.description or ""
        )

        if update.rawInput.prompt then
            message.body = self:safe_split(update.rawInput.prompt)
        end
    elseif kind == "other" or kind == "switch_mode" then
        if update.title == "SlashCommand" then
            -- Override kind to increase UX, `other` doesn't say much
            message.kind = "SlashCommand"
            message.argument = update.rawInput.command or ""
        elseif update.title == "Skill" then
            message.kind = "Skill"
            message.argument = update.rawInput.skill or "unknown skill"

            if update.rawInput.args then
                message.body = self:safe_split(update.rawInput.args)
            end
        else
            local ml = mode_switch_label(update.title)
            if ml then
                message.kind = "switch_mode"
                message.argument = ml
            end
        end
    else
        local command = update.rawInput.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end

        message.argument = command or update.title or ""
        message.body = self:extract_content_body(update)

        if kind == "search" and update.rawInput.pattern then
            message.search_pattern = update.rawInput.pattern
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

return ClaudeACPAdapter

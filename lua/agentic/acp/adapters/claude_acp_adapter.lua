local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local ClaudeShared = require("agentic.acp.adapters.claude_shared")

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
local ClaudeACPAdapter = ACPClient.extend()

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
        self:__resolve_fetch_fields(message, update.rawInput)
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
            message.kind = "SlashCommand"
            message.argument = update.rawInput.command or ""
        elseif update.title == "Skill" then
            message.kind = "Skill"
            message.argument = update.rawInput.skill or "unknown skill"
            if update.rawInput.args then
                message.body = self:safe_split(update.rawInput.args)
            end
        else
            local ml = ClaudeShared.mode_switch_label(update.title)
            if ml then
                message.kind = "switch_mode"
                message.argument = ml
            end
        end
    else
        message.argument = self:__ensure_command_string(update.rawInput.command)
            or update.title
            or ""
        message.body = self:extract_content_body(update)

        if kind == "search" then
            message.argument = ClaudeShared.rewrite_grep_to_rg(message.argument)
            if update.rawInput.pattern then
                message.search_pattern = update.rawInput.pattern
            end
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

return ClaudeACPAdapter

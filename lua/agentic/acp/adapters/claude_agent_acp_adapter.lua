local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local ClaudeShared = require("agentic.acp.adapters.claude_shared")

--- @class agentic.acp.ClaudeAgentRawInput : agentic.acp.RawInput
--- @field content? string For creating new files instead of new_string
--- @field subagent_type? string For sub-agent tasks (Task tool)
--- @field model? string Model used for sub-agent tasks
--- @field skill? string Skill name
--- @field args? string Arguments for the skill
--- @field offset? integer Line offset for range reads
--- @field limit? integer Line count for range reads

--- claude-agent-acp sends rawInput/title/kind on tool_call_update, not just tool_call
--- @class agentic.acp.ClaudeAgentToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field rawInput? agentic.acp.ClaudeAgentRawInput
--- @field title? string
--- @field kind? agentic.acp.ToolKind

--- @class agentic.acp.ClaudeAgentACPAdapter : agentic.acp.ACPClient
local ClaudeAgentACPAdapter = ACPClient.extend()

--- Intercept mode-switching tools at the initial tool_call level before the
--- base class renders the body (which contains internal instructions).
--- @protected
--- @param session_id string
--- @param update agentic.acp.ClaudeAgentToolCallUpdate
function ClaudeAgentACPAdapter:__handle_tool_call(session_id, update)
    -- Provider sends kind="other" for EnterPlanMode but kind="switch_mode"
    -- for ExitPlanMode ("Ready to code?"). Check both.
    local mode_label = (update.kind == "other" or update.kind == "switch_mode")
        and ClaudeShared.mode_switch_label(update.title)
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
    if update.status == "failed" then
        message.failure_reason = self:extract_failure_reason(update.rawOutput)
    end

    local rawInput = update.rawInput
    if not rawInput or vim.tbl_isempty(rawInput) then
        return message
    end

    local kind = update.kind

    if kind == "read" or kind == "edit" then
        if rawInput.file_path then
            message.argument = FileSystem.to_smart_path(rawInput.file_path)
        end

        if kind == "read" then
            if rawInput.offset then
                message.read_range = {
                    offset = rawInput.offset,
                    limit = rawInput.limit,
                }
            elseif update.title then
                -- rawInput may lack offset/limit; fall back to parsing
                -- the title string e.g. "Read file.txt (10 - 42)"
                local a, b = update.title:match("%((%d+)%s*%-%s*(%d+)%)%s*$")
                if a then
                    local na = tonumber(a) --[[@as integer]]
                    local nb = tonumber(b) --[[@as integer]]
                    message.read_range = {
                        offset = na,
                        limit = nb - na + 1,
                    }
                end
            end
        end

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
        self:__resolve_fetch_fields(message, rawInput)
    elseif kind == "think" and rawInput.subagent_type then
        message.kind = "SubAgent"
        message.argument = rawInput.description or rawInput.subagent_type
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
            message.argument = rawInput.command or ""
        elseif update.title == "Skill" then
            message.kind = "Skill"
            message.argument = rawInput.skill or "unknown skill"
            if rawInput.args then
                message.body = self:safe_split(rawInput.args)
            end
        else
            local ml = ClaudeShared.mode_switch_label(update.title)
            if ml then
                message.kind = "switch_mode"
                message.argument = ml
            end
        end
    else
        message.argument = self:__ensure_command_string(rawInput.command)
            or update.title
            or ""

        if not message.body then
            message.body = self:extract_content_body(update)
        end

        if kind == "search" then
            message.argument = ClaudeShared.rewrite_grep_to_rg(message.argument)
            if rawInput.pattern then
                message.search_pattern = rawInput.pattern
            end
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

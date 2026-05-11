local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")

--- Format opencode grep/glob arguments into an executable rg-equivalent
--- command so search blocks show the actual pattern/path instead of the bare
--- tool name ("grep"/"glob"). Returns nil when no pattern is set, signalling
--- the caller to fall back to a placeholder.
--- @param tool string "grep" or "glob"
--- @param raw_input { pattern?: string, path?: string, include?: string }
--- @return string|nil
local function format_search_command(tool, raw_input)
    local pattern = raw_input.pattern
    if not pattern or pattern == "" then
        return nil
    end
    local quoted = string.format('"%s"', pattern:gsub('"', '\\"'))
    local parts = { "rg" }
    if tool == "glob" then
        table.insert(parts, "--files")
        table.insert(parts, "--glob")
        table.insert(parts, quoted)
    else
        if raw_input.include and raw_input.include ~= "" then
            local q_include =
                string.format('"%s"', raw_input.include:gsub('"', '\\"'))
            table.insert(parts, "--glob")
            table.insert(parts, q_include)
        end
        table.insert(parts, quoted)
    end
    if raw_input.path and raw_input.path ~= "" then
        table.insert(parts, FileSystem.to_smart_path(raw_input.path))
    end
    return table.concat(parts, " ")
end

--- OpenCode-specific adapter that extends ACPClient with OpenCode-specific behaviors
--- @class agentic.acp.OpenCodeACPAdapter : agentic.acp.ACPClient
local OpenCodeACPAdapter = ACPClient.extend()

--- @protected
--- @param session_id string
--- @param update agentic.acp.OpenCodeToolCallMessage
function OpenCodeACPAdapter:__handle_tool_call(session_id, update)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = update.kind,
        status = update.status,
        argument = update.title ~= update.kind and update.title or "pending...",
    }

    if update.title == "list" then
        message.kind = "search"
    elseif update.title == "websearch" or update.title == "google_search" then
        message.kind = "WebSearch"
    elseif update.title == "task" then
        message.kind = "SubAgent"
    elseif update.title == "skill" then
        message.kind = "Skill"
        message.argument = update.rawInput and update.rawInput.name
            or "unknown skill"
    elseif update.title == "todowrite" then
        message.kind = "TodoWrite"
    elseif update.title == "grep" or update.title == "glob" then
        -- rawInput is usually empty on the initial tool_call; the pattern
        -- arrives in tool_call_update. Try to format here so the block
        -- shows the real command immediately when rawInput is populated,
        -- and fall back to "pending..." otherwise.
        local cmd = update.rawInput
            and format_search_command(update.title, update.rawInput)
        message.argument = cmd or "pending..."
        if update.rawInput and update.rawInput.pattern then
            message.search_pattern = update.rawInput.pattern
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- Specific OpenCode structure - created to avoid confusion with the standard ACP types,
--- as only OpenCode sends these fields
--- @class agentic.acp.OpenCodeToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? agentic.acp.OpenCodeToolCallRawInput

--- @class agentic.acp.OpenCodeToolCallRawInput : agentic.acp.RawInput
--- @field filePath? string
--- @field newString? string
--- @field oldString? string
--- @field replaceAll? boolean
--- @field error? string
--- @field name? string Skill name
--- @field subagent_type? string For sub-agent tasks
--- @field description? string For sub-agent tasks
--- @field prompt? string For sub-agent tasks
--- @field path? string Search directory for grep/glob
--- @field include? string File pattern filter for grep

--- @class agentic.acp.OpenCodeToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field kind? agentic.acp.ToolKind
--- @field title? string
--- @field rawInput? agentic.acp.OpenCodeToolCallRawInput

--- @protected
--- @param session_id string
--- @param update agentic.acp.ToolCallUpdate
function OpenCodeACPAdapter:__handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    ---@cast update agentic.acp.OpenCodeToolCallUpdate

    -- Opencode flips status to "in_progress" the moment the LLM finishes
    -- streaming tool args — before execute() runs and before the permission
    -- ask. The tool is not actually executing. Relabel to "pending" so the
    -- chat footer reflects the true state. See acp skill
    -- `references/opencode.md` § "Premature `in_progress`".
    local status = (update.status == "in_progress" and "pending" or update.status) --[[@as agentic.acp.ToolCallStatus]]

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = status,
    }

    -- Detect SubAgent for ALL statuses (kind comes as "other" from OpenCode)
    if update.rawInput and update.rawInput.subagent_type then
        message.kind = "SubAgent"
    end

    -- Opencode sends Edit diffs via the standard ACP content field
    -- (type="diff", oldText, newText). The diff may not be at index [1] —
    -- for writes, content[1] is a "Wrote file successfully." text entry and
    -- content[2] is the diff. Scan the array. MessageWriter freezes the diff
    -- after first render, so double-setting across updates is safe.
    if update.content then
        for _, entry in ipairs(update.content) do
            if entry.type == "diff" then
                message.argument = FileSystem.to_smart_path(entry.path or "")
                message.diff = {
                    new = self:safe_split(entry.newText),
                    old = self:safe_split(entry.oldText),
                }
                break
            end
        end
    end

    if update.status == "completed" or update.status == "failed" then
        if
            update.kind == "other"
            and update.rawInput
            and update.rawInput.name
        then
            message.body = { update.title or "" }
        elseif not message.diff then
            message.body = self:extract_content_body(update)
        end
    else
        if update.rawInput then
            if update.rawInput.newString then
                message.argument =
                    FileSystem.to_smart_path(update.rawInput.filePath or "")

                local old_string = update.rawInput.oldString

                message.diff = {
                    new = self:safe_split(update.rawInput.newString),
                    old = self:safe_split(old_string),
                    all = update.rawInput.replaceAll or false,
                }
            elseif update.rawInput.pattern then -- grep/glob search
                -- Only format the argument when we can identify the tool by
                -- its in-progress title. On `completed`, opencode replaces
                -- title with `part.state.title` (the pattern itself), so
                -- treating that as a tool name would mis-format. Skipping
                -- here lets MessageWriter's merge keep the argument written
                -- during the earlier in_progress update.
                if update.title == "grep" or update.title == "glob" then
                    local cmd =
                        format_search_command(update.title, update.rawInput)
                    if cmd then
                        message.argument = cmd
                    end
                end
                message.search_pattern = update.rawInput.pattern
            elseif update.rawInput.url then -- fetch command
                message.argument = update.rawInput.url
            elseif update.rawInput.query then -- WebSearch command
                message.argument = update.rawInput.query
                message.body = self:safe_split(update.rawInput.query)
            elseif update.rawInput.command then
                message.argument = update.rawInput.command

                if update.rawInput.description then
                    message.body = self:safe_split(update.rawInput.description)
                end
            elseif update.rawInput.subagent_type then
                message.argument = string.format(
                    "%s: %s",
                    update.rawInput.subagent_type,
                    update.rawInput.description or ""
                )
                if update.rawInput.prompt then
                    message.body = self:safe_split(update.rawInput.prompt)
                end
            elseif update.rawInput.filePath then
                message.argument =
                    FileSystem.to_smart_path(update.rawInput.filePath)
            elseif update.rawInput.name then
                message.argument = update.rawInput.name
            elseif update.rawInput.error then
                message.body = self:safe_split(update.rawInput.error)
            end
        elseif update.rawOutput then -- rawOutput doesn't seem standard, also we don't have types
            if update.rawOutput.output then
                message.body = self:safe_split(update.rawOutput.output)
            elseif update.rawOutput.error then
                message.body = self:safe_split(update.rawOutput.error)
            end
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return OpenCodeACPAdapter

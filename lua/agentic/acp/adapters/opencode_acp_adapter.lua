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

--- The block fields a tool call's input gives: its head, and for some tools
--- a body, description or search pattern.
--- @param tool string|nil Tool name. Only `grep` and `glob` get an `rg` command as head.
--- @param update agentic.acp.OpenCodeToolCallMessage|agentic.acp.OpenCodeToolCallUpdate
--- @return { argument?: string, body?: string[], description?: string, search_pattern?: string } fields Empty when the input names nothing
local function input_fields(tool, update)
    local raw = update.rawInput or {}
    -- opencode resolves this against the session cwd, unlike `rawInput.path`.
    -- Only a read or edit's location is its file: shell's is its cwd,
    -- grep's and glob's the search directory.
    local file = (update.kind == "read" or update.kind == "edit")
        and update.locations
        and update.locations[1]
    if raw.pattern then
        return {
            argument = (tool == "grep" or tool == "glob")
                    and format_search_command(tool, raw)
                or nil,
            search_pattern = raw.pattern,
        }
    elseif raw.url then
        return { argument = raw.url }
    elseif raw.query then
        return { argument = raw.query, body = ACPClient:safe_split(raw.query) }
    elseif raw.command then
        return { argument = raw.command, description = raw.description }
    elseif update.kind == "think" and raw.agent then
        return {
            argument = string.format(
                "%s: %s",
                raw.agent,
                raw.description or ""
            ),
            body = raw.prompt and ACPClient:safe_split(raw.prompt) or nil,
        }
    elseif file and file.path then
        return { argument = FileSystem.to_smart_path(file.path) }
    elseif raw.id then
        return { argument = raw.id }
    end
    return {}
end

--- Adapter kind per opencode tool name, for tools opencode kinds `other`.
--- @type table<string, string>
local KIND_BY_NAME = {
    websearch = "WebSearch",
    skill = "Skill",
    todowrite = "TodoWrite",
}

local SCANNER_REFUSAL = "Portable shell scanner cannot analyze command: "

--- The rejection line for a failed tool call, if opencode refused the call
--- before it ran. ACP carries no flag for whether a call ran, so only two
--- error texts match: a declined call (also each
--- sibling opencode cancels with it) and a command its shell scanner cannot
--- analyse. Other errors, e.g. `Tool execution aborted`, also come from calls
--- that ran.
--- @param err string Error text of the failed call
--- @return string|nil line `Rejected`, or `Rejected: ` and the scanner error joined to one line. nil for any other error
local function pre_run_rejection(err)
    if err == "The user declined this tool call" then
        -- Not the provider's text: it is false for a cancelled sibling.
        return "Rejected"
    end
    if vim.startswith(err, SCANNER_REFUSAL) then
        return "Rejected: " .. table.concat(vim.split(err, "\n"), " ")
    end
    return nil
end

--- @class agentic.acp.OpenCodeACPAdapter : agentic.acp.ACPClient
local OpenCodeACPAdapter = ACPClient.extend()

--- @protected
--- @param session_id string
--- @param update agentic.acp.OpenCodeToolCallMessage
function OpenCodeACPAdapter:__handle_tool_call(session_id, update)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = update.kind == "think" and "SubAgent"
            or KIND_BY_NAME[update.name]
            or update.kind,
        status = update.status,
        argument = update.title ~= update.kind and update.title or "pending...",
    }
    message =
        vim.tbl_extend("force", message, input_fields(update.name, update)) --[[@as agentic.ui.MessageWriter.ToolCallBlock]]

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- `OPENCODE_CONFIG_CONTENT` with an `ask` rule for every tool appended to
--- its `permissions`: opencode's last matching rule wins, and the inline
--- config outranks every config file. The base is `env`'s value, else the
--- editor's, else `{}`.
--- @param env table<string, string|nil> The env the process starts with
--- @return table<string, string>|nil env
--- @return string|nil err Why the base config cannot be extended
function OpenCodeACPAdapter:unattended_env(env)
    local base = env.OPENCODE_CONFIG_CONTENT
        or vim.env.OPENCODE_CONFIG_CONTENT
        or "{}"
    local ok, config = pcall(vim.json.decode, base)
    if not ok or type(config) ~= "table" or vim.islist(config) then
        return nil, "OPENCODE_CONFIG_CONTENT is not a JSON object: " .. base
    end
    local rules = config.permissions or {}
    if not vim.islist(rules) then
        return nil, "OPENCODE_CONFIG_CONTENT `permissions` is not a list"
    end
    table.insert(rules, { action = "*", resource = "*", effect = "ask" })
    config.permissions = rules
    return { OPENCODE_CONFIG_CONTENT = vim.json.encode(config) }
end

--- Specific OpenCode structure - created to avoid confusion with the standard ACP types,
--- as only OpenCode sends these fields
--- @class agentic.acp.OpenCodeToolCallMessage : agentic.acp.ToolCallMessage
--- @field name? string Tool name
--- @field rawInput? agentic.acp.OpenCodeToolCallRawInput

--- @class agentic.acp.OpenCodeToolCallRawInput : agentic.acp.RawInput
--- @field newString? string
--- @field oldString? string
--- @field replaceAll? boolean
--- @field id? string Skill id
--- @field agent? string For sub-agent tasks
--- @field description? string Sub-agent task description, or a 1.x shell command's
--- @field prompt? string For sub-agent tasks
--- @field path? string File path as the model gave it, or search directory for grep/glob
--- @field include? string File pattern filter for grep

--- @class agentic.acp.OpenCodeToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field title? string
--- @field rawInput? agentic.acp.OpenCodeToolCallRawInput
--- @field rawOutput? { error?: string } `error` is set on a `failed` update

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
    -- chat footer reflects the true state.
    local status = (
        update.status == "in_progress" and "pending" or update.status
    ) --[[@as agentic.acp.ToolCallStatus]]

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = status,
    }

    if update.kind == "think" then
        message.kind = "SubAgent"
    end

    -- Opencode sends Edit diffs via the standard ACP content field. On a
    -- completed edit content[1] is a status text entry (e.g. `Edited a.txt
    -- (1 replacement)`) ahead of the diff, hence find_content_diff rather
    -- than extract_content_body. MessageWriter freezes the diff after first
    -- render, so double-setting across updates is safe.
    local diff_content = self:find_content_diff(update)
    if diff_content then
        message.argument = FileSystem.to_smart_path(diff_content.path or "")
        message.diff = {
            new = self:safe_split(diff_content.newText),
            old = self:safe_split(diff_content.oldText),
        }
    end

    if update.status == "completed" or update.status == "failed" then
        local raw_output = update.rawOutput
        if
            update.status == "failed"
            and type(raw_output) == "table"
            and type(raw_output.error) == "string"
        then
            message.rejection = pre_run_rejection(raw_output.error)
        end
        -- The content repeats the error that the rejection line shows.
        if not message.diff and not message.rejection then
            message.body = self:extract_content_body(update)
        end
    else
        local raw = update.rawInput
        if raw and raw.newString then
            message.diff = {
                new = self:safe_split(raw.newString),
                old = self:safe_split(raw.oldString),
                all = raw.replaceAll or false,
            }
        end
        -- An update's title is the tool name (the command for shell),
        -- prefixed with the subagent's title for a child call.
        message =
            vim.tbl_extend("force", message, input_fields(update.title, update)) --[[@as agentic.ui.MessageWriter.ToolCallBase]]
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

return OpenCodeACPAdapter

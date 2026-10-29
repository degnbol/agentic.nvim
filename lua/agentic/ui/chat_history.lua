local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")
local TextWrap = require("agentic.utils.text_wrap")

--- @class agentic.ui.ChatHistory.UserMessage
--- @field type "user"
--- @field text string Raw user input text, not the buffer formatted content
--- @field timestamp integer Unix timestamp when message was sent
--- @field provider_name string

--- @class agentic.ui.ChatHistory.AgentMessage
--- @field type "agent"
--- @field provider_name string
--- @field text string Agent response text (concatenated chunks)
--- @field parent_tool_use_id? string The spawning Task's tool call id, on a subagent's message

--- @class agentic.ui.ChatHistory.ThoughtMessage : agentic.ui.ChatHistory.AgentMessage
--- @field type "thought"

--- @class agentic.ui.ChatHistory.ToolCall : agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id? string
--- @field type "tool_call"
--- @field parent_tool_use_id? string The spawning Task's tool call id, on a subagent's call

--- @alias agentic.SessionMessageKind "task"|"message"|"result"

--- How a session message is classified, the same for all its views.
--- @class agentic.SessionMessageInfo
--- @field kind agentic.SessionMessageKind
--- @field summary? string Short label of the message, when there is one

--- One view of a message between two sessions of the conversation.
--- @class agentic.ui.ChatHistory.SessionMessage : agentic.SessionMessageInfo
--- @field type "session_message"
--- @field message_id string Shared by the message's views
--- @field view "sent"|"received" The view on the sender's session, or on the recipient's
--- @field sender_session_id? string
--- @field recipient_session_id? string
--- @field text string
--- @field parent_tool_use_id? string The spawning Task's tool call id, on a subagent's row

--- The end of a subagent's run.
--- @class agentic.ui.ChatHistory.SubagentEnd
--- @field type "subagent_end"
--- @field state string How the run ended: `completed`, `cancelled`, `failed`, `ended`, `unknown` or a stop reason
--- @field error? string The provider's error text
--- @field parent_tool_use_id? string The spawning Task's tool call id

--- @alias agentic.ui.ChatHistory.Message
--- | agentic.ui.ChatHistory.UserMessage
--- | agentic.ui.ChatHistory.AgentMessage
--- | agentic.ui.ChatHistory.ThoughtMessage
--- | agentic.ui.ChatHistory.ToolCall
--- | agentic.ui.ChatHistory.SessionMessage
--- | agentic.ui.ChatHistory.SubagentEnd

--- The id, working directory, provider and model of a session.
--- @class agentic.ui.ChatHistory.SessionRef
--- @field session_id string
--- @field cwd? string Working directory of the session. The file is in the project folder of this path. Absent on legacy files
--- @field provider? agentic.UserConfig.ProviderName config key, absent on pre-2026-04-23 sessions
--- @field model? string model id used at last save

--- The fields that a session file and its metadata share.
--- @class agentic.ui.ChatHistory.SessionHeader : agentic.ui.ChatHistory.SessionRef
--- @field title string
--- @field timestamp integer
--- @field last_activity? integer Unix timestamp of most recent save
--- @field provider_version? string provider binary version as reported in its ACP initialize response

--- @class agentic.ui.ChatHistory.SessionMeta : agentic.ui.ChatHistory.SessionHeader
--- @field file_path string Full path to the session file
--- @field prompt_count? integer Number of user prompts in the session

--- @class agentic.ui.ChatHistory.StorageData : agentic.ui.ChatHistory.SessionHeader
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field subagent_messages? agentic.ui.ChatHistory.Message[] Absent from files written before subagent output was saved
--- @field subagents? table<string, agentic.ui.ChatHistory.Subagent> Absent from files written before subagents were sessions of their own
--- @field file_activity? agentic.ui.FileActivity.Data

--- What a session records about one of its subagents beyond its main-chat
--- block.
--- @class agentic.ui.ChatHistory.Subagent
--- @field task_id? string Id of the Agent tool use that spawned it, the `parent_tool_use_id` of its messages. Absent until known

--- @class agentic.ui.ChatHistory
--- @field session_id? string
--- @field timestamp integer Unix timestamp when session was created
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field subagent_messages agentic.ui.ChatHistory.Message[] Kept apart from `messages`, which are what a restore sends to the provider, what the picker previews and what the chat replays
--- @field subagents table<string, agentic.ui.ChatHistory.Subagent> Child session id -> what the session records about that subagent
--- @field title string
--- @field provider? agentic.UserConfig.ProviderName config key
--- @field model? string model id
--- @field provider_version? string provider binary version
--- @field file_activity? agentic.ui.FileActivity.Data Tally of files the agent changed. Cannot be rebuilt from `messages`: the restore path that replays them writes tool-call blocks straight to the chat buffer, bypassing the handlers that record ops.
--- @field dirty boolean Mutated since the last `save` or `load`, so the session file is behind. Set by every mutating method; assign `messages` or `title` only through them.
local ChatHistory = {}
ChatHistory.__index = ChatHistory

--- @return agentic.ui.ChatHistory
function ChatHistory:new()
    --- @type agentic.ui.ChatHistory
    local instance = {
        session_id = nil,
        timestamp = os.time(),
        messages = {},
        subagent_messages = {},
        subagents = {},
        title = "",
        provider = nil,
        model = nil,
        provider_version = nil,
        file_activity = nil,
        dirty = false,
    }

    setmetatable(instance, self)
    return instance
end

--- Project folder name of `cwd`: the path with slashes, whitespace and
--- colons as underscores and leading underscores dropped, then `_` and the
--- first 8 hex chars of its SHA256.
--- @param cwd string
--- @return string folder
function ChatHistory.get_project_folder(cwd)
    local normalized = cwd:gsub("[/\\%s:]", "_"):gsub("^_+", "")
    local hash = vim.fn.sha256(cwd):sub(1, 8)

    return normalized .. "_" .. hash
end

--- Path of the project folder of `cwd`.
--- @param cwd string
--- @return string folder_path
function ChatHistory.get_sessions_folder(cwd)
    return vim.fs.joinpath(
        ChatHistory.get_base_storage_path(),
        ChatHistory.get_project_folder(cwd)
    )
end

--- Path of the session file of `session_id` in the project folder of `cwd`.
--- @param session_id string
--- @param cwd string Working directory of the session
--- @return string file_path
function ChatHistory.get_file_path(session_id, cwd)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(cwd),
        session_id .. ".json"
    )
end

--- Paths of the files of `session_id` in all project folders, newest by
--- mtime first.
--- @param session_id string
--- @return string[] file_paths Empty when no folder holds one
function ChatHistory.find_files(session_id)
    local base = ChatHistory.get_base_storage_path()
    local found = {} --- @type { path: string, mtime: uv.fs_stat.result.time }[]
    for dirname, dir_type in vim.fs.dir(base) do
        if dir_type == "directory" then
            local path = vim.fs.joinpath(base, dirname, session_id .. ".json")
            local stat = vim.uv.fs_stat(path)
            if stat then
                table.insert(found, { path = path, mtime = stat.mtime })
            end
        end
    end
    table.sort(found, function(a, b)
        if a.mtime.sec ~= b.mtime.sec then
            return a.mtime.sec > b.mtime.sec
        end
        return a.mtime.nsec > b.mtime.nsec
    end)
    return vim.tbl_map(function(f)
        return f.path
    end, found)
end

--- The list a message belongs in: `subagent_messages` for one with
--- `parent_tool_use_id`, else `messages`.
--- @param msg { parent_tool_use_id?: string }
--- @return agentic.ui.ChatHistory.Message[]
function ChatHistory:_list_for(msg)
    return msg.parent_tool_use_id and self.subagent_messages or self.messages
end

--- @param msg agentic.ui.ChatHistory.Message
function ChatHistory:add_message(msg)
    table.insert(self:_list_for(msg), msg)
    self.dirty = true
end

--- @param title string
function ChatHistory:set_title(title)
    self.title = title
    self.dirty = true
end

--- Record the Agent tool use that spawned a subagent, replacing any earlier
--- record, and mark the history dirty. Messages stored under the child id or
--- the earlier record move to the new Task id, so one key holds all of the
--- subagent's messages.
--- @param child_id string The subagent's child session id
--- @param task_id string|nil Nil while unknown
function ChatHistory:set_subagent_task(child_id, task_id)
    local previous = vim.tbl_get(self.subagents, child_id, "task_id")
    self.subagents[child_id] = { task_id = task_id }
    if task_id then
        for _, msg in ipairs(self.subagent_messages) do
            if
                msg.parent_tool_use_id == child_id
                or msg.parent_tool_use_id == previous
            then
                msg.parent_tool_use_id = task_id
            end
        end
    end
    self.dirty = true
end

--- The stored messages of the agent one Task spawned, in stored order.
--- @param task_id string The spawning Task's tool call id
--- @return agentic.ui.ChatHistory.Message[]
function ChatHistory:messages_for_task(task_id)
    return vim.tbl_filter(function(msg)
        return msg.parent_tool_use_id == task_id
    end, self.subagent_messages)
end

--- Append text to the same agent's last message (same `parent_tool_use_id`)
--- when it has the same type, or add a new message.
--- @param msg { type: "agent"|"thought", text: string, provider_name: string, parent_tool_use_id?: string }
--- @param starts_response boolean|nil `msg.text` starts a new model response, so a merge into the last message puts a blank line before it
function ChatHistory:append_agent_text(msg, starts_response)
    local list = self:_list_for(msg)
    --- @type agentic.ui.ChatHistory.Message|nil
    local last
    for i = #list, 1, -1 do
        if list[i].parent_tool_use_id == msg.parent_tool_use_id then
            last = list[i]
            break
        end
    end
    if last and last.type == msg.type then
        local text = msg.text
        if starts_response then
            local _, trailing_newlines = last.text:match("%s*$"):gsub("\n", "")
            text = TextWrap.paragraph_break(text, trailing_newlines)
        end
        last.text = last.text .. text
    else
        table.insert(list, msg)
    end
    self.dirty = true
end

--- Update an existing tool_call, main or subagent, by merging update data
--- @param tool_call_id string
--- @param update agentic.ui.ChatHistory.ToolCall
function ChatHistory:update_tool_call(tool_call_id, update)
    for _, list in ipairs({ self.messages, self.subagent_messages }) do
        for i = #list, 1, -1 do
            local msg = list[i]
            if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
                list[i] = vim.tbl_deep_extend("force", msg, update)
                self.dirty = true
                return
            end
        end
    end
end

--- The fields of `agentic.ui.MessageWriter.ToolCallBase`, kept in sync by
--- hand and compared with the class by a test. The fields `ToolCallBlock`
--- adds, such as extmark ids and render caches, are left out.
local TOOL_CALL_FIELDS = {
    "tool_call_id",
    "status",
    "body",
    "diff",
    "kind",
    "argument",
    "search_pattern",
    "search_scope",
    "read_range",
    "failure_reason",
    "description",
    "shell",
    "exits_plan",
    "file_created",
    "hunk_ranges",
    "skill_path",
    "subagent",
    "decided_by",
}

--- The `TOOL_CALL_FIELDS` of `source`, sharing its values.
--- @param source table
--- @return table<string, any>
local function tool_call_fields(source)
    local fields = {}
    for _, key in ipairs(TOOL_CALL_FIELDS) do
        fields[key] = source[key]
    end
    return fields
end

--- The history record of a tool call or of an update to one, without
--- rendering state. Shares the tables of `tool_call`.
--- @param tool_call agentic.ui.MessageWriter.ToolCallBase
--- @return agentic.ui.ChatHistory.ToolCall record
function ChatHistory.tool_call_record(tool_call)
    local record = tool_call_fields(tool_call) --[[@as agentic.ui.ChatHistory.ToolCall]]
    record.type = "tool_call"
    return record
end

--- The tool call block a history record renders as. Shares the tables of
--- `record`.
--- @param record agentic.ui.ChatHistory.ToolCall
--- @return agentic.ui.MessageWriter.ToolCallBlock block
function ChatHistory.to_tool_call_block(record)
    local block = tool_call_fields(record) --[[@as agentic.ui.MessageWriter.ToolCallBlock]]
    block.argument = block.argument or ""
    return block
end

--- The label of a session among `messages`: its SubAgent block's label, else
--- `main agent`. The block is the `tool_call` whose `tool_call_id` is the
--- session id.
--- @param messages agentic.ui.ChatHistory.Message[]
--- @param session_id string|nil
--- @return string
function ChatHistory.session_label(messages, session_id)
    for _, msg in ipairs(messages) do
        if
            msg.type == "tool_call"
            and msg.tool_call_id == session_id
            and msg.subagent
        then
            return msg.subagent.label
        end
    end
    return "main agent"
end

--- Prepend restored messages to prompt in ACP Content format
--- @param messages agentic.ui.ChatHistory.Message[]
--- @param prompt agentic.acp.Content[] The prompt array to prepend to
function ChatHistory.prepend_restored_messages(messages, prompt)
    for _, msg in ipairs(messages) do
        -- Convert stored messages to ACP Content format
        if msg.type == "user" then
            table.insert(prompt, { type = "text", text = "User: " .. msg.text })
        elseif msg.type == "agent" then
            table.insert(
                prompt,
                { type = "text", text = "Assistant: " .. msg.text }
            )
        elseif msg.type == "thought" then
            table.insert(prompt, {
                type = "text",
                text = "Assistant (thinking): " .. msg.text,
            })
        elseif msg.type == "tool_call" and msg.subagent then
            local subagent = msg.subagent --[[@as agentic.ui.MessageWriter.SubagentInfo]]
            table.insert(prompt, {
                type = "text",
                text = string.format(
                    "Subagent %s%q: %s",
                    subagent.agent_type and (subagent.agent_type .. " ") or "",
                    subagent.label or "Agent",
                    msg.status
                ),
            })
        elseif msg.type == "tool_call" and msg.argument then
            local tool_text = string.format(
                "Tool call (%s): %s",
                msg.kind or "unknown",
                msg.argument
            )
            -- Include tool output if available
            if msg.body and #msg.body > 0 then
                tool_text = tool_text
                    .. "\nResult:\n"
                    .. table.concat(msg.body, "\n")
            end
            table.insert(prompt, { type = "text", text = tool_text })
        elseif msg.type == "session_message" then
            local sent = msg.view == "sent"
            local peer = sent and msg.recipient_session_id
                or msg.sender_session_id
            table.insert(prompt, {
                type = "text",
                text = string.format(
                    "%s %s %s:\n%s",
                    msg.kind:sub(1, 1):upper() .. msg.kind:sub(2),
                    sent and "sent to" or "received from",
                    ChatHistory.session_label(messages, peer),
                    msg.text
                ),
            })
        end
    end
end

--- Write the history to the session file in the project folder of `cwd`,
--- synchronously, and record `cwd` in it. Clears `dirty` on success.
--- @param cwd string Working directory of the session
--- @return string|nil err Why nothing was written
function ChatHistory:save(cwd)
    if not self.session_id then
        return "No session_id set"
    end

    local path = ChatHistory.get_file_path(self.session_id, cwd)
    local dir = vim.fs.dirname(path)

    local dir_ok, dir_err = FileSystem.mkdirp(dir)
    if not dir_ok then
        return "Failed to create directory: " .. (dir_err or "unknown error")
    end

    --- @type agentic.ui.ChatHistory.StorageData
    local data = {
        session_id = self.session_id,
        title = self.title,
        timestamp = self.timestamp,
        last_activity = os.time(),
        cwd = cwd,
        provider = self.provider,
        provider_version = self.provider_version,
        model = self.model,
        messages = self.messages,
        subagent_messages = self.subagent_messages,
        subagents = self.subagents,
        file_activity = self.file_activity,
    }

    local encode_ok, json = pcall(vim.json.encode, data)
    if not encode_ok then
        return "JSON encoding error: " .. tostring(json)
    end

    --- @type string|nil
    local err
    FileSystem.write_file(path, json, function(write_err)
        err = write_err
    end)
    if not err then
        self.dirty = false
    end
    return err
end

--- A history holding the contents of a session file.
--- @param data agentic.ui.ChatHistory.StorageData
--- @return agentic.ui.ChatHistory history
function ChatHistory.from_data(data)
    -- Assigned directly: a loaded history mirrors the file, so it is not
    -- dirty.
    local instance = ChatHistory:new()
    instance.session_id = data.session_id
    instance.timestamp = data.timestamp
    -- `subagent_event` rows, from files written before session messages kept
    -- their text, are dropped.
    local function current(msg)
        return msg.type ~= "subagent_event"
    end
    instance.messages = vim.tbl_filter(current, data.messages)
    instance.subagent_messages =
        vim.tbl_filter(current, data.subagent_messages or {})
    instance.subagents = data.subagents or {}
    instance.title = data.title or ""
    instance.provider = data.provider
    instance.provider_version = data.provider_version
    instance.model = data.model
    instance.file_activity = data.file_activity
    return instance
end

--- Get the base storage path for all session folders.
--- @return string
function ChatHistory.get_base_storage_path()
    return Config.session_restore.storage_path
        or vim.fs.joinpath(
            vim.fn.stdpath("cache") --[[@as string]],
            "agentic",
            "sessions"
        )
end

--- Read session metadata from all JSON files in a folder.
--- @param folder string
--- @return agentic.ui.ChatHistory.SessionMeta[] sessions
--- @return string[] errors One per file that could not be read or decoded
local function read_sessions_from_folder(folder)
    local sessions = {} --- @type agentic.ui.ChatHistory.SessionMeta[]
    local errors = {} --- @type string[]

    for filename, file_type in vim.fs.dir(folder) do
        if file_type == "file" and filename:match("%.json$") then
            local file_path = vim.fs.joinpath(folder, filename)
            local parsed, err = FileSystem.read_json(file_path)
            if parsed then
                local prompt_count = 0
                if parsed.messages then
                    for _, msg in ipairs(parsed.messages) do
                        if msg.type == "user" then
                            prompt_count = prompt_count + 1
                        end
                    end
                end
                table.insert(sessions, {
                    session_id = filename:gsub("%.json$", ""),
                    title = parsed.title or "",
                    timestamp = parsed.timestamp or 0,
                    last_activity = parsed.last_activity,
                    cwd = parsed.cwd,
                    file_path = file_path,
                    prompt_count = prompt_count,
                    provider = parsed.provider,
                    model = parsed.model,
                })
            else
                table.insert(errors, err)
            end
        end
    end

    return sessions, errors
end

--- Warn once about every session file that could not be listed.
--- @param errors string[]
local function warn_unreadable(errors)
    if #errors > 0 then
        Logger.notify(
            "Unreadable session files:\n" .. table.concat(errors, "\n"),
            vim.log.levels.WARN
        )
    end
end

--- List the sessions of the project folder of `cwd`, by last activity
--- descending.
--- @param cwd string
--- @param callback fun(sessions: agentic.ui.ChatHistory.SessionMeta[])
function ChatHistory.list_sessions(cwd, callback)
    local folder = ChatHistory.get_sessions_folder(cwd)

    if vim.fn.isdirectory(folder) == 0 then
        Logger.debug("Session folder does not exist:", folder)
        callback({})
        return
    end

    local sessions, errors = read_sessions_from_folder(folder)
    warn_unreadable(errors)

    table.sort(sessions, function(a, b)
        return (a.last_activity or a.timestamp)
            > (b.last_activity or b.timestamp)
    end)

    callback(sessions)
end

--- List sessions from ALL projects, sorted by last activity descending.
--- @param callback fun(sessions: agentic.ui.ChatHistory.SessionMeta[])
function ChatHistory.list_all_sessions(callback)
    local base = ChatHistory.get_base_storage_path()

    if vim.fn.isdirectory(base) == 0 then
        Logger.debug("Base session folder does not exist:", base)
        callback({})
        return
    end

    local all_sessions = {} --- @type agentic.ui.ChatHistory.SessionMeta[]
    local all_errors = {} --- @type string[]

    for dirname, dir_type in vim.fs.dir(base) do
        if dir_type == "directory" then
            local sessions, errors =
                read_sessions_from_folder(vim.fs.joinpath(base, dirname))
            vim.list_extend(all_sessions, sessions)
            vim.list_extend(all_errors, errors)
        end
    end
    warn_unreadable(all_errors)

    table.sort(all_sessions, function(a, b)
        return (a.last_activity or a.timestamp)
            > (b.last_activity or b.timestamp)
    end)

    callback(all_sessions)
end

return ChatHistory

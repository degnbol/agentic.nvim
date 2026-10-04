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
--- @alias agentic.ui.ChatHistory.Message
--- | agentic.ui.ChatHistory.UserMessage
--- | agentic.ui.ChatHistory.AgentMessage
--- | agentic.ui.ChatHistory.ThoughtMessage
--- | agentic.ui.ChatHistory.ToolCall

--- A message with `parent_tool_use_id` set, of type `agent`, `thought` or
--- `tool_call`.
--- @alias agentic.ui.ChatHistory.SubagentMessage agentic.ui.ChatHistory.Message

--- @class agentic.ui.ChatHistory.SessionMeta
--- @field session_id string
--- @field title string
--- @field timestamp integer
--- @field last_activity? integer Unix timestamp of most recent save
--- @field cwd? string Working directory the session was created in
--- @field file_path? string Full path to JSON file (set by list_all_sessions)
--- @field prompt_count? integer Number of user prompts in the session
--- @field provider? agentic.UserConfig.ProviderName config key, absent on pre-2026-04-23 sessions
--- @field model? string model id used at last save
--- @field provider_version? string provider binary version as reported in its ACP initialize response

--- @class agentic.ui.ChatHistory.StorageData : agentic.ui.ChatHistory.SessionMeta
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field subagent_messages? agentic.ui.ChatHistory.SubagentMessage[] Absent from files written before subagent output was saved
--- @field file_activity? agentic.ui.FileActivity.Data

--- @class agentic.ui.ChatHistory
--- @field session_id? string
--- @field timestamp integer Unix timestamp when session was created
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field subagent_messages agentic.ui.ChatHistory.SubagentMessage[] Kept apart from `messages`, which are what a restore sends to the provider, what the picker previews and what the chat replays
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

--- Generate the project folder name from CWD
--- Normalizes path by replacing slashes, spaces, and colons with underscores
--- Appends first 8 chars of SHA256 hash for collision resistance
function ChatHistory.get_project_folder()
    local cwd = vim.uv.cwd() or ""

    local normalized = cwd:gsub("[/\\%s:]", "_"):gsub("^_+", "")
    local hash = vim.fn.sha256(cwd):sub(1, 8)

    return normalized .. "_" .. hash
end

--- Get the folder path for storing sessions for the current project
--- @return string folder_path
function ChatHistory.get_sessions_folder()
    local base = Config.session_restore.storage_path
        or vim.fs.joinpath(vim.fn.stdpath("cache"), "agentic", "sessions")
    local project_folder = ChatHistory.get_project_folder()
    return vim.fs.joinpath(base, project_folder)
end

--- Generate the full file path for this session's JSON file
--- @param session_id string
--- @return string file_path
function ChatHistory.get_file_path(session_id)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(),
        session_id .. ".json"
    )
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
        end
    end
end

--- Write the history to its session file, synchronously. Clears `dirty` on
--- success.
--- @return string|nil err Why nothing was written
function ChatHistory:save()
    if not self.session_id then
        return "No session_id set"
    end

    local path = ChatHistory.get_file_path(self.session_id)
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
        cwd = vim.uv.cwd(),
        provider = self.provider,
        provider_version = self.provider_version,
        model = self.model,
        messages = self.messages,
        subagent_messages = self.subagent_messages,
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

--- Read a session file, synchronously.
--- @param session_id string
--- @param file_path string|nil Override path (for cross-project sessions)
--- @return agentic.ui.ChatHistory|nil history
--- @return string|nil err Why nothing was read
function ChatHistory.read(session_id, file_path)
    local path = file_path or ChatHistory.get_file_path(session_id)

    --- @type string|nil
    local content
    FileSystem.read_file(path, nil, nil, function(read)
        content = read
    end)
    if not content then
        return nil, "Failed to read file"
    end

    local ok, parsed = pcall(vim.json.decode, content)
    if not ok then
        Logger.debug("JSON decode failed:", parsed)
        return nil, "JSON decode error"
    end

    --- @cast parsed agentic.ui.ChatHistory.StorageData

    -- Assigned directly: a loaded history mirrors the file, so it is not
    -- dirty.
    local instance = ChatHistory:new()
    instance.session_id = parsed.session_id
    instance.timestamp = parsed.timestamp
    instance.messages = parsed.messages
    instance.subagent_messages = parsed.subagent_messages or {}
    instance.title = parsed.title or ""
    instance.provider = parsed.provider
    instance.provider_version = parsed.provider_version
    instance.model = parsed.model
    instance.file_activity = parsed.file_activity
    return instance, nil
end

--- `read`, delivering its result on the next event-loop tick.
--- @param session_id string
--- @param callback fun(history: agentic.ui.ChatHistory|nil, err: string|nil)
--- @param file_path? string Override path (for cross-project sessions)
function ChatHistory.load(session_id, callback, file_path)
    local history, err = ChatHistory.read(session_id, file_path)
    vim.schedule(function()
        callback(history, err)
    end)
end

--- Delete a session file from disk.
--- @param session_id string
--- @return boolean success
--- @return string|nil error
function ChatHistory.delete_session(session_id)
    local file_path = ChatHistory.get_file_path(session_id)
    local ok, err = os.remove(file_path)
    if not ok then
        Logger.debug("Failed to delete session file:", file_path, err)
        return false, err
    end
    return true, nil
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
--- @return agentic.ui.ChatHistory.SessionMeta[]
local function read_sessions_from_folder(folder)
    local sessions = {} --- @type agentic.ui.ChatHistory.SessionMeta[]

    for filename, file_type in vim.fs.dir(folder) do
        if file_type == "file" and filename:match("%.json$") then
            local file_path = vim.fs.joinpath(folder, filename)
            local content = vim.fn.readfile(file_path)
            if #content > 0 then
                local ok, parsed =
                    pcall(vim.json.decode, table.concat(content, "\n"))
                if ok and parsed then
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
                    Logger.debug(
                        "Failed to parse session file:",
                        file_path,
                        parsed
                    )
                end
            end
        end
    end

    return sessions
end

--- List all sessions for the current project, sorted by last activity descending.
--- @param callback fun(sessions: agentic.ui.ChatHistory.SessionMeta[])
function ChatHistory.list_sessions(callback)
    local folder = ChatHistory.get_sessions_folder()

    if vim.fn.isdirectory(folder) == 0 then
        Logger.debug("Session folder does not exist:", folder)
        callback({})
        return
    end

    local sessions = read_sessions_from_folder(folder)

    table.sort(sessions, function(a, b)
        return (a.last_activity or a.timestamp)
            > (b.last_activity or b.timestamp)
    end)

    callback(sessions)
end

--- List sessions from ALL projects, sorted by last activity descending.
--- Each session includes cwd and file_path for cross-project access.
--- @param callback fun(sessions: agentic.ui.ChatHistory.SessionMeta[])
function ChatHistory.list_all_sessions(callback)
    local base = ChatHistory.get_base_storage_path()

    if vim.fn.isdirectory(base) == 0 then
        Logger.debug("Base session folder does not exist:", base)
        callback({})
        return
    end

    local all_sessions = {} --- @type agentic.ui.ChatHistory.SessionMeta[]

    for dirname, dir_type in vim.fs.dir(base) do
        if dir_type == "directory" then
            local folder = vim.fs.joinpath(base, dirname)
            local sessions = read_sessions_from_folder(folder)
            vim.list_extend(all_sessions, sessions)
        end
    end

    table.sort(all_sessions, function(a, b)
        return (a.last_activity or a.timestamp)
            > (b.last_activity or b.timestamp)
    end)

    callback(all_sessions)
end

return ChatHistory

local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")
local SideRecords = require("agentic.ui.side_records")
local TextWrap = require("agentic.utils.text_wrap")

--- @class agentic.ui.ChatHistory.UserMessage
--- @field type "user"
--- @field text string Raw user input text, not the buffer formatted content
--- @field timestamp integer Unix timestamp when message was sent
--- @field provider_name string
--- @field synthetic? boolean Sent by the plugin, not typed. Kept as a session/load alignment key; every rendering of the history skips it, so a replay reads the response as one continuous turn
--- @field author? string Who wrote the prompt when not the user, a key of `Glyphs.AUTHOR`
--- @field model? string The model the prompt was sent with. Absent on files saved before it was recorded and on prompts from a session/load replay

--- @class agentic.ui.ChatHistory.AgentMessage
--- @field type "agent"
--- @field provider_name string
--- @field text string Agent response text (concatenated chunks)
--- @field agent_key? string Key of the subagent that owns the message: its task id, else its child session id while that is unknown
--- @field response_id? string `messageId` of the last model response whose text the message holds, in the current ACP session. Absent when the provider sends none, on files saved before it was recorded, and on messages carried over from an earlier ACP session

--- @class agentic.ui.ChatHistory.ThoughtMessage : agentic.ui.ChatHistory.AgentMessage
--- @field type "thought"

--- @class agentic.ui.ChatHistory.ToolCall : agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id? string
--- @field type "tool_call"
--- @field agent_key? string Key of the subagent that owns the call: its task id, else its child session id while that is unknown

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
--- @field sender_name? string The display name the provider gave the sender
--- @field recipient_session_id? string
--- @field text string
--- @field agent_key? string Key of the subagent that owns the row: its task id, else its child session id while that is unknown
--- @field launch_reply? boolean A `result` that is the provider's reply to the launch of its sender

--- The end of a subagent's run.
--- @class agentic.ui.ChatHistory.SubagentEnd
--- @field type "subagent_end"
--- @field state string How the run ended: `completed`, `interrupted`, `failed`, `ended`, `unknown` or a stop reason. Saved by earlier versions as `cancelled` for `interrupted`
--- @field error? string The provider's error text
--- @field agent_key? string Key of the subagent that owns the row: its task id, else its child session id while that is unknown

--- Records a provider wrote outside the ACP feed.
--- @class agentic.ui.ChatHistory.SideRecordsMessage
--- @field type "side_records"
--- @field records agentic.acp.SideRecord[]

--- A link to the other chat of a fork. The plugin's own: no provider
--- transcript holds it.
--- @class agentic.ui.ChatHistory.ForkLink
--- @field type "fork_link"
--- @field direction "to"|"from" A fork this chat made, or the chat this one was forked from
--- @field chat_id string The other chat
--- @field cwd string Working directory of the other chat
--- @field title string The other chat's title when the link was made, else the first 8 characters of `chat_id`

--- @alias agentic.ui.ChatHistory.Message
--- | agentic.ui.ChatHistory.UserMessage
--- | agentic.ui.ChatHistory.AgentMessage
--- | agentic.ui.ChatHistory.ThoughtMessage
--- | agentic.ui.ChatHistory.ToolCall
--- | agentic.ui.ChatHistory.SessionMessage
--- | agentic.ui.ChatHistory.SubagentEnd
--- | agentic.ui.ChatHistory.SideRecordsMessage
--- | agentic.ui.ChatHistory.ForkLink

--- The working directory, provider and model of a session.
--- @class agentic.ui.ChatHistory.SessionContext
--- @field cwd? string Working directory of the session. The file is in the project folder of this path. Absent on legacy files
--- @field provider? agentic.UserConfig.ProviderName config key, absent on pre-2026-04-23 sessions
--- @field model? string model id used at last save

--- The chat id, working directory, provider and model of a session.
--- @class agentic.ui.ChatHistory.SessionRef : agentic.ui.ChatHistory.SessionContext
--- @field chat_id string

--- The fields that a session file and its metadata share.
--- @class agentic.ui.ChatHistory.SessionHeader : agentic.ui.ChatHistory.SessionContext
--- @field title string
--- @field timestamp integer
--- @field last_activity? integer Unix timestamp of most recent save
--- @field provider_version? string provider binary version as reported in its ACP initialize response

--- @class agentic.ui.ChatHistory.SessionMeta : agentic.ui.ChatHistory.SessionRef, agentic.ui.ChatHistory.SessionHeader
--- @field chat_id string The file's name
--- @field session_id string The file's ACP session id, else its name
--- @field file_path string Full path to the session file
--- @field prompt_count? integer Number of user prompts in the session

--- @class agentic.ui.ChatHistory.StorageData : agentic.ui.ChatHistory.SessionHeader
--- @field session_id string The ACP session id at the last save
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field subagent_messages? agentic.ui.ChatHistory.Message[] Absent from files written before subagent output was saved
--- @field subagents? table<string, agentic.ui.ChatHistory.Subagent> Absent from files written before subagents were sessions of their own
--- @field file_activity? agentic.ui.FileActivity.Data

--- What a session records about one of its subagents beyond its main-chat
--- block.
--- @class agentic.ui.ChatHistory.Subagent
--- @field task_id? string Task id of the subagent, the `agent_key` of its messages: the first one seen, replaced by the spawn's once the provider's record is read. Absent until known

--- @class agentic.ui.ChatHistory
--- @field chat_id string 8 hex digits the plugin gives the chat; the session file's name
--- @field session_id? string The current ACP session id
--- @field timestamp integer Unix timestamp when the chat was created
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field subagent_messages agentic.ui.ChatHistory.Message[] Kept apart from `messages`, which are what a re-create from history sends to the provider, what the picker previews and what the chat replays
--- @field subagents table<string, agentic.ui.ChatHistory.Subagent> Child session id -> what the session records about that subagent
--- @field title string
--- @field provider? agentic.UserConfig.ProviderName config key
--- @field model? string model id
--- @field provider_version? string provider binary version
--- @field file_activity? agentic.ui.FileActivity.Data Tally of files the agent changed. Cannot be rebuilt from `messages`: the replay writes tool-call blocks straight to the chat buffer, bypassing the handlers that record ops.
--- @field dirty boolean Mutated since the last `save` or `load`, so the session file is behind. Set by every mutating method; assign `messages` or `title` only through them.
local ChatHistory = {}
ChatHistory.__index = ChatHistory

--- @param chat_id string|nil Else a new one (`new_chat_id`)
--- @return agentic.ui.ChatHistory
function ChatHistory:new(chat_id)
    --- @type agentic.ui.ChatHistory
    local instance = {
        chat_id = chat_id or ChatHistory.new_chat_id(),
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

--- Path of the session file of `chat_id` in the project folder of `cwd`.
--- @param chat_id string
--- @param cwd string Working directory of the session
--- @return string file_path
function ChatHistory.get_file_path(chat_id, cwd)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(cwd),
        chat_id .. ".json"
    )
end

--- Paths of the files of `chat_id` in all project folders, newest by mtime
--- first.
--- @param chat_id string
--- @return string[] file_paths Empty when no folder holds one
function ChatHistory.find_files(chat_id)
    local base = ChatHistory.get_base_storage_path()
    local found = {} --- @type { path: string, mtime: uv.fs_stat.result.time }[]
    for dirname, dir_type in vim.fs.dir(base) do
        if dir_type == "directory" then
            local path = vim.fs.joinpath(base, dirname, chat_id .. ".json")
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

--- A random chat id of 8 lowercase hex digits that no saved file has.
--- Raises an error when 10 draws all name a saved file.
--- @return string chat_id
function ChatHistory.new_chat_id()
    for _ = 1, 10 do
        local chat_id = vim.text.hexencode(assert(vim.uv.random(4))):lower()
        if #ChatHistory.find_files(chat_id) == 0 then
            return chat_id
        end
    end
    error("Agentic: 10 random chat ids all name a saved session file")
end

--- The newest saved file of `chat_id` in any project folder, decoded.
--- Warns when that file cannot be read or decoded.
--- @param chat_id string
--- @return agentic.ui.ChatHistory.StorageData|nil data Nil when there is no file or it cannot be read
function ChatHistory.read_saved(chat_id)
    local path = ChatHistory.find_files(chat_id)[1]
    if not path then
        return nil
    end
    local data, err = FileSystem.read_json(path)
    if not data then
        Logger.notify(
            "Failed to read saved session: " .. err,
            vim.log.levels.WARN
        )
    end
    return data
end

--- The list a message belongs in: `subagent_messages` for one with
--- `agent_key`, else `messages`.
--- @param msg { agent_key?: string }
--- @return agentic.ui.ChatHistory.Message[]
function ChatHistory:_list_for(msg)
    return msg.agent_key and self.subagent_messages or self.messages
end

--- @param msg agentic.ui.ChatHistory.Message
function ChatHistory:add_message(msg)
    table.insert(self:_list_for(msg), msg)
    self.dirty = true
end

--- Insert `msg` into the main history at `index`.
--- @param index integer
--- @param msg agentic.ui.ChatHistory.Message
function ChatHistory:insert_message(index, msg)
    table.insert(self.messages, index, msg)
    self.dirty = true
end

--- The position of `message` in the main history.
--- @param message agentic.ui.ChatHistory.Message
--- @return integer|nil index Nil when the main history does not hold it
function ChatHistory:index_of(message)
    for i, msg in ipairs(self.messages) do
        if msg == message then
            return i
        end
    end
    return nil
end

--- Remove `message` and every message after it, when `message` is in the
--- main history.
--- @param message agentic.ui.ChatHistory.Message
--- @return boolean removed
function ChatHistory:truncate_from(message)
    local i = self:index_of(message)
    if not i then
        return false
    end
    for j = #self.messages, i, -1 do
        self.messages[j] = nil
    end
    self.dirty = true
    return true
end

--- The first prompt the user sent after position `index` of the main
--- history.
--- @param index integer
--- @return agentic.ui.ChatHistory.UserMessage|nil
function ChatHistory:next_prompt(index)
    for i = index + 1, #self.messages do
        local msg = self.messages[i]
        if msg.type == "user" and not msg.synthetic then
            return msg
        end
    end
    return nil
end

--- The index of the first message a chat shows of `messages`: the last
--- `from` fork link, else 1. What comes before the link is the conversation
--- the session was forked with.
--- @param messages agentic.ui.ChatHistory.Message[]
--- @return integer
function ChatHistory.render_start(messages)
    for i = #messages, 1, -1 do
        local msg = messages[i]
        if msg.type == "fork_link" and msg.direction == "from" then
            return i
        end
    end
    return 1
end

--- A new unsaved history holding copies of the first `count` main messages,
--- without their fork links, and the source's provider, model and provider
--- version. It has no title, session id, subagents or file tally.
--- @param count integer
--- @return agentic.ui.ChatHistory
function ChatHistory:copy_prefix(count)
    local copy = ChatHistory:new()
    for i = 1, count do
        local msg = self.messages[i]
        if msg.type ~= "fork_link" then
            table.insert(copy.messages, vim.deepcopy(msg))
        end
    end
    copy.provider = self.provider
    copy.model = self.model
    copy.provider_version = self.provider_version
    copy.dirty = true
    return copy
end

--- The response to end a provider's copy of the main history on: the
--- `response_id` of the last message other than side records and fork
--- links, when that message is an agent message or a thought.
--- @return string|nil response_id
function ChatHistory:fork_point()
    for i = #self.messages, 1, -1 do
        local msg = self.messages[i]
        if msg.type ~= "side_records" and msg.type ~= "fork_link" then
            if msg.type == "agent" or msg.type == "thought" then
                return msg.response_id
            end
            return nil
        end
    end
    return nil
end

--- Remove `response_id` from every message. Leaves `dirty` as it is: an id
--- names a response of one ACP session, so a file holding it is not behind
--- a history without it.
function ChatHistory:clear_response_ids()
    for _, list in ipairs({ self.messages, self.subagent_messages }) do
        for _, msg in ipairs(list) do
            msg.response_id = nil
        end
    end
end

--- Whether the history holds a prompt the user sent.
--- @return boolean
function ChatHistory:has_prompt()
    for _, msg in ipairs(self.messages) do
        if msg.type == "user" and not msg.synthetic then
            return true
        end
    end
    return false
end

--- @param title string
function ChatHistory:set_title(title)
    self.title = title
    self.dirty = true
end

--- Record a subagent's task id, replacing any earlier one, and mark the
--- history dirty. Messages keyed by the child id or by the earlier task id
--- move to the new one, so one key holds all of the subagent's messages.
--- @param child_id string The subagent's child session id
--- @param task_id string|nil Nil while unknown
function ChatHistory:set_subagent_task(child_id, task_id)
    local previous = vim.tbl_get(self.subagents, child_id, "task_id")
    self.subagents[child_id] = { task_id = task_id }
    if task_id then
        for _, msg in ipairs(self.subagent_messages) do
            if
                msg.agent_key == child_id
                or (previous and msg.agent_key == previous)
            then
                msg.agent_key = task_id
            end
        end
    end
    self.dirty = true
end

--- The stored messages of one subagent, in stored order.
--- @param agent_key string Key of the subagent (`AgentMessage.agent_key`)
--- @return agentic.ui.ChatHistory.Message[]
function ChatHistory:messages_for_agent(agent_key)
    return vim.tbl_filter(function(msg)
        return msg.agent_key == agent_key
    end, self.subagent_messages)
end

--- Append text to the same agent's last message (same `agent_key`)
--- when it has the same type, or add a new message. A merge keeps the
--- last message's `response_id` when `msg` has none.
--- @param msg { type: "agent"|"thought", text: string, provider_name: string, agent_key?: string, response_id?: string }
--- @param starts_response boolean|nil `msg.text` starts a new model response, so a merge into the last message puts a blank line before it
function ChatHistory:append_agent_text(msg, starts_response)
    local list = self:_list_for(msg)
    --- @type agentic.ui.ChatHistory.Message|nil
    local last
    for i = #list, 1, -1 do
        if list[i].agent_key == msg.agent_key then
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
        last.response_id = msg.response_id or last.response_id
    else
        table.insert(list, msg)
    end
    self.dirty = true
end

--- The record of a tool call, in the main chat's messages or a subagent's.
--- @param tool_call_id string
--- @return agentic.ui.ChatHistory.ToolCall|nil
function ChatHistory:tool_call(tool_call_id)
    for _, list in ipairs({ self.messages, self.subagent_messages }) do
        for i = #list, 1, -1 do
            local msg = list[i]
            if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
                return msg --[[@as agentic.ui.ChatHistory.ToolCall]]
            end
        end
    end
    return nil
end

--- Update an existing tool_call, main or subagent, by merging update data
--- into its record in place. No-op when no record has the id.
--- @param tool_call_id string
--- @param update agentic.ui.ChatHistory.ToolCall
function ChatHistory:update_tool_call(tool_call_id, update)
    local msg = self:tool_call(tool_call_id)
    if not msg then
        return
    end
    for key, value in pairs(vim.tbl_deep_extend("force", {}, msg, update)) do
        msg[key] = value
    end
    self.dirty = true
end

--- Apply updates to tool calls, main or subagent.
--- @param updates agentic.ui.MessageWriter.ToolCallBase[]
function ChatHistory:update_tool_calls(updates)
    for _, update in ipairs(updates) do
        self:update_tool_call(
            update.tool_call_id,
            ChatHistory.tool_call_record(update)
        )
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
    "read_range",
    "failure_reason",
    "description",
    "shell",
    "exits_plan",
    "file_created",
    "hunk_ranges",
    "skill_path",
    "subagent",
    "causes",
    "rejection",
    "ended_as",
    "background_job_id",
    "output_file",
    "output_ended",
    "is_compaction",
    "stopped_job_id",
    "stopped_job_output_file",
    "stopped_by",
    "provider_note",
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

--- The label of a session: its SubAgent block's label, else `main agent`.
--- The block is the `tool_call` whose `tool_call_id` is the session id.
--- @param session_id string|nil
--- @return string
function ChatHistory:session_label(session_id)
    local block = session_id and self:tool_call(session_id)
    return block and block.subagent and block.subagent.label or "main agent"
end

--- One sequence entry per main-chat message but fork links, in order. Tool
--- calls, prompts and session message rows are keyed and start a tail. A
--- synthetic prompt is keyed but does not start one. Other rows have no key.
---
--- A fork link gives no entry: no replay holds it, and an unkeyed entry
--- after the file's last keyed one would hide where the file ends.
--- @return agentic.utils.SequenceTail.Entry[]
function ChatHistory:sequence_entries()
    local entries = {} --- @type agentic.utils.SequenceTail.Entry[]
    for _, msg in ipairs(self.messages) do
        if msg.type == "tool_call" then
            -- `tostring`: the field is optional, and a row without an id
            -- matches nothing.
            table.insert(
                entries,
                { key = "tool:" .. tostring(msg.tool_call_id), starts = true }
            )
        elseif msg.type == "user" then
            table.insert(
                entries,
                { key = "prompt:" .. msg.text, starts = not msg.synthetic }
            )
        elseif msg.type == "session_message" then
            table.insert(
                entries,
                { key = "message:" .. msg.message_id, starts = true }
            )
        elseif msg.type ~= "fork_link" then
            table.insert(entries, { starts = false })
        end
    end
    return entries
end

--- Prepend the main chat's messages to `prompt` as a text transcript (ACP
--- content). Synthetic prompts are skipped.
--- @param prompt agentic.acp.Content[] The prompt array to prepend to
function ChatHistory:prepend_history_messages(prompt)
    for _, msg in ipairs(self.messages) do
        if msg.type == "user" and not msg.synthetic then
            local author = msg.author
                and (msg.author:sub(1, 1):upper() .. msg.author:sub(2))
            table.insert(
                prompt,
                { type = "text", text = (author or "User") .. ": " .. msg.text }
            )
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
            local range = msg.read_range
            local tool_text = string.format(
                "Tool call (%s): %s%s",
                msg.kind or "unknown",
                msg.argument,
                range and " " .. CanonicalToolCall.format_read_range(range)
                    or ""
            )
            local rejection_line = CanonicalToolCall.rejection_line(msg)
            if rejection_line then
                tool_text = tool_text .. "\nResult: " .. rejection_line
            elseif msg.body and #msg.body > 0 then
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
                    not peer and msg.sender_name or self:session_label(peer),
                    msg.text
                ),
            })
        end
    end
end

--- Write the history to the file of its chat id in the project folder of
--- `cwd`, synchronously, and record `cwd` and the ACP session id in it.
--- Clears `dirty` on success.
--- @param cwd string Working directory of the session
--- @return string|nil err Why nothing was written
function ChatHistory:save(cwd)
    local path = ChatHistory.get_file_path(self.chat_id, cwd)
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

--- Remove from each `side_records` message of `messages` the records of a
--- kind `SideRecords` does not write, such as one a newer build stored.
--- @param messages agentic.ui.ChatHistory.Message[] updated in place
--- @return string[] kinds the removed kinds, sorted
local function remove_unknown_side_records(messages)
    --- @type table<string, true>
    local unknown = {}
    for _, msg in ipairs(messages) do
        if msg.type == "side_records" then
            msg.records = vim.tbl_filter(function(side)
                if SideRecords.KINDS[side.kind] then
                    return true
                end
                unknown[tostring(side.kind)] = true
                return false
            end, msg.records)
        end
    end
    local kinds = vim.tbl_keys(unknown)
    table.sort(kinds)
    return kinds
end

--- A history holding the contents of a session file. Side records of a kind
--- this build does not write are dropped with a notification.
--- @param data agentic.ui.ChatHistory.StorageData
--- @param chat_id string The file's name, which the file does not hold
--- @return agentic.ui.ChatHistory history
function ChatHistory.from_data(data, chat_id)
    -- Assigned directly: a loaded history mirrors the file, so it is not
    -- dirty.
    local instance = ChatHistory:new(chat_id)
    instance.session_id = data.session_id
    instance.timestamp = data.timestamp
    -- `subagent_event` rows, from files written before session messages kept
    -- their text, are dropped.
    local function current(msg)
        return msg.type ~= "subagent_event"
    end
    instance.messages = vim.tbl_filter(current, data.messages)
    local unknown_kinds = remove_unknown_side_records(instance.messages)
    if #unknown_kinds > 0 then
        Logger.notify(
            "Agentic: skipped side records of unknown kind: "
                .. table.concat(unknown_kinds, ", ")
        )
    end
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
    return Config.sessions.storage_path
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
                local messages = parsed.messages or {}
                for i = ChatHistory.render_start(messages), #messages do
                    local msg = messages[i]
                    if msg.type == "user" and not msg.synthetic then
                        prompt_count = prompt_count + 1
                    end
                end
                local chat_id = filename:gsub("%.json$", "")
                table.insert(sessions, {
                    chat_id = chat_id,
                    session_id = parsed.session_id or chat_id,
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

--- One row per chat id. An id in several project folders keeps the row of
--- its newest file by mtime.
--- @param sessions agentic.ui.ChatHistory.SessionMeta[]
--- @return agentic.ui.ChatHistory.SessionMeta[] distinct In the order of `sessions`
local function newest_per_id(sessions)
    local count = {} --- @type table<string, integer>
    for _, s in ipairs(sessions) do
        count[s.chat_id] = (count[s.chat_id] or 0) + 1
    end
    local newest = {} --- @type table<string, string>
    local distinct = {} --- @type agentic.ui.ChatHistory.SessionMeta[]
    for _, s in ipairs(sessions) do
        local id = s.chat_id
        if count[id] == 1 then
            table.insert(distinct, s)
        else
            newest[id] = newest[id] or ChatHistory.find_files(id)[1]
            if s.file_path == newest[id] then
                table.insert(distinct, s)
            end
        end
    end
    return distinct
end

--- The sessions `query` matches: those whose chat id or ACP session id
--- starts with it, else those whose title equals it (case-insensitive). In
--- the order of `sessions`.
--- @param sessions agentic.ui.ChatHistory.SessionMeta[]
--- @param query string
--- @return agentic.ui.ChatHistory.SessionMeta[]
function ChatHistory.match_sessions(sessions, query)
    local by_id = vim.tbl_filter(function(s)
        return vim.startswith(s.chat_id, query)
            or vim.startswith(s.session_id, query)
    end, sessions)
    if #by_id > 0 then
        return by_id
    end
    local query_lower = query:lower()
    return vim.tbl_filter(function(s)
        return type(s.title) == "string" and s.title:lower() == query_lower
    end, sessions)
end

--- List sessions from ALL projects, sorted by last activity descending. A chat
--- id saved in several projects gives one row, from its newest file.
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
    all_sessions = newest_per_id(all_sessions)

    table.sort(all_sessions, function(a, b)
        return (a.last_activity or a.timestamp)
            > (b.last_activity or b.timestamp)
    end)

    callback(all_sessions)
end

return ChatHistory

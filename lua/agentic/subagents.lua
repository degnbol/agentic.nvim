local AgentConfigOptions = require("agentic.acp.agent_config_options")
local AgentView = require("agentic.ui.agent_view")
local BufHelpers = require("agentic.utils.buf_helpers")
local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
local Config = require("agentic.config")
local Json = require("agentic.utils.json")
local Logger = require("agentic.utils.logger")
local SessionResume = require("agentic.session_resume")
local SubagentInput = require("agentic.ui.subagent_input")
local WidgetLayout = require("agentic.ui.widget_layout")

--- A subagent, one child session of the conversation. Its label, prompt, type
--- and mode are on its block in its parent's view.
--- @class agentic.Subagents.Agent
--- @field transcript? agentic.ui.SubagentTranscript Nil once the user wiped it
--- @field open boolean Working, as far as this instance knows
--- @field record_read boolean The provider's record of the spawn has been read
--- @field parent_session_id? string The session that announced it. Nil for one read from a session file
--- @field title? string The provider's title for it, the label's fallback
--- @field description? string The provider's description of its task, the label
--- @field config_options? agentic.acp.AgentConfigOptions Its own, once the provider reports any
--- @field model_announced? boolean Its transcript has had a `Loaded` line

--- What a session gives its subagents.
--- @class agentic.Subagents.Host
--- @field agent fun(): agentic.acp.ACPClient The session's current client
--- @field history fun(): agentic.ui.ChatHistory The session's current history
--- @field session_id fun(): string|nil
--- @field config_options fun(): agentic.acp.AgentConfigOptions The main agent's current config options
--- @field history_changed fun() The current history was mutated
--- @field sync_modified fun() Set the `modified` flags of the chat and the transcripts from the current history and the running work
--- @field setup_buf fun(bufnr: integer, writer: agentic.ui.MessageWriter|nil) Bind the session's own maps; with `writer`, a chat-style buffer, also the session's 'tagfunc'
--- @field write_chat_row fun(row: agentic.ui.ChatHistory.SessionMessage) Write a row to the main chat and add it to the history
--- @field write fun() Write the session file (`:w`)
--- @field end_side_records fun(child_id: string) Apply the tool call fields a subagent's side records give, and drop those held for calls it never reported
--- @field relay fun(instruction: string, on_returned: agentic.OnReturned|nil): string|nil Send a prompt on the user's behalf; when held, returns the cause, as a phrase
--- @field return_prompt fun(text: string, bufnr: integer|nil, reason: agentic.ReturnReason) Give a returned message back, at the top of `bufnr` or of the session's input

--- The subagents of one session: their blocks in the chat, transcripts,
--- message inputs, session messages, and which subagent owns each tool call.
--- @class agentic.Subagents
--- @field _widget agentic.ui.ChatWidget
--- @field _main_view agentic.ui.AgentView
--- @field _host agentic.Subagents.Host
--- @field _agents table<string, agentic.Subagents.Agent> By child session id
--- @field _inputs table<string, agentic.ui.SubagentInput> Message inputs of background subagents by child session id
--- @field _agent_by_task table<string, string> Task id -> child session id of the subagent it gave work
--- @field _tool_call_owner table<string, string> toolCallId -> child session id of the subagent whose transcript holds the call
--- @field _seen_messages table<string, true> `<session id>:<messageId>` of each session message view and received message handled
--- @field _message_infos table<string, agentic.SessionMessageInfo> Kind and summary of each session message by message id, decided at its first view
--- @field _delegated table<string, true> Session ids of the subagents a delegation has reached
local Subagents = {}
Subagents.__index = Subagents

--- @param widget agentic.ui.ChatWidget
--- @param main_view agentic.ui.AgentView View of the main chat, which holds the main agent's subagent blocks
--- @param host agentic.Subagents.Host
--- @return agentic.Subagents
function Subagents:new(widget, main_view, host)
    return setmetatable({
        _widget = widget,
        _main_view = main_view,
        _host = host,
        _agents = {},
        _inputs = {},
        _agent_by_task = {},
        _tool_call_owner = {},
        _seen_messages = {},
        _message_infos = {},
        _delegated = {},
    }, self)
end

--- Whether a subagent works.
--- @return boolean
function Subagents:any_open()
    for _, agent in pairs(self._agents) do
        if agent.open then
            return true
        end
    end
    return false
end

--- Set the `modified` flag of every loaded transcript.
--- @param unsaved boolean
function Subagents:set_modified(unsaved)
    for _, agent in pairs(self._agents) do
        if agent.transcript then
            agent.transcript:set_modified(unsaved)
        end
    end
end

--- Mark a subagent working or not, and with it the chat's `modified` flag and
--- its transcript's header.
--- @param agent agentic.Subagents.Agent
--- @param open boolean
function Subagents:_set_open(agent, open)
    agent.open = open
    self._host.sync_modified()
    -- Nil once the user wiped it.
    if agent.transcript then
        agent.transcript:set_running(open)
    end
end

--- The block of a subagent in its parent's view, as the history holds it.
--- @param child_id string
--- @return agentic.ui.ChatHistory.ToolCall|nil
function Subagents:_agent_block(child_id)
    return self._host.history():tool_call(child_id)
end

--- The key of a subagent's stored messages: its task id, else, while that
--- is unknown, the child id.
--- @param child_id string
--- @return string agent_key
function Subagents:agent_key(child_id)
    return vim.tbl_get(self._host.history().subagents, child_id, "task_id")
        or child_id
end

--- A new transcript for a subagent, tied to the session's buffers and
--- history.
--- @param child_id string
--- @param subagent agentic.ui.MessageWriter.SubagentInfo|nil
--- @return agentic.ui.SubagentTranscript
function Subagents:_new_transcript(child_id, subagent)
    local SubagentTranscript = require("agentic.ui.subagent_transcript")
    --- @type agentic.ui.SubagentTranscript
    local transcript
    transcript = SubagentTranscript:new(child_id, subagent, self._widget, {
        setup_buf = function(bufnr, writer)
            self._host.setup_buf(bufnr, writer)
            self:_bind_agent_keymaps(child_id, bufnr)
        end,
        on_reload = function()
            self:_replay_transcript(child_id)
        end,
        on_write = function()
            self._host.write()
        end,
        on_wipeout = function()
            local agent = self._agents[child_id]
            if agent and agent.transcript == transcript then
                agent.transcript = nil
            end
        end,
    })
    return transcript
end

--- Render a subagent's transcript again from the history: its heading, then
--- its messages, and its header, which an unload by `:bd` clears.
--- @param child_id string
function Subagents:_replay_transcript(child_id)
    local agent = self._agents[child_id]
    local transcript = agent.transcript --[[@as agentic.ui.SubagentTranscript]]
    local block = self:_agent_block(child_id)
    local rows =
        self._host.history():messages_for_agent(self:agent_key(child_id))
    transcript:restart(block and block.subagent)
    SessionResume.replay_messages(transcript.view.writer, rows, function(id)
        return self:buffer_name(id)
    end)
    transcript.view.status_indicator:reposition()

    transcript:set_header(block and block.subagent)
    transcript:set_running(agent.open)
    --- @type string|nil
    local end_state = nil
    if not agent.open then
        for i = #rows, 1, -1 do
            if rows[i].type == "subagent_end" then
                end_state = SessionResume.end_state(rows[i])
                break
            end
        end
    end
    transcript:set_context(end_state)
    self._host.sync_modified()
end

--- A subagent's transcript, loaded and rendered: created and replayed again if
--- the user wiped it, loaded if `:bd` unloaded it.
--- @param child_id string
--- @return agentic.ui.SubagentTranscript
function Subagents:transcript(child_id)
    local agent = self._agents[child_id]
    local transcript = agent.transcript
    if not transcript then
        local block = self:_agent_block(child_id)
        transcript = self:_new_transcript(child_id, block and block.subagent)
        agent.transcript = transcript
        self:_replay_transcript(child_id)
        if agent.open then
            transcript.view.status_indicator:start("generating")
        end
    elseif not transcript:is_loaded() then
        -- Its `BufReadCmd` renders it now, before a caller writes to it,
        -- rather than as a side effect of that write.
        vim.fn.bufload(transcript.bufnr)
    end
    return transcript
end

--- The subagent whose stored messages are keyed `agent_key`: the one the key
--- routes to as a task id, else the one keyed by its child id.
--- @param agent_key string
--- @return string|nil child_id Nil when no subagent has them
function Subagents:_child_of_key(agent_key)
    local child_id = self._agent_by_task[agent_key] or agent_key
    return self._agents[child_id] and child_id or nil
end

--- The transcript of the subagent whose stored messages are keyed
--- `agent_key`, loaded and rendered. Nil when no subagent has them.
--- @param agent_key string
--- @return agentic.ui.SubagentTranscript|nil
function Subagents:transcript_of_key(agent_key)
    local child_id = self:_child_of_key(agent_key)
    return child_id and self:transcript(child_id)
end

--- The transcript of the subagent whose stored messages are keyed
--- `agent_key`, when it exists and its buffer is loaded. Makes, loads and
--- renders nothing.
--- @param agent_key string
--- @return agentic.ui.SubagentTranscript|nil
function Subagents:loaded_transcript_of_key(agent_key)
    local child_id = self:_child_of_key(agent_key)
    local transcript = child_id and self._agents[child_id].transcript
    if transcript and transcript:is_loaded() then
        return transcript
    end
    return nil
end

--- The writer of the buffer that renders a tool call record: the chat's, or
--- its subagent's transcript's.
--- @param record agentic.ui.ChatHistory.ToolCall
--- @param make boolean Make, load and render the transcript when needed
--- @return agentic.ui.MessageWriter|nil writer Nil when the transcript does not exist, or with `make` false, is not loaded
function Subagents:record_writer(record, make)
    local agent_key = record.agent_key
    if not agent_key then
        return self._main_view.writer
    end
    local transcript
    if make then
        transcript = self:transcript_of_key(agent_key)
    else
        transcript = self:loaded_transcript_of_key(agent_key)
    end
    return transcript and transcript.view.writer
end

--- Give each subagent the history holds a transcript, unloaded, so it renders
--- on its first load, and point its block at the transcript's name.
function Subagents:add_history_transcripts()
    for child_id, record in pairs(self._host.history().subagents) do
        if record.task_id then
            self._agent_by_task[record.task_id] = child_id
        end
        local agent = self._agents[child_id]
        if not (agent and agent.transcript) then
            local block = self:_agent_block(child_id)
            local transcript =
                self:_new_transcript(child_id, block and block.subagent)
            transcript:unload()
            self._agents[child_id] = {
                transcript = transcript,
                open = false,
                record_read = true,
            }
            if block then
                block.argument = vim.api.nvim_buf_get_name(transcript.bufnr)
            end
        end
    end
end

--- The subagent whose transcript is `bufnr`.
--- @param bufnr integer
--- @return string|nil child_id
function Subagents:child_of_buf(bufnr)
    for child_id, agent in pairs(self._agents) do
        if agent.transcript and agent.transcript.bufnr == bufnr then
            return child_id
        end
    end
    return nil
end

--- A subagent's message input.
--- @param child_id string
--- @return agentic.ui.SubagentInput|nil
function Subagents:input_of(child_id)
    return self._inputs[child_id]
end

--- The subagent an update belongs to: the one whose child session sent it,
--- else the one its task id names. Nil for the main agent's.
--- @param source_session_id string|nil
--- @param task_id string|nil Task id the update is tagged with, nil when untagged
--- @return string|nil child_id
function Subagents:agent_of(source_session_id, task_id)
    if source_session_id and self._agents[source_session_id] then
        return source_session_id
    end
    return task_id and self._agent_by_task[task_id]
end

--- The subagent that a tool call or its permission request belongs to: the
--- call's recorded owner, else `agent_of`. Records it as the call's owner.
--- Nil for the main agent's.
--- @param tool_call_id string
--- @param source_session_id string|nil
--- @param task_id string|nil
--- @return string|nil child_id
function Subagents:claim_tool_call(tool_call_id, source_session_id, task_id)
    local child_id = self._tool_call_owner[tool_call_id]
        or self:agent_of(source_session_id, task_id)
    if child_id then
        self._tool_call_owner[tool_call_id] = child_id
    end
    return child_id
end

--- The subagent recorded as a tool call's owner.
--- @param tool_call_id string
--- @return string|nil child_id
function Subagents:owner_of(tool_call_id)
    return self._tool_call_owner[tool_call_id]
end

--- Map a task id to its subagent, and record it as the subagent's while none
--- is known. A resumed subagent's updates carry the id of what resumed it, and
--- its recorded task id stays the earlier one.
--- @param child_id string
--- @param task_id string|nil Nil when untagged
function Subagents:note_task(child_id, task_id)
    if not task_id or self._agent_by_task[task_id] then
        return
    end
    self._agent_by_task[task_id] = child_id
    local history = self._host.history()
    if not vim.tbl_get(history.subagents, child_id, "task_id") then
        history:set_subagent_task(child_id, task_id)
    end
end

--- The subagent a message or thought chunk belongs to, with what the chunk
--- tells about it noted, and its transcript to write to. Nil for the main
--- agent's.
--- @param update agentic.acp.SessionUpdateMessage
--- @param source_session_id string|nil
--- @return string|nil child_id
--- @return agentic.ui.SubagentTranscript|nil transcript
function Subagents:agent_of_chunk(update, source_session_id)
    local task_id = self._host.agent():subagent_task_id(update)
    local child_id = self:agent_of(source_session_id, task_id)
    if not child_id then
        return nil, nil
    end
    -- The provider's record of the spawn is read at the agent's other events,
    -- not per chunk: a lookup that keeps missing can be costly.
    self:note_task(child_id, task_id)
    return child_id, self:transcript(child_id)
end

--- Read the provider's record of a subagent's spawn, once, and apply it: the task id to the lookup and the history, the
--- type and confirmed mode to the block and the transcript header. Does
--- nothing until the record exists.
--- @param child_id string
function Subagents:read_record(child_id)
    local agent = self._agents[child_id]
    local session_id = self._host.session_id()
    if not agent or agent.record_read or not session_id then
        return
    end
    local record = self._host.agent():subagent_record(session_id, child_id)
    if not record then
        return
    end
    agent.record_read = true
    self._agent_by_task[record.task_id] = child_id
    self._host.history():set_subagent_task(child_id, record.task_id)

    local block = self:_agent_block(child_id)
    if not (block and block.subagent) then
        return
    end
    local subagent = vim.tbl_extend("force", block.subagent, {
        agent_type = record.agent_type,
        mode = record.background and "background" or "blocking",
        confirmed = true,
    }) --[[@as agentic.ui.MessageWriter.SubagentInfo]]
    self:_set_agent_info(child_id, subagent)
    if agent.transcript then
        agent.transcript:set_header(subagent)
    end

    if record.background then
        self:_open_input(child_id)
        return
    end
    -- The agent blocks its spawner, so the main agent cannot reach it apart
    -- from its own turn.
    if self._inputs[child_id] then
        self:_destroy_input(child_id)
    end
end

--- `read_record` for every subagent.
function Subagents:read_records()
    for child_id in pairs(self._agents) do
        self:read_record(child_id)
    end
end

--- Give a subagent's block new identity and mode, in the history and in its
--- parent's view. A parent transcript that is not loaded renders it from the
--- history when it loads, and a wiped one is not made again. No-op for a
--- subagent without a block.
--- @param child_id string
--- @param subagent agentic.ui.MessageWriter.SubagentInfo
function Subagents:_set_agent_info(child_id, subagent)
    local block = self:_agent_block(child_id)
    if not block then
        return
    end
    AgentView.merge_tool_call_fields(
        self:record_writer(block, false),
        self._host.history(),
        { tool_call_id = child_id, subagent = subagent }
    )
    self._host.history_changed()
end

--- Start a subagent the provider announced: its block in its parent's view
--- (the main chat for a child of the main agent), `completed` from the start
--- since it records the launch only, then its transcript, closed until the
--- agent reports work.
--- @param child_id string
--- @param label string
--- @param parent_session_id string The session that announced it
--- @param replayed boolean From a session/load replay: the transcript starts unloaded, so its first load renders the session file's rows
function Subagents:_open_agent(child_id, label, parent_session_id, replayed)
    local history = self._host.history()
    if not history.subagents[child_id] then
        history:set_subagent_task(child_id, nil)
    end
    local task_id = history.subagents[child_id].task_id
    if task_id then
        self._agent_by_task[task_id] = child_id
    end

    --- @type agentic.ui.MessageWriter.SubagentInfo
    local subagent = {
        label = label,
        mode = self._host.agent():subagent_predicted_mode(),
        confirmed = false,
    }
    local transcript = self:_new_transcript(child_id, subagent)
    self._agents[child_id] = {
        transcript = transcript,
        open = false,
        record_read = false,
        parent_session_id = parent_session_id,
    }

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local block = {
        tool_call_id = child_id,
        kind = "SubAgent",
        status = "completed",
        argument = vim.api.nvim_buf_get_name(transcript.bufnr),
        subagent = subagent,
    }
    self:_view_of(parent_session_id):write_tool_call(
        history,
        block,
        nil,
        self._agents[parent_session_id] and self:agent_key(parent_session_id)
            or nil
    )
    self._host.history_changed()

    if replayed then
        transcript:unload()
    end
    self:read_record(child_id)
end

--- Start a closed subagent's work, first or again: its model when known
--- (`_announce_model`), its working indicator, a header without the last
--- run's end, and a background one's message input.
--- @param child_id string
function Subagents:_start_agent(child_id)
    local agent = self._agents[child_id]
    self:_set_open(agent, true)
    local transcript = self:transcript(child_id)
    self:_announce_model(agent)
    transcript.view.status_indicator:start("generating")
    transcript:set_context(nil)
    self:_open_input(child_id)
end

--- The word for how a subagent's work ended. An `idle` without a stop reason
--- ended for a reason the provider does not give: `ended`.
--- @param state agentic.acp.SubagentWorkState
--- @return string
local function end_word(state)
    if state.state ~= "idle" then
        return state.state
    end
    local reason = Json.present(state.stopReason)
    if not reason then
        return "ended"
    end
    return CanonicalToolCall.stop_reason_word(reason)
end

--- End a subagent's work as `state` reports it: stop its indicator, end its
--- unfinished calls `failed` with the end's word unless it ended its turn or
--- the end is `unknown`, write an end row and show the end in the header. On
--- an ended agent, only a report with error text writes a row, holding that
--- text: the provider can report a failure a second time to add it.
--- @param child_id string
--- @param state agentic.acp.SubagentWorkState
function Subagents:end_agent(child_id, state)
    local agent = self._agents[child_id]
    local word = end_word(state)
    --- @type agentic.ui.ChatHistory.SubagentEnd
    local row = {
        type = "subagent_end",
        state = word,
        error = Json.present(vim.tbl_get(state, "error", "message")),
    }
    self._host.end_side_records(child_id)
    if not agent.open then
        if row.error then
            self:_write_row(child_id, row)
        end
        return
    end

    self:_set_open(agent, false)
    local transcript = self:transcript(child_id)
    transcript.view.status_indicator:stop()
    -- An `unknown` end does not say the calls stopped.
    if word ~= "completed" and word ~= "unknown" then
        self._host.history():update_tool_calls(
            transcript.view.writer:stamp_open_calls(word, "failed")
        )
    end
    self:_write_row(child_id, row)
    transcript:set_context(word)
end

--- End every working subagent as `state`.
--- @param state agentic.acp.SubagentWorkState
function Subagents:close_all(state)
    for child_id, agent in pairs(self._agents) do
        if agent.open then
            self:end_agent(child_id, state)
        end
    end
end

--- The view of a session's buffer: a subagent's transcript, loaded and
--- rendered, else the chat. Get it before adding what it writes to the
--- history: loading a transcript replays the history.
--- @param session_id string
--- @return agentic.ui.AgentView
function Subagents:_view_of(session_id)
    if not self._agents[session_id] then
        return self._main_view
    end
    return self:transcript(session_id).view
end

--- Write a session message or subagent end row to a subagent's transcript and
--- add it to the history. While the subagent works, the row leaves its turn
--- open; otherwise the row ends the turn.
--- @param child_id string
--- @param row agentic.ui.ChatHistory.SessionMessage|agentic.ui.ChatHistory.SubagentEnd Gets `agent_key` set
function Subagents:_write_row(child_id, row)
    local view = self:_view_of(child_id)
    row.agent_key = self:agent_key(child_id)
    SessionResume.write_row(
        view.writer,
        row,
        self._agents[child_id].open,
        function(id)
            return self:buffer_name(id)
        end
    )
    view.status_indicator:reposition()
    self._host.history():add_message(row)
    self._host.history_changed()
end

--- Name of a session's buffer: a subagent's transcript, nil while it has
--- none, else the chat. Any other id counts as the root, since a re-create from
--- history leaves the old root id in the history's rows.
--- @param session_id string
--- @return string|nil
function Subagents:buffer_name(session_id)
    local agent = self._agents[session_id]
    if not agent then
        return vim.api.nvim_buf_get_name(self._widget.buf_nrs.agent)
    end
    return agent.transcript
        and vim.api.nvim_buf_get_name(agent.transcript.bufnr)
end

--- Apply a `subagent_update`: announce an unknown child, relabel a known one,
--- then start or end its work. A label is the description, else the title,
--- else the child session id. Any other state, custom (`_`-prefixed) or
--- from a later ACP version, neither starts nor ends it.
--- @param update agentic.acp.SubagentUpdate
--- @param source_session_id string The session it arrived on, the child's parent
--- @param replayed boolean From a session/load replay: a transcript it opens starts unloaded
function Subagents:update(update, source_session_id, replayed)
    local child_id = update.sessionId
    local agent = self._agents[child_id]
    local title = agent and agent.title
    local description = agent and agent.description
    if update.title ~= nil then
        title = Json.present(update.title)
    end
    if update.description ~= nil then
        description = Json.present(update.description)
    end
    local label = description or title or child_id

    if not agent then
        self:_open_agent(child_id, label, source_session_id, replayed)
        agent = self._agents[child_id]
    elseif update.title ~= nil or update.description ~= nil then
        local block = self:_agent_block(child_id)
        if block and block.subagent then
            local subagent =
                vim.tbl_extend("force", block.subagent, { label = label }) --[[@as agentic.ui.MessageWriter.SubagentInfo]]
            self:_set_agent_info(child_id, subagent)
            if agent.transcript then
                agent.transcript:set_header(subagent)
            end
        end
    end
    agent.title, agent.description = title, description
    -- An agent read from a session file has none; the parent never changes.
    agent.parent_session_id = agent.parent_session_id or source_session_id

    local state = Json.present(update.state)
    if not state then
        return
    end
    if state.state == "running" or state.state == "requires_action" then
        if not agent.open then
            self:_start_agent(child_id)
        end
    elseif state.state == "idle" or state.state == "unknown" then
        self:end_agent(child_id, state)
    else
        Logger.debug("Subagent state left alone: " .. state.state)
    end
end

--- Decide the kind and summary of a session message at its first view and
--- record the delegation it makes; later views reuse them. Relies on the
--- bridge announcing an agent before any of its views, which sets the
--- `parent_session_id` the result rule reads.
---
--- `result` when the sender is a child of the recipient. A message to a
--- subagent delegates to it: `task` when it is the first delegation to the
--- agent or the agent's last row in the history is the end of a run, else
--- `message`. Anything else is a `message`. The first delegation is the
--- agent's launch prompt, summarised by the agent's description.
--- @param message_id string
--- @param sender string|nil
--- @param recipient string|nil
--- @return agentic.SessionMessageInfo
function Subagents:_message_info(message_id, sender, recipient)
    local cached = self._message_infos[message_id]
    if cached then
        return cached
    end
    --- @type agentic.SessionMessageInfo
    local info = { kind = "message" }
    local from = sender and self._agents[sender]
    local to = recipient and self._agents[recipient]
    if from and recipient and from.parent_session_id == recipient then
        info.kind = "result"
    elseif recipient and to then
        if not self._delegated[recipient] then
            info = { kind = "task", summary = to.description }
        else
            local rows = self._host
                .history()
                :messages_for_agent(self:agent_key(recipient))
            if vim.tbl_get(rows, #rows, "type") == "subagent_end" then
                info.kind = "task"
            end
        end
        self._delegated[recipient] = true
    end
    self._message_infos[message_id] = info
    return info
end

--- Reuse the kinds and summaries of the session messages `history` holds,
--- and count each agent they delegate to as reached.
--- @param history agentic.ui.ChatHistory
function Subagents:seed_message_infos(history)
    for _, list in ipairs({ history.messages, history.subagent_messages }) do
        for _, msg in ipairs(list) do
            if msg.type == "session_message" then
                self._message_infos[msg.message_id] =
                    { kind = msg.kind, summary = msg.summary }
                if msg.kind ~= "result" and msg.recipient_session_id then
                    self._delegated[msg.recipient_session_id] = true
                end
            end
        end
    end
end

--- Show one view of a session message as a row in the buffer of the session
--- it arrived on, tagged with the message id. A received view on a subagent
--- that is not a result is a delegation, whose id routes to the subagent.
--- @param update agentic.acp.SessionMessage
--- @param source_session_id string The session it arrived on
function Subagents:message(update, source_session_id)
    local on_root = source_session_id == self._host.session_id()
    if not (on_root or self._agents[source_session_id]) then
        return
    end
    local key = source_session_id .. ":" .. update.messageId
    if self._seen_messages[key] then
        Logger.debug("Session message shown already: " .. key)
        return
    end
    self._seen_messages[key] = true

    local texts = {}
    for _, block in ipairs(Json.present(update.content) or {}) do
        if block.type == "text" then
            table.insert(texts, block.text)
        end
    end

    local sender = Json.present(update.senderSessionId)
    local recipient = Json.present(update.recipientSessionId)
    local received = recipient == source_session_id
    local info = self:_message_info(update.messageId, sender, recipient)
    if received and not on_root and info.kind ~= "result" then
        self:note_task(source_session_id, update.messageId)
    end

    --- @type agentic.ui.ChatHistory.SessionMessage
    local row = {
        type = "session_message",
        message_id = update.messageId,
        kind = info.kind,
        summary = info.summary,
        view = received and "received" or "sent",
        sender_session_id = sender,
        recipient_session_id = recipient,
        text = table.concat(texts),
    }
    if on_root then
        self._host.write_chat_row(row)
    else
        self:_write_row(source_session_id, row)
    end
end

--- Show a message the session received outside the ACP feed as a received
--- row in the chat, once per message id. The row names its sender's
--- transcript when the sender is one of the subagents, else the sender's name.
--- The row records no recipient.
--- @param message agentic.acp.ReceivedMessage
function Subagents:write_received_message(message)
    local key = self._host.session_id() .. ":" .. message.message_id
    if self._seen_messages[key] then
        Logger.debug("Received message shown already: " .. key)
        return
    end
    self._seen_messages[key] = true

    local sender = message.sender_id
        and self._host
            .agent()
            :sender_session(message.sender_id, vim.tbl_keys(self._agents))
    --- @type agentic.ui.ChatHistory.SessionMessage
    local row = {
        type = "session_message",
        message_id = message.message_id,
        kind = "message",
        view = "received",
        sender_session_id = sender,
        sender_name = message.sender_name,
        text = message.text,
    }
    self._host.write_chat_row(row)
end

--- Write a `Loaded` line for a subagent's model in its transcript, once per
--- subagent: when it works, its transcript is loaded and its config options
--- name a model. Later models get none.
--- @param agent agentic.Subagents.Agent
function Subagents:_announce_model(agent)
    local options = agent.config_options
    local model_id = options and options:current_model_id()
    local transcript = agent.transcript
    if
        not model_id
        or agent.model_announced
        or not agent.open
        or not (transcript and transcript:is_loaded())
    then
        return
    end
    --- @cast options agentic.acp.AgentConfigOptions
    agent.model_announced = true
    transcript.view:announce_model(
        options,
        model_id,
        self._host.config_options()
    )
end

--- Keep a subagent's own config options, read only: no selector reaches
--- them, and announce its model (`_announce_model`). Those of an unknown
--- child are dropped with a debug log.
--- @param child_id string
--- @param options agentic.acp.ConfigOption[]
function Subagents:set_config_options(child_id, options)
    local agent = self._agents[child_id]
    if not agent then
        Logger.debug(
            "Config options of an unknown child session dropped: " .. child_id
        )
        return
    end
    local config_options = agent.config_options
        or AgentConfigOptions:new(
            function() end,
            function() end,
            function() end,
            function()
                return false
            end
        )
    agent.config_options = config_options
    config_options:set_options(options)
    self:_announce_model(agent)
end

--- Mark every subagent ended, stop its indicator and wipe the message
--- inputs. Blocks and transcripts stay.
function Subagents:forget()
    for _, agent in pairs(self._agents) do
        self:_set_open(agent, false)
        if agent.transcript then
            agent.transcript.view.status_indicator:stop()
        end
    end
    self:_destroy_inputs()
end

--- Forget every subagent and wipe the transcripts and inputs.
function Subagents:reset()
    self:_destroy_inputs()
    for _, agent in pairs(self._agents) do
        if agent.transcript then
            agent.transcript:destroy()
        end
    end
    self._agents = {}
    self._host.sync_modified()
    self._agent_by_task = {}
    self._tool_call_owner = {}
    self._seen_messages = {}
    self._message_infos = {}
    self._delegated = {}
end

--- Wipe an agent's message input. Unsent text in it is given back in a
--- notification.
--- @param child_id string
function Subagents:_destroy_input(child_id)
    local input = self._inputs[child_id]
    self._inputs[child_id] = nil
    local text = input:text()
    input:destroy()
    if text:find("%S") then
        Logger.notify(
            string.format(
                "Unsent message to subagent %s, discarded:\n%s",
                self:_agent_label(child_id),
                text
            ),
            vim.log.levels.WARN
        )
    end
end

--- Wipe every message input.
function Subagents:_destroy_inputs()
    for child_id in pairs(self._inputs) do
        self:_destroy_input(child_id)
    end
end

--- Give a running subagent known to run in the background a message input,
--- shown in no window. No-op when it has one, for an agent that has ended or
--- was read from a session file, and for a provider whose main agent cannot message one.
--- @param child_id string
function Subagents:_open_input(child_id)
    local agent = self._agents[child_id]
    local block = self:_agent_block(child_id)
    local subagent = block and block.subagent
    if
        self._inputs[child_id]
        or not (agent and agent.open)
        or not (subagent and subagent.mode == "background")
        or not self._host
            .agent()
            :subagent_message_instruction(child_id, subagent.label, "")
    then
        return
    end

    local transcript = self:transcript(child_id)
    --- @type agentic.ui.SubagentInput
    local input
    input = SubagentInput:new(
        vim.fn.fnamemodify(vim.api.nvim_buf_get_name(transcript.bufnr), ":t"),
        subagent.label,
        self._widget,
        {
            on_submit = function(text)
                return self:_relay_to_agent(child_id, text)
            end,
            setup_buf = function(bufnr)
                self._host.setup_buf(bufnr, nil)
                BufHelpers.multi_keymap_set(
                    Config.keymaps.widget.stop_generation,
                    bufnr,
                    function()
                        self:stop(child_id)
                    end,
                    { desc = "Agentic: Stop subagent" }
                )
            end,
            on_wipeout = function()
                if self._inputs[child_id] == input then
                    self._inputs[child_id] = nil
                end
            end,
        }
    )
    self._inputs[child_id] = input
end

--- The window to type into for a subagent: the window in the current
--- tabpage showing its message input, else one opened below the current
--- window. For an agent without a message input, the session's input.
--- @param child_id string
--- @return integer|nil winid Nil when the session's input panel fails to open
function Subagents:_agent_input_win(child_id)
    local input = self._inputs[child_id]
    if input then
        return WidgetLayout.input_win(input.bufnr)
    end
    return self._widget:input_win()
end

--- Bind the keys of a subagent's transcript that act on the agent.
--- `keymaps.agent.to_input` runs in the agent's message input, resolved when
--- pressed, and `keymaps.widget.stop_generation` cancels the agent's session.
--- @param child_id string
--- @param bufnr integer The transcript
function Subagents:_bind_agent_keymaps(child_id, bufnr)
    BufHelpers.bind_to_input(Config.keymaps.agent.to_input, bufnr, function()
        return self:_agent_input_win(child_id)
    end)
    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.stop_generation,
        bufnr,
        function()
            self:stop(child_id)
        end,
        { desc = "Agentic: Stop subagent" }
    )
end

--- Mark a subagent's open tool calls `interrupted`, in its transcript and in
--- the history, for when they fail.
--- @param child_id string
function Subagents:_mark_stopped(child_id)
    self._host.history():update_tool_calls(
        self:transcript(child_id).view.writer:stamp_open_calls("interrupted")
    )
end

--- Stop a subagent's current work.
--- @param child_id string
function Subagents:stop(child_id)
    self:_mark_stopped(child_id)
    self._host.agent():stop_generation(child_id)
end

--- Mark the open tool calls of each working subagent not running in the
--- background `interrupted`: a stop of the main agent's turn stops them too.
function Subagents:mark_foreground_stopped()
    for child_id, agent in pairs(self._agents) do
        local block = self:_agent_block(child_id)
        local mode = block and block.subagent and block.subagent.mode
        if agent.open and mode ~= "background" then
            self:_mark_stopped(child_id)
        end
    end
end

--- A subagent's display name, else its child session id.
--- @param child_id string
--- @return string
function Subagents:_agent_label(child_id)
    local block = self:_agent_block(child_id)
    return block and block.subagent and block.subagent.label or child_id
end

--- Whether the provider's record says a subagent blocks its spawner.
--- @param child_id string
--- @return boolean
function Subagents:_confirmed_blocking(child_id)
    local block = self:_agent_block(child_id)
    local subagent = block and block.subagent
    return subagent ~= nil
        and subagent.confirmed
        and subagent.mode == "blocking"
end

--- Ask the main agent to pass `text` to a subagent, through the provider's
--- message instruction. A finished agent resumes. Notifies for an agent that
--- blocks its spawner, a provider that gives no instruction, or a message the
--- session holds. A message refused or turned away by the usage limit goes
--- back to the top of the agent's input, or of the session's input once the
--- agent's is gone.
--- @param child_id string
--- @param text string
--- @return boolean sent
function Subagents:_relay_to_agent(child_id, text)
    if not text:find("%S") then
        return false
    end
    local label = self:_agent_label(child_id)
    local instruction = not self:_confirmed_blocking(child_id)
        and self._host
            .agent()
            :subagent_message_instruction(child_id, label, text)
    if not instruction then
        Logger.notify(
            string.format("Subagent %s cannot be messaged", label),
            vim.log.levels.WARN
        )
        return false
    end
    local held = self._host.relay(instruction, function(reason)
        local input = self._inputs[child_id]
        self._host.return_prompt(text, input and input.bufnr, reason)
    end)
    if held then
        Logger.notify(
            string.format("Subagent %s not messaged — %s.", label, held),
            vim.log.levels.WARN
        )
    end
    return not held
end

return Subagents

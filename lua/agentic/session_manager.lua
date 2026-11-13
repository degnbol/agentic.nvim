-- The session manager class glues together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- When the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local ACPClient = require("agentic.acp.acp_client")
local ACPPayloads = require("agentic.acp.acp_payloads")
local AcpKind = require("agentic.utils.acp_kind")
local AgentConfigOptions = require("agentic.acp.agent_config_options")
local AgentView = require("agentic.ui.agent_view")
local Bootstrap = require("agentic.bootstrap")
local BufHelpers = require("agentic.utils.buf_helpers")
local Budget = require("agentic.budget")
local CanonicalToolCall = require("agentic.acp.canonical_tool_call")
local ChatHistory = require("agentic.ui.chat_history")
local CodeSelection = require("agentic.ui.code_selection")
local Config = require("agentic.config")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local DiffJump = require("agentic.ui.diff_jump")
local EnvironmentInfo = require("agentic.environment_info")
local FileSystem = require("agentic.utils.file_system")
local FileTail = require("agentic.utils.file_tail")
local Glyphs = require("agentic.glyphs")
local GrantCommand = require("agentic.grant_command")
local GrantSafety = require("agentic.utils.grant_safety")
local InfoPanel = require("agentic.ui.info_panel")
local Json = require("agentic.utils.json")
local Listeners = require("agentic.utils.listeners")
local Logger = require("agentic.utils.logger")
local MessageWriter = require("agentic.ui.message_writer")
local PermissionOptions = require("agentic.acp.permission_options")
local PromptBlocks = require("agentic.utils.prompt_blocks")
local Recovery = require("agentic.session_recovery")
local RunClocks = require("agentic.ui.run_clocks")
local SessionRegistry = require("agentic.session_registry")
local SessionResume = require("agentic.session_resume")
local SequenceTail = require("agentic.utils.sequence_tail")
local ShellParse = require("agentic.utils.shell_parse")
local SideRecords = require("agentic.ui.side_records")
local SlashCommands = require("agentic.acp.slash_commands")
local States = require("agentic.states")
local Subagents = require("agentic.subagents")
local ToolTimings = require("agentic.tool_timings")
local WidgetLayout = require("agentic.ui.widget_layout")
local WindowDecoration = require("agentic.ui.window_decoration")

--- @class agentic._SessionManagerPrivate
local P = {}

local FORK_NOTICE = MessageWriter.FORK_NOTICE

--- Tool call kinds that mutate files on disk.
--- When these complete, buffers must be reloaded via checktime.
local FILE_MUTATING_KINDS = {
    edit = true,
    create = true,
    write = true,
    delete = true,
    move = true,
}

--- Safely invoke a user-configured hook
--- @param hook_name "on_prompt_submit" | "on_response_complete" | "on_permission_request"
--- @param data table
function P.invoke_hook(hook_name, data)
    local hook = Config.hooks and Config.hooks[hook_name]

    if hook and type(hook) == "function" then
        vim.schedule(function()
            local ok, err = pcall(hook, data)
            if not ok then
                Logger.notify(
                    string.format("Hook '%s' error: %s", hook_name, err),
                    vim.log.levels.ERROR
                )
            end
        end)
    end
end

--- How the replay of a session/load in flight is handled:
--- - `loading`: its replay arrives and is written as it comes.
--- - `holding`: the session file rendered the chat, and the replay is held.
--- - `dropping`: the held replay was given up. The rest of it is dropped
---   until the load ends or a turn starts.
--- @alias agentic.SessionManager.LoadState "loading"|"holding"|"dropping"

--- @class agentic.SessionManager.PendingLoad
--- @field chat_id string The chat to load, or the ACP id of a session with no saved file
--- @field cwd? string Working directory of the session. Nil for the one its file records, else the editor's
--- @field model? string Model id to apply after the load succeeds

--- What a fork starts from, every value taken when the fork is asked for:
--- the source can be destroyed or move to another session before the fork
--- starts.
--- @class agentic.SessionManager.ForkStart
--- @field source_id string ACP session id of the source, which `session/fork` takes
--- @field source_chat_id string Chat id of the source
--- @field source_cwd string
--- @field source_title string
--- @field history agentic.ui.ChatHistory The conversation the fork starts with
--- @field before? agentic.ui.ChatHistory.UserMessage The source's prompt the fork leaves out, above which the source gets its link
--- @field model? string
--- @field mode? string

--- @class agentic.SessionManager
--- @field id integer Monotonic identity, unique for the editor's lifetime. Names the session's buffers
--- @field session_id? string
--- @field _is_first_message boolean Whether this is the first message in the session, used to add system info only once
--- @field is_generating boolean The running state the chat header shows
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field main_view agentic.ui.AgentView The chat's. Its response boundary is never reset: every session starts with the writer's prose run closed and history ending on a user message, where a stale verdict writes no break
--- @field message_writer agentic.ui.MessageWriter `main_view.writer`
--- @field permission_manager agentic.ui.PermissionManager
--- @field _grant_command agentic.GrantCommand
--- @field tail_lines agentic.ui.TailLines `main_view.tail_lines`
--- @field _subagents agentic.Subagents
--- @field _run_clocks? agentic.ui.RunClocks How long each live tool call runs. Nil when `tool_call_display.elapsed_threshold_ms` is false
--- @field _output_tails table<string, agentic.utils.FileTail> toolCallId -> tail of the output file of a command still running
--- @field _held_tool_call_updates table<string, { update: agentic.ui.MessageWriter.ToolCallBase, child_id?: string }> toolCallId -> fields a side record gave a call the chat does not show yet, and the subagent whose records gave them. Dropped at the turn's end for the main agent, at the subagent's end for a subagent
--- @field file_list agentic.ui.FileList
--- @field file_activity agentic.ui.FileActivity
--- @field code_selection agentic.ui.CodeSelection
--- @field diagnostics_list agentic.ui.DiagnosticsList
--- @field config_options agentic.acp.AgentConfigOptions
--- @field todo_list agentic.ui.TodoList
--- @field agents_panel agentic.ui.AgentsPanel
--- @field chat_history agentic.ui.ChatHistory
--- @field _thought_response_id? string `messageId` of the main agent's last thought chunk
--- @field _compaction_summary? string Summary text of the running compaction streamed so far
--- @field _title_user_set? boolean Set once the user picks a title via /rename; blocks the provider's auto-summary from overriding it
--- @field _history_to_send? agentic.ui.ChatHistory History whose messages to prepend on next prompt submit, as a text transcript (the history prefix)
--- @field _session_epoch integer Monotonic counter incremented on each new_session/load; guards stale create_session callbacks
--- @field _pending_load? agentic.SessionManager.PendingLoad A session/load deferred until the agent is ready
--- @field _pending_fork? agentic.SessionManager.ForkStart A fork the constructor's on-ready starts instead of a new session
--- @field _cwd string Working directory of the ACP session. Also selects the project folder of its session file
--- @field _usage? agentic.ui.InfoPanel.Usage
--- @field _name? string The provider's name for the session as last shown
--- @field _available_commands? agentic.acp.AvailableCommand[] The provider's last advertised slash commands; nil before the first advertisement
--- @field _last_prompt? string
--- @field destroyed boolean Flag set on destroy() to guard async callbacks
--- @field _draining_queue? boolean A queued block is being taken; guards _drain_queue against re-entry
--- @field _foreground "running"|"requires_action"|"idle" The agent's foreground work, as the last turn state reported it
--- @field _untaken agentic.SessionManager.SentPrompt[] Prompts sent and not yet taken in, oldest first
--- @field _taken agentic.SessionManager.SentPrompt[] Prompts taken in whose turn has not ended, oldest first. ACP v1 takes a prompt in when it is sent, so it can hold several
--- @field _continue_mark? integer Queued-region tag of the automatic "continue"
--- @field _load_state? agentic.SessionManager.LoadState How the replay of a session/load in flight is handled. Nil with no load, or once its replay was given up. Set only through `_set_load_state`
--- @field _replay_hold? agentic.SessionManager.HeldUpdate[] Conversation updates of a session/load replay, held until the load completes. Set exactly while `_load_state` is `holding`
--- @field _reauth_live_retry boolean Set when a re-login was answered by keeping the live session, cleared by the next successful turn; a re-login while still set restarts the provider subprocess instead
--- @field _transient_attempt number Consecutive silent retries of transient server errors (0 = none this chain)
--- @field _checktime_scheduled boolean Coalesces rapid checktime calls into one deferred check
--- @field extensions table<string, any> Per-session state of extensions, keyed by extension name
--- @field _listeners table<agentic.SessionEvent, agentic.utils.Listeners>
local SessionManager = {}
SessionManager.__index = SessionManager

--- Ring terminal bell if notifications.bell is enabled.
--- Static method (stubbable in tests).
function SessionManager._ring_bell()
    if Config.notifications and Config.notifications.bell then
        io.stderr:write("\a")
    end
end

--- Notify the user that the agent needs attention: bell when the chat window
--- is unfocused, and with `mark_idle`, the idle state in the chat header when
--- no chat window follows.
--- @param mark_idle boolean
function SessionManager:_notify_attention(mark_idle)
    local is_chat_focused = vim.api.nvim_get_current_buf()
        == self.widget.buf_nrs.agent
    if not is_chat_focused then
        SessionManager._ring_bell()
    end
    if mark_idle and not self.message_writer:any_following() then
        self.widget:set_idle(true)
    end
end

--- Signal a permission request waiting with its float hidden, not visible in
--- the current tabpage: bell, the waiting state in the header of
--- `badge_bufnr`, and a notification naming the session and `anchor_bufnr`,
--- the buffer the request belongs to. The state stays until the request ends.
--- @param badge_bufnr integer
--- @param anchor_bufnr integer
function SessionManager:_on_permission_hidden(badge_bufnr, anchor_bufnr)
    SessionManager._ring_bell()
    self.widget:set_waiting(true, badge_bufnr)
    local title = self.chat_history.title
    local label = self:_subagent_label(anchor_bufnr)
    local where = label and "subagent " .. label
        or string.format("its %s buffer", vim.b[anchor_bufnr].agentic_window)
    Logger.notify(
        string.format(
            "%s is waiting for a permission in %s",
            title ~= "" and title or "An Agentic session",
            where
        ),
        vim.log.levels.INFO,
        { title = "Agentic" }
    )
end

--- The label of the subagent whose transcript is `bufnr`.
--- @param bufnr integer
--- @return string|nil label Nil for a buffer that is no transcript
function SessionManager:_subagent_label(bufnr)
    local child_id = self._subagents:child_of_buf(bufnr)
    return child_id and self._subagents:agent_label(child_id)
end

--- Generate the welcome header for a new session
--- @param session_id string|nil
--- @return string header
function SessionManager._generate_welcome_header(_, session_id)
    local ts = os.date("%Y-%m-%d %H:%M")
    local short_id = session_id and session_id:sub(1, 8) or "unknown"
    return string.format("# %s · %s", ts, short_id)
end

--- Refresh `history`'s provider / provider_version / model / file_activity from
--- current state so the next save records which provider, provider version and
--- model produced the conversation, and which files it changed.
---
--- Takes its target rather than reading `self.chat_history`, which an async
--- caller holding an earlier history is not necessarily writing back.
--- @param history agentic.ui.ChatHistory
function SessionManager:_sync_history_context(history)
    history.file_activity = self.file_activity:serialize()
    history.provider = self.agent.provider_name
    -- Guarded: a provider that reports no agentInfo, or whose initialize is
    -- still in flight, must not erase the version a resumed session recorded.
    local agent_info = self.agent.agent_info
    if agent_info then
        history.provider_version = agent_info.version
    end
    history.model = self.config_options:current_model_id()
end

--- Sync the session context onto `history` and write it to disk. A history
--- with no session id is left alone, and so is one a session/load is still
--- filling: until the load ends it is a partial copy of its file, and writing
--- it would drop the rest. A history without a prompt from the user is left
--- alone too: it holds no conversation to resume.
--- @param history agentic.ui.ChatHistory
function SessionManager:_persist_history(history)
    if
        not history.session_id
        or self:_replaying()
        or not history:has_prompt()
    then
        return
    end

    self:_sync_history_context(history)
    local save_err = history:save(self._cwd)
    if save_err then
        -- Not a debug-only line: this is the write that makes a conversation
        -- survive a crash, so a failure has to reach whoever would otherwise
        -- assume it is on disk.
        Logger.notify(
            "Chat history save failed: " .. save_err,
            vim.log.levels.WARN
        )
    end
    self:_sync_modified(history)
end

--- Set the `modified` flag of the chat and the transcripts, their only owner.
--- Each is true while `history` is unsaved; the chat's also while a turn or
--- a subagent works. Running work counts even once written: quitting would
--- cut it off, so `:qa`, `:wqa` and `:bd` refuse until it ends. A
--- history a session/load is filling is a copy of its file, so it counts as
--- saved, and one without a prompt from the user has nothing to save. A no-op
--- for any history but the current one, so a callback holding a replaced
--- history cannot touch the flags.
--- @param history agentic.ui.ChatHistory
function SessionManager:_sync_modified(history)
    if history ~= self.chat_history then
        return
    end
    local unsaved = history.dirty
        and not self:_replaying()
        and history:has_prompt()
    -- Nil once the widget is destroyed.
    local chat = self.widget.buf_nrs.agent
    if chat and vim.api.nvim_buf_is_valid(chat) then
        vim.bo[chat].modified = unsaved
            or self:_in_flight()
            or self._subagents:any_open()
    end
    self._subagents:set_modified(unsaved)
end

--- Whether the agent works in the foreground or holds a prompt sent and not
--- yet taken in.
--- @return boolean
function SessionManager:_in_flight()
    return self._foreground ~= "idle" or #self._untaken > 0
end

--- Set the load state, and with it the replay hold (a new empty one for
--- `holding`, else nil) and the chat's `modified` flag.
--- @param state agentic.SessionManager.LoadState|nil
function SessionManager:_set_load_state(state)
    self._load_state = state
    self._replay_hold = state == "holding" and {} or nil
    self:_sync_modified(self.chat_history)
end

--- Whether a session/load's replay of past work is still arriving.
--- @return boolean
function SessionManager:_replaying()
    return self._load_state == "loading" or self._load_state == "holding"
end

--- Whether a turn or a load's replay is still arriving, whose own end will
--- finalize the writer.
--- @return boolean
function SessionManager:_turn_open()
    return self._foreground ~= "idle" or self:_replaying()
end

--- Set `is_generating` and show it in the chat header.
--- @param generating boolean
function SessionManager:_set_generating(generating)
    self.is_generating = generating
    self.widget:set_running(generating)
end

--- Handle a mutation of `history`. With no turn open the change is written
--- at once. Otherwise only the chat's `modified` flag follows it, and the
--- turn's end writes it.
--- @param history agentic.ui.ChatHistory
function SessionManager:_history_changed(history)
    -- A session/load writes once, at its end.
    if not self:_turn_open() then
        self:_persist_history(history)
    else
        self:_sync_modified(history)
    end
end

--- Last `SessionManager.id` handed out.
local last_id = 0

--- @param provider agentic.UserConfig.ProviderName
function SessionManager:new(provider)
    Bootstrap.ensure()

    local AgentInstance = require("agentic.acp.agent_instance")
    local ChatWidget = require("agentic.ui.chat_widget")
    local FileActivity = require("agentic.ui.file_activity")
    local FileList = require("agentic.ui.file_list")
    local PermissionManager = require("agentic.ui.permission_manager")
    local TodoList = require("agentic.ui.todo_list")
    local AgentsPanel = require("agentic.ui.agents_panel")

    last_id = last_id + 1
    self = setmetatable({
        id = last_id,
        session_id = nil,
        _is_first_message = true,
        is_generating = false,
        _session_epoch = 0,
        _cwd = vim.fn.getcwd(),
        destroyed = false,
        --- @type string|nil Smart path of the most recently edited .md file (plan candidate)
        _last_edited_md = nil,
        _reauth_live_retry = false,
        _transient_attempt = 0,
        _foreground = "idle",
        _untaken = {},
        _taken = {},
        _checktime_scheduled = false,
        _output_tails = {},
        _held_tool_call_updates = {},
        extensions = {},
        _listeners = {
            turn_end = Listeners:new(),
            session_changed = Listeners:new(),
            destroy = Listeners:new(),
        },
    }, self)

    local agent = AgentInstance.get_instance(provider, function(_client)
        vim.schedule(function()
            if self.destroyed then
                return
            end

            local pending = self._pending_load
            if pending then
                self._pending_load = nil
                self:_do_load_acp_session(
                    pending.chat_id,
                    pending.cwd,
                    pending.model
                )
            elseif self._pending_fork then
                local fork = self._pending_fork --[[@as agentic.SessionManager.ForkStart]]
                self._pending_fork = nil
                self:_do_start_fork(fork)
            elseif not self._load_state then
                self:new_session({ keep_cwd = true })
            end
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent

    self.chat_history = ChatHistory:new()

    self.widget = ChatWidget:new(
        self.id,
        self.chat_history.chat_id,
        function(input_text, opts)
            self:on_user_submit()
            return self:_handle_input_submit(input_text, opts)
        end
    )

    self.widget.on_refresh = function()
        self:_refresh()
    end

    self.widget.on_goto_bottom = function(winid)
        local writer = self:_writer_of_buf(vim.api.nvim_win_get_buf(winid))
        if writer then
            writer:go_to_bottom(winid)
        end
    end

    local threshold_ms = Config.tool_call_display.elapsed_threshold_ms
    if threshold_ms then
        self._run_clocks = RunClocks:new(threshold_ms, function(ids)
            for _, id in ipairs(ids) do
                self:_refresh_status(id)
            end
        end)
    end
    self.main_view = AgentView:new(self.widget.buf_nrs.agent, self._run_clocks)
    self.tail_lines = self.main_view.tail_lines
    self.message_writer = self.main_view.writer
    self._subagents =
        Subagents:new(self.widget, self.main_view, self:_subagents_host())

    self.permission_manager = PermissionManager:new(
        self.message_writer,
        self.widget.buf_nrs,
        function(tool_call_id)
            return self:_view_for(tool_call_id).writer
        end,
        function()
            return self.agent:claude_config_dir()
        end
    )
    self._grant_command = GrantCommand:new(
        self.permission_manager,
        self.message_writer,
        function()
            return self._cwd
        end,
        function()
            return self:_turn_open()
        end
    )
    self.permission_manager.on_hidden = function(badge_bufnr, anchor_bufnr)
        self:_on_permission_hidden(badge_bufnr, anchor_bufnr)
    end
    self.permission_manager.on_hidden_resolved = function(bufnr)
        -- A marked transcript the user wiped took its header with it.
        if
            vim.api.nvim_buf_is_valid(bufnr)
            and WindowDecoration.get_header(bufnr).waiting
        then
            self.widget:set_waiting(false, bufnr)
        end
    end
    self.permission_manager.open_anchor = function(bufnr, how)
        return WidgetLayout.open_buf(bufnr, how, self.widget:target_win())
    end
    self.permission_manager.title_for = function(anchor)
        return self:_subagent_label(anchor)
    end
    self.permission_manager.proxy_tool_call = function(anchor)
        return self._subagents:child_of_buf(anchor)
    end
    self.permission_manager.companion_bufs = function(anchor)
        local child_id = self._subagents:child_of_buf(anchor)
        local input = child_id and self._subagents:input_of(child_id)
        return input and { input.bufnr } or {}
    end
    self.permission_manager.on_decided = function(tool_call_id, causes)
        self:_on_permission_decided(tool_call_id, causes)
    end

    self.config_options = AgentConfigOptions:new(
        function(mode_id, is_legacy, opts)
            self:_handle_mode_change(mode_id, is_legacy, opts)
        end,
        function(model_id, is_legacy, opts)
            self:_handle_model_change(model_id, is_legacy, opts)
        end,
        function(value, opts)
            self:_handle_thought_level_change(value, opts)
        end,
        function()
            return self.agent ~= nil and self.agent.state == "ready"
        end
    )

    --- @param panel agentic.ui.ChatWidget.StackPanel
    --- @return fun(): integer|nil
    local function buf_of(panel)
        return function()
            return self.widget:panel_buf(panel)
        end
    end

    self.file_list =
        FileList:new(buf_of("files"), self:_context_panel_on_change("files"))

    -- Unlike the sibling list panels, an empty tally must not close the window
    -- and a new row must not open it: the panel is a toggle. The callback only
    -- re-fits an already-open window.
    self.file_activity = FileActivity:new(buf_of("activity"), function()
        self.widget:resize_panel("activity")
    end)

    self.code_selection =
        CodeSelection:new(buf_of("code"), self:_context_panel_on_change("code"))

    self.diagnostics_list = DiagnosticsList:new(
        buf_of("diagnostics"),
        self:_context_panel_on_change("diagnostics")
    )

    self.agents_panel = AgentsPanel:new(buf_of("agents"), {
        buf_of = function(child_id)
            return self._subagents:buf_of(child_id)
        end,
        open = function(child_id)
            local bufnr = self._subagents:open_buf(child_id)
            if bufnr then
                WidgetLayout.open_buf(bufnr, "edit", self.widget:target_win())
            end
        end,
    })

    self.todo_list = TodoList:new(buf_of("todos"), function(todo_list)
        if not todo_list:is_empty() then
            self.widget:sync_panels()
        end
    end, function()
        self.widget:close_panel("todos")
    end)

    self:_setup_session_buf(self.widget.buf_nrs.agent, self.message_writer)
    --- @param panel agentic.ui.ChatWidget.StackPanel
    --- @param bufnr integer
    local function setup_panel(panel, bufnr)
        self:_watch_panel_buf(panel, bufnr)
        self:_setup_panel_buf(panel, bufnr)
    end
    for _, panel in ipairs(Config.windows.stack) do
        setup_panel(panel, self.widget.buf_nrs[panel])
    end
    self.widget.on_panel_buf = setup_panel

    self:_setup_buffer_lifecycle()

    return self
end

--- A handler that, given a list, closes `panel` and focuses the input when
--- the list is empty, else shows the item count in the panel's header.
--- @param panel agentic.ui.ChatWidget.StackPanel
--- @return fun(list: agentic.ui.ContextList) handler
function SessionManager:_context_panel_on_change(panel)
    return function(list)
        if list:is_empty() then
            self.widget:close_panel(panel)
            self.widget:move_cursor_to("input")
        else
            self.widget:render_header(panel, tostring(list:count()))
            self.widget:sync_panels()
        end
    end
end

--- Bind the session's own buffer-local maps (the widget binds its own) to a
--- buffer of this session, and give a chat-style buffer the 'tagfunc' that
--- links the rows of a message (`TAGFUNC`). In the chat, the fork keys fork.
--- @param bufnr integer
--- @param writer agentic.ui.MessageWriter|nil The writer of a chat-style buffer, whose diffs `gf` jumps into
function SessionManager:_setup_session_buf(bufnr, writer)
    self.config_options:bind_keymaps(bufnr)
    self:_bind_owner_keymaps(bufnr)
    if not writer then
        return
    end
    vim.bo[bufnr].tagfunc = SessionManager.TAGFUNC
    DiffJump.set_goto_file_keymaps(bufnr, writer)
    if writer == self.message_writer then
        self:_bind_fork_keymaps(bufnr)
    end
end

--- Bind each key of `Config.keymaps.agent.fork` in `bufnr` to fork at the
--- cursor, and with `<C-w>` or `<C-w>g` before it, to fork into a split or a
--- tab, as `gf`, `<C-w>f` and `<C-w>gf` open a file.
--- @param bufnr integer
function SessionManager:_bind_fork_keymaps(bufnr)
    local keys = Config.keymaps.agent.fork
    --- @type { prefix: string, placement: agentic.utils.BufHelpers.Placement }[]
    local variants = {
        { prefix = "", placement = {} },
        { prefix = "<C-w>", placement = { mods = { horizontal = true } } },
        { prefix = "<C-w>g", placement = { new_tab = true } },
    }
    for _, variant in ipairs(variants) do
        BufHelpers.multi_keymap_set(
            BufHelpers.prefix_keymaps(keys, variant.prefix),
            bufnr,
            function()
                self:fork_at_cursor(
                    BufHelpers.placement_mods(variant.placement)
                )
            end,
            { desc = "Agentic: Fork before this turn" }
        )
    end
end

--- Insert `link` above the prompt `before`: in the history, and in the chat
--- when the chat shows that prompt. Nothing when the history no longer holds
--- `before`.
--- @param link agentic.ui.ChatHistory.ForkLink
--- @param before agentic.ui.ChatHistory.UserMessage
function SessionManager:add_fork_link(link, before)
    local index = self.chat_history:index_of(before)
    if not index then
        return
    end
    self.chat_history:insert_message(index, link)
    local mark = self.message_writer:prompt_mark_of(before)
    if mark then
        self.message_writer:write_fork_link(link, mark)
    end
    self:_history_changed(self.chat_history)
end

--- Bind the session's maps and those of the panel's owner in a panel buffer.
--- For the input, also set the chat it completes words from and the
--- advertised slash commands. Renders nothing.
--- @param panel agentic.ui.ChatWidget.StackPanel
--- @param bufnr integer
function SessionManager:_setup_panel_buf(panel, bufnr)
    self:_setup_session_buf(bufnr, nil)
    --- @type table<agentic.ui.ChatWidget.StackPanel, { bind_keymaps: fun(self: any, bufnr: integer) }>
    local owners = {
        code = self.code_selection,
        files = self.file_list,
        diagnostics = self.diagnostics_list,
        activity = self.file_activity,
        agents = self.agents_panel,
    }
    local owner = owners[panel]
    if owner then
        owner:bind_keymaps(bufnr)
    end
    if panel == "input" then
        States.setChatBufnr(bufnr, self.widget.buf_nrs.agent)
        if self._available_commands then
            SlashCommands.setCommands(bufnr, self._available_commands)
        end
    end
end

--- Keep the provider's advertised slash commands, and offer them in the input.
--- @param commands agentic.acp.AvailableCommand[]
function SessionManager:_set_available_commands(commands)
    self._available_commands = commands
    SlashCommands.setCommands(self.widget.buf_nrs.input, commands)
end

--- Per panel, the call that renders its buffer again from the session's state.
--- @type table<agentic.ui.ChatWidget.StackPanel, fun(self: agentic.SessionManager)>
local PANEL_RELOADS = {
    agents = function(self)
        self:render_agents()
    end,
    todos = function(self)
        self.todo_list:redraw()
    end,
    code = function(self)
        self.code_selection:render()
    end,
    files = function(self)
        self.file_list:render()
    end,
    diagnostics = function(self)
        self.diagnostics_list:render()
    end,
    activity = function(self)
        self.file_activity:render()
    end,
    info = function(self)
        self:render_info()
    end,
}

--- Render a panel buffer again from the session's state on `:e`. Once per
--- buffer: the autocmd outlives an unload.
--- @param panel agentic.ui.ChatWidget.StackPanel
--- @param bufnr integer
function SessionManager:_watch_panel_buf(panel, bufnr)
    local reload = PANEL_RELOADS[panel]
    if not reload then
        return
    end
    vim.api.nvim_create_autocmd("BufReadCmd", {
        buffer = bufnr,
        callback = function()
            if not self.destroyed then
                reload(self)
            end
        end,
    })
end

--- 'tagfunc' value that calls `tagfunc`.
SessionManager.TAGFUNC = "v:lua.require'agentic.session_manager'.tagfunc"

--- 'tagfunc' (`:h tag-function`) that runs the `_tagfunc` of the session
--- owning the current buffer. Falls back to `vim.lsp.tagfunc` when no session
--- owns it.
--- @param pattern string
--- @param flags string
--- @return { name: string, filename: string, cmd: string }[]|vim.NIL
function SessionManager.tagfunc(pattern, flags)
    local owner = SessionRegistry.owner_of_buf(vim.api.nvim_get_current_buf())
    if not owner then
        return vim.lsp.tagfunc(pattern, flags)
    end
    return owner:_tagfunc(pattern, flags)
end

--- 'tagfunc' (`:h tag-function`) over this session's buffers: each message id
--- is a tag at the message's rows, rows in other buffers before the current
--- buffer's, and each background job id a tag at the head of the job's block.
--- With the `c` flag (`CTRL-]`) the tag is the message whose row holds the
--- cursor, else the job the tool call block there stops, instead of
--- `pattern`. Falls back to `vim.lsp.tagfunc` when nothing matches.
--- @param pattern string
--- @param flags string
--- @return { name: string, filename: string, cmd: string }[]|vim.NIL
function SessionManager:_tagfunc(pattern, flags)
    local current = vim.api.nvim_get_current_buf()
    local at_cursor = flags:find("c", 1, true) ~= nil
    --- @type string|nil
    local name = pattern
    if at_cursor then
        local writer = self:_writer_of_buf(current)
        local row = vim.api.nvim_win_get_cursor(0)[1] - 1
        name = writer and writer:notice_at(row)
        -- A fork link is followed with `gf`, not as a tag.
        if name and vim.startswith(name, FORK_NOTICE) then
            name = nil
        end
        if writer and not name then
            local block = DiffJump.find_block_at_row(
                current,
                row,
                writer.tool_call_blocks
            )
            name = block and block.stopped_job_id
        end
    end
    if not name then
        return vim.lsp.tagfunc(pattern, flags)
    end
    local tags = {}
    --- @type agentic.ui.MessageWriter|nil
    local first_other
    --- @param writer agentic.ui.MessageWriter
    --- @param row integer 0-indexed
    local function add_tag(writer, row)
        local tag = {
            name = name,
            filename = vim.api.nvim_buf_get_name(writer.bufnr),
            cmd = tostring(row + 1),
        }
        if writer.bufnr == current then
            table.insert(tags, tag)
        else
            table.insert(tags, 1, tag)
            first_other = writer
        end
    end
    for _, writer in ipairs(self:_writers_of_message(name)) do
        local row = writer:notice_row(name)
        if row then
            add_tag(writer, row)
        end
    end
    if #tags == 0 then
        local record = self:_background_job_record(name)
        local target = record and self._subagents:record_writer(record, true)
        if record and target then
            local row = target:tool_call_row(record.tool_call_id)
            if row then
                add_tag(target, row)
            end
        end
    end
    if first_other and at_cursor then
        -- The jump shows the buffer before it places the cursor, which
        -- following would move.
        first_other:hand_next_window_to_user()
    end
    return #tags > 0 and tags or vim.lsp.tagfunc(pattern, flags)
end

--- The writers of the buffers that can hold a row of a message: the chat's,
--- and the transcript's of each subagent whose history holds one. Such a
--- transcript is loaded and rendered, or made again, first.
--- @param message_id string
--- @return agentic.ui.MessageWriter[]
function SessionManager:_writers_of_message(message_id)
    local writers = { self.message_writer }
    for _, msg in ipairs(self.chat_history.subagent_messages) do
        if msg.type == "session_message" and msg.message_id == message_id then
            local transcript = self._subagents:transcript_of_key(msg.agent_key)
            if transcript then
                table.insert(writers, transcript.view.writer)
            end
        end
    end
    return writers
end

--- The history record of the tool call that went to the background as
--- `job_id`: the main agent's newest, else the subagents' newest.
--- @param job_id string
--- @return agentic.ui.ChatHistory.ToolCall|nil
function SessionManager:_background_job_record(job_id)
    local history = self.chat_history
    for _, list in ipairs({ history.messages, history.subagent_messages }) do
        for i = #list, 1, -1 do
            local msg = list[i]
            if msg.type == "tool_call" and msg.background_job_id == job_id then
                return msg
            end
        end
    end
    return nil
end

--- Link a call that stops a background job to the job's block: head it with
--- the job's description and show the job's output file, and once the stop
--- has completed, mark the job's block stopped. Does nothing for a call that
--- stops no job, or a job with no record in the history. Does not persist the
--- history.
--- @param tool_call_id string
function SessionManager:_sync_job_stop(tool_call_id)
    local writer = self:_view_for(tool_call_id).writer
    local tracker = writer.tool_call_blocks[tool_call_id]
    local job_id = tracker and tracker.stopped_job_id
    local record = job_id and self:_background_job_record(job_id)
    if not record then
        return
    end

    local description = record.description
    if description == "" then
        description = nil
    end
    -- Compared, not set once: a later update can set the head back to the
    -- job id.
    if
        (description and description ~= tracker.argument)
        or record.output_file ~= tracker.stopped_job_output_file
    then
        AgentView.merge_tool_call_fields(writer, self.chat_history, {
            tool_call_id = tool_call_id,
            argument = description,
            stopped_job_output_file = record.output_file,
        })
    end

    if tracker.status == "completed" and not record.stopped_by then
        -- A transcript that is not loaded renders the field from the history
        -- when it loads.
        AgentView.merge_tool_call_fields(
            self._subagents:record_writer(record, false),
            self.chat_history,
            {
                tool_call_id = record.tool_call_id,
                stopped_by = tool_call_id,
            }
        )
    end
end

--- Bind the widget keymaps that act on a whole session to a buffer of this
--- one, as closures over it: they act on the buffer's owner wherever the
--- buffer is shown.
--- @param bufnr integer
function SessionManager:_bind_owner_keymaps(bufnr)
    local keymaps = Config.keymaps.widget
    BufHelpers.multi_keymap_set(keymaps.switch_provider, bufnr, function()
        SessionRegistry.select_provider(
            self.agent.provider_name,
            function(provider_name)
                if provider_name then
                    self:switch_provider(provider_name)
                end
            end
        )
    end, { desc = "Agentic: Switch provider" })

    BufHelpers.multi_keymap_set(keymaps.stop_generation, bufnr, function()
        self:stop_generation()
    end, { desc = "Agentic: Stop generation" })

    BufHelpers.multi_keymap_set(keymaps.toggle_activity, bufnr, function()
        self:toggle_file_activity()
    end, { desc = "Agentic: Toggle changed-files panel" })

    BufHelpers.multi_keymap_set(keymaps.toggle_info, bufnr, function()
        self:toggle_info()
    end, { desc = "Agentic: Toggle session info panel" })

    BufHelpers.multi_keymap_set(keymaps.toggle_agents, bufnr, function()
        self:toggle_agents()
    end, { desc = "Agentic: Toggle agents panel" })

    BufHelpers.multi_keymap_set(keymaps.restart_session, bufnr, function()
        self:restart_session()
    end, { desc = "Agentic: Restart session (re-create from history)" })

    BufHelpers.multi_keymap_set(keymaps.resume_session, bufnr, function()
        SessionResume.pick(nil, { marked_id = self:chat_id() })
    end, { desc = "Agentic: Pick a saved session" })
end

--- Write the history to the session file. Warns and writes nothing before
--- the session exists or while it loads.
function SessionManager:_write_session()
    if not self.chat_history.session_id then
        Logger.notify(
            "No session yet, so no session file to write",
            vim.log.levels.WARN
        )
        return
    end
    if self:_replaying() then
        Logger.notify(
            "The session is still loading from its file, so there is nothing to write",
            vim.log.levels.WARN
        )
        return
    end
    self:_persist_history(self.chat_history)
    -- Vim gives no reason when `:wqa` stops on a buffer its write left
    -- modified.
    if self:_in_flight() or self._subagents:any_open() then
        Logger.notify(
            "History written; the chat stays modified while a turn or a subagent runs",
            vim.log.levels.WARN
        )
    end
end

--- Tie the session to its chat buffer the way a file ties to its buffer:
--- `:w` writes the history, `:bd` ends the session, `:e` re-renders the chat
--- from the session's state, and a session nobody used goes when its chat
--- is no longer shown, as a scratch buffer with `bufhidden=wipe` would.
function SessionManager:_setup_buffer_lifecycle()
    local buf_nrs = self.widget.buf_nrs
    local chat = buf_nrs.agent

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = chat,
        callback = function()
            self:_write_session()
        end,
    })

    vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        buffer = chat,
        callback = function()
            SessionRegistry.destroy(self)
        end,
    })

    vim.api.nvim_create_autocmd("BufWinLeave", {
        buffer = chat,
        callback = function()
            -- Deferred: the leaving window still shows the buffer here, and a
            -- re-layout reopens the chat straight after.
            vim.schedule(function()
                local input = buf_nrs.input
                if
                    not self.destroyed
                    and not self.chat_history:has_prompt()
                    -- A wiped input holds no draft.
                    and not (vim.api.nvim_buf_is_valid(input) and vim.bo[input].modified)
                    and #vim.fn.win_findbuf(chat) == 0
                then
                    SessionRegistry.destroy(self)
                end
            end)
        end,
    })

    vim.api.nvim_create_autocmd("BufReadCmd", {
        buffer = chat,
        callback = function()
            if not self.destroyed then
                self:_reload_chat()
            end
        end,
    })
end

--- Re-render the chat from the in-memory history, which is the session file
--- plus the running turn. What the history does not hold is not rendered
--- again: notices, errors and the session-start marker.
function SessionManager:_reload_chat()
    self.main_view:restart()
    SessionResume.replay_messages(
        self.message_writer,
        self:_rendered_messages(),
        function(id)
            return self._subagents:peer_detail(id)
        end
    )
    self.tail_lines:reposition()
    self:_sync_modified(self.chat_history)
end

--- The writer rendering a buffer of this session, if it is the chat or a
--- transcript.
--- @param bufnr integer
--- @return agentic.ui.MessageWriter|nil
function SessionManager:_writer_of_buf(bufnr)
    if bufnr == self.widget.buf_nrs.agent then
        return self.message_writer
    end
    local child_id = self._subagents:child_of_buf(bufnr)
    return child_id and self._subagents:transcript(child_id).view.writer
end

--- The view of the agent that owns a tool call: its subagent's transcript,
--- else the chat. The owner is the one recorded at the initial `tool_call`,
--- as later notifications do not reliably carry the wire tag.
--- @param tool_call_id string
--- @return agentic.ui.AgentView
function SessionManager:_view_for(tool_call_id)
    local child_id = self._subagents:owner_of(tool_call_id)
    if child_id then
        return self._subagents:transcript(child_id).view
    end
    return self.main_view
end

--- Rewrite a tool call's status footer, where its buffer is loaded. Loads
--- no transcript: one loaded later renders the call from the history.
--- @param tool_call_id string
function SessionManager:_refresh_status(tool_call_id)
    local writer = self._subagents:loaded_writer_of(tool_call_id)
    if writer then
        writer:refresh_status(tool_call_id)
    end
end

--- The id of the main chat's block for a tool call: the id itself when the
--- call has a block of its own, else the child id of the subagent the id
--- delegated to, else the id itself.
--- @param tool_call_id string|nil
--- @return string|nil block_id
function SessionManager:_block_id(tool_call_id)
    if
        not tool_call_id
        or self.message_writer.tool_call_blocks[tool_call_id]
    then
        return tool_call_id
    end
    return self._subagents:agent_of(nil, tool_call_id) or tool_call_id
end

--- Drop the held tool call fields an agent's side records gave.
--- @param held table<string, { child_id?: string }> Held fields by tool call id, edited in place
--- @param child_id string|nil The subagent, nil for the main agent
local function drop_held(held, child_id)
    for id, entry in pairs(held) do
        if entry.child_id == child_id then
            held[id] = nil
        end
    end
end

--- Write a session message row to the main chat and add it to the history.
--- While a turn runs, the row leaves it open; otherwise the row ends the turn.
--- @param row agentic.ui.ChatHistory.SessionMessage
function SessionManager:_write_chat_row(row)
    -- A load replays a running conversation.
    local mid_turn = self:_turn_open()
    SessionResume.write_row(self.message_writer, row, mid_turn, function(id)
        return self._subagents:peer_detail(id)
    end)
    self.tail_lines:reposition()
    self.chat_history:add_message(row)
    self:_history_changed(self.chat_history)
end

--- What this session gives its subagents.
--- @return agentic.Subagents.Host
function SessionManager:_subagents_host()
    --- @type agentic.Subagents.Host
    local host = {
        agent = function()
            return self.agent
        end,
        history = function()
            return self.chat_history
        end,
        session_id = function()
            return self.session_id
        end,
        config_options = function()
            return self.config_options
        end,
        history_changed = function()
            self:_history_changed(self.chat_history)
        end,
        sync_modified = function()
            self:_sync_modified(self.chat_history)
        end,
        setup_buf = function(bufnr, writer)
            self:_setup_session_buf(bufnr, writer)
        end,
        write_chat_row = function(row)
            self:_write_chat_row(row)
        end,
        write = function()
            self:_write_session()
        end,
        end_side_records = function(child_id)
            self:_drain_subagent_side_records(child_id)
            drop_held(self._held_tool_call_updates, child_id)
        end,
        relay = function(instruction, on_returned)
            return self:_relay(instruction, on_returned)
        end,
        agents_changed = function()
            -- A transcript reports a listing change on the next tick.
            if not self.destroyed then
                self:render_agents()
            end
        end,
        run_clocks = self._run_clocks,
        return_prompt = function(text, bufnr, reason)
            local return_prompt = reason == "refusal"
                    and Recovery.restore_refused_prompt
                or Recovery.return_as_draft
            return_prompt(
                self,
                text,
                { selections = {}, files = {}, diagnostics = {} },
                bufnr
            )
        end,
    }
    return host
end

--- Write an agent's message or thought chunk to the chat, or to the
--- transcript of the subagent that sent it, and append its text to the
--- history. While that agent still runs, outside a replay, a message chunk
--- shows the prose cursor. A message chunk that opens a new response loses
--- its leading newlines, and is dropped if no text is left. A thought chunk
--- is written as sent.
--- @param update agentic.acp.AgentMessageChunk|agentic.acp.AgentThoughtChunk
--- @param source_session_id string|nil The session that sent it: the root, or a subagent's child session
function SessionManager:_on_agent_chunk(update, source_session_id)
    local is_message = update.sessionUpdate == "agent_message_chunk"
    local child_id, transcript =
        self._subagents:agent_of_chunk(update, source_session_id)
    local view = transcript and transcript.view or self.main_view
    local chunk, starts_response = update, nil
    if is_message then
        local filtered
        filtered, starts_response = view.response_boundary:filter_chunk(
            update --[[@as agentic.acp.AgentMessageChunk]]
        )
        if not filtered then
            return
        end
        chunk = filtered
    end
    if not transcript then
        -- Records already recorded go above a new response, so a reply to
        -- Stop hook feedback reads under that feedback. Work no prompt
        -- started, such as a turn a received message started, can open with
        -- thinking, which marks no response start; such work has no prompt
        -- taken in.
        local starts_thinking = false
        if not is_message then
            local message_id = Json.present(update.messageId)
            starts_thinking = message_id ~= self._thought_response_id
            self._thought_response_id = message_id
        end
        if
            not self:_replaying()
            and (starts_response or (starts_thinking and #self._taken == 0))
        then
            self:_drain_side_records()
        end
    end
    local live
    if transcript then
        -- Late chunks of an ended subagent are not live.
        live = self._subagents:is_open(child_id --[[@as string]])
    else
        live = self:_turn_open() and not self:_replaying()
    end
    view.writer:write_message_chunk(chunk, starts_response, live)
    view.tail_lines:reposition()
    if chunk.content and chunk.content.text then
        self.chat_history:append_agent_text({
            type = is_message and "agent" or "thought",
            text = chunk.content.text,
            provider_name = self.agent.provider_config.name,
            agent_key = child_id and self._subagents:agent_key(child_id),
            -- A fork is cut only after a main-agent response.
            response_id = not child_id and Json.present(update.messageId)
                or nil,
        }, starts_response)
        -- Subagent text is never written per chunk, even outside a turn
        -- (see `_on_tool_call_update`).
        if child_id then
            self:_sync_modified(self.chat_history)
        else
            self:_history_changed(self.chat_history)
        end
    end
end

--- @param update agentic.acp.SessionUpdateMessage
--- @param source_session_id string|nil The session that sent it: the root, or a subagent's child session
function SessionManager:_on_session_update(update, source_session_id)
    -- order the IF blocks in order of likeliness to be called for performance

    if update.sessionUpdate == "plan" then
        if Config.windows.todos.display then
            self.todo_list:render(update.entries)
        end
    elseif
        update.sessionUpdate == "agent_message_chunk"
        or update.sessionUpdate == "agent_thought_chunk"
    then
        self:_on_agent_chunk(update, source_session_id)
    elseif update.sessionUpdate == "subagent_update" then
        self._subagents:update(
            update,
            source_session_id --[[@as string]],
            self:_replaying()
        )
    elseif update.sessionUpdate == "session_message" then
        self._subagents:message(update, source_session_id --[[@as string]])
    elseif update.sessionUpdate == "user_message_chunk" then
        -- Arrives during session/load replay (ACPClient filters it out in
        -- normal operation). Format as a user heading and write to chat.
        -- The provider sends each content block from the original prompt as
        -- a separate event.
        local text = update.content and update.content.text
        -- A subagent's is its prompt, which its block holds.
        if
            text
            and text ~= ""
            and not self._subagents:agent_of(source_session_id, nil)
            and not self.agent:subagent_task_id(update)
            and ACPPayloads.is_prompt_text(text)
        then
            --- @type agentic.ui.ChatHistory.UserMessage
            local user_msg = {
                type = "user",
                text = text,
                timestamp = os.time(),
                provider_name = self.agent.provider_config.name,
            }
            self.message_writer:write_user_prompt(text, nil, nil, user_msg)
            self.chat_history:add_message(user_msg)
            self:_history_changed(self.chat_history)
        end
    elseif update.sessionUpdate == "available_commands_update" then
        self:_set_available_commands(update.availableCommands)
    elseif update.sessionUpdate == "current_mode_update" then
        -- only for legacy modes, not for config_options
        self.config_options.legacy_agent_modes:handle_agent_update_mode(
            update.currentModeId
        )
        self:render_info()
    elseif update.sessionUpdate == "config_option_update" then
        if source_session_id and source_session_id ~= self.session_id then
            self._subagents:set_config_options(
                source_session_id,
                update.configOptions
            )
        else
            self:_handle_new_config_options(update.configOptions)
        end
    elseif update.sessionUpdate == "usage_update" then
        self._usage = {
            used = update.used,
            size = update.size,
            -- Rate-limit-triggered updates omit cost; keep the last known value.
            cost = update.cost or (self._usage and self._usage.cost),
        }

        local windows = self.agent:budget_windows(update)
        if windows then
            Budget.record(windows, os.time())
        end

        self:_update_chat_header()
        self:render_info()
    elseif update.sessionUpdate == "session_info_update" then
        -- Provider pushes the SDK's background-generated title at turn-end.
        -- Adopt it unless the user has chosen a title via /rename.
        if update.title and update.title ~= "" and not self._title_user_set then
            self.chat_history:set_title(update.title)
            self.widget:set_chat_title(update.title)
            self:_history_changed(self.chat_history)
        end
    elseif update.sessionUpdate == "notice" then
        self:_on_notice(update)
    elseif update.sessionUpdate == "compaction_update" then
        self:_on_compaction_update(update)
    elseif update.sessionUpdate == "compaction_summary_chunk" then
        local text = vim.tbl_get(update, "content", "text")
        if text then
            self._compaction_summary = (self._compaction_summary or "") .. text
        end
    else
        -- TODO: Move this to Logger from notify to debug when confidence is high
        Logger.notify(
            "Unknown session update type: "
                .. tostring(
                    --- @diagnostic disable-next-line: undefined-field -- expected it to be unknown
                    update.sessionUpdate
                ),
            vim.log.levels.WARN,
            { title = "⚠️ Unknown session update" }
        )
    end
end

--- Write the provider's notice, its title named with the provider so it
--- cannot read as the agent's, its description folded under it.
--- @param notice agentic.acp.Notice
function SessionManager:_on_notice(notice)
    local description = Json.present(notice.description)
    self.message_writer:write_notice({
        glyph = Glyphs.PROVIDER,
        title = self.agent.provider_config.name .. ": " .. notice.title,
        fold_body = description
                and vim.split(description, "\n", { plain = true })
            or nil,
        mid_turn = self:_turn_open(),
    })
end

--- The notice titles of a compaction's end, by status.
--- @type table<string, string>
local COMPACTION_ENDS = {
    completed = "Conversation compacted",
    failed = "Compaction failed",
    cancelled = "Compaction cancelled",
}

--- Write a notice at a compaction's start, and one at its end that holds the
--- summary folded: the one the update gives, else the chunks streamed.
--- @param update agentic.acp.CompactionUpdate
function SessionManager:_on_compaction_update(update)
    local mid_turn = self:_turn_open()
    if update.status == "in_progress" then
        self._compaction_summary = nil
        self.message_writer:write_notice({
            glyph = Glyphs.COMMAND.compact,
            title = "Compacting conversation",
            mid_turn = mid_turn,
        })
        return
    end
    local summary = vim.tbl_map(function(block)
        return block.text or ""
    end, Json.present(update.summary) or {})
    local text = #summary > 0 and table.concat(summary)
        or self._compaction_summary
    self._compaction_summary = nil
    self.message_writer:write_notice({
        glyph = Glyphs.COMMAND.compact,
        title = COMPACTION_ENDS[update.status] or update.status,
        detail = Json.present(update.error),
        fold_body = text and vim.split(vim.trim(text), "\n", { plain = true })
            or nil,
        mid_turn = mid_turn,
    })
end

--- Manual refresh: reset stale generating state.
--- Workaround for when the display gets out of sync (e.g. background task
--- completion, or the prompt response callback racing with a new turn).
function SessionManager:_refresh()
    if self.is_generating then
        -- If nothing is actually streaming, the state is stale — reset it.
        -- If a turn IS active, this is harmless: the next response callback
        -- will set is_generating = false anyway.
        self:_set_generating(false)
    end
    -- A lost session/new, session/load or session/fork callback leaves its
    -- step shown.
    self.tail_lines:clear_step()

    -- Release the gate states a lost update can wedge. A turn whose `idle`
    -- never arrives, a prompt never taken in or a session/load that never
    -- completes would otherwise defer every later submit with no way back,
    -- and unwedging that is what this function is for.
    self:_reset_turn_state()
    -- The rest of a held replay would otherwise render below the file and save
    -- as duplicates. A later load adds what the dropped part held.
    if self._load_state == "holding" then
        self:_set_load_state("dropping")
    elseif self._load_state == "loading" then
        self:_set_load_state(nil)
    end
    -- A subagent the provider never reports as ended holds the chat modified.
    self._subagents:close_all({ state = "unknown" })

    -- Clear per-turn MessageWriter flags that can desynchronise the display.
    -- Cosmetic-only effect mid-turn; essential for recovering from a stuck
    -- state between turns. Subagents run outside turns, and their own ends
    -- reset their writers.
    self.message_writer:reset_turn_state()
end

--- Display context usage info locally (intercepted /context command)
function SessionManager:_display_context_usage()
    local usage = self._usage
    local body = {}
    -- The totals are the notice's title; the glyph says what they measure, so
    -- there is no label line. With no totals to show there is nothing to title
    -- the notice with either, hence the bare fallback.
    local totals = InfoPanel.context_totals(usage)
    local title = totals or "context"

    if totals then
        local cost = InfoPanel.cost(usage)
        if cost then
            table.insert(body, "- Cost: " .. cost)
        end
    else
        -- Cost stays with the totals: a spend figure under "no usage data"
        -- would contradict the line above it.
        table.insert(body, "No usage data available yet.")
    end

    self.message_writer:write_notice({
        glyph = Glyphs.COMMAND.context,
        title = title,
        body = body,
        mid_turn = self:_turn_open(),
    })
end

--- Rename the current session and update its header.
--- @param new_title string
function SessionManager:_rename_session(new_title)
    local trimmed = vim.trim(new_title)
    if trimmed == "" then
        return
    end

    self.chat_history:set_title(trimmed)
    self._title_user_set = true
    self.widget:set_chat_title(trimmed)

    self.message_writer:write_notice({
        glyph = Glyphs.COMMAND.rename,
        title = trimmed,
        mid_turn = self:_turn_open(),
    })

    self:_persist_history(self.chat_history)
end

--- Delete the current session from disk and clear the UI.
--- With confirm_delete enabled (default), prompts before proceeding.
function SessionManager:_delete_session()
    local chat_id = self.chat_history.chat_id
    if not self.chat_history.session_id then
        self.message_writer:write_message(
            ACPPayloads.generate_agent_message("No active session to delete.")
        )
        self:_finalize_turn()
        return
    end

    local function do_delete()
        local paths = ChatHistory.find_files(chat_id)
        local failures = {} --- @type string[]
        for _, path in ipairs(paths) do
            local ok, err = os.remove(path)
            if not ok then
                table.insert(failures, path .. ": " .. (err or "unknown error"))
            end
        end
        --- @type string|nil
        local problem
        if #paths == 0 then
            problem = "No saved file for this session"
        elseif #failures > 0 then
            problem = string.format(
                "removed %d of %d files; %s",
                #paths - #failures,
                #paths,
                table.concat(failures, "; ")
            )
        end
        if not problem then
            self:_cancel_session()
            -- Deleting is the one transition with no new_session after it, so
            -- nothing else supersedes the callbacks left in flight: a turn
            -- callback would write the file back, a re-auth callback would
            -- renew what the user just removed.
            self:_advance_session_epoch()
            self:_truncate_queue()
            Logger.notify(
                "Session " .. chat_id:sub(1, 8) .. " deleted.",
                vim.log.levels.INFO
            )
        else
            self.message_writer:write_message(
                ACPPayloads.generate_agent_message(
                    "Failed to delete session: " .. problem
                )
            )
            self:_finalize_turn()
        end
    end

    if Config.sessions.confirm_delete ~= false then
        local choice = vim.fn.confirm( -- no nvim_* equivalent
            "Delete session " .. chat_id:sub(1, 8) .. "?",
            "&Yes\n&No",
            2
        )
        if choice == 1 then
            do_delete()
        end
    else
        do_delete()
    end
end

--- One conversation update of a session/load replay, as its handler got it.
--- @class agentic.SessionManager.HeldUpdate
--- @field kind "on_session_update"|"on_tool_call"|"on_tool_call_update" The handler that got it
--- @field args { [1]: table, [2]: string|nil } The update and the session that sent it

--- The method each replay handler runs.
--- @type table<string, string>
local REPLAY_METHODS = {
    on_session_update = "_on_session_update",
    on_tool_call = "_on_tool_call",
    on_tool_call_update = "_on_tool_call_update",
}

--- The `sessionUpdate` values of the conversation, as opposed to provider
--- state (commands, modes, config options, usage, plan). Tool calls and their
--- updates have handlers of their own.
--- @type table<string, true>
local CONVERSATION_UPDATES = {
    user_message_chunk = true,
    agent_message_chunk = true,
    agent_thought_chunk = true,
    subagent_update = true,
    session_message = true,
    notice = true,
    compaction_update = true,
    compaction_summary_chunk = true,
}

--- Run a replay update through its handler's method.
--- @param held agentic.SessionManager.HeldUpdate
function SessionManager:_dispatch_held(held)
    self[REPLAY_METHODS[held.kind]](self, held.args[1], held.args[2])
end

--- Build the ACP client handlers table. Conversation updates of a session/load
--- replay are held or dropped instead of handled.
--- @return agentic.acp.ClientHandlers
function SessionManager:_build_handlers()
    --- @type agentic.acp.ClientHandlers
    return {
        on_session_update = function(update, source_session_id)
            if
                not (
                    CONVERSATION_UPDATES[update.sessionUpdate]
                    and self:_take_replay_update(
                        "on_session_update",
                        update,
                        source_session_id
                    )
                )
            then
                self:_on_session_update(update, source_session_id)
            end
        end,

        on_tool_call = function(tool_call, source_session_id)
            if
                not self:_take_replay_update(
                    "on_tool_call",
                    tool_call,
                    source_session_id
                )
            then
                self:_on_tool_call(tool_call, source_session_id)
            end
        end,

        on_tool_call_update = function(tool_call_update, source_session_id)
            if
                not self:_take_replay_update(
                    "on_tool_call_update",
                    tool_call_update,
                    source_session_id
                )
            then
                self:_on_tool_call_update(tool_call_update)
            end
        end,

        on_request_permission = function(request, callback)
            self:_on_request_permission(request, callback)
        end,

        on_disconnect = function()
            if not self.destroyed then
                self._subagents:close_all({ state = "idle" })
                -- No command end can arrive any more.
                self:_stop_output_tails(true)
            end
        end,

        on_usage_lifted = function()
            if not self.destroyed then
                self:_drain_queue()
            end
        end,

        on_turn_state = function(state)
            if not self.destroyed then
                self:_on_turn_state(state)
            end
        end,

        on_prompt_taken = function()
            if not self.destroyed then
                self:_on_prompt_taken()
            end
        end,
    }
end

--- Append an update to `_replay_hold` while `holding`, or drop it while
--- `dropping`.
--- @param kind "on_session_update"|"on_tool_call"|"on_tool_call_update" The handler that got it
--- @param update table
--- @param source_session_id string|nil
--- @return boolean taken False when the update is neither held nor dropped
function SessionManager:_take_replay_update(kind, update, source_session_id)
    if self._load_state == "holding" then
        table.insert(
            self._replay_hold,
            { kind = kind, args = { update, source_session_id } }
        )
        return true
    end
    return self._load_state == "dropping"
end

--- The sequence entry of one held replay update. Nil when the update makes no
--- main-chat row: a `tool_call_update`, or an update from a subagent.
--- `subagent_update` counts as a subagent's, because the bridge replays a
--- subagent under an id of its own, which no key could match.
--- @param held agentic.SessionManager.HeldUpdate
--- @return agentic.utils.SequenceTail.Entry|nil
function SessionManager:_replay_entry(held)
    local update, source_session_id = held.args[1], held.args[2]
    if held.kind == "on_tool_call_update" then
        return nil
    end
    -- Not from the subagents: no held `subagent_update` has been dispatched yet.
    if source_session_id ~= self.session_id then
        return nil
    end
    if held.kind == "on_tool_call" then
        if update.task_id then
            return nil
        end
        return { key = "tool:" .. update.tool_call_id, starts = true }
    end
    local kind = update.sessionUpdate
    if
        kind == "subagent_update"
        or self.agent:subagent_task_id(
            update --[[@as agentic.acp.SessionUpdateMessage]]
        )
    then
        return nil
    end
    if kind == "session_message" then
        return { key = "message:" .. update.messageId, starts = true }
    end
    local text = kind == "user_message_chunk"
        and vim.tbl_get(update, "content", "text")
    if text and text ~= "" and ACPPayloads.is_prompt_text(text) then
        return {
            key = "prompt:" .. text,
            starts = not self.agent:is_replay_only_prompt(text),
        }
    end
    return { starts = false }
end

--- Dispatch the part of a held session/load replay that the rendered history
--- does not hold. Warns and dispatches nothing when the replay cannot be
--- matched to the history.
---
--- An update from the tail's start on is dispatched, except a
--- `tool_call_update` of a call the tail did not dispatch: a block the history
--- rendered is never changed. Before the start, only a subagent's view of a
--- message whose main view is in the tail is dispatched.
--- @param hold agentic.SessionManager.HeldUpdate[]
function SessionManager:_dispatch_replay_tail(hold)
    local entries, held_index = {}, {}
    --- @type table<integer, true> Held indices of the main-chat updates
    local is_main = {}
    for i, held in ipairs(hold) do
        local entry = self:_replay_entry(held)
        if entry then
            table.insert(entries, entry)
            held_index[#entries] = i
            is_main[i] = true
        end
    end
    local start =
        SequenceTail.tail_start(self.chat_history:sequence_entries(), entries)
    if not start then
        Logger.notify(
            "The provider's replay of this session does not match its session file; showing the file only",
            vim.log.levels.WARN
        )
        return
    end
    local first = held_index[start] or #hold + 1

    --- @type table<string, true>
    local tail_messages = {}
    for i = first, #hold do
        local update = hold[i].args[1]
        if update.sessionUpdate == "session_message" and is_main[i] then
            tail_messages[update.messageId] = true
        end
    end
    --- @type table<string, true>
    local tail_calls = {}
    for i, held in ipairs(hold) do
        local update = held.args[1]
        if held.kind == "on_tool_call_update" then
            if tail_calls[update.tool_call_id] then
                self:_dispatch_held(held)
            end
        elseif
            i >= first
            or update.sessionUpdate == "session_message"
                and tail_messages[update.messageId]
        then
            if held.kind == "on_tool_call" then
                tail_calls[update.tool_call_id] = true
            end
            self:_dispatch_held(held)
        end
    end
end

--- Whether a tool call status is one the provider reports as the call's end.
--- @param status string|nil
--- @return boolean
local function has_ended(status)
    return status == "completed" or status == "failed"
end

--- Handle initial tool_call: write to UI, store in history.
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @param source_session_id string|nil The session that sent it: the root, or a subagent's child session
function SessionManager:_on_tool_call(tool_call, source_session_id)
    local id = tool_call.tool_call_id
    local task_id = tool_call.task_id
    local child_id =
        self._subagents:claim_tool_call(id, source_session_id, task_id)
    --- @type string|nil
    local agent_key
    if child_id then
        self._subagents:note_task(child_id, task_id)
        self._subagents:read_record(child_id)
        agent_key = self._subagents:agent_key(child_id)
    elseif not self:_turn_open() then
        -- Records already recorded go above a turn no prompt started, which
        -- can open with a tool call. Drain before taking the held fields:
        -- the drain can add to them.
        self:_drain_side_records()
    end

    local held = self._held_tool_call_updates[id]
    if held then
        self._held_tool_call_updates[id] = nil
        tool_call = vim.tbl_extend("force", tool_call, held.update) --[[@as agentic.ui.MessageWriter.ToolCallBlock]]
    end
    tool_call = self:_view_for(id):write_tool_call(
        self.chat_history,
        tool_call,
        self.permission_manager:take_causes(id),
        agent_key
    )
    if
        self._run_clocks
        and not self:_replaying()
        and not has_ended(tool_call.status)
    then
        self._run_clocks:start(id, child_id == nil)
    end
    self:_sync_job_stop(id)
    if agent_key then
        self:_sync_modified(self.chat_history)
    else
        self:_history_changed(self.chat_history)
    end

    self:_try_record_edit_range(tool_call.tool_call_id)
    self:_record_file_op(tool_call.tool_call_id)

    -- A call can be first reported already ended; see `_on_tool_call_update`.
    if has_ended(tool_call.status) then
        self:_drain_side_records_of(child_id)
    end
end

--- Show what decided a tool call's permission on its block and in the history,
--- and take the causes from the permission manager once shown. No-op once the
--- session is destroyed.
--- @param tool_call_id string
--- @param causes agentic.PermissionCause[]
function SessionManager:_on_permission_decided(tool_call_id, causes)
    if self.destroyed then
        return
    end
    local view = self:_view_for(tool_call_id)
    if view:show_causes(self.chat_history, tool_call_id, causes) then
        self.permission_manager:take_causes(tool_call_id)
        self:_history_changed(self.chat_history)
    end
end

--- Capture the pre-edit line position for an Edit, using the accumulated
--- MessageWriter tracker. The base ACPClient builder does not forward
--- `diff` on the initial `tool_call` notification; Claude's adapter
--- populates `diff` only on the tool_call_update path. We therefore try
--- to record from BOTH `_on_tool_call` and `_on_tool_call_update`, and
--- use the merged tracker state instead of the partial update.
---
--- Idempotent (skips if already pending/finalized). Skips completed tool
--- calls — disk is post-edit at that point and `diff.old` no longer
--- matches. Skips the session/load replay for the same reason: the bridge
--- replays each past Edit as `pending`, but disk already holds the edit, so
--- `diff.old` is either gone or found at a post-edit position.
---
--- The range is recorded here, not searched for at grant-check time. Claude's
--- Edit tool sends no line numbers, the bridge flattens `rawOutput` to a
--- success string (dropping the SDK's `structuredPatch`), and a check-time
--- search for `diff.new` is ambiguous for short replacements such as `}`,
--- `end` or a blank line.
--- @param tool_call_id string
function SessionManager:_try_record_edit_range(tool_call_id)
    if not tool_call_id or self:_replaying() then
        return
    end
    if self.permission_manager:has_edit_range(tool_call_id) then
        return
    end
    local tracker =
        self:_view_for(tool_call_id).writer.tool_call_blocks[tool_call_id]
    if not tracker or AcpKind.normalise(tracker.kind) ~= "edit" then
        return
    end
    if tracker.status == "completed" or tracker.status == "failed" then
        return
    end
    local diff = tracker.diff
    if not diff or diff.all then
        return
    end
    local old_lines = diff.old
    local new_lines = diff.new
    if not old_lines or #old_lines == 0 or not new_lines then
        return
    end
    if not tracker.argument then
        return
    end
    -- Resolved: `PermissionManager:_kind_args` reads an edited file's state,
    -- and looks up its edit records, by the resolved path.
    local path = GrantSafety.resolve(vim.fn.fnamemodify(tracker.argument, ":p"))
    if not path then
        return
    end
    local file_lines, err = FileSystem.read_from_disk(path)
    if not file_lines then
        Logger.debug("grant: pre-edit read failed for", path, err)
        return
    end
    local start_line =
        GrantSafety.find_unique_subsequence(file_lines, old_lines)
    if not start_line then
        return
    end
    self.permission_manager:record_pending_edit(
        tool_call_id,
        path,
        start_line,
        new_lines
    )
end

--- Append a completed file mutation to the session's activity tally.
---
--- Called from both tool-call handlers, like `_try_record_edit_range`, and
--- self-gating so neither site needs to know when a mutation is final. Reads
--- the accumulated `MessageWriter` tracker rather than the update that
--- triggered it: `argument` arrives on an early update and is absent from the
--- `completed` one.
---
--- An `execute` call is recorded by `_record_shell_ops`. Of the edit family,
--- only `completed` is recorded. `failed` covers a rejected permission prompt,
--- where nothing reached disk.
---
--- `file_created` comes from the provider's post-tool response and is the exact
--- answer, but it is a separate notification — when it has not arrived, fall
--- back to the shape of the diff. An empty `old` side means the tool had no
--- prior content to replace, which is true of every creation and of no edit.
--- The one case that misreports is a whole-file write over an existing file.
--- @param tool_call_id string
function SessionManager:_record_file_op(tool_call_id)
    if not tool_call_id or not Config.windows.activity.display then
        return
    end
    local tracker =
        self:_view_for(tool_call_id).writer.tool_call_blocks[tool_call_id]
    if not tracker then
        return
    end
    local kind = AcpKind.normalise(tracker.kind)
    if kind == "execute" then
        self:_record_shell_ops(tool_call_id, tracker)
        return
    end
    if tracker.status ~= "completed" or not FILE_MUTATING_KINDS[kind] then
        return
    end
    if not tracker.argument or tracker.argument == "" then
        return
    end

    local created = tracker.file_created
    if created == nil then
        created = #((tracker.diff and tracker.diff.old) or {}) == 0
    end

    --- @type agentic.ui.FileActivity.OpClass
    local op = "edit"
    if kind == "delete" then
        op = "delete"
    elseif created then
        op = "create"
    end

    self.file_activity:record({
        tool_call_id = tool_call_id,
        path = tracker.argument,
        op = op,
        ranges = tracker.hunk_ranges,
    })
end

--- Append the files a shell command's text writes or deletes to the activity
--- tally, marked `parsed`.
---
--- Recorded once the command ran (`CanonicalToolCall.ran`). A relative path is
--- dropped when the call's start directory is unknown.
--- @param tool_call_id string
--- @param tracker agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_record_shell_ops(tool_call_id, tracker)
    if
        not CanonicalToolCall.ran(tracker)
        or not tracker.argument
        or tracker.argument == ""
    then
        return
    end

    local effects = ShellParse.file_effects(
        tracker.argument,
        self.permission_manager:bash_cwd(tool_call_id)
    )
    for _, effect in ipairs(effects) do
        self.file_activity:record({
            tool_call_id = tool_call_id,
            path = effect.path,
            op = effect.kind == "delete" and "delete" or "edit",
            source = "parsed",
        })
    end
end

--- Show or hide the changed-files panel. Opening reconciles the rows against
--- disk first (rendering what is already known, then correcting when the git
--- probe returns); closing marks every row seen, clearing the unseen dots.
function SessionManager:toggle_file_activity()
    if not Config.windows.activity.display then
        Logger.notify(
            "File activity tracking is disabled (windows.activity.display).",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return
    end

    self.widget:toggle_panel("activity", function()
        self.file_activity:reconcile(function()
            self.widget:resize_panel("activity")
        end)
    end, function()
        self.file_activity:mark_viewed()
        -- Persist immediately rather than waiting for the next turn to save.
        -- The marker's whole point is surviving a quit-and-resume, and quitting
        -- straight after looking at the panel is the ordinary case.
        self:_persist_history(self.chat_history)
    end)
end

--- The session's current agent, account and context usage, with the account
--- budget from `vim.g.agentic_budget`.
--- @return agentic.ui.InfoPanel.Snapshot
function SessionManager:_info_snapshot()
    local options = self.config_options
    local model_id = options:current_model_id()
    local mode_id = options:current_mode_id()
    --- @type agentic.ui.InfoPanel.Snapshot
    local snap = {
        provider = self.agent.provider_config.name,
        model = model_id and (options:model_display(model_id)),
        mode = mode_id and options:get_mode_name(mode_id),
        thought_level = options:current_thought_level_label(),
        name = self._name,
        auth = self.agent.auth_status,
        usage = self._usage,
        budget = vim.g.agentic_budget,
    }
    return snap
end

--- Render the info panel's buffer, and fit its window when it is open.
--- No-op once the widget is destroyed.
function SessionManager:render_info()
    local info = self.widget:panel_buf("info")
    if not info then
        return
    end
    InfoPanel.render(info, self:_info_snapshot(), os.time())
    self.widget:resize_panel("info")
end

--- Show the provider's current name for the session: a notice when it changes
--- to a name, and the info panel on any change.
function SessionManager:_refresh_name()
    if self.destroyed or not self.session_id then
        return
    end
    local name = self.agent:name(self.session_id)
    if name == self._name then
        return
    end
    self._name = name
    if name then
        self.message_writer:write_notice({
            glyph = Glyphs.COMMAND.agents,
            title = name,
            mid_turn = self:_turn_open(),
        })
    end
    self:render_info()
end

--- Show or hide the info panel.
function SessionManager:toggle_info()
    self.widget:toggle_panel("info", function()
        self:render_info()
    end)
end

--- Render the agents panel from the subagents' entries: closed without one,
--- else fitted when open.
function SessionManager:render_agents()
    local entries = self._subagents:entries()
    self.agents_panel:render(entries)
    if #entries == 0 then
        self.widget:close_panel("agents")
    else
        self.widget:resize_panel("agents")
    end
end

--- Show or hide the agents panel. Notifies, and opens nothing, without a
--- subagent to list.
function SessionManager:toggle_agents()
    if
        not self.widget:panel_win("agents")
        and #self._subagents:entries() == 0
    then
        Logger.notify(
            "No subagents to list.",
            vim.log.levels.INFO,
            { title = "Agentic" }
        )
        return
    end
    self.widget:toggle_panel("agents", function()
        self:render_agents()
    end)
end

local PLAN_IMPLEMENT_ID = "__plan_implement__"

--- Queue a permission request with the permission manager. When the request
--- waits for the user (not auto-approved), signal attention and fire the
--- `on_permission_request` hook.
--- For a tool call marked `exits_plan`, injects a "Clear context & implement plan"
--- option that accepts the plan, cancels the session, and starts a fresh
--- session with the plan file as the initial prompt.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function SessionManager:_on_request_permission(request, callback)
    local tool_call_id = request.toolCall.toolCallId
    -- A subagent's request can come before its call, which is then the
    -- agent's too.
    self._subagents:claim_tool_call(tool_call_id, request.sessionId, nil)

    local tracker =
        self:_view_for(tool_call_id).writer.tool_call_blocks[tool_call_id]
    if tracker and tracker.exits_plan then
        -- Sorts first (priority 0 in PermissionManager).
        table.insert(request.options, {
            kind = "plan_implement",
            name = "Clear context & implement plan",
            optionId = PLAN_IMPLEMENT_ID,
        })
    end

    local function wrapped_callback(option_id)
        -- Handle the custom plan-implement option: accept the plan with
        -- the provider, then cancel and start a fresh implementation session.
        if option_id == PLAN_IMPLEMENT_ID then
            local accept_id
            for _, opt in ipairs(request.options) do
                if AcpKind.normalise(opt.kind) == "allow_once" then
                    accept_id = opt.optionId
                    break
                end
            end
            callback(accept_id)

            -- Before `new_session`, whose cancel clears `_last_edited_md`
            local plan_path = self.agent:plan_file(request)
                or self._last_edited_md

            -- Defer to avoid re-entrancy with PermissionManager cleanup
            vim.schedule(function()
                self:new_session({
                    keep_cwd = true,
                    on_created = function()
                        if plan_path then
                            self:_handle_input_submit(
                                "Initiate work on plan: " .. plan_path
                            )
                        end
                    end,
                })
            end)
            return
        end

        -- The tool runs from the answer on.
        local kind = PermissionOptions.option_kind(request.options, option_id)
        if
            self._run_clocks
            and (kind == "allow_once" or kind == "allow_always")
        then
            self._run_clocks:restart(tool_call_id)
        end
        callback(option_id)
    end

    -- add_request must run first and unconditionally: if it never runs, the
    -- ACP permission callback is lost and the provider waits forever, locking
    -- the session. It resolves auto-approvals synchronously and reports whether
    -- an interactive prompt was queued — only then do we ring the bell / fire
    -- the hook, so auto-approved requests stay silent.
    local prompted =
        self.permission_manager:add_request(request, wrapped_callback)

    if prompted then
        if self._run_clocks then
            self._run_clocks:wait(tool_call_id)
            self:_refresh_status(tool_call_id)
        end

        -- Notifications and hooks are non-essential UI; a throw here must not
        -- escape (add_request has already run, so the callback is safe).
        local ok, err = pcall(function()
            -- A hidden float is signalled by `_on_permission_hidden`.
            if
                self.permission_manager.permission_float:is_visible_in_current_tab()
            then
                self:_notify_attention(false)
            end

            P.invoke_hook("on_permission_request", {
                session_id = self.session_id,
                tool_call_id = tool_call_id,
            })
        end)

        if not ok then
            Logger.notify(
                "Error setting up permission UI: " .. tostring(err),
                vim.log.levels.WARN
            )
        end
    end
end

--- Handle the side records recorded since the last drain, in order: add tool
--- call fields to their calls, write received messages, and write the other
--- records to the chat buffer. Each run of the other records between two
--- received messages is kept in the history as one message. A record naming
--- a call that delegated to a subagent goes under the subagent's block.
function SessionManager:_drain_side_records()
    if self.destroyed or not self.session_id then
        return
    end
    -- A subagent's record links its call to it, and may not have existed when
    -- the subagent was announced.
    self._subagents:read_records()
    --- @type agentic.acp.SideRecord[]
    local placed = {}
    local stored = false
    local function store_placed()
        if #placed == 0 then
            return
        end
        SideRecords.write(self.message_writer, placed)
        self.chat_history:add_message({
            type = "side_records",
            records = placed,
        })
        placed = {}
        stored = true
    end
    for _, side in ipairs(self.agent:drain_side_records(self.session_id)) do
        if side.kind == "tool_call" then
            self:_apply_side_tool_call(side.tool_call)
        elseif side.kind == "received_message" then
            -- A replay writes history messages in order, so the records
            -- before the message are stored before its row.
            store_placed()
            self._subagents:write_received_message(side.received_message)
        else
            local anchor = side[side.kind] --[[@as agentic.acp.Anchor]]
            anchor.tool_call_id = self:_block_id(anchor.tool_call_id)
            table.insert(placed, side)
        end
    end
    store_placed()
    if stored then
        self:_history_changed(self.chat_history)
    end
end

--- Add the tool call fields a subagent's side records give to its calls.
--- Its hook activity and loaded files are not shown.
--- @param child_id string
function SessionManager:_drain_subagent_side_records(child_id)
    if self.destroyed or not self.session_id then
        return
    end
    local sides = self.agent:drain_side_records(self.session_id, child_id)
    for _, side in ipairs(sides) do
        if side.kind == "tool_call" then
            self:_apply_side_tool_call(side.tool_call, child_id)
        end
    end
end

--- Drain an agent's side records.
--- @param child_id string|nil The subagent, nil for the main agent
function SessionManager:_drain_side_records_of(child_id)
    if child_id then
        self:_drain_subagent_side_records(child_id)
    else
        self:_drain_side_records()
    end
end

--- Add fields a side record gave a tool call to its block and its history
--- record, or hold them until the call is reported: a provider can record a
--- call before reporting it.
--- @param update agentic.ui.MessageWriter.ToolCallBase
--- @param child_id string|nil The subagent whose records gave the fields, nil for the main agent's
function SessionManager:_apply_side_tool_call(update, child_id)
    local id = update.tool_call_id
    local writer = self:_view_for(id).writer
    if not writer.tool_call_blocks[id] then
        self._held_tool_call_updates[id] =
            { update = update, child_id = child_id }
        return
    end
    AgentView.merge_tool_call_fields(writer, self.chat_history, update)
    self:_history_changed(self.chat_history)
end

--- End every tool call in the chat left open by a turn that ended unfinished
--- `failed`, with the turn's end word. A subagent's calls are left alone: the
--- subagent can outlive the turn that started it.
---
--- Whether the provider sends a late update for a call it abandoned is
--- provider-dependent, so without this sweep such a block keeps its pending
--- footer for the rest of the session, and after a resume too.
--- @param word string How the turn ended, a `CanonicalToolCall.stop_reason_word`
function SessionManager:_end_open_tool_calls(word)
    -- Not through `_on_tool_call_update`: that would also re-record edit
    -- ranges.
    self.chat_history:update_tool_calls(
        self.message_writer:stamp_open_calls(word, "failed")
    )
end

--- Close out a turn dispatched to the agent: end it in the chat buffer, stamp
--- its usage footer, then write the side records it produced. The single
--- chokepoint for those three — client-side notices end their own turn through
--- `MessageWriter:write_notice`, having dispatched nothing.
--- @param usage { inputTokens?: number, outputTokens?: number }|nil
function SessionManager:_finalize_turn(usage)
    self.message_writer:finalize_turn()
    self.message_writer:set_turn_usage(usage)
    -- Last of the three: a region appended before the footer would move the row
    -- the footer is stamped on, and this drain still appends the remaining
    -- records that have no anchor in the buffer. Where an appended region falls
    -- relative to the prose run does not matter; `_append_collapsed_region`
    -- brackets the run it ends.
    self:_drain_side_records()
    -- A call not reported by the turn's end never will be.
    drop_held(self._held_tool_call_updates, nil)
end

--- Apply a tool call update to its chat block, the chat history and the
--- pending permission requests. When a file-mutating call completes, reload
--- changed buffers (debounced).
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBase
function SessionManager:_on_tool_call_update(tool_call_update)
    local id = tool_call_update.tool_call_id
    local child_id = self._subagents:owner_of(id)
    local is_subagent = child_id ~= nil
    if child_id then
        self._subagents:read_record(child_id)
    end
    local view = self:_view_for(id)
    local writer = view.writer
    tool_call_update =
        view:update_tool_call(self.chat_history, tool_call_update)
    self:_try_record_edit_range(id)
    self:_record_file_op(id)
    self:_sync_job_stop(id)
    -- A subagent can outlive its turn, so outside a turn its output is written
    -- as each of its calls ends, not per update.
    if is_subagent and not has_ended(tool_call_update.status) then
        self:_sync_modified(self.chat_history)
    else
        self:_history_changed(self.chat_history)
    end

    -- Remove the permission request if the tool call failed before user granted it
    if tool_call_update.status == "failed" then
        self.permission_manager:remove_request_by_tool_call_id(id)
        self.permission_manager:drop_pending_edit(id)
    end

    if tool_call_update.status == "completed" then
        self.permission_manager:finalize_edit_range(id)
    end

    if has_ended(tool_call_update.status) then
        self.permission_manager:drop_bash_cwd(id)
    end

    -- Debounce: rapid tool_call_update completions (e.g. hook retry cycles)
    -- coalesce into a single deferred checktime() to avoid cascading
    -- autocmds (FileChangedShell → BufReadPost → LSP → treesitter) that
    -- can overwhelm the event loop and crash neovim.
    if tool_call_update.status == "completed" then
        local tracker = writer.tool_call_blocks[id]
        local mutates_file = tracker ~= nil
            and FILE_MUTATING_KINDS[AcpKind.normalise(tracker.kind)] == true
        if mutates_file then
            if not self._checktime_scheduled then
                self._checktime_scheduled = true
                vim.schedule(function()
                    self._checktime_scheduled = false
                    if not self.destroyed then
                        vim.cmd.checktime()
                    end
                end)
            end
        end

        -- Track the most recently edited/written .md file as plan candidate.
        -- The last .md mutation before a Plan→Normal switch is the plan file.
        -- Use tracker.argument (accumulated from all updates) — the completed
        -- update itself rarely carries the argument field.
        if
            mutates_file
            and tracker.argument
            and tracker.argument:match("%.md$")
        then
            self._last_edited_md = tracker.argument
        end
    end

    -- Look for records as soon as the call they fired on ends, rather than
    -- waiting for the turn-end drain — where they land is settled by the
    -- anchor each record carries, not by when the drain runs.
    if has_ended(tool_call_update.status) then
        self:_drain_side_records_of(child_id)
    end

    self:_sync_output_tail(id)
end

--- Follow the output file of a tool call's block while its command runs, and
--- show its last rows once the command has ended. Does nothing for a block
--- without an output file.
--- @param tool_call_id string
function SessionManager:_sync_output_tail(tool_call_id)
    local writer = self:_view_for(tool_call_id).writer
    local block = writer.tool_call_blocks[tool_call_id]
    local path = block and block.output_file
    if not path then
        return
    end

    local tail = self._output_tails[tool_call_id]
    if block.output_ended then
        if tail then
            tail:stop()
            self._output_tails[tool_call_id] = nil
        end
        -- Once shown as final, later updates leave the rows alone.
        if block.output_live ~= false then
            self:_show_final_tail(tool_call_id)
        end
        return
    end
    if tail then
        return
    end

    local err
    tail, err = FileTail:new(
        path,
        Config.tool_call_display.background_tail_lines,
        function(rows)
            -- A wiped or unloaded transcript keeps its writer's trackers.
            if
                not self.destroyed
                and vim.api.nvim_buf_is_loaded(writer.bufnr)
                and writer.tool_call_blocks[tool_call_id]
            then
                writer:set_output_tail(tool_call_id, rows, true)
            end
        end
    )
    if not tail then
        Logger.notify("Agentic: cannot follow " .. path .. ": " .. err)
        self:_show_final_tail(tool_call_id)
        return
    end
    self._output_tails[tool_call_id] = tail
end

--- Show the last rows of a tool call's output file as no longer followed. A
--- missing file gives no rows and no warning: the provider may have removed it.
--- @param tool_call_id string
function SessionManager:_show_final_tail(tool_call_id)
    local writer = self:_view_for(tool_call_id).writer
    local block = writer.tool_call_blocks[tool_call_id]
    if not (block and block.output_file) then
        return
    end
    local rows = FileSystem.read_last_lines(
        block.output_file,
        Config.tool_call_display.background_tail_lines
    )
    writer:set_output_tail(tool_call_id, rows or {}, false)
end

--- Stop following every output file.
--- @param final boolean Show each file's last rows as no longer followed
function SessionManager:_stop_output_tails(final)
    local tails = self._output_tails
    self._output_tails = {}
    for tool_call_id, tail in pairs(tails) do
        tail:stop()
        if final then
            self:_show_final_tail(tool_call_id)
        end
    end
end

--- Send the newly selected mode to the agent and handle the response
--- @param mode_id string
--- @param is_legacy boolean|nil
--- @param opts agentic.acp.AgentConfigOptions.ChangeOpts|nil `as_notice` is
---   set by the mode picker. Without it the change is silent, since the
---   configured `default_mode` at session start arrives through this same
---   callback and is not a user switch.
function SessionManager:_handle_mode_change(mode_id, is_legacy, opts)
    self:_set_session_option("mode", mode_id, is_legacy, function()
        if is_legacy then
            self.config_options.legacy_agent_modes.current_mode_id = mode_id
        end
        if opts and opts.as_notice then
            self:_notice_mode_switched(mode_id)
        end
    end)
end

--- Send the newly selected model to the agent
--- @param model_id string
--- @param is_legacy boolean|nil
--- @param opts agentic.acp.AgentConfigOptions.ChangeOpts|nil `as_notice` renders the announce as
---   a command notice instead of prose. Set by the model picker; the render
---   style cannot be inferred from the call site, since the queued-initial-model
---   flush (resume, `/new`, `/clear`) arrives through this same callback and is
---   not a user switch.
function SessionManager:_handle_model_change(model_id, is_legacy, opts)
    self:_set_session_option("model", model_id, is_legacy, function()
        if is_legacy then
            self.config_options.legacy_agent_models.current_model_id = model_id
        end
        if opts and opts.as_notice then
            self:_notice_model_switched(model_id)
        else
            self:announce_model_loaded(model_id)
        end
    end)
end

--- Set the session's thought level on the agent.
--- @param value string
--- @param opts agentic.acp.AgentConfigOptions.ChangeOpts|nil
function SessionManager:_handle_thought_level_change(value, opts)
    self:_set_session_option("thought_level", value, false, function()
        if opts and opts.as_notice then
            self:_notice_thought_level_switched(value)
        end
    end)
end

--- Set the session's mode, model or thought level on the provider. On
--- success, apply the config options the provider returns, then call
--- `on_set`. On failure, notify. A no-op without a session.
--- @param category "mode"|"model"|"thought_level"
--- @param value_id string
--- @param is_legacy boolean|nil Send `session/set_mode` or `session/set_model` instead of `session/set_config_option`
--- @param on_set fun()
function SessionManager:_set_session_option(
    category,
    value_id,
    is_legacy,
    on_set
)
    if not self.session_id then
        return
    end

    --- @param reason string
    local function notify_failure(reason)
        Logger.notify(
            string.format(
                "Failed to change %s to '%s': %s",
                category,
                value_id,
                reason
            ),
            vim.log.levels.ERROR
        )
    end

    local function callback(result, err)
        -- Destroyed while the request was in flight: its buffers are gone.
        if self.destroyed then
            return
        end
        if err then
            notify_failure(err.message)
            return
        end
        if result and result.configOptions then
            Logger.debug("received result after setting " .. category)
            self:_handle_new_config_options(result.configOptions)
        end
        on_set()
        self:render_info()
    end

    if not is_legacy then
        -- A picker stays open across option updates, which can drop the option.
        local option = self.config_options[category]
        if not option then
            notify_failure("option no longer offered")
            return
        end
        self.agent:set_config_option(
            self.session_id,
            option.id,
            value_id,
            callback
        )
    elseif category == "mode" then
        self.agent:set_mode(self.session_id, value_id, callback)
    else
        self.agent:set_model(self.session_id, value_id, callback)
    end
end

function SessionManager:_update_chat_header()
    -- Used-token count, not %: performance degrades near a fixed ~200k
    -- threshold regardless of the model's advertised window, so the absolute
    -- number is what matters. Full ratio + % stays in the /context panel.
    local context = nil
    if self._usage and self._usage.size > 0 then
        local used_k = math.floor(self._usage.used / 1000 + 0.5)
        context = string.format("%dk", used_k)
    end
    self.widget:render_header("agent", context)
end

--- Announce in the chat that `model_id` runs from here on
--- (`AgentView:announce_model`).
---
--- Prose rather than a notice because it marks the model a session starts or
--- resumes on, under the `#` welcome header or after a replay. An explicit
--- switch renders as a notice instead (`_notice_model_switched`).
--- @param model_id string|nil
function SessionManager:announce_model_loaded(model_id)
    self.main_view:announce_model(self.config_options, model_id)
end

--- Announce the current model at the end of the chat, then switch the session
--- to `model_id`.
---
--- The switch announces `model_id` only once it succeeds; a turn sent before
--- then runs on the current model. A `model_id` the provider does not offer
--- keeps the current model and warns. Before any model options arrive,
--- `model_id` is queued until they do.
--- @param model_id string|nil nil keeps the current model
function SessionManager:_reapply_model(model_id)
    local options = self.config_options
    local current_model_id = options:current_model_id()
    self:announce_model_loaded(current_model_id)
    if not model_id then
        return
    end

    if current_model_id and not options:has_model(model_id) then
        Logger.notify(
            string.format(
                "Saved model '%s' not offered by the provider. Using '%s'",
                model_id,
                current_model_id
            ),
            vim.log.levels.WARN
        )
        return
    end
    options:set_pending_initial_model(model_id)
end

--- Announce a model the user just switched to, as a command notice.
--- @param model_id string|nil
function SessionManager:_notice_model_switched(model_id)
    if not model_id then
        return
    end

    local options = self.config_options
    local name, description = options:model_display(model_id)

    --- @type string[]|nil
    local body
    if description and description ~= "" then
        body = { description }
    end

    self.message_writer:write_notice({
        glyph = Glyphs.COMMAND.model,
        title = options:model_title(name, model_id),
        body = body,
        mid_turn = self:_turn_open(),
    })
end

--- Announce a mode the user just switched to, as a command notice. Signed
--- with the `switch_mode` tool glyph: the agent leaving plan mode is the same
--- act, and the sign colour already tells whose row it is.
--- @param mode_id string
function SessionManager:_notice_mode_switched(mode_id)
    local mode = self.config_options:get_mode(mode_id)
        or self.config_options.legacy_agent_modes:get_mode(mode_id)

    --- @type string[]|nil
    local body
    if mode and mode.description and mode.description ~= "" then
        body = { mode.description }
    end

    self.message_writer:write_notice({
        glyph = Glyphs.KIND.switch_mode,
        title = mode and mode.name or mode_id,
        body = body,
        mid_turn = self:_turn_open(),
    })
end

--- Announce a thought level the user just switched to, as a command notice.
--- @param value string Level id, the title when the level has no label
function SessionManager:_notice_thought_level_switched(value)
    self.message_writer:write_notice({
        glyph = Glyphs.COMMAND.effort,
        title = self.config_options:current_thought_level_label() or value,
        mid_turn = self:_turn_open(),
    })
end

--- `/new` and `/clear`: start a fresh session, named `arg` unless empty.
--- @param arg string
function SessionManager:_command_new(arg)
    -- Resetting locally avoids a race: the agent might not send an
    -- identifiable response to act on. /clear through ACP doesn't
    -- actually reset provider context, so it is handled as /new.
    local on_created
    if arg ~= "" then
        -- An argument names the fresh session, as /rename names the
        -- current one.
        on_created = function()
            self:_rename_session(arg)
        end
    end
    self:new_session({ on_created = on_created })
end

--- `/rename`: rename the session to `arg`, or show the usage when empty.
--- @param arg string
function SessionManager:_command_rename(arg)
    if arg == "" then
        self.message_writer:write_message(
            ACPPayloads.generate_agent_message("Usage: `/rename <new name>`")
        )
        self:_finalize_turn()
        return
    end
    self:_rename_session(arg)
end

--- `/grant`. See `GrantCommand:run`.
--- @param arg string
--- @param on_done fun()|nil
function SessionManager:_command_grant(arg, on_done)
    self._grant_command:run(arg, on_done)
end

--- `/login`. See `Recovery.login`.
--- @param arg string
--- @param on_done fun()|nil
function SessionManager:_command_login(arg, on_done)
    Recovery.login(self, arg, on_done --[[@as fun()]])
end

--- Commands answered entirely in the client, with no provider round-trip.
---
--- Keyed by the exact command word, which carries the word boundary
--- structurally instead of each entry re-anchoring it: `/newsflash` and
--- `/new/data/f.csv` are prose because neither yields the word `new`.
---
--- `takes_arg = false` rejects any argument, so `/context foo` reaches the
--- provider as prose. For the rest, the command's method decides what an
--- empty argument means.
---
--- `async` means the command can return with a dialog still open, so the
--- sequencer must wait for its `on_done` before dispatching the next block
--- rather than reading the gate — which is clear, the command needing no
--- provider round-trip.
---
--- `session_ending` marks the commands that end the current session, so
--- running one on text the user did not mean as a command destroys work.
--- Pasted notes, changelogs and transcripts quote them as examples — this
--- repo's own `TODO.md` and `doc/agentic.txt` do. See
--- `_confirm_queued_command`.
---
--- `method` names the `SessionManager` method that runs the command, called
--- with the argument ("" for none) and the `async` commands' `on_done`.
--- @type table<string, { takes_arg: boolean, async: boolean, session_ending: boolean, method: string }>
local LOCAL_COMMANDS = {
    new = {
        takes_arg = true,
        async = false,
        session_ending = true,
        method = "_command_new",
    },
    clear = {
        takes_arg = true,
        async = false,
        session_ending = true,
        method = "_command_new",
    },
    -- ACP providers don't emit context info over the protocol, so this
    -- shows the last known usage_update locally.
    context = {
        takes_arg = false,
        async = false,
        session_ending = false,
        method = "_display_context_usage",
    },
    rename = {
        takes_arg = true,
        async = false,
        session_ending = false,
        method = "_command_rename",
    },
    grant = {
        takes_arg = true,
        async = true,
        session_ending = false,
        method = "_command_grant",
    },
    login = {
        takes_arg = true,
        async = true,
        session_ending = false,
        method = "_command_login",
    },
    delete = {
        takes_arg = false,
        async = false,
        session_ending = true,
        method = "_delete_session",
    },
}

--- Read a block's text as a local command word and its argument, or nil when
--- it is not one of them.
---
--- The line shape (and with it the fact that an argument never spans lines) is
--- `PromptBlocks.command`'s, shared with the splitter and the chat highlight.
--- @param text string
--- @return string|nil word
--- @return string arg Empty when the command took none
local function parse_local_command(text)
    local word, arg = PromptBlocks.command(text)
    if not word then
        return nil, ""
    end
    local spec = LOCAL_COMMANDS[word]
    if not spec then
        return nil, ""
    end
    if arg ~= "" and not spec.takes_arg then
        return nil, ""
    end
    return word, arg
end

--- Run a local command parsed out by `parse_local_command`.
--- @param word string A key of LOCAL_COMMANDS
--- @param arg string
--- @param on_done? fun() Called by the `async` commands when their dialog
---   resolves. The rest are finished when this returns.
function SessionManager:_run_local_command(word, arg, on_done)
    self[LOCAL_COMMANDS[word].method](self, arg, on_done)
end

--- Add a synchronous local slash command, which ends no session, and its
--- completion item.
--- @param name string Command word without the leading `/`
--- @param spec { takes_arg: boolean, description: string, run: fun(session: agentic.SessionManager, arg: string|nil) } `run` gets nil for no argument
function SessionManager.register_local_command(name, spec)
    local method = "_command_" .. name
    SessionManager[method] = function(self, arg)
        spec.run(self, arg ~= "" and arg or nil)
    end
    LOCAL_COMMANDS[name] = {
        takes_arg = spec.takes_arg,
        async = false,
        session_ending = false,
        method = method,
    }
    SlashCommands.register_builtin(name, spec.description)
end

--- @alias agentic.SubmitDeferReason "usage_limited"|"in_flight"|"loading"|"not_ready"

--- How a turn returned its prompt to the user: the model refused it, the
--- provider's usage limit turned it away before it produced anything, or the
--- agent never took it in.
--- @alias agentic.ReturnReason "refusal"|"usage_limit"|"untaken"

--- Called when a turn returns its prompt. `held`, for `"usage_limit"`: the
--- limit still holds and a lift will drain the queue.
--- @alias agentic.OnReturned fun(reason: agentic.ReturnReason, held: boolean|nil)

--- The defer reasons that hold a prompt the user sends, each as a phrase.
--- `in_flight` and `usage_limited` hold only the queue's automatic drain:
--- the provider runs a mid-turn prompt as its next turn, and the provider,
--- not the plugin's view of the limit, decides whether the limit still holds.
--- @type table<agentic.SubmitDeferReason, string>
local SUBMIT_HOLDS = {
    loading = "the session is still loading",
    not_ready = "no session yet",
}

--- Why `prompt` cannot go out as a turn of its own right now, or nil if it can.
---
--- `loading` and `not_ready` mean the session cannot take a prompt at all.
--- They come first, so a caller that ignores the other reasons still holds
--- for them. `in_flight` sequences automatic sends one block per turn.
--- `usage_limited` holds them until the usage limit's timer fires.
---
--- Local commands are never deferred — they need no provider round-trip, so
--- they answer mid-turn and before a session exists, which is what makes
--- `/new` and `/delete` usable to recover a wedged one.
--- @param prompt string
--- @return agentic.SubmitDeferReason|nil
function SessionManager:_submit_defer_reason(prompt)
    if parse_local_command(prompt) then
        return nil
    end
    local busy = self:_busy_reason()
    if busy then
        return busy
    end
    if self.agent.usage_limit:holds_drain() then
        return "usage_limited"
    end
    return nil
end

--- Why the session cannot take a turn of its own right now, or nil if it
--- can: `loading` while a session/load replays, `not_ready` without a
--- session or a ready agent, `in_flight` while the agent works or holds a
--- prompt not yet taken in.
--- @return "loading"|"not_ready"|"in_flight"|nil
function SessionManager:_busy_reason()
    -- session_id is assigned before the session/load RPC, so the readiness
    -- check below reads clear while a session is still being replayed.
    if self:_replaying() then
        return "loading"
    end
    if not (self.session_id and self.agent and self.agent.state == "ready") then
        return "not_ready"
    end
    -- Not is_generating: stop_generation clears that flag before the turn
    -- ends, so a drain gated on it would dispatch into a turn that is still
    -- resolving — and the drain is what keeps one queued block per turn.
    if self:_in_flight() then
        return "in_flight"
    end
    return nil
end

--- Answer a prompt the user submitted: their attention is back on the chat, so
--- the header's idle state clears, last turn's finished todo panel closes, and
--- every chat window in user control follows again. Call it from the user's
--- submit, never from the dispatch path: the automatic queue drains reach that
--- too, and one of them would clear the idle state in the tick it was set, or
--- jump a reader to the bottom.
function SessionManager:on_user_submit()
    self.widget:set_idle(false)
    self.todo_list:close_if_all_completed()
    self.message_writer:resume_follow()
end

--- @class agentic.SessionManager.SubmitOpts
--- @field from_buffer? boolean The caller owns a buffer range and tags it when the submit defers

--- Items of the context panels.
--- @class agentic.SessionManager.PanelContext
--- @field selections agentic.Selection[]
--- @field files string[]
--- @field diagnostics agentic.ui.DiagnosticsList.Diagnostic[]

--- Dispatch a submitted prompt, or report that the gate deferred it.
---
--- A running turn is not a reason to hold a submit. The provider takes a
--- mid-turn prompt as a turn of its own and runs it after the current one
--- (claude-agent-acp queues it on `session.turnQueue`), so the text goes out
--- now and the running turn is the user's to interrupt with `<C-c>`.
---
--- A deferred submit stays in the input as a queued region. With
--- `from_buffer` the caller tags its range, otherwise the text is added at the
--- end of the input.
--- @param input_text string
--- @param opts? agentic.SessionManager.SubmitOpts
--- @return boolean dispatched
function SessionManager:_handle_input_submit(input_text, opts)
    opts = opts or {}
    if SUBMIT_HOLDS[self:_submit_defer_reason(input_text)] then
        if not opts.from_buffer then
            self:_queue_input(input_text)
        end
        return false
    end
    self:_handle_input_submit_inner(input_text)
    return true
end

--- Add text to the input as a queued paragraph (see
--- `InputDispatch:queue_paragraph`), making the input again when it was wiped.
--- @param text string
--- @param opts { first?: boolean }|nil
--- @return integer|nil mark_id
function SessionManager:_queue_input(text, opts)
    -- Making the input makes its dispatch.
    self.widget:panel_buf("input")
    return self.widget.input_dispatch:queue_paragraph(text, opts)
end

--- Send a prompt to the main agent on the user's behalf, or as `author`,
--- apart from the user's own turns. It passes the submit gate, but carries none of the pending
--- context, title, history prefix or system info of a user submit, and
--- clears no idle state, todo panel or user control. A held relay is not kept.
--- @param instruction string
--- @param on_returned agentic.OnReturned|nil Called when the turn returns the prompt
--- @param author string|nil Who wrote the prompt, a key of `Glyphs.AUTHOR`; nil for the user
--- @return string|nil held_cause Why the prompt was held, as a phrase; nil when sent
function SessionManager:_relay(instruction, on_returned, author)
    local held_cause = SUBMIT_HOLDS[self:_submit_defer_reason(instruction)]
    if not held_cause then
        self:_send_user_prompt(instruction, {}, {}, on_returned, author)
    end
    return held_cause
end

--- Send `text` as a prompt written by `author`, not the user. The prompt sign
--- and the history row carry `author`, and the `on_prompt_submit` hook does
--- not run. A prompt the submit gate or the usage limit holds is dropped, not
--- queued.
--- @param author string A key of `Glyphs.AUTHOR`
--- @param text string
--- @return string|nil held_cause Why the prompt was held, as a phrase; nil when sent
function SessionManager:send_from(author, text)
    if self:_submit_defer_reason(text) == "usage_limited" then
        return "the usage limit holds"
    end
    return self:_relay(text, nil, author)
end

--- @alias agentic.SessionEvent "turn_end"|"session_changed"|"destroy"

--- @class agentic.SessionEventData
--- @field user_msg? agentic.ui.ChatHistory.UserMessage turn_end: the turn's prompt row; nil for work no prompt started
--- @field stop_reason? string turn_end: the provider's stop reason; nil when the turn ended in an error
--- @field continued? boolean session_changed: true when the conversation carries on in the new session (a re-create from history), false for a fresh session or a load

--- Run `listener` on `event` of this session:
--- - `turn_end`: a turn ended and is not being retried.
--- - `session_changed`: the session has a new ACP session id.
--- - `destroy`: the session is being destroyed, before it tears anything down.
--- @param event agentic.SessionEvent
--- @param listener fun(session: agentic.SessionManager, data: agentic.SessionEventData)
--- @return fun() unsubscribe
function SessionManager:on(event, listener)
    return self._listeners[event]:add(listener)
end

--- Run the listeners of `event`.
--- @param event agentic.SessionEvent
--- @param data agentic.SessionEventData
function SessionManager:_emit(event, data)
    self._listeners[event]:call(self, data)
end

--- Working directory of the ACP session.
--- @return string
function SessionManager:cwd()
    return self._cwd
end

--- Supersede the current session generation, so callbacks still in flight for
--- the outgoing one are refused.
---
--- Resetting the turn state belongs here rather than in `_cancel_session`:
--- every epoch bump strands the outgoing session's turn, whose `idle` no
--- longer arrives, and the prompts it had not taken in, which go back to the
--- input. A load or a re-create from history leaves `_cancel_session` unrun.
--- The same holds for the load state of a load the refused callback would
--- have ended, and for `is_generating` and the step line, which the refused
--- callbacks would have cleared. The usage limit is the provider account's,
--- and stays.
function SessionManager:_advance_session_epoch()
    self._session_epoch = self._session_epoch + 1
    self.tail_lines:clear_step()
    self._subagents:forget()
    self:_reset_turn_state()
    self:_set_generating(false)
    self:_set_load_state(nil)
end

--- Forget the agent's foreground work and the prompts it took in, as idle,
--- and return the prompts it has not taken in.
function SessionManager:_reset_turn_state()
    self._foreground = "idle"
    self._taken = {}
    local untaken = self._untaken
    self._untaken = {}
    self:_untaken_changed()
    -- Newest first: each goes on top of the input, so the oldest ends on top.
    for i = #untaken, 1, -1 do
        if untaken[i].on_returned then
            untaken[i].on_returned("untaken")
        end
    end
end

--- Stop the running turn without ending the session. Safe when nothing is
--- running. The open calls of the main agent and of each working subagent not
--- running in the background, which the turn's cancel also stops, are marked
--- `interrupted`, for when they fail.
---
--- Leaves the turn state alone: the cancelled turn still ends `idle`, and
--- each prompt not taken in still fails. Clearing it here would report the
--- session idle while the old turn is still resolving, so the queue would
--- drain into it.
function SessionManager:stop_generation()
    if not self.session_id then
        return
    end
    self.chat_history:update_tool_calls(
        self.message_writer:stamp_open_calls("interrupted")
    )
    self._subagents:mark_foreground_stopped()
    self.agent:stop_generation(self.session_id)
    self.permission_manager:cancel_requests()
    self:_set_generating(false)
end

--- Delete the automatic "continue" from the input while it is still queued
--- and unedited.
function SessionManager:_withdraw_auto_continue()
    if self._continue_mark then
        self.widget.input_dispatch:delete_queued_region(
            self._continue_mark,
            "continue"
        )
        self._continue_mark = nil
    end
end

--- Drop the rest of the queue once the session is deleted: a block queued
--- against a deleted session has no destination left. Warning about work left
--- undone beats inventing somewhere to send it.
function SessionManager:_truncate_queue()
    local count = self.widget.input_dispatch:queued_block_count()
    if count == 0 then
        return
    end
    self.widget.input_dispatch:cancel_queue()
    self._continue_mark = nil
    self.message_writer:write_error_action(
        string.format(
            "/delete: %d queued block(s) left as draft, unsent.",
            count
        )
    )
end

--- Confirm a session-ending command that reached the queue behind other
--- content, and report whether to run it.
---
--- A submit's own first block is unambiguous — there the user typed the
--- command *as* the message — and that block never comes through the queue.
--- Behind other content is the signature of pasted data instead: a note or
--- transcript that quotes `/new` runs it. Declining drops every tag, leaving
--- all remaining text as draft, because text that turned out to be data wants
--- editing rather than dispatching.
---
--- Blocking rather than scheduled: a caller acts on the returned verdict,
--- which an answer arriving a tick later cannot supply. The wait is not inert — vim
--- keeps running scheduled callbacks and timers while a dialog is open — so
--- the drain guards itself against being re-entered across this call.
--- @param text string
--- @return boolean run
function SessionManager:_confirm_queued_command(text)
    local word = parse_local_command(text)
    local spec = word and LOCAL_COMMANDS[word]
    if not (spec and spec.session_ending) then
        return true
    end
    local count = self.widget.input_dispatch:queued_block_count()
    local choice = vim.fn.confirm( -- no nvim_* equivalent
        string.format(
            "Run /%s? It is the first of %d queued block(s).",
            word,
            count
        ),
        "&Yes\n&No",
        2
    )
    if choice == 1 then
        return true
    end
    self.widget.input_dispatch:cancel_queue()
    self._continue_mark = nil
    self.message_writer:write_error_action(
        string.format(
            "/%s declined — %d queued block(s) left as draft.",
            word,
            count
        )
    )
    return false
end

--- Dispatch the queue's next block as a new turn.
---
--- Re-checks the gate itself, so overlapping conditions (a usage-limit lift
--- during a turn) need no per-case guard at any
--- call site. Reads the block before consuming it, so a still-gated drain
--- leaves it tagged and visible rather than eating it, and dispatches what the
--- consume actually took — the block read first is only a candidate.
---
--- Non-reentrant. The confirm below waits for a keypress without stopping the
--- event loop, so a drain edge landing in that window would otherwise take the
--- same unconsumed block and dispatch it twice.
--- @return boolean dispatched
function SessionManager:_drain_queue()
    if self._draining_queue then
        return false
    end
    local candidate = self.widget.input_dispatch:next_queued_block()
    if not candidate then
        return false
    end
    if self:_submit_defer_reason(candidate.text) then
        return false
    end
    -- Held only across the confirm and the consume: a dispatch can error, and
    -- a flag still set afterwards would wedge every later drain.
    self._draining_queue = true
    local run = self:_confirm_queued_command(candidate.text)
    --- @type agentic.utils.PromptBlocks.Block|nil
    local block
    -- A destroy can also have run while the dialog was open.
    if run and not self.destroyed then
        block = self.widget.input_dispatch:consume_queued_block()
    end
    self._draining_queue = false

    if not block then
        return false
    end
    self:_handle_input_submit_inner(block.text)
    return true
end

--- Dispatch one block: a local command, or one turn to the provider.
---
--- Blocks arrive one at a time — the submit's first from
--- `_handle_input_submit`, the rest from `_drain_queue` — so what used to
--- happen once per submit happens on the first *prose* block instead: the
--- session title, the history prefix, the system info and the context
--- panels. A command is not a message about the work, and any text block ahead
--- of one shadows it for opencode.
--- @param input_text string
function SessionManager:_handle_input_submit_inner(input_text)
    local word, arg = parse_local_command(input_text)
    if word then
        -- The gate cannot hold the next block behind a local command: local
        -- commands are exempt from it, and one that answers synchronously
        -- reaches no Stop for the drain to run at. So the sequence continues
        -- from here — after the synchronous commands, from the completion
        -- callback for those that leave a dialog open.
        --
        -- Scheduled rather than called outright: the submit that dispatched
        -- this command has not deleted its own lines yet, and consuming the
        -- next block edits the rows it is about to delete by number.
        local function dispatch_next()
            vim.schedule(function()
                if self.destroyed then
                    return
                end
                self:_drain_queue()
            end)
        end
        if LOCAL_COMMANDS[word].async then
            self:_run_local_command(word, arg, dispatch_next)
        else
            self:_run_local_command(word, arg)
            dispatch_next()
        end
        return
    end

    --- @type agentic.acp.Content[]
    local prompt = {}

    -- The splitter's line shape, so a block dispatches as what it was split
    -- as, and text that never went through the splitter (`Agentic.send_prompt`)
    -- classifies the same way.
    local is_command = PromptBlocks.command(input_text) ~= nil

    --- @type agentic.SessionManager.PanelContext
    local consumed = { selections = {}, files = {}, diagnostics = {} }

    if not is_command then
        if self._history_to_send then
            self._history_to_send:prepend_history_messages(prompt)
            self._history_to_send = nil
        elseif self.chat_history.title == "" then
            self.chat_history:set_title(input_text)
            self.widget:set_chat_title(input_text)
        end
    end

    -- Context blocks (system info, selected code, files, diagnostics) go
    -- BEFORE the user text for regular messages. For slash commands (/compact,
    -- /model, etc.), context blocks are omitted entirely because some providers
    -- (e.g. opencode) join ALL text blocks to detect the leading `/`, and any
    -- preceding text would shadow the command. The Claude Code SDK instead
    -- extracts its `inputString` from the last text block only, so context
    -- before user text works for claude-agent-acp. Its hooks are the exception:
    -- a UserPromptSubmit payload's `.prompt` is the join of every text block,
    -- so a keyword-matching hook reads these blocks as the user's own words.
    if self._is_first_message and not is_command then
        self._is_first_message = false

        table.insert(prompt, {
            type = "text",
            text = EnvironmentInfo.build(self._cwd, self.agent:exec_shell()),
        })
    end

    local timings = not is_command
        and self._run_clocks
        and ToolTimings.prompt_text(
            self._run_clocks:take_reports(),
            self.message_writer.tool_call_blocks,
            self._run_clocks.threshold_ms
        )
    if timings then
        table.insert(prompt, { type = "text", text = timings })
    end

    --- Display-only lines appended after the prompt body in the chat widget
    --- (heading and region signs are owned by MessageWriter:write_user_prompt)
    local extra_lines = {}

    if not is_command and not self.code_selection:is_empty() then
        table.insert(extra_lines, "\n- **Selected code**:\n")

        table.insert(prompt, {
            type = "text",
            text = table.concat({
                "IMPORTANT: Focus and respect the line numbers provided in the <line_start> and <line_end> tags for each <selected_code> tag.",
                "The selection shows ONLY the specified line range, not the entire file!",
                "The file may contain duplicated content of the selected snippet.",
                "When using edit tools, on the referenced files, MAKE SURE your changes target the correct lines by including sufficient surrounding context to make the match unique.",
                "After you make edits to the referenced files, go back and read the file to verify your changes were applied correctly.",
            }, "\n"),
        })

        local selections = self.code_selection:take() --[[@as agentic.Selection[] ]]
        consumed.selections = selections

        for _, selection in ipairs(selections) do
            if selection and #selection.lines > 0 then
                local numbered_lines = {}
                for i, line in ipairs(selection.lines) do
                    local line_num = selection.start_line + i - 1
                    table.insert(
                        numbered_lines,
                        string.format("Line %d: %s", line_num, line)
                    )
                end
                local numbered_snippet = table.concat(numbered_lines, "\n")

                table.insert(prompt, {
                    type = "text",
                    text = string.format(
                        table.concat({
                            "<selected_code>",
                            "<path>%s</path>",
                            "<line_start>%s</line_start>",
                            "<line_end>%s</line_end>",
                            "<snippet>",
                            "%s",
                            "</snippet>",
                            "</selected_code>",
                        }, "\n"),
                        FileSystem.to_absolute_path(selection.file_path),
                        selection.start_line,
                        selection.end_line,
                        numbered_snippet
                    ),
                })

                table.insert(
                    extra_lines,
                    table.concat(CodeSelection.fence_rows(selection), "\n")
                )
            end
        end
    end

    if not is_command and not self.file_list:is_empty() then
        table.insert(extra_lines, "\n- **Referenced files**:")

        local files = self.file_list:take() --[[@as string[] ]]
        consumed.files = files

        for _, file_path in ipairs(files) do
            table.insert(prompt, ACPPayloads.create_file_content(file_path))

            table.insert(
                extra_lines,
                string.format("  - @%s", FileSystem.to_smart_path(file_path))
            )
        end
    end

    if not is_command and not self.diagnostics_list:is_empty() then
        table.insert(extra_lines, "\n- **Diagnostics**:")

        local diagnostics = self.diagnostics_list:take() --[[@as agentic.ui.DiagnosticsList.Diagnostic[] ]]
        consumed.diagnostics = diagnostics

        local DiagnosticsContext = require("agentic.ui.diagnostics_context")

        local formatted_diagnostics = DiagnosticsContext.format_diagnostics(
            diagnostics,
            Config.windows.wrap_width
        )

        for _, prompt_entry in ipairs(formatted_diagnostics.prompt_entries) do
            table.insert(prompt, prompt_entry)
        end

        for _, summary_line in ipairs(formatted_diagnostics.summary_lines) do
            table.insert(extra_lines, summary_line)
        end
    end

    self:_send_user_prompt(
        input_text,
        prompt,
        extra_lines,
        function(reason, held)
            if reason == "refusal" then
                Recovery.restore_refused_prompt(self, input_text, consumed)
            elseif held then
                Recovery.requeue_limited_prompt(self, input_text, consumed)
            else
                -- Never taken in, or no lift to wait for.
                Recovery.return_as_draft(self, input_text, consumed)
            end
        end
    )
end

--- A prompt sent to the agent, from its send until its turn ends.
--- @class agentic.SessionManager.SentPrompt
--- @field input_text string
--- @field extra_lines string[] Display-only lines below the prompt in the chat
--- @field author? string Who wrote the prompt, a key of `Glyphs.AUTHOR`; nil for the user
--- @field user_msg agentic.ui.ChatHistory.UserMessage Its history row; `synthetic` for a prompt the user did not author
--- @field on_returned? agentic.OnReturned Called when the turn returns the prompt

--- Send the user's prompt as a turn: `input_text` after the `prompt` blocks
--- assembled so far. Once the agent takes it in, it shows in the chat with
--- `extra_lines` below it and is recorded in the history as the user's
--- message.
--- @param input_text string
--- @param prompt agentic.acp.Content[] Blocks to send ahead of the text. The text block is appended to it
--- @param extra_lines string[] Display-only lines below the prompt in the chat
--- @param on_returned agentic.OnReturned|nil Called when the turn returns the prompt
--- @param author string|nil Who wrote the prompt, a key of `Glyphs.AUTHOR`; nil for the user, the only author the `on_prompt_submit` hook runs for
function SessionManager:_send_user_prompt(
    input_text,
    prompt,
    extra_lines,
    on_returned,
    author
)
    table.insert(prompt, {
        type = "text",
        text = input_text,
    })

    if not author then
        P.invoke_hook("on_prompt_submit", {
            prompt = input_text,
            session_id = self.session_id,
        })
    end

    self:_dispatch_turn(prompt, {
        input_text = input_text,
        extra_lines = extra_lines,
        author = author,
        on_returned = on_returned,
        user_msg = {
            type = "user",
            text = input_text,
            timestamp = os.time(),
            provider_name = self.agent.provider_config.name,
            author = author,
            model = self.config_options:current_model_id(),
        },
    })
end

--- Send a prompt that the user did not author, recording nothing that would
--- attribute it to them: no `## ` heading, prompt sign or `---` separator
--- (`write_user_prompt`), and no context blocks, because pending @files,
--- selections and diagnostics belong to the user's *next* prompt and stay
--- pending. No `on_prompt_submit` hook either. The history records it as a
--- `synthetic` user row.
--- @param text string
function SessionManager:_send_synthetic_prompt(text)
    self:_dispatch_turn({ { type = "text", text = text } }, {
        input_text = text,
        extra_lines = {},
        user_msg = {
            type = "user",
            text = text,
            timestamp = os.time(),
            provider_name = self.agent.provider_config.name,
            synthetic = true,
        },
    })
end

--- History rows a turn holds that are not the agent's reply: hook records,
--- loaded files and skills, and messages received during the turn.
local NOT_REPLIES = { side_records = true, session_message = true }

--- Whether the agent's reply to `prompt` is only agent messages whose joined
--- text, trimmed, is part of `text`. Rows in `NOT_REPLIES` are skipped; any
--- other row (a thought, a tool call, a later prompt) fails. False when
--- `prompt` is not in `messages`.
--- @param messages agentic.ui.ChatHistory.Message[]
--- @param prompt agentic.ui.ChatHistory.Message
--- @param text string
--- @return boolean
local function replied_only_with(messages, prompt, text)
    local replies = {}
    for i = #messages, 1, -1 do
        local msg = messages[i]
        if msg == prompt then
            local reply = vim.trim(table.concat(replies))
            return text:find(reply, 1, true) ~= nil
        end
        if msg.type == "agent" then
            table.insert(replies, 1, msg.text)
        elseif not NOT_REPLIES[msg.type] then
            return false
        end
    end
    return false
end

--- Send an assembled prompt and hold it as not yet taken in until the agent
--- takes it in (`_on_prompt_taken`). Shared by user submits and synthetic
--- prompts.
---
--- A prompt the agent fails before taking it in goes back through its
--- `on_returned` (`"untaken"`), with the error written to the chat unless a
--- cancel ended it.
--- @param prompt agentic.acp.Content[]
--- @param sent agentic.SessionManager.SentPrompt
function SessionManager:_dispatch_turn(prompt, sent)
    -- What arrives from here on answers this turn, not a replay `_refresh`
    -- abandoned.
    if self._load_state == "dropping" then
        self:_set_load_state(nil)
    end

    -- Before the send: ACP v1 takes the prompt in within it.
    table.insert(self._untaken, sent)
    self:_untaken_changed()

    self.agent:send_prompt(self.session_id, prompt, function(_answer, err)
        -- Once taken in, the prompt's turn reports its own outcome. A prompt
        -- `_reset_turn_state` returned is no longer held.
        if self.destroyed or not err or not self:_drop_untaken(sent) then
            return
        end
        if err.code ~= ACPClient.ERROR_CODES.REQUEST_CANCELLED then
            self.message_writer:write_error_message(err)
            if not self:_turn_open() then
                self.message_writer:finalize_turn()
            end
        end
        if sent.on_returned then
            sent.on_returned("untaken")
        end
        -- The idle signals the turn's end held back for this prompt. A cancel
        -- fails the prompts not taken in around the turn's `idle`.
        if not self:_in_flight() then
            self:_set_generating(false)
            self:_notify_attention(true)
        end
    end)
end

--- Remove `sent` from the prompts not yet taken in.
--- @param sent agentic.SessionManager.SentPrompt
--- @return boolean removed False when it was not held
function SessionManager:_drop_untaken(sent)
    for i, held in ipairs(self._untaken) do
        if held == sent then
            table.remove(self._untaken, i)
            self:_untaken_changed()
            return true
        end
    end
    return false
end

--- Show the prompts not yet taken in below the chat, the user's own (not
--- synthetic ones), and sync the chat's `modified` flag.
function SessionManager:_untaken_changed()
    --- @type agentic.ui.TailLines.Prompt[]
    local prompts = {}
    for _, sent in ipairs(self._untaken) do
        if not sent.user_msg.synthetic then
            table.insert(prompts, {
                sign = MessageWriter.prompt_sign(sent.input_text, sent.author),
                text = sent.input_text,
            })
        end
    end
    self.tail_lines:show_prompts(prompts)
    self:_sync_modified(self.chat_history)
end

--- Take the oldest prompt not yet taken in as taken: write a user's prompt
--- to the chat, and add its row to the history. A no-op when none is held.
function SessionManager:_on_prompt_taken()
    local sent = table.remove(self._untaken, 1)
    if not sent then
        return
    end
    table.insert(self._taken, sent)
    self:_untaken_changed()
    if not sent.user_msg.synthetic then
        self.message_writer:write_user_prompt(
            sent.input_text,
            sent.extra_lines,
            sent.author,
            sent.user_msg
        )
    end
    self.chat_history:add_message(sent.user_msg)
    self:_history_changed(self.chat_history)
end

--- Apply a change of the agent's foreground work. An `idle` ends the turn
--- running, if one runs; an `idle` while idle is a snapshot and ends nothing.
--- @param state agentic.acp.TurnState
function SessionManager:_on_turn_state(state)
    local was = self._foreground
    self._foreground = state.state
    self:_sync_modified(self.chat_history)
    if state.state ~= "idle" then
        self:_set_generating(true)
    elseif was ~= "idle" then
        self:_end_turn(state)
    end
end

--- End the turn `state` reports `idle`: per-turn state reset, error
--- dispatch, finalization, attention notification, hooks and queue drain. The
--- turn's prompt is the oldest taken in; work no prompt started has none.
---
--- The turn returns its prompt when the model refuses it (`"refusal"`, after
--- the refusal is reported), or when the usage limit turns it away before any
--- reply (`"usage_limit"`). A turned-away prompt and the limit's notice are
--- removed from the chat history.
--- @param state agentic.acp.TurnState
function SessionManager:_end_turn(state)
    local sent = table.remove(self._taken, 1)
    local user_msg = sent and sent.user_msg
    local on_returned = sent and sent.on_returned
    local chat_history = self.chat_history
    local err = state.error

    -- A turn that ends with another prompt still to run still owes the
    -- reader its own boundary: the usage footer, the separator and the
    -- per-turn writer flags, which corrupt the next turn if they carry into
    -- it. What it does not owe is the signals that say the session went idle,
    -- since the next turn is about to run.
    local busy = state.more or #self._untaken > 0

    self:_set_generating(busy)

    --- Set when this failure is being resent as a fresh turn. Everything
    --- that would tell the user the turn ended is suppressed, so a
    --- recovered failure leaves no trace but its calls left open, which end
    --- `failed`: no error block, no bell or idle state, no
    --- on_response_complete, and no queue drain.
    local retrying = err ~= nil
        and Recovery.should_retry_transient(self, err, busy)

    if not err then
        -- A turn that started before another session's hit says nothing
        -- about the limit.
        if not self.agent.usage_limit:is_held() then
            self.agent.usage_limit:clear_attempts()
        end
        self._transient_attempt = 0
        self._reauth_live_retry = false
        Recovery.surface_unexpected_response(self, state)
        if on_returned and state.stop_reason == "refusal" then
            on_returned("refusal")
        end
    elseif not retrying then
        local error_type, reset_epoch =
            self.message_writer:write_error_message(err)
        -- Account for the retries the user never saw — otherwise this error
        -- follows a multi-turn stall with nothing to explain it. Covers a
        -- chain ending in a different error class too, so no branch below
        -- can leave a stale budget behind.
        if self._transient_attempt > 0 then
            self.message_writer:write_error_action(
                string.format(
                    "Auto-retry gave up (%d attempts).",
                    self._transient_attempt
                )
            )
            self._transient_attempt = 0
        end
        if err.code == ACPClient.ERROR_CODES.AUTH_REQUIRED then
            Recovery.offer_login(self)
        elseif error_type == "usage_limit" then
            -- claude-agent-acp reuses a stalled query after this error,
            -- so the next prompt can end with no content. It keeps one
            -- query per ACP session, so a new ACP session gets a fresh
            -- one. See `.claude/skills/issues/references/chunk-flush.md`.
            -- Hold before the renewal, not after: the renewal's
            -- new_session drains when it completes, which would otherwise
            -- dispatch into a still-limited provider.
            local limit = self.agent.usage_limit
            if reset_epoch then
                limit:hold(reset_epoch)
            end
            -- The turn's own records (its UserPromptSubmit hook) belong
            -- under its prompt, so the cut below takes them with it.
            self:_drain_side_records()
            -- The bridge forwards the limit's notice as an ordinary agent
            -- message (claude-agent-acp's legacy transcript behaviour, for
            -- clients that do not advertise session failures), so "no
            -- reply" means nothing but that notice. Truncated before the
            -- renewal, so the prompt reaches no history prefix.
            if
                on_returned
                and user_msg
                and replied_only_with(
                    chat_history.messages,
                    user_msg,
                    err.message or ""
                )
                and chat_history:truncate_from(user_msg)
            then
                self:_history_changed(chat_history)
                on_returned("usage_limit", limit:holds_drain())
            end
            Recovery.renew_session(self)
            if reset_epoch then
                Recovery.offer_auto_continue(self, limit)
            end
        end
        -- No other error clears the limit's attempts: a client restart
        -- after a re-login fails sibling sessions' turns with transport
        -- errors, which say nothing about the limit.
    end

    -- Above the history save below, so the corrected statuses are the ones
    -- persisted. A turn without a stop reason ends as a normal Stop.
    local stop_reason = err and "error" or state.stop_reason or "end_turn"
    if stop_reason ~= "end_turn" then
        self:_end_open_tool_calls(
            CanonicalToolCall.stop_reason_word(stop_reason)
        )
    end

    self:_finalize_turn(state.usage)
    -- The provider can rename the session while it runs.
    self:_refresh_name()

    if not retrying then
        if not busy then
            self:_notify_attention(true)
        end

        -- Fires once per user turn, not once per provider turn: the
        -- retried attempts are not outcomes the user asked about.
        P.invoke_hook("on_response_complete", {
            session_id = self.session_id,
            success = err == nil,
            error = err,
        })
        self:_emit("turn_end", {
            user_msg = user_msg,
            stop_reason = not err and stop_reason or nil,
        })
    end

    -- Persist on failure too: the user prompt is already in `chat_history`,
    -- so a turn that dies before the session's first success would
    -- otherwise leave the conversation with no on-disk copy at all. Not
    -- while retrying — the resent turn writes the same history at its own
    -- completion, and each save is a synchronous disk write.
    if not retrying then
        self:_persist_history(chat_history)
    end

    if retrying then
        -- The retry turn reaches its own Stop where the drain runs.
        -- Draining here too would fire a second concurrent send_prompt,
        -- so deferred prompts wait up to MAX_TRANSIENT_RETRIES turns
        -- (one dispatch per Stop).
        Recovery.retry_after_transient_error(self)
    elseif stop_reason == "end_turn" and not busy then
        -- Only a normal Stop. `cancelled` is <C-c>, where the user is
        -- asking a question rather than queueing the next task; `refusal`,
        -- `max_tokens` and `max_turn_requests` all left the work unfinished,
        -- and launching a follow-up onto a truncated state is wrong.
        -- Deferred prompts stay visible in the input buffer meanwhile.
        self:_drain_queue()
    end
end

--- Make the just-created ACP session `session_id` this session's: take its
--- id, clear the name, give the history its id, apply the grant defaults,
--- announce the change, and apply and show the mode and model options of
--- `response`.
--- @param session_id string
--- @param response table The session/new or session/fork result
--- @param continued boolean The conversation carries on in the new session
function SessionManager:_adopt_session(session_id, response, continued)
    self.session_id = session_id
    -- The name was the old session's.
    self._name = nil
    self.chat_history.session_id = session_id
    self:_session_changed(session_id, continued)
    self:_apply_session_options(response)
    self:render_info()
end

--- Start the session `session_id` on the grant defaults, fire
--- `AgenticSessionChanged` and emit `session_changed`.
--- @param session_id string
--- @param continued boolean The conversation carries on in the new session
function SessionManager:_session_changed(session_id, continued)
    self._grant_command:apply_defaults()
    vim.api.nvim_exec_autocmds("User", {
        pattern = "AgenticSessionChanged",
        data = { session_id = session_id },
    })
    self:_emit("session_changed", { continued = continued })
end

--- Switch the session to `mode_id` once, when the provider offers it and it
--- is not the current mode.
--- @param mode_id string|nil
function SessionManager:_set_initial_mode(mode_id)
    self.config_options:set_initial_mode(mode_id, function(mode, is_legacy)
        self:_handle_mode_change(mode, is_legacy)
    end)
end

--- Create a new ACP session. Without `history`, first cancel the current
--- session and keep its selected model. With `history`, carry that
--- conversation into the new session: it becomes the session's history under
--- the new session id, and its messages are prepended to the next submit.
--- The agent's session is empty, so that is the only way they reach the
--- agent, and the history's response ids, which name responses of another
--- session, are cleared.
--- @param opts {history?: agentic.ui.ChatHistory, keep_cwd?: boolean, quiet_welcome?: boolean, on_created?: fun(), mode?: string}|nil `keep_cwd` keeps the session's working directory instead of taking the editor cwd. `history` implies it. `mode` replaces the provider's `default_mode`
function SessionManager:new_session(opts)
    opts = opts or {}
    local history = opts.history
    local quiet_welcome = opts.quiet_welcome or false
    local on_created = opts.on_created

    if history then
        history:clear_response_ids()
    end

    -- Preserve the user-selected model across /new and /clear. The provider's
    -- session/new response carries its default configOptions, which would
    -- otherwise revert the model to the provider default.
    local preserved_model
    if not history then
        preserved_model = self.config_options:current_model_id()
        -- The "continue" refers to the conversation that hit the usage limit.
        -- Scheduled: a `/new` sent from the input runs before its submit
        -- deletes the sent rows, by number.
        vim.schedule(function()
            if not self.destroyed then
                self:_withdraw_auto_continue()
            end
        end)
        self:_cancel_session()
    end

    local handlers = self:_build_handlers()

    -- Capture epoch so the callback can detect if a load (or another
    -- new_session) superseded this create while the RPC was in flight.
    self:_advance_session_epoch()
    local epoch = self._session_epoch
    self.tail_lines:show_step("starting session")

    if not (history or opts.keep_cwd) then
        self._cwd = vim.fn.getcwd()
    end
    self.agent:create_session(self._cwd, handlers, function(response, err)
        -- This SessionManager may have been destroyed (for example the
        -- unused session a resume replaces) while session/new was in flight.
        -- Its agent and widget are gone but the callback closure still holds
        -- a reference to self.
        -- Continuing would fall through to _apply_session_options etc. on
        -- wiped buffers.
        if self.destroyed then
            if response and response.sessionId and self.agent then
                self.agent:unsubscribe(response.sessionId)
            end
            return
        end

        -- A superseded create leaves the step of what superseded it.
        if epoch == self._session_epoch then
            self.tail_lines:clear_step()
        end

        if err or not response then
            -- no log here, already logged in create_session
            self.session_id = nil
            return
        end

        -- A load or another new_session superseded this create while it was
        -- in flight.
        --
        -- Only remove the subscriber — do NOT send session/cancel. Sending
        -- cancel for the stale session while session/load is active or just
        -- completed can confuse providers (observed: claude-agent-acp drops
        -- loaded session context when a cancel arrives for a different session
        -- around the same time).
        if epoch ~= self._session_epoch then
            self.agent:unsubscribe(response.sessionId)
            return
        end

        if history then
            self.chat_history = history
            if history:has_prompt() then
                self._history_to_send = history
            end
            self:_sync_modified(history)
        end
        self:_adopt_session(response.sessionId, response, history ~= nil)

        if preserved_model then
            self.config_options:set_pending_initial_model(preserved_model)
        end

        self:_set_initial_mode(
            opts.mode or self.agent.provider_config.default_mode
        )

        self._is_first_message = true

        -- Defer to avoid fast event context issues
        -- For a re-create from history: write welcome first, then replay via on_created
        -- quiet_welcome is used by a session renewal so the chat does not
        -- get a session-header divider mid-conversation.
        vim.schedule(function()
            if not quiet_welcome then
                local welcome_message = SessionManager._generate_welcome_header(
                    self.agent.provider_config.name,
                    self.session_id
                )

                self.message_writer:write_message(
                    ACPPayloads.generate_user_message(welcome_message)
                )

                -- A re-create from history replays after this, so its
                -- on_created announces the model. The switch to
                -- preserved_model announces itself.
                if not history then
                    self:announce_model_loaded(
                        self.config_options:current_model_id()
                    )
                end
            end

            if on_created then
                on_created()
            end
            -- After on_created, so the notice follows any history it replays.
            self:_refresh_name()

            self:_drain_queue()
        end)
    end)
end

--- Load a saved chat, or an existing ACP session with no saved file (e.g.
--- from claude-agent-acp), with ACP `session/load`. The agent replays the
--- conversation via session/update notifications. Call it only while the
--- agent is ready, or before this session first sees it ready (just
--- created). Otherwise the load is deferred and may never run.
--- @param chat_id string The chat id, or the full ACP session id of a session with no saved file, which loads into a new chat
--- @param cwd? string Original working directory for the session.
---   When nil, the cwd recorded in the saved session file, else vim.fn.getcwd().
--- @param model? string Model id saved with the session, applied after load
function SessionManager:load_acp_session(chat_id, cwd, model)
    if self.agent and self.agent.state == "ready" then
        self:_do_load_acp_session(chat_id, cwd, model)
    else
        self._pending_load = {
            chat_id = chat_id,
            cwd = cwd,
            model = model,
        }
        self:_name_buffers()
    end
end

--- The id the deferred load was given, else the history's chat id.
--- @return string
function SessionManager:chat_id()
    return self._pending_load and self._pending_load.chat_id
        or self.chat_history.chat_id
end

--- Name the session's buffers after `chat_id()`.
function SessionManager:_name_buffers()
    self.widget:rename_buffers(self:chat_id())
end

--- The live buffer of this session for the parts of its name: the chat, a
--- panel, or a subagent's transcript or message input. Makes nothing.
--- @param sub_id string|nil A subagent's short key (`agentic.BufferNames.Parts`)
--- @param part string|nil
--- @return integer|nil bufnr Nil while that buffer does not exist
function SessionManager:buf_of(sub_id, part)
    if sub_id then
        local child_id = self._subagents:child_for_key(sub_id)
        return child_id
            and self._subagents:buf_of(child_id, part --[[@as "input"|nil]])
    end
    local bufnr = self.widget.buf_nrs[part or "agent"]
    return bufnr and vim.api.nvim_buf_is_valid(bufnr) and bufnr or nil
end

--- Like `buf_of`, but makes the buffer when it does not exist: a wiped panel
--- or transcript, or a message input.
--- @param sub_id string|nil A subagent's short key (`agentic.BufferNames.Parts`)
--- @param part string|nil
--- @return integer|nil bufnr Nil for a subagent the session does not have, or a message input it cannot have
function SessionManager:open_buf(sub_id, part)
    if sub_id then
        local child_id = self._subagents:child_for_key(sub_id)
        return child_id
            and self._subagents:open_buf(child_id, part --[[@as "input"|nil]])
    end
    if part then
        return self.widget:panel_buf(
            part --[[@as agentic.ui.ChatWidget.StackPanel]]
        )
    end
    return self:buf_of(nil, nil)
end

--- Internal: actually send session/load after the agent is ready.
--- @param chat_id string See `load_acp_session`
--- @param cwd? string See `load_acp_session`
--- @param model? string Model id to reapply after load (queued until options arrive).
function SessionManager:_do_load_acp_session(chat_id, cwd, model)
    local saved_data = ChatHistory.read_saved(chat_id)
    local saved_history = saved_data
        and ChatHistory.from_data(saved_data, chat_id)
    -- Without a file, the id given is an ACP id.
    local session_id = saved_data and saved_data.session_id or chat_id
    -- The file renders the chat and the replay adds only what comes after the
    -- file's end. Without `loadSession` the load fails at once, and the
    -- fallback renders the file.
    local from_file = saved_history ~= nil
        and vim.tbl_get(self.agent, "agent_capabilities", "loadSession")
            == true

    -- The load state stops the constructor's deferred new_session, the epoch
    -- rejects an in-flight one.
    self:_advance_session_epoch()
    self:_set_load_state(from_file and "holding" or "loading")
    local epoch = self._session_epoch

    -- Clean up the old session's UI state and subscriber, but do NOT send
    -- session/cancel to the provider. Sending cancel immediately before
    -- session/load disrupts some providers (claude-agent-acp loses loaded
    -- session context). The old ACP session is orphaned — it will expire
    -- on the provider side or be replaced by the loaded session's subscriber.
    if self.session_id then
        self.agent:unsubscribe(self.session_id)
    end
    self:_reset_conversation()

    self.tail_lines:show_step("loading session")

    self.session_id = session_id
    if not from_file then
        self.chat_history.session_id = session_id
        self.chat_history.timestamp = os.time()
        -- The saved chat keeps its key until the fallback installs its file.
        if saved_data then
            self.chat_history.chat_id = chat_id
            self:_name_buffers()
        end
    end
    self._cwd = cwd and FileSystem.canonical_path(cwd)
        or saved_data and saved_data.cwd
        or vim.fn.getcwd()
    self:_session_changed(session_id, false)

    local handlers = self:_build_handlers()

    if saved_history then
        -- Replayed views and the tail reuse the saved kinds and summaries,
        -- and no later message to an agent the file shows delegated to is its
        -- first delegation.
        self._subagents:seed_message_infos(saved_history)
    end
    if from_file then
        --- @cast saved_history agentic.ui.ChatHistory
        self:_install_history(saved_history)
        self:_render_history()
    end

    self.agent:load_session(
        session_id,
        self._cwd,
        {},
        handlers,
        -- Unscheduled: a response callback runs on the main loop already, and
        -- this one must run whole before any notification sent after the
        -- response, each of which is scheduled once.
        function(result, err)
            -- `/new` (exempt from the load gate) or a destroy superseded this
            -- load: the session belongs to them now. An error has already
            -- unsubscribed the loaded id.
            if self.destroyed or epoch ~= self._session_epoch then
                if not err then
                    self.agent:unsubscribe(session_id)
                end
                return
            end
            if err then
                -- An agent that never advertised `session/load` fails it as
                -- expected.
                local capabilities = self.agent.agent_capabilities
                if capabilities and capabilities.loadSession == true then
                    local details = err.data and err.data.details
                        or err.message
                        or "Unknown error"
                    Logger.notify(
                        string.format(
                            "session/load failed: %s — falling back to local history",
                            details
                        ),
                        vim.log.levels.WARN
                    )
                end
                self:_set_load_state(nil)
                -- With `from_file` the same object as `self.chat_history`.
                self:_new_session_after_failed_load(chat_id, saved_history)
                return
            end

            -- Not `holding` once `_refresh` dropped the hold.
            if self._load_state == "holding" then
                local hold = self._replay_hold --[[@as agentic.SessionManager.HeldUpdate[] ]]
                -- Still replaying: the tail's edits are on disk already, so
                -- `_try_record_edit_range` must skip them.
                self:_set_load_state("loading")
                self:_dispatch_replay_tail(hold)
            end
            self:_set_load_state(nil)
            self.tail_lines:clear_step()

            if not from_file then
                -- After the replay, whose spawns made the transcripts they
                -- had a block for.
                self._subagents:add_history_transcripts()
            end

            -- The options the provider returned with session/load, so they
            -- hold the loaded session's mode and model rather than stale
            -- state from a pre-switch session.
            if result then
                self:_apply_session_options(result)
                self:render_info()
            end

            -- A load whose replay added nothing to the file writes nothing.
            -- The model saved here can be the one from before the switch to
            -- the saved model takes effect; the next turn's save corrects it.
            if self.chat_history.dirty then
                self:_history_changed(self.chat_history)
            end

            self.message_writer:write_notice({
                glyph = Glyphs.RESUME,
                title = session_id:sub(1, 8),
                body = {
                    string.format(
                        "Provider: **%s**",
                        self.agent.provider_config.name
                            or self.agent.provider_name
                    ),
                },
                -- A turn sent after `_refresh` dropped the hold can still run.
                mid_turn = self:_turn_open(),
            })
            self:_reapply_model(model)
            self:_refresh_name()

            -- The only drain on this path: the load state keeps the
            -- constructor's on-ready from running new_session, and
            -- replace_with_history does not run. Placed after the welcome
            -- write, never at the top of the callback — the error branch
            -- above reaches a drain of its own and a top-of-callback one
            -- would double-send.
            --
            -- `_reapply_model` switches to the saved model asynchronously,
            -- so a drained turn may run on the provider default rather than
            -- the session's own model.
            self:_drain_queue()
        end
    )
end

--- Fallback when ACP session/load fails: drop what the partial replay showed,
--- then re-create the session from `history`. Without a history, warn, leave
--- the queue as draft and start an empty session in the same working
--- directory.
--- @param chat_id string The id the load was asked for
--- @param history agentic.ui.ChatHistory|nil The session's file, nil when it could not be read
function SessionManager:_new_session_after_failed_load(chat_id, history)
    -- What the replay wrote. Context the user added meanwhile stays. Clearing
    -- the failed id keeps `new_session` from sending `session/cancel` for it.
    self.session_id = nil
    self:clear_chat()
    self.todo_list:clear()
    self.file_activity:clear()
    if not history then
        Logger.notify(
            "No local history found for session " .. chat_id:sub(1, 8),
            vim.log.levels.WARN
        )
        -- Queued for the conversation that failed to load, not for an empty
        -- agent.
        self.widget.input_dispatch:cancel_queue()
        self:new_session({ keep_cwd = true })
        return
    end
    self:replace_with_history(history)
end

--- Wipe the conversation out of the chat panels: their text, the region signs
--- over it, and the tool call trackers whose extmarks address rows in it.
---
--- The one place those three come apart safely. Clearing the text alone leaves
--- every extmark collapsed on row 0, where a stale tracker resolves to the top
--- of the next conversation.
---
--- The run clocks of its calls go too: no update ends them now.
function SessionManager:clear_chat()
    self:_stop_output_tails(false)
    self.widget:clear()
    self.message_writer:reset()
    self._subagents:reset()
    self._held_tool_call_updates = {}
    if self._run_clocks then
        self._run_clocks:clear()
    end
end

--- Return the session to an empty conversation with no ACP session. Sends
--- nothing to the provider. With a session, also clears the chat, the
--- context panels, the config options and the file tally, and ends a
--- running turn. Without one, keeps the context the user added before the
--- first session, and an unchanged empty history stays. Leaves the load
--- gate as it is.
function SessionManager:_reset_conversation()
    local history = self.chat_history
    local used = self.session_id or history.dirty or #history.messages > 0
    if self.session_id then
        self:clear_chat()
        self.todo_list:clear()
        self.file_list:clear()
        self.code_selection:clear()
        self.diagnostics_list:clear()
        self.config_options:clear()
        -- The tally belongs to the conversation. Installing a history brings
        -- back the incoming one from its file.
        self.file_activity:clear()

        -- Tearing down a live session ends any in-flight turn. Reset the
        -- generating flag so a reset mid-turn doesn't leave is_generating
        -- stale-true. Only reachable with a session — is_generating is set
        -- true only after the session is ready.
        self:_set_generating(false)
    end

    self.session_id = nil
    self._transient_attempt = 0
    self.permission_manager:clear()
    self:_set_available_commands({})
    self._last_edited_md = nil
    self._subagents:reset()
    self._held_tool_call_updates = {}

    if used then
        self.chat_history = ChatHistory:new()
        self:_sync_modified(self.chat_history)
        self:_name_buffers()
    end
    self._title_user_set = false
    self.widget:set_chat_title(nil)
    self.widget:set_idle(false)
    self._history_to_send = nil
    self._usage = nil
    self._name = nil
    self:_update_chat_header()
    self:render_info()
end

--- Cancel the ACP session on the provider and reset the conversation like
--- `_reset_conversation`.
function SessionManager:_cancel_session()
    if self.session_id then
        self.agent:cancel_session(self.session_id)
    end
    self:_reset_conversation()
end

--- Switch to a different ACP provider while preserving chat UI and history.
--- The new provider's client carries its own usage limit.
--- @param provider_name agentic.UserConfig.ProviderName
function SessionManager:switch_provider(provider_name)
    if self.is_generating then
        Logger.notify(
            "Cannot switch provider while generating. Stop generation first.",
            vim.log.levels.WARN
        )
        return
    end

    local AgentInstance = require("agentic.acp.agent_instance")

    self._transient_attempt = 0

    -- Save references before get_instance (on_ready fires synchronously for
    -- a ready agent)
    local saved_history = self.chat_history
    local old_agent = self.agent
    local old_session_id = self.session_id

    -- Get new agent instance BEFORE tearing down the current session
    local new_agent = AgentInstance.get_instance(provider_name, function(client)
        vim.schedule(function()
            self.agent = client

            self:new_session({
                history = saved_history,
                on_created = function()
                    -- Nothing else names the new provider: the welcome
                    -- header takes it and discards it.
                    self.message_writer:write_notice({
                        glyph = Glyphs.PROVIDER,
                        title = self.agent.provider_config.name,
                    })
                    self:announce_model_loaded(
                        self.config_options:current_model_id()
                    )
                end,
            })
        end)
    end)

    if not new_agent then
        return
    end

    -- Soft cancel: tear down old ACP session now that we have a new agent
    if old_session_id then
        old_agent:cancel_session(old_session_id)
    end
    self.session_id = nil
    self.permission_manager:cancel_requests()
    self.todo_list:clear()

    -- If the agent was ready, on_ready fired synchronously above.
    -- If not, it will fire when the process is ready.
    self.agent = new_agent
end

function SessionManager:add_selection_or_file_to_session()
    local added_selection = self:add_selection_to_session()

    if not added_selection then
        self:add_file_to_session()
    end
end

function SessionManager:add_selection_to_session()
    local selection = self.code_selection.get_selected_text()

    if selection then
        self.code_selection:add(selection)
        return true
    end

    return false
end

--- @param buf number|string|nil Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    return self.file_list:add(buf_path)
end

--- Add diagnostics at the current cursor line to context
--- @param bufnr integer|nil Buffer number to get diagnostics from, defaults to current buffer
--- @return integer count Number of diagnostics added
function SessionManager:add_current_line_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_diagnostics_at_cursor(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- Add all diagnostics from the current buffer to context
--- @param bufnr integer|nil Buffer number, defaults to current buffer
--- @return integer count Number of diagnostics added
function SessionManager:add_buffer_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_buffer_diagnostics(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- Store the mode and model options of a session/new or session/load result,
--- in either the configOptions or the legacy form.
--- @param response table The RPC result
function SessionManager:_apply_session_options(response)
    if response.configOptions then
        Logger.debug("Provider announce configOptions")
        self.config_options:set_options(response.configOptions)
        return
    end

    if response.modes then
        Logger.debug("Provider announce legacy mode")
        self.config_options:set_legacy_modes(response.modes)
    end

    if response.models then
        Logger.debug("Provider announce legacy models")
        self.config_options:set_legacy_models(response.models)
    end
end

--- @param new_config_options agentic.acp.ConfigOption[]
function SessionManager:_handle_new_config_options(new_config_options)
    self.config_options:set_options(new_config_options)
    self:render_info()
end

function SessionManager:destroy()
    self:_emit("destroy", {})
    self.destroyed = true

    Recovery.stop_login(self)

    self:_cancel_session()
    self.widget:destroy()
    if self._run_clocks then
        self._run_clocks:destroy()
    end
end

--- Replace the conversation with `history` in a new ACP session: clear the
--- chat, take the history's title and file tally, and once the session is
--- created, replay the messages into the chat and put the session back on its
--- model. The history is sent with the first prompt.
--- @param history agentic.ui.ChatHistory
--- @param opts {model?: string, mode?: string, quiet_welcome?: boolean, on_created?: fun()}|nil `model` overrides the model saved in `history`. `mode`, `quiet_welcome` and `on_created` go to `new_session`, with `on_created` run after the replay
function SessionManager:replace_with_history(history, opts)
    opts = opts or {}
    local model = opts.model or history.model
    self:clear_chat()
    -- Held while session/new is in flight, and kept if it fails.
    self:_install_history(history)
    self:new_session({
        history = history,
        mode = opts.mode,
        quiet_welcome = opts.quiet_welcome,
        on_created = function()
            self:_render_history()
            self:_reapply_model(model)
            if opts.on_created then
                opts.on_created()
            end
        end,
    })
end

--- Make `history` the session's: the history, its modified flag, file tally
--- and title, and the buffers' names.
--- @param history agentic.ui.ChatHistory
function SessionManager:_install_history(history)
    self.chat_history = history
    self:_sync_modified(history)
    self:_name_buffers()

    -- Rendering the history writes tool-call blocks straight to the chat
    -- buffer, bypassing the handlers that record ops, so the tally has to come
    -- from the history. Cleared first: `load` deliberately keeps ops recorded
    -- before it ran, but the tally of the conversation being replaced must not
    -- follow the user into the new one.
    self.file_activity:clear()
    self.file_activity:load(history.file_activity)

    if history.title ~= "" then
        self._title_user_set = true
        self.widget:set_chat_title(history.title)
    end
end

--- Render `self.chat_history`: the subagent transcripts, then the messages
--- the chat shows.
function SessionManager:_render_history()
    -- The history's own messages, not `_history_to_send`: adding the
    -- transcripts points the blocks at their new names in the history.
    self._subagents:add_history_transcripts()
    SessionResume.replay_messages(
        self.message_writer,
        self:_rendered_messages(),
        function(id)
            return self._subagents:peer_detail(id)
        end
    )
    self.tail_lines:reposition()
end

--- The messages of the history the chat shows: those from
--- `ChatHistory.render_start` on. A fork's copied conversation is in its
--- source's chat.
--- @return agentic.ui.ChatHistory.Message[]
function SessionManager:_rendered_messages()
    local messages = self.chat_history.messages
    return vim.list_slice(messages, ChatHistory.render_start(messages))
end

--- Restart the current session: cancel it and re-create it from chat history.
--- Use when a session becomes stuck or unresponsive.
function SessionManager:restart_session()
    if not self.chat_history:has_prompt() then
        self:new_session({ keep_cwd = true })
        return
    end

    local saved_history = vim.deepcopy(self.chat_history)
    -- The history's model is the one at its last save.
    local model = self.config_options:current_model_id()
    self:_cancel_session()
    self:replace_with_history(saved_history, { model = model })
end

--- Fork the conversation into a new chat that changes the turn the cursor
--- is in: the new chat holds the conversation before the prompt at or above
--- the cursor, with that prompt as its draft. Above the chat's first prompt
--- it holds what the chat does not show, with no draft. A prompt the history
--- no longer holds gives way to the one above it. Warns instead while the
--- session loads or is not ready. Works during a running turn.
--- @param mods vim.api.keyset.cmd_mods|nil A split or tab modifier shows the new chat in a new window
function SessionManager:fork_at_cursor(mods)
    local hold = SUBMIT_HOLDS[self:_busy_reason()]
    if hold then
        Logger.notify("Cannot fork: " .. hold, vim.log.levels.WARN)
        return
    end

    local history = self.chat_history
    local writer = self.message_writer
    local target =
        writer:prompt_payload_at(vim.api.nvim_win_get_cursor(0)[1] - 1)
    while target and not history:index_of(target.payload) do
        target = writer:prompt_payload_at(target.row - 1)
    end
    --- @type agentic.ui.ChatHistory.UserMessage|nil
    local prompt = target and target.payload
    local count = (
        prompt and history:index_of(prompt)
        or ChatHistory.render_start(history.messages)
    ) - 1

    local prefix = history:copy_prefix(count)
    if history.title ~= "" then
        prefix:set_title(history.title .. " (fork)")
    end

    local new = SessionRegistry.create(self.agent.provider_name)
    if not new then
        return
    end
    -- Before the constructor's deferred on-ready runs.
    new._pending_fork = {
        source_id = self.session_id --[[@as string]],
        source_chat_id = history.chat_id,
        source_cwd = self._cwd,
        source_title = history.title,
        history = prefix,
        before = prompt or history:next_prompt(count),
        model = prompt and prompt.model
            or self.config_options:current_model_id(),
        mode = self.config_options:current_mode_id(),
    }
    new._cwd = self._cwd
    if prompt then
        new.widget:panel_buf("input")
        new.widget.input_dispatch:prepend_draft(prompt.text)
    end
    new.widget:show(mods, SessionRegistry.target_win())
end

--- Start the session of a fork. A fork holding no prompt is a new session
--- without links. Otherwise the fork's history gets its link to the source,
--- and the provider cuts its own copy of the conversation where it can
--- (`ACPClient:can_fork`); else, or when the cut fails, the history is sent
--- as text with the first prompt.
--- @param fork agentic.SessionManager.ForkStart
function SessionManager:_do_start_fork(fork)
    local history = fork.history
    if not history:has_prompt() then
        if fork.model then
            self.config_options:set_pending_initial_model(fork.model)
        end
        self:new_session({ keep_cwd = true, mode = fork.mode })
        return
    end

    --- @type agentic.ui.ChatHistory.ForkLink
    local link = {
        type = "fork_link",
        direction = "from",
        chat_id = fork.source_chat_id,
        cwd = fork.source_cwd,
        title = fork.source_title ~= "" and fork.source_title
            or fork.source_chat_id:sub(1, 8),
    }
    history:add_message(link)

    local point = history:fork_point()
    if not (point and self.agent:can_fork(point)) then
        self:_start_fork_from_history(fork)
        return
    end

    self:_install_history(history)
    self:_advance_session_epoch()
    self.tail_lines:show_step("forking")
    local epoch = self._session_epoch
    self.agent:fork_session(
        fork.source_id,
        self._cwd,
        point,
        self:_build_handlers(),
        function(result, err)
            if self.destroyed or epoch ~= self._session_epoch then
                if result then
                    self.agent:unsubscribe(result.sessionId)
                end
                return
            end
            self.tail_lines:clear_step()
            if err or not result then
                local message = "session/fork failed: "
                    .. (err and err.message or "no result")
                    .. " — sending the history with the first prompt"
                -- A response the provider has not recorded: one stopped
                -- early, or one still streaming.
                if err and err.code == ACPClient.ERROR_CODES.INVALID_PARAMS then
                    Logger.debug(message)
                else
                    Logger.notify(message, vim.log.levels.WARN)
                end
                self:_start_fork_from_history(fork)
                return
            end

            -- Not continued: the new manager has no earlier conversation.
            self:_adopt_session(result.sessionId, result, false)
            self:_set_initial_mode(fork.mode)
            self:_render_history()
            self:_started_fork(fork)
            self:_reapply_model(fork.model)
            self:_refresh_name()
            self:_drain_queue()
        end
    )
end

--- Start the session of a fork with its history sent as text with the first
--- prompt.
--- @param fork agentic.SessionManager.ForkStart
function SessionManager:_start_fork_from_history(fork)
    self:replace_with_history(fork.history, {
        model = fork.model,
        mode = fork.mode,
        quiet_welcome = true,
        on_created = function()
            self:_started_fork(fork)
        end,
    })
end

--- Save the history of this fork, and give its source, when a session has the
--- source chat open, the link to this fork above `fork.before`.
--- @param fork agentic.SessionManager.ForkStart
function SessionManager:_started_fork(fork)
    self:_history_changed(self.chat_history)
    local source = SessionRegistry.session_for_key(fork.source_chat_id)
    if not (source and fork.before) then
        return
    end
    local chat_id = self.chat_history.chat_id
    local title = self.chat_history.title
    source:add_fork_link({
        type = "fork_link",
        direction = "to",
        chat_id = chat_id,
        cwd = self._cwd,
        title = title ~= "" and title or chat_id,
    }, fork.before)
end

return SessionManager

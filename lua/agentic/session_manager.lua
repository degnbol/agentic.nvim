-- The session manager class glues together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- When the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local FileSystem = require("agentic.utils.file_system")
local GitFiles = require("agentic.utils.git_files")
local Logger = require("agentic.utils.logger")
local SlashCommands = require("agentic.acp.slash_commands")
local States = require("agentic.states")
local TrustSafety = require("agentic.utils.trust_safety")
local WindowDecoration = require("agentic.ui.window_decoration")

--- @class agentic._SessionManagerPrivate
local P = {}

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

--- @class agentic.SessionManager
--- @field session_id? string
--- @field tab_page_id integer
--- @field _is_first_message boolean Whether this is the first message in the session, used to add system info only once
--- @field is_generating boolean
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field message_writer agentic.ui.MessageWriter
--- @field permission_manager agentic.ui.PermissionManager
--- @field status_animation agentic.ui.StatusAnimation
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field diagnostics_list agentic.ui.DiagnosticsList
--- @field config_options agentic.acp.AgentConfigOptions
--- @field todo_list agentic.ui.TodoList
--- @field chat_history agentic.ui.ChatHistory
--- @field _history_to_send? agentic.ui.ChatHistory.Message[] Messages to prepend on next prompt submit
--- @field _restoring boolean Flag to prevent auto-new_session during restore
--- @field _session_epoch integer Monotonic counter incremented on each new_session/load; guards stale create_session callbacks
--- @field _pending_load_session_id? string Deferred session/load until agent is ready
--- @field _pending_load_cwd? string CWD for the deferred session/load
--- @field _pending_load_model? string Model id to apply after session/load succeeds
--- @field _usage? { used: number, size: number, cost?: { amount: number, currency: string } }
--- @field _last_prompt? string
--- @field _destroyed boolean Flag set on destroy() to guard async callbacks
--- @field _reauth_keymap? {bufnr: number, lhs: string} Active re-auth keymap for cleanup
--- @field _reauth_job? table Running claude auth login process (vim.SystemObj)
--- @field _health_check_timer? uv.uv_timer_t Exponential backoff timer for server health checks
--- @field _pending_input? string Prompt queued before the ACP session is ready
--- @field _retry_timer? uv.uv_timer_t Scheduled auto-continue timer for usage limit errors
--- @field _retry_keymap? {bufnr: number, lhs: string} Active cancel-retry keymap
--- @field _retry_attempt number Consecutive auto-continue attempts (0 = first try)
--- @field _queued_prompts? string[] User messages queued while waiting for auto-continue timer
--- @field _checktime_scheduled boolean Coalesces rapid checktime calls into one deferred check
local SessionManager = {}
SessionManager.__index = SessionManager

--- Ring terminal bell if notifications.bell is enabled.
--- Static method (stubbable in tests).
function SessionManager._ring_bell()
    if Config.notifications and Config.notifications.bell then
        io.stderr:write("\a")
    end
end

--- Notify the user that the agent needs attention.
--- Bell for unfocused windows, buffer-name badge when scrolled up in a focused window.
--- @param badge string Badge text (e.g. "[done]", "[?]")
function SessionManager:_notify_attention(badge)
    local chat_win = self.widget.win_nrs.chat
    local is_chat_focused = chat_win
        and vim.api.nvim_win_is_valid(chat_win)
        and vim.api.nvim_get_current_win() == chat_win

    local near_bottom = self.message_writer:is_near_bottom()

    if is_chat_focused then
        -- Focused on chat: badge if scrolled up, no bell (can't dismiss easily)
        if not near_bottom then
            self.widget:set_unread_badge(badge)
        end
    else
        -- Not focused on chat: bell + badge
        SessionManager._ring_bell()
        if not near_bottom then
            self.widget:set_unread_badge(badge)
        end
    end
end

--- Generate the welcome header for a new session
--- @param session_id string|nil
--- @return string header
function SessionManager._generate_welcome_header(_, session_id)
    local ts = os.date("%Y-%m-%d %H:%M")
    local short_id = session_id and session_id:sub(1, 8) or "unknown"
    return string.format("# %s · %s", ts, short_id)
end

--- Refresh chat_history.provider / model from current state so the next save
--- records which provider and model produced the conversation.
function SessionManager:_sync_history_context()
    if not self.chat_history then
        return
    end
    self.chat_history.provider = Config.provider
    local opts = self.config_options
    if opts then
        self.chat_history.model = (opts.model and opts.model.currentValue)
            or (
                opts.legacy_agent_models
                and opts.legacy_agent_models.current_model_id
            )
    end
end

--- @param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local ChatWidget = require("agentic.ui.chat_widget")
    local CodeSelection = require("agentic.ui.code_selection")
    local FileList = require("agentic.ui.file_list")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local StatusAnimation = require("agentic.ui.status_animation")
    local TodoList = require("agentic.ui.todo_list")
    local AgentConfigOptions = require("agentic.acp.agent_config_options")

    self = setmetatable({
        session_id = nil,
        tab_page_id = tab_page_id,
        _is_first_message = true,
        is_generating = false,
        _restoring = false,
        _session_epoch = 0,
        _destroyed = false,
        --- @type string|nil Smart path of the most recently edited .md file (plan candidate)
        _last_edited_md = nil,
        --- @type boolean Set when Plan→Normal mode switch detected; cleared after turn ends
        _plan_exit_pending = false,
        _retry_attempt = 0,
        _checktime_scheduled = false,
    }, self)

    local agent = AgentInstance.get_instance(Config.provider, function(_client)
        vim.schedule(function()
            if self._destroyed then
                return
            end

            if self._pending_load_session_id then
                -- Deferred load_acp_session: agent is now ready
                --- @type string
                local sid = self._pending_load_session_id
                local pending_cwd = self._pending_load_cwd
                local pending_model = self._pending_load_model
                self._pending_load_session_id = nil
                self._pending_load_cwd = nil
                self._pending_load_model = nil
                self:_do_load_acp_session(sid, pending_cwd, pending_model)
            elseif not self._restoring then
                -- Skip auto-new_session if restore_from_history was called
                self:new_session()
            end
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent

    self.chat_history = ChatHistory:new()

    self.widget = ChatWidget:new(tab_page_id, function(input_text)
        self:_handle_input_submit(input_text)
    end)

    self.widget.on_refresh = function()
        self:_refresh()
    end

    self.widget.on_hide = function()
        if #self.chat_history.messages == 0 then
            -- Trivial session (no prompts sent) — destroy without a trace.
            -- Schedule to avoid re-entering widget:destroy() from inside hide().
            -- Capture self so a replacement session installed on the same tab
            -- during the schedule delay isn't wiped by destroy-by-tab-id.
            local this = self
            vim.schedule(function()
                local SessionRegistry = require("agentic.session_registry")
                if SessionRegistry.sessions[this.tab_page_id] == this then
                    SessionRegistry.destroy_session(this.tab_page_id)
                end
            end)
            return
        end
        if self.session_id then
            local short_id = self.session_id:sub(1, 8)
            Logger.notify("Session " .. short_id)
        end
    end

    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)
    self.message_writer =
        MessageWriter:new(self.widget.buf_nrs.chat, self.status_animation)
    self.permission_manager =
        PermissionManager:new(self.message_writer, self.widget.buf_nrs)

    States.setChatBufnr(self.widget.buf_nrs.input, self.widget.buf_nrs.chat)

    local LspServer = require("agentic.completion.lsp_server")
    vim.schedule(function()
        LspServer.attach(self.widget.buf_nrs.input)
    end)

    self.config_options = AgentConfigOptions:new(
        self.widget.buf_nrs,
        function(mode_id, is_legacy)
            self:_handle_mode_change(mode_id, is_legacy)
        end,
        function(model_id, is_legacy)
            self:_handle_model_change(model_id, is_legacy)
        end
    )

    self.file_list = FileList:new(self.widget.buf_nrs.files, function(file_list)
        if file_list:is_empty() then
            self.widget:close_optional_window("files")
            self.widget:move_cursor_to(self.widget.win_nrs.input)
        else
            self.widget:render_header("files", tostring(#file_list:get_files()))
            self.widget:show({ focus_prompt = false })
        end
    end)

    self.code_selection = CodeSelection:new(
        self.widget.buf_nrs.code,
        function(code_selection)
            if code_selection:is_empty() then
                self.widget:close_optional_window("code")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                self.widget:render_header(
                    "code",
                    tostring(#code_selection:get_selections())
                )
                self.widget:show({ focus_prompt = false })
            end
        end
    )

    self.diagnostics_list = DiagnosticsList:new(
        self.widget.buf_nrs.diagnostics,
        function(diagnostics_list)
            if diagnostics_list:is_empty() then
                self.widget:close_optional_window("diagnostics")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                -- show() opens layouts but does not update the diagnostics header count
                self.widget:render_header(
                    "diagnostics",
                    tostring(#diagnostics_list:get_diagnostics())
                )
                self.widget:show({ focus_prompt = false })
            end
        end
    )

    self.todo_list = TodoList:new(self.widget.buf_nrs.todos, function(todo_list)
        if not todo_list:is_empty() then
            self.widget:show({ focus_prompt = false })
        end
    end, function()
        self.widget:close_optional_window("todos")
    end)

    return self
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    -- order the IF blocks in order of likeliness to be called for performance

    if update.sessionUpdate == "plan" then
        if Config.windows.todos.display then
            self.todo_list:render(update.entries)
        end
    elseif update.sessionUpdate == "agent_message_chunk" then
        self.message_writer:write_message_chunk(update)
        self.status_animation:start("generating")

        if update.content and update.content.text then
            self.chat_history:append_agent_text({
                type = "agent",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "agent_thought_chunk" then
        self.message_writer:write_message_chunk(update)
        self.status_animation:start("thinking")

        if update.content and update.content.text then
            self.chat_history:append_agent_text({
                type = "thought",
                text = update.content.text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "user_message_chunk" then
        -- Arrives during session/load replay (ACPClient filters it out in
        -- normal operation). Format as a user heading and write to chat.
        -- The provider sends each content block from the original prompt as
        -- a separate event — including system metadata (environment_info,
        -- slash command tags, selection instructions, etc.). Filter those
        -- out: real user text is plain prose, system blocks start with `<`.
        local text = update.content and update.content.text
        if text and text ~= "" then
            local trimmed = vim.trim(text)
            -- Match XML-tagged system blocks: <tag_name> ... </tag_name>
            -- Requires both opening and closing tags to avoid false positives
            -- on user text that happens to start with '<'.
            local tag = trimmed:match("^<(%w[%w_-]*)[ >]")
            if
                (tag and trimmed:match("</" .. tag .. ">%s*$"))
                or trimmed:match("^IMPORTANT: Focus")
            then
                -- System metadata injected into the prompt — skip
            else
                local user_message = ACPPayloads.generate_user_message({
                    "##",
                    text,
                    "\n---\n",
                })
                self.message_writer:write_message(user_message)
                self.chat_history:add_message({
                    type = "user",
                    text = text,
                    timestamp = os.time(),
                    provider_name = self.agent.provider_config.name,
                })
            end
        end
    elseif update.sessionUpdate == "available_commands_update" then
        SlashCommands.setCommands(
            self.widget.buf_nrs.input,
            update.availableCommands
        )
    elseif update.sessionUpdate == "current_mode_update" then
        -- only for legacy modes, not for config_options
        if
            self.config_options.legacy_agent_modes:handle_agent_update_mode(
                update.currentModeId
            )
        then
            self:_update_chat_header()
        end
    elseif update.sessionUpdate == "config_option_update" then
        self:_handle_new_config_options(update.configOptions)
    elseif update.sessionUpdate == "usage_update" then
        self._usage = {
            used = update.used,
            size = update.size,
            cost = update.cost,
        }

        self:_update_chat_header()
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

--- Manual refresh: reset stale generating state and scroll to bottom.
--- Workaround for when the display gets out of sync (e.g. background task
--- completion, or the prompt response callback racing with a new turn).
function SessionManager:_refresh()
    if self.is_generating then
        -- If nothing is actually streaming, the state is stale — reset it.
        -- If a turn IS active, this is harmless: the next response callback
        -- will set is_generating = false anyway.
        self.is_generating = false
        self.status_animation:stop()
    end

    -- Clear per-turn MessageWriter flags that can desynchronise the display
    -- (rejection suppression, chunk tracking, etc.). Cosmetic-only effect
    -- mid-turn; essential for recovering from a stuck state between turns.
    self.message_writer:reset_turn_state()

    self.message_writer:scroll_to_bottom()
end

--- Display context usage info locally (intercepted /context command)
function SessionManager:_display_context_usage()
    local lines = { "**Context usage:**", "" }

    if self._usage and self._usage.size > 0 then
        local pct = math.floor(self._usage.used / self._usage.size * 100)
        local used_k = string.format("%.1fk", self._usage.used / 1000)
        local size_k = string.format("%.1fk", self._usage.size / 1000)

        table.insert(
            lines,
            string.format("- Tokens: %s / %s (%d%%)", used_k, size_k, pct)
        )

        if self._usage.cost then
            table.insert(
                lines,
                string.format(
                    "- Cost: $%.4f %s",
                    self._usage.cost.amount,
                    self._usage.cost.currency
                )
            )
        end
    else
        table.insert(lines, "No usage data available yet.")
    end

    self.message_writer:write_message(
        ACPPayloads.generate_agent_message(table.concat(lines, "\n"))
    )
    self.message_writer:append_separator()
end

--- Rename the current session and update buffer name.
--- @param new_title string
function SessionManager:_rename_session(new_title)
    local trimmed = vim.trim(new_title)
    if trimmed == "" then
        return
    end

    self.chat_history.title = trimmed
    self.widget:set_chat_title(trimmed)

    self.message_writer:write_message(
        ACPPayloads.generate_agent_message(
            string.format("Session renamed to: **%s**", trimmed)
        )
    )
    self.message_writer:append_separator()

    -- Persist the updated title
    self:_sync_history_context()
    self.chat_history:save()
end

--- Push the trust scope display into the chat panel headers state so
--- external UI plugins (incline, tabline) can surface it.
--- @param display? string Trust scope display string, or nil to clear
function SessionManager:_push_trust_to_headers(display)
    local headers = WindowDecoration.get_headers_state(self.tab_page_id)
    if not headers.chat then
        return
    end
    headers.chat.trust = display
    WindowDecoration.set_headers_state(self.tab_page_id, headers)
end

--- Apply a compiled trust scope: store on PermissionManager, write a chat
--- confirmation, push to headers, and emit a WARN notify when the scope is
--- judged unusually wide.
--- @param scope agentic.utils.TrustSafety.Scope
function SessionManager:_apply_trust_scope(scope)
    self.permission_manager:set_trust_scope(scope)
    self:_push_trust_to_headers(scope.display)

    self.message_writer:write_message(
        ACPPayloads.generate_agent_message(
            string.format("Trust scope set: **%s**", scope.display)
        )
    )
    self.message_writer:append_separator()

    local wide, reason = TrustSafety.is_wide_scope(scope)
    if wide then
        Logger.notify(
            string.format(
                "Wide trust scope (%s): %s — auto-approves edit/write/create/delete/move",
                reason or "wide",
                scope.display
            ),
            vim.log.levels.WARN,
            { title = "Agentic /trust" }
        )
    end
end

--- Clear the active trust scope.
function SessionManager:_clear_trust_scope()
    self.permission_manager:clear_trust_scope()
    self:_push_trust_to_headers(nil)

    self.message_writer:write_message(
        ACPPayloads.generate_agent_message("Trust scope cleared.")
    )
    self.message_writer:append_separator()
end

--- @param prompt string
--- @param items table[]
--- @param on_choice fun(item: any|nil)
local function ui_select(prompt, items, on_choice, format_item)
    vim.ui.select(items, {
        prompt = prompt,
        format_item = format_item,
    }, on_choice)
end

--- Open the /trust selector menu (no argument form).
function SessionManager:_show_trust_picker()
    local cwd = vim.uv.cwd() or vim.fn.getcwd()
    --- @type { kind: "repo"|"here"|"path"|"off", label: string }[]
    local items = {
        { kind = "repo", label = "Git-tracked files in repo" },
        {
            kind = "here",
            label = string.format("Git-tracked files under %s", cwd),
        },
        { kind = "path", label = "Path or glob…" },
        { kind = "off", label = "Off" },
    }
    ui_select("Agentic trust scope:", items, function(choice)
        if not choice then
            return
        end
        if choice.kind == "off" then
            self:_clear_trust_scope()
        elseif choice.kind == "path" then
            vim.ui.input({ prompt = "Path or glob: " }, function(input)
                if not input or vim.trim(input) == "" then
                    return
                end
                self:_handle_trust_command(vim.trim(input))
            end)
        else
            self:_handle_trust_command(choice.kind)
        end
    end, function(item)
        return item.label
    end)
end

--- Dispatch /trust subcommands. Empty arg opens the picker; the three
--- reserved literals are handled directly; anything else is treated as a
--- path or glob.
--- @param arg string Trimmed argument
function SessionManager:_handle_trust_command(arg)
    if not Config.auto_approve_trust_scope then
        self.message_writer:write_error_action(
            "/trust is disabled (Config.auto_approve_trust_scope = false)."
        )
        return
    end

    if arg == "" then
        self:_show_trust_picker()
        return
    end

    if arg == "off" then
        self:_clear_trust_scope()
        return
    end

    local cwd = vim.uv.cwd() or vim.fn.getcwd()

    if arg == "repo" or arg == "here" then
        local git_root = GitFiles.get_git_root(cwd)
        if not git_root then
            self.message_writer:write_error_action(
                string.format("/trust %s: no git repository at %s.", arg, cwd)
            )
            return
        end
        local scope = TrustSafety.build_reserved_scope(arg, cwd, git_root)
        self:_apply_trust_scope(scope)
        return
    end

    local scope = TrustSafety.compile_path_scope(arg, cwd)
    self:_apply_trust_scope(scope)
end

--- Delete the current session from disk and clear the UI.
--- With confirm_delete enabled (default), prompts before proceeding.
function SessionManager:_delete_session()
    if not self.session_id then
        self.message_writer:write_message(
            ACPPayloads.generate_agent_message("No active session to delete.")
        )
        self.message_writer:append_separator()
        return
    end

    local session_id = self.session_id --[[@as string]]

    local function do_delete()
        local ok, err = ChatHistory.delete_session(session_id)
        if ok then
            self:_cancel_session()
            Logger.notify(
                "Session " .. session_id:sub(1, 8) .. " deleted.",
                vim.log.levels.INFO
            )
        else
            self.message_writer:write_message(
                ACPPayloads.generate_agent_message(
                    string.format(
                        "Failed to delete session: %s",
                        err or "unknown error"
                    )
                )
            )
            self.message_writer:append_separator()
        end
    end

    if Config.session_restore.confirm_delete ~= false then
        -- Deferred to run after _submit_input completes its cleanup
        -- (close_optional_window, move_cursor_to). Without the schedule,
        -- confirm() races with the scheduled move_cursor_to(chat).
        vim.schedule(function()
            local choice = vim.fn.confirm( -- no nvim_* equivalent
                "Delete session " .. session_id:sub(1, 8) .. "?",
                "&Yes\n&No",
                2
            )
            if choice == 1 then
                do_delete()
            end
        end)
    else
        do_delete()
    end
end

--- Handle non-JSON text from the ACP process (stdout non-JSON or stderr).
--- Used for local command output (e.g. /context) that bypasses JSON-RPC.
--- Only displays when a prompt is actively generating to avoid noise.
--- @param text string
function SessionManager:_on_stdout_text(text)
    if not self.is_generating then
        return
    end

    self.message_writer:write_message(ACPPayloads.generate_agent_message(text))
end

--- Build the ACP client handlers table.
--- @param opts { skip_history?: boolean }|nil
--- @return agentic.acp.ClientHandlers
function SessionManager:_build_handlers(opts)
    local skip_history = opts and opts.skip_history or false

    --- @type agentic.acp.ClientHandlers
    return {
        on_error = function(err)
            Logger.debug("Agent error: ", err)
            local error_type, reset_epoch =
                self.message_writer:write_error_message(err)
            if error_type == "authentication_error" then
                self:_offer_reauth()
            elseif error_type == "usage_limit" and reset_epoch then
                self:_offer_auto_continue(reset_epoch)
            end
        end,

        on_session_update = function(update)
            self:_on_session_update(update)
        end,

        on_tool_call = function(tool_call)
            self:_on_tool_call(tool_call, skip_history)
        end,

        on_tool_call_update = function(tool_call_update)
            self:_on_tool_call_update(tool_call_update)
            self.status_animation:reposition()
        end,

        on_stdout_text = function(text)
            self:_on_stdout_text(text)
        end,

        on_request_permission = function(request, callback)
            self:_on_request_permission(request, callback)
        end,
    }
end

--- Handle initial tool_call: write to UI, store in history, track plan exit.
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
--- @param skip_history boolean|nil Skip chat history storage (e.g. during session/load replay)
function SessionManager:_on_tool_call(tool_call, skip_history)
    self.message_writer:write_tool_call_block(tool_call)
    self.status_animation:reposition()

    if not skip_history then
        --- @type agentic.ui.ChatHistory.ToolCall
        local tool_msg = {
            type = "tool_call",
            tool_call_id = tool_call.tool_call_id,
            kind = tool_call.kind,
            status = tool_call.status,
            argument = tool_call.argument,
            body = tool_call.body,
            diff = tool_call.diff,
        }
        self.chat_history:add_message(tool_msg)
    end

    self:_try_record_edit_range(tool_call.tool_call_id)
    self:_track_plan_exit(tool_call)
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
--- matches.
---
--- The recorded path is canonicalised to match the shape
--- `PermissionManager:_check_trust` uses for lookup (derived from
--- `rawInput.file_path`, normalised via vim.fs.normalize).
--- @param tool_call_id string
function SessionManager:_try_record_edit_range(tool_call_id)
    if not tool_call_id then
        return
    end
    if self.permission_manager:has_edit_range(tool_call_id) then
        return
    end
    local tracker = self.message_writer.tool_call_blocks[tool_call_id]
    if not tracker or tracker.kind ~= "edit" then
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
    local path = vim.fs.normalize(
        vim.fn.fnamemodify(tracker.argument, ":p"),
        { expand_env = false }
    )
    local file_lines, err = FileSystem.read_from_disk(path)
    if not file_lines then
        Logger.debug("trust: pre-edit read failed for", path, err)
        return
    end
    local start_line =
        TrustSafety.find_unique_subsequence(file_lines, old_lines)
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

--- Detect Plan→Normal mode switch so the turn-end callback can offer
--- context clearing and plan implementation.
--- @param tool_call agentic.ui.MessageWriter.ToolCallBlock
function SessionManager:_track_plan_exit(tool_call)
    if tool_call.kind == "switch_mode" and tool_call.argument == "Normal" then
        self._plan_exit_pending = true
    end
end

--- Find the most recently modified .md file in ~/.claude/plans/.
--- Returns the path if modified within the last 5 minutes, nil otherwise.
--- @return string|nil
local function find_recent_plan_file()
    local plans_dir = vim.fn.expand("~/.claude/plans")
    local best_path, best_mtime = nil, 0
    local cutoff = os.time() - 300 -- 5 minutes

    local handle = vim.uv.fs_scandir(plans_dir)
    if not handle then
        return nil
    end

    while true do
        local name, type = vim.uv.fs_scandir_next(handle)
        if not name then
            break
        end
        if type == "file" and name:match("%.md$") then
            local full = plans_dir .. "/" .. name
            local stat = vim.uv.fs_stat(full)
            if stat and stat.mtime.sec > best_mtime then
                best_mtime = stat.mtime.sec
                best_path = full
            end
        end
    end

    if best_path and best_mtime >= cutoff then
        return best_path
    end
    return nil
end

local PLAN_IMPLEMENT_ID = "__plan_implement__"

--- Handle permission request: show diff preview, set up keymaps, queue request.
--- For ExitPlanMode permissions, injects a "Clear context & implement plan"
--- option that accepts the plan, cancels the session, and starts a fresh
--- session with the plan file as the initial prompt.
--- @param request agentic.acp.RequestPermission
--- @param callback fun(option_id: string|nil)
function SessionManager:_on_request_permission(request, callback)
    self.status_animation:stop()

    -- Detect ExitPlanMode permission via the tracked tool call block
    local tracker =
        self.message_writer.tool_call_blocks[request.toolCall.toolCallId]
    local is_plan_exit = tracker
        and tracker.kind == "switch_mode"
        and tracker.argument == "Normal"

    if is_plan_exit then
        -- Inject "Clear context & implement plan" option.
        -- It sorts first (priority 0 in PermissionManager).
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
            -- Find the real allow_once option to accept the plan
            local accept_id
            for _, opt in ipairs(request.options) do
                if opt.kind == "allow_once" then
                    accept_id = opt.optionId
                    break
                end
            end
            callback(accept_id)

            -- Discover the plan file before cancelling (clears tracking state)
            local plan_path = self._last_edited_md or find_recent_plan_file()

            -- Defer to avoid re-entrancy with PermissionManager cleanup
            vim.schedule(function()
                self:new_session({
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

        callback(option_id)

        if self._destroyed then
            return
        end

        -- Look up the option kind from the request options.
        -- option_id is an opaque ACP identifier (e.g. "reject-once"),
        -- not the kind string ("reject_once").
        local option_kind
        for _, opt in ipairs(request.options) do
            if opt.optionId == option_id then
                option_kind = opt.kind
                break
            end
        end

        local is_rejection = option_kind == "reject_once"
            or option_kind == "reject_always"
        self:_clear_diff_in_buffer(request.toolCall.toolCallId, is_rejection)

        if is_rejection then
            self.message_writer:suppress_next_rejection()
        end

        if
            not self.permission_manager.current_request
            and #self.permission_manager.queue == 0
        then
            self.status_animation:start("generating")
        end
    end

    -- Non-essential UI setup (notifications, hooks) must not prevent
    -- add_request from being called. If add_request never runs, the ACP
    -- permission callback is lost — the provider waits forever for a
    -- response, permanently locking the session.
    local ok, err = pcall(function()
        self:_notify_attention("[?]")

        P.invoke_hook("on_permission_request", {
            session_id = self.session_id,
            tab_page_id = self.tab_page_id,
            tool_call_id = request.toolCall.toolCallId,
        })
    end)

    if not ok then
        Logger.notify(
            "Error setting up permission UI (permission still queued): "
                .. tostring(err),
            vim.log.levels.WARN
        )
    end

    self.permission_manager:add_request(request, wrapped_callback)
end

--- Handle tool call update: update UI, history, diff preview, permissions, and reload buffers
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBase
function SessionManager:_on_tool_call_update(tool_call_update)
    self.message_writer:update_tool_call_block(tool_call_update)
    self:_try_record_edit_range(tool_call_update.tool_call_id)

    --- @type agentic.ui.ChatHistory.ToolCall
    local tool_call = {
        type = "tool_call",
        tool_call_id = tool_call_update.tool_call_id,
        status = tool_call_update.status,
        body = tool_call_update.body,
        diff = tool_call_update.diff,
    }

    self.chat_history:update_tool_call(tool_call_update.tool_call_id, tool_call)

    -- pre-emptively clear diff preview when tool call update is received, as it's either done or failed
    local is_rejection = tool_call_update.status == "failed"
    self:_clear_diff_in_buffer(tool_call_update.tool_call_id, is_rejection)

    -- Remove the permission request if the tool call failed before user granted it
    if tool_call_update.status == "failed" then
        self.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
        self.permission_manager:drop_pending_edit(tool_call_update.tool_call_id)
    end

    if tool_call_update.status == "completed" then
        self.permission_manager:finalize_edit_range(
            tool_call_update.tool_call_id
        )
    end

    -- Reload buffers when file-mutating tool calls complete.
    -- Debounce: rapid tool_call_update completions (e.g. hook retry cycles)
    -- coalesce into a single deferred checktime() to avoid cascading
    -- autocmds (FileChangedShell → BufReadPost → LSP → treesitter) that
    -- can overwhelm the event loop and crash neovim.
    if tool_call_update.status == "completed" then
        local tracker =
            self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]

        if tracker and tracker.kind and FILE_MUTATING_KINDS[tracker.kind] then
            if not self._checktime_scheduled then
                self._checktime_scheduled = true
                vim.schedule(function()
                    self._checktime_scheduled = false
                    if not self._destroyed then
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
            tracker
            and FILE_MUTATING_KINDS[tracker.kind]
            and tracker.argument
            and tracker.argument:match("%.md$")
        then
            self._last_edited_md = tracker.argument
        end
    end

    if
        not self.permission_manager.current_request
        and #self.permission_manager.queue == 0
    then
        self.status_animation:start("generating")
    end
end

--- Send the newly selected mode to the agent and handle the response
--- @param mode_id string
--- @param is_legacy boolean|nil
function SessionManager:_handle_mode_change(mode_id, is_legacy)
    if not self.session_id then
        return
    end

    local function callback(result, err)
        if err then
            Logger.notify(
                string.format(
                    "Failed to change mode to '%s': %s",
                    mode_id,
                    err.message
                ),
                vim.log.levels.ERROR
            )
        else
            -- needed for backward compatibility
            self.config_options.legacy_agent_modes.current_mode_id = mode_id

            if result and result.configOptions then
                Logger.debug("received result after setting mode")
                self:_handle_new_config_options(result.configOptions)
            end

            self:_update_chat_header()

            local mode_name = self.config_options:get_mode_name(mode_id)
            Logger.notify(
                "Mode changed to: " .. mode_name,
                vim.log.levels.INFO,
                {
                    title = "Agentic Mode changed",
                }
            )
        end
    end

    if is_legacy then
        self.agent:set_mode(self.session_id, mode_id, callback)
    else
        self.agent:set_config_option(self.session_id, "mode", mode_id, callback)
    end
end

--- Send the newly selected model to the agent
--- @param model_id string
--- @param is_legacy boolean|nil
function SessionManager:_handle_model_change(model_id, is_legacy)
    if not self.session_id then
        return
    end

    local callback = function(result, err)
        if err then
            Logger.notify(
                string.format(
                    "Failed to change model to '%s': %s",
                    model_id,
                    err.message
                ),
                vim.log.levels.ERROR
            )
        else
            if result and result.configOptions then
                Logger.debug("received result after setting model")
                self:_handle_new_config_options(result.configOptions)
            end

            Logger.notify(
                "Model changed to: " .. model_id,
                vim.log.levels.INFO,
                { title = "Agentic Model changed" }
            )
        end
    end

    if is_legacy then
        self.agent:set_model(self.session_id, model_id, callback)
    else
        self.agent:set_config_option(
            self.session_id,
            "model",
            model_id,
            callback
        )
    end
end

function SessionManager:_update_chat_header()
    local parts = {}

    -- Model name (e.g. "Opus", "Haiku") — always show when available
    local model_id = self.config_options.model
            and self.config_options.model.currentValue
        or self.config_options.legacy_agent_models.current_model_id
    if model_id then
        local model_opt = self.config_options:get_model(model_id)
        local model_name
        if model_opt then
            model_name = model_opt.name
            -- "Default (recommended)" → extract real model from description
            -- e.g. "Opus 4.6 with 1M context" → "Opus"
            if model_name:find("^Default") and model_opt.description then
                model_name = model_opt.description:match("^(%S+)") or model_name
            end
        end
        if not model_name then
            -- Legacy path
            local legacy =
                self.config_options.legacy_agent_models:get_model(model_id)
            model_name = legacy and legacy.name or model_id
        end
        -- Strip "Claude " prefix — redundant for anyone using the plugin
        model_name = model_name:gsub("^Claude ", "")
        table.insert(parts, model_name)
    end

    -- Mode — only show non-default modes (e.g. "Plan")
    local mode_id = self.config_options.mode
            and self.config_options.mode.currentValue
        or self.config_options.legacy_agent_modes.current_mode_id
    if mode_id and mode_id ~= "default" then
        local mode_name = self.config_options:get_mode_name(mode_id) or mode_id
        mode_name = mode_name:gsub(" Mode$", "")
        table.insert(parts, mode_name)
    end

    if self._usage and self._usage.size > 0 then
        local pct = math.floor(self._usage.used / self._usage.size * 100)
        table.insert(parts, string.format("%d%%", pct))
    end

    local context = #parts > 0 and table.concat(parts, " · ") or nil

    -- Update headers state synchronously so external plugins (incline, tabline)
    -- always see current data. render_header's vim.schedule callback also sets
    -- this, but bails out when winid == -1 (widget hidden), losing the update.
    local tab = self.widget.tab_page_id
    if vim.api.nvim_tabpage_is_valid(tab) then
        local headers = WindowDecoration.get_headers_state(tab)
        if headers.chat then
            headers.chat.context = context
            WindowDecoration.set_headers_state(tab, headers)
        end
    end

    -- Render winbar and buffer name (context is already in headers state)
    self.widget:render_header("chat")
end

--- @param input_text string
function SessionManager:_handle_input_submit(input_text)
    -- Intercept /delete before the ready-state guard — it's a local-only
    -- command that doesn't need the ACP provider.
    if input_text:match("^/delete%s*$") then
        self:_delete_session()
        return
    end

    if not (self.session_id and self.agent and self.agent.state == "ready") then
        -- Store for _flush_pending_input when session becomes ready
        self._pending_input = input_text
        return
    end
    self:_handle_input_submit_inner(input_text)
end

--- Send any prompt that was queued before the ACP session was ready.
function SessionManager:_flush_pending_input()
    local text = self._pending_input
    if not text then
        return
    end
    self._pending_input = nil
    self:_handle_input_submit_inner(text)
end

--- @param input_text string
function SessionManager:_handle_input_submit_inner(input_text)
    self.widget:clear_unread_badge()
    self.todo_list:close_if_all_completed()

    -- Intercept /new and /clear to start new session locally, cancelling
    -- existing one. Necessary to avoid race conditions — the agent might not
    -- send an identifiable response that could be acted upon. /clear through
    -- ACP doesn't actually reset provider context, so we handle it as /new.
    if input_text:match("^/new%s*") or input_text:match("^/clear%s*$") then
        self:new_session()
        return
    end

    -- Intercept /context — ACP providers don't emit context info via the protocol,
    -- so we display the last known usage_update data locally
    if input_text:match("^/context%s*$") then
        self:_display_context_usage()
        return
    end

    -- Intercept /rename — rename the current session
    local rename_arg = input_text:match("^/rename%s+(.+)$")
    if rename_arg then
        self:_rename_session(rename_arg)
        return
    elseif input_text:match("^/rename%s*$") then
        self.message_writer:write_message(
            ACPPayloads.generate_agent_message("Usage: `/rename <new name>`")
        )
        self.message_writer:append_separator()
        return
    end

    -- Intercept /trust — set scoped auto-approval for file edits this session
    local trust_arg = input_text:match("^/trust%s*(.*)$")
    if trust_arg then
        self:_handle_trust_command(vim.trim(trust_arg))
        return
    end

    -- Queue message if waiting for usage limit reset — sending now would
    -- just hit the same limit. The timer callback drains the queue.
    if self._retry_timer then
        if not self._queued_prompts then
            self._queued_prompts = {}
        end
        table.insert(self._queued_prompts, input_text)
        self.message_writer:write_error_action(
            "Message queued — will send when usage resets."
        )
        return
    end

    --- @type agentic.acp.Content[]
    local prompt = {}

    -- If restored/switched session, prepend history on first submit
    if self._history_to_send then
        ChatHistory.prepend_restored_messages(self._history_to_send, prompt)
        self._history_to_send = nil
    elseif self.chat_history.title == "" then
        self.chat_history.title = input_text -- Set title for new session
        self.widget:set_chat_title(input_text)
    end

    table.insert(prompt, {
        type = "text",
        text = input_text,
    })

    -- Add system info on first message only (after user text so resume picker shows the prompt)
    local is_first_turn = self._is_first_message
    if self._is_first_message then
        self._is_first_message = false

        table.insert(prompt, {
            type = "text",
            text = self:_get_system_info(),
        })
    end

    --- The message to be written to the chat widget
    local message_lines = {
        "##",
    }

    table.insert(message_lines, input_text)

    if not self.code_selection:is_empty() then
        table.insert(message_lines, "\n- **Selected code**:\n")

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

        local selections = self.code_selection:get_selections()
        self.code_selection:clear()

        for _, selection in ipairs(selections) do
            if selection and #selection.lines > 0 then
                -- Add line numbers to each line in the snippet
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
                    message_lines,
                    string.format(
                        "```%s %s#L%d-L%d\n%s\n```",
                        selection.file_type,
                        selection.file_path,
                        selection.start_line,
                        selection.end_line,
                        table.concat(selection.lines, "\n")
                    )
                )
            end
        end
    end

    if not self.file_list:is_empty() then
        table.insert(message_lines, "\n- **Referenced files**:")

        local files = self.file_list:get_files()
        self.file_list:clear()

        for _, file_path in ipairs(files) do
            table.insert(prompt, ACPPayloads.create_file_content(file_path))

            table.insert(
                message_lines,
                string.format("  - @%s", FileSystem.to_smart_path(file_path))
            )
        end
    end

    if not self.diagnostics_list:is_empty() then
        table.insert(message_lines, "\n- **Diagnostics**:")

        local diagnostics = self.diagnostics_list:get_diagnostics()
        self.diagnostics_list:clear()

        local WidgetLayout = require("agentic.ui.widget_layout")

        local chat_width = WidgetLayout.calculate_width(Config.windows.width)
        local chat_winid = self.widget.win_nrs.chat
        if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
            chat_width = vim.api.nvim_win_get_width(chat_winid)
        end

        local DiagnosticsContext = require("agentic.ui.diagnostics_context")

        local formatted_diagnostics =
            DiagnosticsContext.format_diagnostics(diagnostics, chat_width)

        for _, prompt_entry in ipairs(formatted_diagnostics.prompt_entries) do
            table.insert(prompt, prompt_entry)
        end

        for _, summary_line in ipairs(formatted_diagnostics.summary_lines) do
            table.insert(message_lines, summary_line)
        end
    end

    table.insert(message_lines, "\n---\n")

    local user_message = ACPPayloads.generate_user_message(message_lines)
    self.message_writer:write_message(user_message)

    --- @type agentic.ui.ChatHistory.UserMessage
    local user_msg = {
        type = "user",
        text = input_text,
        timestamp = os.time(),
        provider_name = self.agent.provider_config.name,
    }
    self.chat_history:add_message(user_msg)

    self.status_animation:start("thinking")

    P.invoke_hook("on_prompt_submit", {
        prompt = input_text,
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
    })

    local session_id = self.session_id
    local tab_page_id = self.tab_page_id
    -- Capture chat_history before send to avoid race with _cancel_session
    -- replacing self.chat_history while the callback is pending
    local chat_history = self.chat_history

    self.is_generating = true

    self.agent:send_prompt(self.session_id, prompt, function(response, err)
        -- This callback already runs inside vim.schedule (from _handle_message).
        -- Do NOT add another vim.schedule here — it delays cleanup by one tick,
        -- creating a race where a fast follow-up prompt sets is_generating=true
        -- before the previous turn's cleanup sets it back to false, permanently
        -- desynchronising the generating state ("stuck 1 message behind").
        self.is_generating = false

        if err then
            local error_type, reset_epoch =
                self.message_writer:write_error_message(err)
            if error_type == "authentication_error" then
                self:_offer_reauth()
            elseif error_type == "usage_limit" and reset_epoch then
                self:_offer_auto_continue(reset_epoch)
            else
                self._retry_attempt = 0
            end
        else
            self._retry_attempt = 0
            -- Surface response details when the provider's own fields show
            -- the turn did not complete normally:
            --   - stopReason != "end_turn" (refusal, max_tokens,
            --     max_turn_requests, cancelled, or provider-specific) — checked
            --     every turn
            --   - usage.totalTokens == 0 — only on the FIRST turn (catches the
            --     opencode+litellm silent-auth-failure case where the upstream
            --     rejected the request before any inference). Later turns can
            --     legitimately report zero usage (e.g. stalled generators,
            --     cancelled turns), so we don't treat mid-session zeros as
            --     errors.
            -- Render the provider's fields verbatim, no interpretation.
            local stop_reason = response and response.stopReason
            local usage = response and response.usage
            local zero_tokens = is_first_turn
                and usage
                and (usage.totalTokens == 0 or usage.totalTokens == nil)
                and (usage.inputTokens == 0 or usage.inputTokens == nil)
                and (usage.outputTokens == 0 or usage.outputTokens == nil)
            if
                response
                and ((stop_reason and stop_reason ~= "end_turn") or zero_tokens)
            then
                local parts = {}
                if stop_reason then
                    table.insert(parts, "stopReason: " .. tostring(stop_reason))
                end
                if usage then
                    table.insert(
                        parts,
                        string.format(
                            "usage: input=%s output=%s total=%s",
                            tostring(usage.inputTokens),
                            tostring(usage.outputTokens),
                            tostring(usage.totalTokens)
                        )
                    )
                end
                if #parts > 0 then
                    self.message_writer:write_error_message({
                        code = 0,
                        message = table.concat(parts, "\n"),
                    })
                end
            end
        end

        self.message_writer:append_separator()
        self.message_writer:scroll_to_bottom()

        self.status_animation:stop()

        self:_notify_attention("[done]")

        P.invoke_hook("on_response_complete", {
            session_id = session_id,
            tab_page_id = tab_page_id,
            success = err == nil,
            error = err,
        })

        -- Save chat history after successful turn completion
        if not err then
            self:_sync_history_context()
            chat_history:save(function(save_err)
                if save_err then
                    Logger.debug("Chat history save error:", save_err)
                end
            end)
        end
    end)
end

--- Create a new session, optionally cancelling any existing one
--- @param opts {restore_mode?: boolean, on_created?: fun()}|nil
function SessionManager:new_session(opts)
    opts = opts or {}
    local restore_mode = opts.restore_mode or false
    local on_created = opts.on_created

    if not restore_mode then
        self:_cancel_session()
    end

    self.status_animation:start("busy")

    local handlers = self:_build_handlers()

    -- Capture epoch so the callback can detect if a load (or another
    -- new_session) superseded this create while the RPC was in flight.
    self._session_epoch = self._session_epoch + 1
    local epoch = self._session_epoch

    self.agent:create_session(handlers, function(response, err)
        -- Provider-switch restore: this SessionManager may have been destroyed
        -- (by align_provider_for_restore) while session/new was in flight on
        -- the outgoing provider. Its agent/widget/tabpage state are gone but
        -- the callback closure still holds a reference to self. Continuing
        -- would stamp the destroyed session's config onto vim.t.agentic_headers
        -- (or fall through to _handle_new_config_options etc.), stomping the
        -- replacement session's UI on the same tab.
        if self._destroyed then
            if response and response.sessionId and self.agent then
                self.agent.subscribers[response.sessionId] = nil
            end
            return
        end

        self.status_animation:stop()

        if err or not response then
            -- no log here, already logged in create_session
            self.session_id = nil
            return
        end

        -- A session load (or another new_session) may have started while
        -- this create was in flight. The epoch counter detects this: if the
        -- epoch has advanced, this response is stale and must be discarded.
        -- The _restoring check is kept as a belt-and-braces guard for the
        -- window between _do_load setting _restoring and incrementing epoch.
        --
        -- Only remove the subscriber — do NOT send session/cancel. Sending
        -- cancel for the stale session while session/load is active or just
        -- completed can confuse providers (observed: claude-agent-acp drops
        -- loaded session context when a cancel arrives for a different session
        -- around the same time).
        if self._restoring or epoch ~= self._session_epoch then
            self.agent.subscribers[response.sessionId] = nil
            return
        end

        self.session_id = response.sessionId
        self.chat_history.session_id = response.sessionId
        self.chat_history.timestamp = os.time()
        vim.api.nvim_exec_autocmds("User", {
            pattern = "AgenticSessionChanged",
            data = { session_id = response.sessionId },
        })

        if response.configOptions then
            Logger.debug("Provider announce configOptions")
            self:_handle_new_config_options(response.configOptions)
        else
            if response.modes then
                Logger.debug("Provider announce legacy mode")
                self.config_options:set_legacy_modes(response.modes)
                self:_update_chat_header()
            end

            if response.models then
                Logger.debug("Provider announce legacy models")
                self.config_options:set_legacy_models(response.models)
            end
        end

        self.config_options:set_initial_mode(
            self.agent.provider_config.default_mode,
            function(mode, is_legacy)
                self:_handle_mode_change(mode, is_legacy)
            end
        )

        -- Reset first message flag for new session (skip when restoring)
        if not restore_mode then
            self._is_first_message = true
        end

        -- Add initial welcome message after session is created
        -- Defer to avoid fast event context issues
        -- For restore: write welcome first, then replay via on_created
        vim.schedule(function()
            local welcome_message = SessionManager._generate_welcome_header(
                self.agent.provider_config.name,
                self.session_id
            )

            self.message_writer:write_message(
                ACPPayloads.generate_user_message(welcome_message)
            )

            -- Invoke on_created callback after welcome message is written
            if on_created then
                on_created()
            end

            self:_flush_pending_input()
        end)
    end)
end

--- Load an existing ACP session by ID (e.g. from claude-agent-acp).
--- The agent replays the conversation via session/update notifications.
--- If the agent isn't ready yet (fresh SessionManager), the load is deferred
--- until the on_ready callback fires.
--- @param session_id string Full UUID of the session to load
--- @param cwd? string Original working directory for the session.
---   Falls back to vim.fn.getcwd() if nil.
--- @param model? string Model id saved with the session, applied after load
function SessionManager:load_acp_session(session_id, cwd, model)
    if self.agent and self.agent.agent_capabilities then
        -- Agent is already initialised, load immediately
        self:_do_load_acp_session(session_id, cwd, model)
    else
        -- Agent still starting — defer until on_ready fires
        self._restoring = true
        self._pending_load_session_id = session_id
        self._pending_load_cwd = cwd
        self._pending_load_model = model
    end
end

--- Internal: actually send session/load after the agent is ready.
--- @param session_id string
--- @param cwd? string Original working directory for the session.
--- @param model? string Model id to reapply after load (queued until options arrive).
function SessionManager:_do_load_acp_session(session_id, cwd, model)
    -- Prevent the constructor's deferred on-ready callback from calling
    -- new_session() after we've already started loading.  When the agent
    -- instance is already initialised, get_instance() fires on_ready
    -- synchronously (which vim.schedule's the inner callback), then the
    -- caller invokes load_acp_session() before the scheduled callback runs.
    -- Without this flag the deferred callback sees _pending_load_session_id
    -- = nil, _restoring = false and creates a fresh session that overwrites
    -- the loaded one — destroying all restored context.
    self._restoring = true

    -- Invalidate any in-flight create_session callback. The epoch check in
    -- the create_session callback (new_session) rejects stale responses
    -- even after _restoring is cleared by the load completion handler.
    self._session_epoch = self._session_epoch + 1

    -- Clean up the old session's UI state and subscriber, but do NOT send
    -- session/cancel to the provider. Sending cancel immediately before
    -- session/load disrupts some providers (claude-agent-acp loses loaded
    -- session context). The old ACP session is orphaned — it will expire
    -- on the provider side or be replaced by the loaded session's subscriber.
    if self.session_id then
        -- Remove subscriber to stop routing stale notifications
        self.agent.subscribers[self.session_id] = nil
        self.widget:clear()
        self.todo_list:clear()
        self.file_list:clear()
        self.code_selection:clear()
        self.diagnostics_list:clear()
        self.config_options:clear()
    end
    self.session_id = nil
    self:_remove_reauth_keymap()
    self:_cancel_health_check_timer()
    self:_cancel_retry_timer()
    self.permission_manager:clear()
    SlashCommands.setCommands(self.widget.buf_nrs.input, {})
    self._last_edited_md = nil
    self._plan_exit_pending = false
    self.chat_history = ChatHistory:new()
    self.widget:set_chat_title(nil)
    self._history_to_send = nil

    self.status_animation:start("busy")

    self.session_id = session_id
    self.chat_history.session_id = session_id
    self.chat_history.timestamp = os.time()
    vim.api.nvim_exec_autocmds("User", {
        pattern = "AgenticSessionChanged",
        data = { session_id = session_id },
    })

    local handlers = self:_build_handlers({ skip_history = true })

    local effective_cwd = cwd or vim.fn.getcwd() --[[@as string]]
    self.agent:load_session(
        session_id,
        effective_cwd,
        {},
        handlers,
        function(result, err)
            vim.schedule(function()
                if err then
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
                    self._restoring = false
                    self:_fallback_restore_from_local(session_id)
                    return
                end

                self._restoring = false
                self.status_animation:stop()

                -- Restore title from local history (ACP doesn't return it)
                ChatHistory.load(session_id, function(history)
                    if history and history.title and history.title ~= "" then
                        self.chat_history.title = history.title
                        self.widget:set_chat_title(history.title)
                    end
                end)

                -- Apply configOptions the provider returned with session/load,
                -- so the header reflects the restored session's mode/model
                -- rather than stale state from a pre-switch session.
                if result and result.configOptions then
                    self:_handle_new_config_options(result.configOptions)
                end

                local opts = self.config_options
                if model and opts and opts.set_pending_initial_model then
                    opts:set_pending_initial_model(model)
                end

                local provider_label = self.agent
                        and self.agent.provider_config
                        and self.agent.provider_config.name
                    or Config.provider
                local model_label = model
                    or (opts and opts.model and opts.model.currentValue)
                    or (
                        opts
                        and opts.legacy_agent_models
                        and opts.legacy_agent_models.current_model_id
                    )
                local welcome = string.format(
                    "\n## Resumed session `%s`\nProvider: **%s** · Model: **%s**\n",
                    session_id:sub(1, 8),
                    provider_label,
                    model_label or "unknown"
                )
                self.message_writer:write_message(
                    ACPPayloads.generate_user_message(welcome)
                )
            end)
        end
    )
end

--- Fallback: load session from local chat history when ACP session/load fails.
--- Creates a new ACP session and replays the saved messages.
--- @param session_id string
function SessionManager:_fallback_restore_from_local(session_id)
    ChatHistory.load(session_id, function(history, load_err)
        if load_err or not history then
            self.status_animation:stop()
            Logger.notify(
                "No local history found for session " .. session_id:sub(1, 8),
                vim.log.levels.WARN
            )
            return
        end

        self.session_id = nil -- clear stale ID so restore_from_history creates a new ACP session
        self:restore_from_history(history)
    end)
end

--- Check if the current provider is Claude-based (supports `claude auth login`).
local function is_claude_provider()
    return Config.provider == "claude-acp"
        or Config.provider == "claude-agent-acp"
end

--- Offer re-authentication after a Claude auth error.
--- Checks server health first — if unreachable, polls with exponential
--- backoff until the server is back, then offers the `r` keymap.
function SessionManager:_offer_reauth()
    if not is_claude_provider() then
        return
    end

    self:_check_server_then_offer_reauth(1)
end

--- Set up the [r] keymap to trigger `claude auth login`.
function SessionManager:_set_reauth_keymap()
    self.message_writer:write_error_action(
        "Press [r] to re-authenticate in browser."
    )

    local chat_bufnr = self.widget.buf_nrs.chat
    local lhs = "r"

    vim.keymap.set("n", lhs, function()
        self:_run_reauth()
    end, { buffer = chat_bufnr, nowait = true })

    self._reauth_keymap = { bufnr = chat_bufnr, lhs = lhs }
end

--- Health check URL for Claude's API infrastructure.
local HEALTH_CHECK_URL = "https://api.anthropic.com"

--- Check if the Claude server is reachable before offering reauth.
--- If unreachable, retries with exponential backoff (30s, 60s, 120s, ...).
--- When reachable, sets up the [r] keymap so the user can authenticate.
--- @param attempt number Current attempt number (1-based)
function SessionManager:_check_server_then_offer_reauth(attempt)
    local max_delay_s = 600 -- cap at 10 minutes
    local base_delay_s = 30
    local delay_s = math.min(base_delay_s * (2 ^ (attempt - 1)), max_delay_s)

    self.message_writer:write_error_action(
        string.format("Checking server health (%s)...", HEALTH_CHECK_URL)
    )

    vim.system({
        "curl",
        "-s",
        "-o",
        "/dev/null",
        "--connect-timeout",
        "5",
        HEALTH_CHECK_URL,
    }, {}, function(result)
        vim.schedule(function()
            if self._destroyed then
                return
            end

            if result.code == 0 then
                -- Server reachable — offer login
                self:_set_reauth_keymap()
            else
                -- Server unreachable — schedule retry with backoff
                self.message_writer:write_error_action(
                    string.format(
                        "Server unreachable. Retrying in %ds... (attempt %d)",
                        delay_s,
                        attempt
                    )
                )

                self:_cancel_health_check_timer()
                local timer = vim.uv.new_timer()
                if not timer then
                    return
                end
                self._health_check_timer = timer
                timer:start(delay_s * 1000, 0, function()
                    -- Nil out immediately so _cancel_health_check_timer
                    -- won't call stop/close on an already-closed handle
                    self._health_check_timer = nil
                    timer:stop()
                    timer:close()
                    vim.schedule(function()
                        if self._destroyed then
                            return
                        end
                        self:_check_server_then_offer_reauth(attempt + 1)
                    end)
                end)
            end
        end)
    end)
end

--- Stop and close the health check backoff timer if active.
function SessionManager:_cancel_health_check_timer()
    if self._health_check_timer then
        self._health_check_timer:stop()
        self._health_check_timer:close()
        self._health_check_timer = nil
    end
end

--- Remove the re-auth keymap if one is active.
function SessionManager:_remove_reauth_keymap()
    local km = self._reauth_keymap
    if not km then
        return
    end

    if vim.api.nvim_buf_is_valid(km.bufnr) then
        pcall(vim.keymap.del, "n", km.lhs, { buffer = km.bufnr })
    end
    self._reauth_keymap = nil
end

--- Spawn `claude auth login` to re-authenticate via browser OAuth.
function SessionManager:_run_reauth()
    self:_remove_reauth_keymap()

    if self._reauth_job then
        Logger.notify("Re-authentication already in progress.")
        return
    end

    local auth_type = Config.auth_type or "claudeai"
    local flag = "--" .. auth_type

    Logger.notify("Opening browser for re-authentication...")

    self._reauth_job = vim.system(
        { "claude", "auth", "login", flag },
        {},
        function(result)
            vim.schedule(function()
                self._reauth_job = nil
                if self._destroyed then
                    return
                end

                if result.code == 0 then
                    Logger.notify("Re-authenticated. Restarting provider...")
                    self:_restart_provider()
                else
                    Logger.notify(
                        "Re-authentication failed. Try running 'claude auth login' manually.",
                        vim.log.levels.WARN
                    )
                end
            end)
        end
    )
end

--- Kill the dead cached agent, spawn a fresh provider subprocess,
--- and create a new session. Used after re-authentication when the
--- provider process has exited.
function SessionManager:_restart_provider()
    local AgentInstance = require("agentic.acp.agent_instance")

    -- Remove the dead cached instance so get_instance spawns a fresh one
    self.agent:stop()
    AgentInstance._instances[Config.provider] = nil

    local new_agent = AgentInstance.get_instance(
        Config.provider,
        function(client)
            vim.schedule(function()
                self.agent = client
                self:new_session()
            end)
        end
    )

    if new_agent then
        self.agent = new_agent
    end
end

--- Cancel a pending auto-continue timer and remove the cancel keymap.
--- @param reset_attempts? boolean Also reset the retry attempt counter (default: true)
function SessionManager:_cancel_retry_timer(reset_attempts)
    if self._retry_timer then
        self._retry_timer:stop()
        self._retry_timer:close()
        self._retry_timer = nil
    end

    local km = self._retry_keymap
    if km then
        if vim.api.nvim_buf_is_valid(km.bufnr) then
            pcall(vim.keymap.del, "n", km.lhs, { buffer = km.bufnr })
        end
        self._retry_keymap = nil
    end

    self._queued_prompts = nil

    if reset_attempts ~= false then
        self._retry_attempt = 0
    end
end

--- Format seconds into a human-readable duration (e.g. "2h 15m", "45m", "30s").
--- @param seconds number
--- @return string
local function format_duration(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return string.format("%dh %dm", h, m)
    elseif m > 0 then
        return string.format("%dm", m)
    end
    return string.format("%ds", seconds)
end

--- Schedule auto-continue after a usage limit error.
--- On the first attempt, waits until `reset_epoch + 2 min`. On subsequent
--- attempts (provider's reset time was inaccurate), retries with a fixed
--- 5-minute backoff. Gives up after 3 consecutive attempts.
--- @param reset_epoch number Epoch seconds when usage resets
function SessionManager:_offer_auto_continue(reset_epoch)
    if not Config.auto_continue_on_usage_limit then
        return
    end

    local MAX_RETRIES = 3
    local RETRY_BACKOFF_S = 5 * 60 -- 5 minutes

    if self._retry_attempt >= MAX_RETRIES then
        self.message_writer:write_error_action(
            string.format(
                "Auto-continue gave up after %d attempts. Send a message manually when usage resets.",
                MAX_RETRIES
            )
        )
        self._retry_attempt = 0
        return
    end

    self:_cancel_retry_timer(false)

    local delay_s
    if self._retry_attempt > 0 then
        -- Previous auto-continue got another usage limit error — the provider's
        -- reset time was inaccurate. Use a fixed backoff instead.
        delay_s = RETRY_BACKOFF_S
    else
        delay_s = math.max(reset_epoch - os.time(), 10)
        -- Add buffer to avoid racing the exact reset moment
        delay_s = delay_s + 120
    end

    self._retry_attempt = self._retry_attempt + 1

    local reset_time = os.date("%H:%M", os.time() + delay_s)
    local duration = format_duration(delay_s)
    local attempt_suffix = self._retry_attempt > 1
            and string.format(
                " (attempt %d/%d)",
                self._retry_attempt,
                MAX_RETRIES
            )
        or ""

    self.message_writer:write_error_action(
        string.format(
            "Auto-continuing at %s (in %s)%s. Press [c] to cancel.",
            reset_time,
            duration,
            attempt_suffix
        )
    )

    local chat_bufnr = self.widget.buf_nrs.chat
    local lhs = "c"

    vim.keymap.set("n", lhs, function()
        self:_cancel_retry_timer()
        Logger.notify("Auto-continue cancelled.")
    end, { buffer = chat_bufnr, nowait = true })

    self._retry_keymap = { bufnr = chat_bufnr, lhs = lhs }

    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    self._retry_timer = timer

    timer:start(
        delay_s * 1000,
        0,
        vim.schedule_wrap(function()
            self:_cancel_retry_timer(false)

            if self._destroyed then
                return
            end

            if not self.session_id then
                Logger.notify(
                    "No active session for auto-continue.",
                    vim.log.levels.WARN
                )
                return
            end

            local queued = self._queued_prompts
            self._queued_prompts = nil

            if queued then
                self:_handle_input_submit(table.concat(queued, "\n\n"))
            else
                self:_handle_input_submit("continue")
            end
        end)
    )
end

function SessionManager:_cancel_session()
    if self.session_id then
        -- only cancel and clear content if there was an session
        -- Otherwise, it clears selections and files when opening for the first time
        self.agent:cancel_session(self.session_id)
        self.widget:clear()
        self.todo_list:clear()
        self.file_list:clear()
        self.code_selection:clear()
        self.diagnostics_list:clear()
        self.config_options:clear()
    end

    self.session_id = nil
    self:_remove_reauth_keymap()
    self:_cancel_health_check_timer()
    self:_cancel_retry_timer()
    self.permission_manager:clear()
    SlashCommands.setCommands(self.widget.buf_nrs.input, {})
    self._last_edited_md = nil
    self._plan_exit_pending = false

    self.chat_history = ChatHistory:new()
    self.widget:set_chat_title(nil) -- Reset buffer name to default
    self._history_to_send = nil
    self._pending_input = nil
    self._usage = nil
end

--- Switch to a different ACP provider while preserving chat UI and history.
--- Reads Config.provider (already set by caller) for the target provider.
function SessionManager:switch_provider()
    if self.is_generating then
        Logger.notify(
            "Cannot switch provider while generating. Stop generation first.",
            vim.log.levels.WARN
        )
        return
    end

    local AgentInstance = require("agentic.acp.agent_instance")

    -- Save references before get_instance (on_ready may fire synchronously)
    local saved_history = self.chat_history
    local old_agent = self.agent
    local old_session_id = self.session_id

    -- Get new agent instance BEFORE tearing down the current session
    local new_agent = AgentInstance.get_instance(
        Config.provider,
        function(client)
            vim.schedule(function()
                self.agent = client

                self:new_session({
                    restore_mode = true,
                    on_created = function()
                        -- Capture new session metadata before overwriting
                        local new_session_id = self.chat_history.session_id
                        local new_timestamp = self.chat_history.timestamp

                        -- Restore saved messages (new_session created a fresh one)
                        self.chat_history = saved_history
                        self.chat_history.session_id = new_session_id
                        self.chat_history.timestamp = new_timestamp
                        self._history_to_send = saved_history.messages
                        self._is_first_message = true
                    end,
                })
            end)
        end
    )

    if not new_agent then
        return
    end

    -- Soft cancel: tear down old ACP session now that we have a new agent
    if old_session_id then
        old_agent:cancel_session(old_session_id)
    end
    self.session_id = nil
    self.permission_manager:clear()
    self.todo_list:clear()

    -- If agent was already cached, on_ready fired synchronously above.
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

--- Open the diff for the current permission request's tool call in a new tab.
--- No-op if there is no active permission request or it's not an edit tool call.
function SessionManager:open_diff_in_tab()
    local request = self.permission_manager.current_request
    if not request then
        Logger.notify("No active permission request", vim.log.levels.INFO)
        return
    end
    self:_show_diff_in_buffer(request.toolCallId)
end

--- @param tool_call_id string
function SessionManager:_show_diff_in_buffer(tool_call_id)
    -- Only show diff if enabled by user config,
    -- and cursor is in the same tabpage as this session to avoid disruption
    if
        not Config.diff_preview.enabled
        or vim.api.nvim_get_current_tabpage() ~= self.tab_page_id
    then
        return
    end

    local tracker = tool_call_id
        and self.message_writer.tool_call_blocks[tool_call_id]

    if not tracker or tracker.kind ~= "edit" or tracker.diff == nil then
        return
    end

    local agent_tab = self.tab_page_id

    DiffPreview.show_diff({
        file_path = tracker.argument,
        diff = tracker.diff,
        get_winid = function(bufnr)
            -- Suppress all events during diff tab setup to prevent plugins
            -- (incline, etc.) from reacting to intermediate state, and to
            -- avoid BufNewFile -> FileType -> LSP detach errors.
            local saved = vim.o.eventignore
            vim.o.eventignore = "all"

            vim.cmd("tabnew")
            local diff_tab = vim.api.nvim_get_current_tabpage()
            tracker.diff_tab = diff_tab
            vim.api.nvim_set_current_tabpage(agent_tab)

            local wins = vim.api.nvim_tabpage_list_wins(diff_tab)
            if #wins == 0 then
                vim.o.eventignore = saved
                return nil
            end
            local winid = wins[1]
            vim.api.nvim_win_set_buf(winid, bufnr)

            vim.o.eventignore = saved
            return winid
        end,
    })
end

--- @param tool_call_id string
--- @param is_rejection boolean|nil
function SessionManager:_clear_diff_in_buffer(tool_call_id, is_rejection)
    local tracker = tool_call_id
        and self.message_writer.tool_call_blocks[tool_call_id]

    if not tracker or tracker.kind ~= "edit" or tracker.diff == nil then
        return
    end

    DiffPreview.clear_diff(tracker.argument, is_rejection)

    -- Close the diff tabpage created for this tool call
    local diff_tab = tracker.diff_tab
    if diff_tab and vim.api.nvim_tabpage_is_valid(diff_tab) then
        -- Ensure we're not on the diff tab before closing it
        if vim.api.nvim_get_current_tabpage() == diff_tab then
            vim.api.nvim_set_current_tabpage(self.tab_page_id)
        end
        -- Close all windows in the diff tab, which closes the tab
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(diff_tab)) do
            pcall(vim.api.nvim_win_close, winid, true)
        end
    end
    tracker.diff_tab = nil
end

--- @param new_config_options agentic.acp.ConfigOption[]
function SessionManager:_handle_new_config_options(new_config_options)
    self.config_options:set_options(new_config_options)

    self:_update_chat_header()
end

function SessionManager:_get_system_info()
    local os_name = vim.uv.os_uname().sysname
    local os_version = vim.uv.os_uname().release
    local os_machine = vim.uv.os_uname().machine
    local shell = os.getenv("SHELL")
    local neovim_version = tostring(vim.version())
    local today = os.date("%Y-%m-%d")

    local res = string.format(
        [[
- Platform: %s-%s-%s
- Shell: %s
- Editor: Neovim %s
- Current date: %s]],
        os_name,
        os_version,
        os_machine,
        shell,
        neovim_version,
        today
    )

    local project_root = vim.uv.cwd()

    local git_root = vim.fs.root(project_root or 0, ".git")
    if git_root then
        project_root = git_root
        res = res .. "\n- This is a Git repository."

        local branch =
            vim.fn.system("git rev-parse --abbrev-ref HEAD"):gsub("\n", "")
        if vim.v.shell_error == 0 and branch ~= "" then
            res = res .. string.format("\n- Current branch: %s", branch)
        end

        local changed = vim.fn.system("git status --porcelain"):gsub("\n$", "")
        if vim.v.shell_error == 0 and changed ~= "" then
            local files = vim.split(changed, "\n")
            res = res .. "\n- Changed files:"
            for _, file in ipairs(files) do
                res = res .. "\n  - " .. file
            end
        end

        local commits = vim.fn
            .system("git log -3 --oneline --format='%h (%ar) %an: %s'")
            :gsub("\n$", "")
        if vim.v.shell_error == 0 and commits ~= "" then
            local commit_lines = vim.split(commits, "\n")
            res = res .. "\n- Recent commits:"
            for _, commit in ipairs(commit_lines) do
                res = res .. "\n  - " .. commit
            end
        end
    end

    if project_root then
        res = res .. string.format("\n- Project root: %s", project_root)
    end

    res = "<environment_info>\n" .. res .. "\n</environment_info>"
    return res
end

function SessionManager:destroy()
    self._destroyed = true

    if self._reauth_job then
        self._reauth_job:kill("sigterm") --- @diagnostic disable-line: undefined-field
        self._reauth_job = nil
    end

    -- widget:destroy() calls hide() which fires on_hide. The scheduled destroy
    -- inside on_hide already guards against wiping a replacement session (it
    -- checks the registry still points at `this`), but disarming is belt and
    -- braces: avoids the schedule entirely once we know we're already
    -- destroying, and keeps the call graph one step simpler to reason about.
    self.widget.on_hide = nil

    self:_cancel_session()
    self.widget:destroy()

    -- Reset the per-tab headers state so a replacement session on the same
    -- tab doesn't inherit the destroyed session's model/mode context.
    if vim.api.nvim_tabpage_is_valid(self.tab_page_id) then
        vim.t[self.tab_page_id].agentic_headers = nil
    end
end

--- Restore session from loaded chat history
--- Creates a new ACP session (agent doesn't know old session_id)
--- and replays messages to UI. History is sent on first prompt submit.
--- @param history agentic.ui.ChatHistory
--- @param opts {reuse_session?: boolean}|nil If reuse_session=true, replay into current session without creating new one
function SessionManager:restore_from_history(history, opts)
    opts = opts or {}

    -- Prevent constructor's auto-new_session from running
    self._restoring = true
    self._history_to_send = history.messages
    self._is_first_message = false

    -- Update existing chat_history with loaded data, keeping current session_id
    if opts.reuse_session then
        self.chat_history.messages = vim.deepcopy(history.messages)
        self.chat_history.title = history.title or ""
    else
        self.chat_history = history
    end

    -- Show restored session title in buffer name
    local restored_title = self.chat_history.title
    if restored_title and restored_title ~= "" then
        self.widget:set_chat_title(restored_title)
    end

    local SessionRestore = require("agentic.session_restore")

    if opts.reuse_session and self.session_id then
        -- Reuse existing ACP session, replay messages to UI
        self._restoring = false
        SessionRestore.replay_messages(
            self.message_writer,
            self._history_to_send
        )
        -- Keep _history_to_send: the ACP provider doesn't have these messages
        -- (they came from disk, not the current session). They'll be prepended
        -- to the first user prompt so the provider has conversation context.
    else
        -- Create fresh ACP session, then replay messages after session is ready
        self:new_session({
            restore_mode = true,
            on_created = function()
                self._restoring = false
                SessionRestore.replay_messages(
                    self.message_writer,
                    self._history_to_send
                )
            end,
        })
    end
end

--- Restart the current session: cancel it and restore from chat history.
--- Use when a session becomes stuck or unresponsive.
function SessionManager:restart_session()
    local saved_history = vim.deepcopy(self.chat_history)

    if #saved_history.messages == 0 then
        -- Nothing to restore — just create a fresh session
        self:new_session()
        return
    end

    self:_cancel_session()
    self:restore_from_history(saved_history)
end

--- @private
--- @param seconds number
--- @return string
function SessionManager._format_duration(seconds)
    return format_duration(seconds)
end

return SessionManager

local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local Theme = require("agentic.theme")
local SessionRegistry = require("agentic.session_registry")
local SessionRestore = require("agentic.session_restore")
local Object = require("agentic.utils.object")
local Logger = require("agentic.utils.logger")

--- @class agentic.Agentic
local Agentic = {}

--- Resolves the effective window position for a call.
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
--- @return agentic.UserConfig.Windows.Position
local function effective_position(opts)
    return (opts and opts.position) or Config.windows.position
end

--- Opens the widget inside a dedicated tab, creating/reusing a tab as needed.
--- Never closes. Used by the `"tab"` position dispatch.
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
local function open_in_tab(opts)
    local tab = vim.api.nvim_get_current_tabpage()
    local existing = SessionRegistry.sessions[tab]
    if existing and existing.widget:is_open() then
        SessionRegistry.get_session_for_tab_page(nil, function(session)
            session.widget:show(opts)
        end)
        return
    end

    local wins = vim.fn.filter(
        vim.api.nvim_tabpage_list_wins(tab),
        function(_, w)
            return vim.api.nvim_win_get_config(w).relative == ""
        end
    )
    local fresh = false
    if #wins == 1 then
        local buf = vim.api.nvim_win_get_buf(wins[1])
        local ft = vim.bo[buf].filetype
        fresh = ft == "dashboard"
            or (ft == "" and vim.api.nvim_buf_get_name(buf) == "")
    end
    if not fresh then
        vim.cmd("tabnew")
    end
    local empty_win = vim.api.nvim_get_current_win()

    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local show_opts = vim.deepcopy(opts or {})
        show_opts.auto_add_to_context = false
        show_opts.position = nil
        session.widget:show(show_opts)
        if vim.api.nvim_win_is_valid(empty_win) then
            local ebuf = vim.api.nvim_win_get_buf(empty_win)
            pcall(vim.api.nvim_win_close, empty_win, true)
            pcall(vim.api.nvim_buf_delete, ebuf, { force = true })
        end
    end)
end

--- Hides the widget on the current tab and closes the tab if no other
--- windows remain.
local function close_tab()
    local tab = vim.api.nvim_get_current_tabpage()
    local session = SessionRegistry.sessions[tab]
    if session and session.widget:is_open() then
        session.widget:hide()
        if #vim.api.nvim_tabpage_list_wins(tab) <= 1 then
            vim.cmd("tabclose")
        end
    end
end

--- Opens the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.open(opts)
    if effective_position(opts) == "tab" then
        return open_in_tab(opts)
    end

    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end

        session.widget:show(opts)
    end)
end

--- Closes any open chat widget and cleans up the dedicated tab if applicable.
--- Safe to call multiple times or when no session exists.
--- @param tab_page_id? integer Tabpage to close. Nil = current tabpage.
function Agentic.close(tab_page_id)
    local tab = tab_page_id or vim.api.nvim_get_current_tabpage()
    local session = SessionRegistry.sessions[tab]
    if not session or not session.widget:is_open() then
        return
    end

    -- Check if this is a dedicated tab (no non-widget, non-floating windows).
    -- If so, destroy session + tabclose — avoids E444 from trying to close
    -- widget windows one-by-one when there's no real fallback window.
    local has_user_window = false
    local widget_win_set = {}
    for _, winid in pairs(session.widget.win_nrs) do
        widget_win_set[winid] = true
    end
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if
            not widget_win_set[winid]
            and vim.api.nvim_win_get_config(winid).relative == ""
        then
            has_user_window = true
            break
        end
    end

    if has_user_window then
        session.widget:hide()
    else
        SessionRegistry.destroy_session(tab)
        if vim.api.nvim_tabpage_is_valid(tab) then
            pcall(vim.cmd.tabclose)
        end
    end
end

--- Toggles the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.toggle(opts)
    if effective_position(opts) == "tab" then
        return Agentic.toggle_tab(opts)
    end

    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if session.widget:is_open() then
            session.widget:hide()
        else
            if not opts or opts.auto_add_to_context ~= false then
                session:add_selection_or_file_to_session()
            end

            session.widget:show(opts)
        end
    end)
end

--- Toggle in a dedicated tab: opens a new tab for agentic, closes the tab on
--- toggle-off when only the agentic window remains. Reuses dashboard/empty tabs.
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.toggle_tab(opts)
    local tab = vim.api.nvim_get_current_tabpage()
    local session = SessionRegistry.sessions[tab]
    if session and session.widget:is_open() then
        close_tab()
    else
        open_in_tab(opts)
    end
end

--- Rotates through predefined window layouts for the chat widget
--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function Agentic.rotate_layout(layouts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session.widget:rotate_layout(layouts)
    end)
end

--- Add the current visual selection to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_to_session()
        session.widget:show(opts)
    end)
end

--- Add the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_file(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_file_to_session()
        session.widget:show(opts)
    end)
end

--- Add either the current visual selection or the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection_or_file_to_context(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_or_file_to_session()
        session.widget:show(opts)
    end)
end

--- @class agentic.ui.NewSessionOpts : agentic.ui.ChatWidget.ShowOpts
--- @field provider? agentic.UserConfig.ProviderName

--- Add diagnostics at the current cursor line to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_current_line_diagnostics(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_current_line_diagnostics_to_context()
        if count > 0 then
            session.widget:show(opts)
        else
            Logger.notify(
                "No diagnostics found on the current line",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Add all diagnostics from the current buffer to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_buffer_diagnostics(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_buffer_diagnostics_to_context()
        if count > 0 then
            session.widget:show(opts)
        else
            Logger.notify(
                "No diagnostics found in the current buffer",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Destroys the current Chat session and starts a new one
--- @param opts agentic.ui.NewSessionOpts|nil
function Agentic.new_session(opts)
    if opts and opts.provider then
        Config.provider = opts.provider
    end

    local session = SessionRegistry.new_session()
    if session then
        if effective_position(opts) == "tab" then
            open_in_tab(opts)
            return
        end
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        session.widget:show(opts)
    end
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.new_session_with_provider(opts)
    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            local merged_opts = vim.tbl_deep_extend("force", opts or {}, {
                provider = provider_name,
            }) --[[@as agentic.ui.NewSessionOpts]]

            Agentic.new_session(merged_opts)
        end
    end)
end

--- @class agentic.ui.SwitchProviderOpts
--- @field provider? agentic.UserConfig.ProviderName

--- @param provider_name agentic.UserConfig.ProviderName
local function apply_provider_switch(provider_name)
    Config.provider = provider_name
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:switch_provider()
    end)
end

--- Switch to a different provider while preserving chat UI and history.
--- If opts.provider is set, switches directly. Otherwise shows a picker.
--- @param opts agentic.ui.SwitchProviderOpts|nil
function Agentic.switch_provider(opts)
    if opts and opts.provider then
        apply_provider_switch(opts.provider)
        return
    end

    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            apply_provider_switch(provider_name)
        end
    end)
end

--- Stops the agent's current generation or tool execution
--- The session remains active and ready for the next prompt
--- Safe to call multiple times or when no generation is active
function Agentic.stop_generation()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if not session.session_id then
            return
        end

        session.agent:stop_generation(session.session_id)
        session.permission_manager:clear()
        session.is_generating = false
        session.status_animation:stop()
    end)
end

--- Restart the current session: cancel and restore from chat history.
--- Use when a session becomes stuck or unresponsive.
function Agentic.restart_session()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:restart_session()
    end)
end

--- show a selector to restore a previous session
function Agentic.restore_session()
    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local current_session = SessionRegistry.sessions[tab_page_id]
    SessionRestore.show_picker(tab_page_id, current_session)
end

--- Load an existing ACP session by full UUID.
--- Opens the chat widget and sends session/load to the agent.
--- @param session_id string
--- @param cwd? string Original working directory for the session (from JSONL).
---   Falls back to vim.fn.getcwd() if nil.
--- @param model? string Model id saved with the session.
function Agentic.load_acp_session(session_id, cwd, model)
    if Config.session_restore.cd_on_load and cwd then
        local st = vim.uv.fs_stat(cwd)
        if st and st.type == "directory" then
            vim.api.nvim_set_current_dir(cwd)
        end
    end
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:load_acp_session(session_id, cwd, model)
        session.widget:show()
        session.widget:close_empty_non_widget_windows()
    end)
end

--- Resolve a session reference (session_id prefix or exact title) to a
--- cached session. The callback receives `nil` when zero or multiple
--- sessions match (multi-match emits a notification).
--- @param query string
--- @param callback fun(session_id?: string, cwd?: string, model?: string)
function Agentic.resolve_session(query, callback)
    SessionRestore.resolve_query(query, callback)
end

--- Resolve a session reference and open it in a new tab.
--- No match: emits a notification, no UI change.
--- @param query string
function Agentic.resume_query(query)
    Agentic.resolve_session(query, function(session_id, cwd, model)
        if not session_id then
            Logger.notify(
                "No session found matching: " .. query,
                vim.log.levels.ERROR
            )
            return
        end
        Agentic.toggle_tab()
        Agentic.load_acp_session(session_id, cwd, model)
    end)
end

--- Send arbitrary text as a prompt to the current session.
--- Convenience for custom keymaps, e.g.:
---   vim.keymap.set("n", "<localLeader>x", function()
---       require("agentic").send_prompt("Explain the last error")
---   end)
--- @param text string
function Agentic.send_prompt(text)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:_handle_input_submit(text)
        session.widget:show({ focus_prompt = false })
    end)
end

--- Operatorfunc callback for sending a motion or line to the chat context.
--- Set via `<Plug>(agentic-send)` and `<Plug>(agentic-send-line)`.
--- @param type string "char"|"line"|"block"
function Agentic.send_operatorfunc(type)
    if type == "char" then
        vim.cmd("silent normal! `[v`]")
    else
        vim.cmd("silent normal! `[V`]")
    end
    Agentic.add_selection()
end

--- Used to make sure we don't set multiple signal handlers or autocmds, if the user calls setup multiple times
local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("AgenticCleanup", {
    clear = true,
})

--- Merges the current user configuration with the default configuration
--- This method should be safe to be called multiple times
--- @param opts agentic.UserConfig
function Agentic.setup(opts)
    -- make sure invalid user config doesn't crash setup and leave things half-initialized
    local ok, err = pcall(function()
        Object.merge_config(Config, opts or {})
    end)

    if not ok then
        Logger.notify(
            "[Agentic] Error in user configuration: " .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic: user config merge error" }
        )
    end

    if traps_set then
        return
    end

    traps_set = true

    vim.treesitter.language.register("markdown", "AgenticChat")

    -- zsh parser for bash is registered globally in nvim config (treesitter.lua).
    -- Fallback here in case agentic.nvim is used standalone without the config.
    if not pcall(vim.treesitter.language.inspect, "bash") then
        vim.treesitter.language.register("zsh", "bash")
    end

    Theme.setup()

    -- Force-reload buffers when files change on disk (e.g., agent edits files directly).
    -- Suppresses the "file changed" prompt so modified buffers reload silently,
    -- matching Cursor/Zed behavior where agent changes always win.
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = cleanup_group,
        pattern = "*",
        callback = function()
            vim.v.fcs_choice = "reload"
        end,
    })

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = cleanup_group,
        callback = function()
            AgentInstance:cleanup_all()
        end,
        desc = "Cleanup Agentic processes on exit",
    })

    -- Cleanup specific tab instance when tab is closed
    vim.api.nvim_create_autocmd("TabClosed", {
        group = cleanup_group,
        callback = function(ev)
            local tab_id = tonumber(ev.match)
            SessionRegistry.destroy_session(tab_id)
        end,
        desc = "Cleanup Agentic processes on tab close",
    })

    if Config.image_paste.enabled then
        local function get_current_session()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            return SessionRegistry.sessions[tab_page_id]
        end

        local Clipboard = require("agentic.ui.clipboard")

        Clipboard.setup({
            is_cursor_in_widget = function()
                local session = get_current_session()
                return session and session.widget:is_cursor_in_widget() or false
            end,
            on_paste = function(file_path)
                local session = get_current_session()

                if not session then
                    return false
                end

                local ret = session.file_list:add(file_path) or false

                if ret then
                    session.widget:show({
                        focus_prompt = false,
                    })
                end

                return ret
            end,
        })
    end

    -- Setup signal handlers for graceful shutdown
    local sigterm_handler = vim.uv.new_signal()
    if sigterm_handler then
        vim.uv.signal_start(sigterm_handler, "sigterm", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end

    -- SIGINT handler (Ctrl-C) - note: may not trigger in raw terminal mode
    local sigint_handler = vim.uv.new_signal()
    if sigint_handler then
        vim.uv.signal_start(sigint_handler, "sigint", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end
end

return Agentic

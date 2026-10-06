local Config = require("agentic.config")
local SessionRegistry = require("agentic.session_registry")
local SessionRestore = require("agentic.session_restore")
local Object = require("agentic.utils.object")
local WidgetLayout = require("agentic.ui.widget_layout")
local Logger = require("agentic.utils.logger")

--- @class agentic.Agentic
local Agentic = {}

--- @class agentic.OpenOpts
--- @field mods? vim.api.keyset.cmd_mods Command modifiers. A split or tab modifier opens the chat in a new window.
--- @field auto_add_to_context? boolean Add the current selection or file to the context (default true)

--- When the current window shows a session's chat, bind that session to the
--- current tabpage (see `SessionManager:bind_to_tab`).
local function bind_shown_chat()
    local buf = vim.api.nvim_get_current_buf()
    if vim.b[buf].agentic_window ~= "chat" then
        return
    end
    local owner = SessionRegistry.owner_of_buf(buf)
    if owner then
        owner:bind_to_tab(vim.api.nvim_get_current_tabpage())
    end
end

--- Whether command modifiers open a new window: a split or tab modifier.
--- @param mods vim.api.keyset.cmd_mods|nil
--- @return boolean
local function opens_window(mods)
    return mods ~= nil
        and (
            (mods.tab or -1) ~= -1
            or (mods.split or "") ~= ""
            or mods.vertical == true
            or mods.horizontal == true
        )
end

--- Show the session's chat. With a split or tab modifier in `mods`, in a new
--- window (`:sbuffer`) that becomes home, its tabpage bound to the session,
--- else as `ChatWidget:reveal`.
--- @param session agentic.SessionManager
--- @param mods vim.api.keyset.cmd_mods|nil
local function show_chat(session, mods)
    if not opens_window(mods) then
        session.widget:reveal()
        return
    end
    vim.cmd.sbuffer({ args = { session.widget.buf_nrs.chat }, mods = mods })
    session:bind_to_tab(vim.api.nvim_get_current_tabpage())
    session.widget:show_in(vim.api.nvim_get_current_win())
end

--- Notify `message` when the session's chat has no home window in the
--- current tabpage, where its panels would show the change.
--- @param session agentic.SessionManager
--- @param message string
local function notify_unless_shown(session, message)
    local home = session.widget:home_win()
    if
        not home
        or vim.api.nvim_win_get_tabpage(home)
            ~= vim.api.nvim_get_current_tabpage()
    then
        Logger.notify(message, vim.log.levels.INFO, { title = "Agentic" })
    end
end

--- Show the chat of the current tabpage's session, created when there is
--- none, and add the current selection or file to its context unless
--- `opts.auto_add_to_context` is false.
---
--- With a split or tab modifier in `opts.mods`, the chat opens in a new
--- window (`:sbuffer`) that becomes its home: the panels of the previous home
--- close, and the non-empty content panels open at the new one. Else focus a
--- window in the current tabpage that shows the chat, the home window first,
--- or show the chat in the current window.
--- @param opts agentic.OpenOpts|nil
function Agentic.open(opts)
    opts = opts or {}
    bind_shown_chat()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        show_chat(session, opts.mods)
    end)
end

--- Add the current visual selection to the Chat context
function Agentic.add_selection()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_to_session()
        notify_unless_shown(session, "Added the selection to the chat context")
    end)
end

--- Add the current file to the Chat context
function Agentic.add_file()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_file_to_session()
        notify_unless_shown(session, "Added the file to the chat context")
    end)
end

--- Add either the current visual selection or the current file to the Chat context
function Agentic.add_selection_or_file_to_context()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_or_file_to_session()
        notify_unless_shown(
            session,
            "Added the selection or file to the chat context"
        )
    end)
end

--- @class agentic.ui.NewSessionOpts : agentic.OpenOpts
--- @field provider? agentic.UserConfig.ProviderName

--- Add diagnostics at the current cursor line to the Chat context
function Agentic.add_current_line_diagnostics()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_current_line_diagnostics_to_context()
        if count > 0 then
            notify_unless_shown(
                session,
                string.format("Added %d diagnostics to the chat context", count)
            )
        else
            Logger.notify(
                "No diagnostics found on the current line",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Add all diagnostics from the current buffer to the Chat context
function Agentic.add_buffer_diagnostics()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_buffer_diagnostics_to_context()
        if count > 0 then
            notify_unless_shown(
                session,
                string.format("Added %d diagnostics to the chat context", count)
            )
        else
            Logger.notify(
                "No diagnostics found in the current buffer",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Destroys the current Chat session, starts a new one and shows its chat.
--- @param opts agentic.ui.NewSessionOpts|nil
function Agentic.new_session(opts)
    opts = opts or {}
    if opts.provider then
        Config.provider = opts.provider
    end

    local session = SessionRegistry.new_session()
    if session then
        if opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        show_chat(session, opts.mods)
    end
end

--- @param opts agentic.OpenOpts|nil
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
        session:stop_generation()
    end)
end

--- Show or hide the panel listing the files this session's agent has changed.
--- Notifies when no session is bound to the current tabpage.
function Agentic.toggle_file_activity()
    -- Not `get_session_for_tab_page`: it would spawn a whole provider for a
    -- session with no chat shown to attach the panel to.
    local session =
        SessionRegistry.bound_session(vim.api.nvim_get_current_tabpage())
    if not session then
        Logger.notify(
            "No Agentic session in this tabpage.",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return
    end
    session:toggle_file_activity()
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
    local current_session = SessionRegistry.bound_session(tab_page_id)
    SessionRestore.show_picker(tab_page_id, current_session)
end

--- Load an existing ACP session by full UUID.
--- Reveals the chat and sends session/load to the agent.
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
        session.widget:reveal()
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

--- Resolve a session reference and load it (`load_acp_session`).
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
        Agentic.load_acp_session(session_id, cwd, model)
    end)
end

--- Send arbitrary text as a prompt to the current session.
--- Convenience for custom keymaps, e.g.:
---   vim.keymap.set("n", "<localLeader>x", function()
---       require("agentic").send_prompt("Explain the last error")
---   end)
---
--- The prompt is held and sent later if the session cannot take it yet, with
--- the reason written to chat. It has no buffer range to tag, so a second call
--- before the first is sent replaces it.
--- @param text string
function Agentic.send_prompt(text)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:on_user_submit()
        session:_handle_input_submit(text)
        notify_unless_shown(session, "Sent the prompt to the chat")
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

--- Merge `opts` into the current configuration. Safe to call more than once.
--- @param opts agentic.UserConfig|nil
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
    WidgetLayout.validate_stack()
end

return Agentic

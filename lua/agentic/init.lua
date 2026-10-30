local Config = require("agentic.config")
local SessionRegistry = require("agentic.session_registry")
local SessionRestore = require("agentic.session_restore")
local Object = require("agentic.utils.object")
local WidgetLayout = require("agentic.ui.widget_layout")
local PermissionStructured = require("agentic.utils.permission_structured")
local Logger = require("agentic.utils.logger")

--- @class agentic.Agentic
local Agentic = {}

--- @class agentic.OpenOpts
--- @field mods? vim.api.keyset.cmd_mods Command modifiers. A split or tab modifier opens the chat in a new window.
--- @field auto_add_to_context? boolean Add the current selection or file to the context (default true). Not with `query`
--- @field query? string A saved session's exact title or session_id prefix (8+ chars) to resume; else the first prompt of a new session

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

--- Show the chat of the current session (`SessionRegistry.current`), created
--- when there is none, and add the current selection or file to its context unless
--- `opts.auto_add_to_context` is false.
---
--- With a split or tab modifier in `opts.mods`, the chat opens in a new
--- window (`:sbuffer`) that becomes its home: the panels of the previous home
--- close, and the non-empty content panels open at the new one. Else focus a
--- window in the current tabpage that shows the chat, the home window first,
--- or show the chat in the current window. From an input or a widget panel,
--- show it instead in the chat window of that buffer's session in the current
--- tabpage, else in a split above the current window.
---
--- With a non-blank `opts.query`, resume the saved session it matches
--- instead. No match: start a new session, show its chat and input and submit `query`
--- as its first prompt, held until the agent is ready. An ambiguous
--- session_id prefix notifies and changes nothing.
--- @param opts agentic.OpenOpts|nil
function Agentic.open(opts)
    opts = opts or {}
    local query = opts.query
    if query and query:find("%S") then
        Agentic.resolve_session(query, function(session_id, cwd, model)
            if session_id then
                Agentic.load_acp_session(session_id, cwd, model, opts.mods)
                return
            end
            local session = Agentic.new_session({
                mods = opts.mods,
                auto_add_to_context = false,
            })
            if not session then
                return
            end
            session.widget:input_win()
            vim.api.nvim_buf_set_lines(
                session.widget.buf_nrs.input,
                0,
                -1,
                false,
                vim.split(query, "\n")
            )
            session.widget:submit()
        end)
        return
    end
    local session = SessionRegistry.get_or_create()
    if not session then
        return
    end
    if opts.auto_add_to_context ~= false then
        session:add_selection_or_file_to_session()
    end
    session.widget:show(opts.mods, SessionRegistry.target_win())
end

--- Add the current visual selection to the Chat context
function Agentic.add_selection()
    local session = SessionRegistry.get_or_create()
    if not session then
        return
    end
    session:add_selection_to_session()
    notify_unless_shown(session, "Added the selection to the chat context")
end

--- Add the current file to the Chat context
function Agentic.add_file()
    local session = SessionRegistry.get_or_create()
    if not session then
        return
    end
    session:add_file_to_session()
    notify_unless_shown(session, "Added the file to the chat context")
end

--- Add either the current visual selection or the current file to the Chat context
function Agentic.add_selection_or_file_to_context()
    local session = SessionRegistry.get_or_create()
    if not session then
        return
    end
    session:add_selection_or_file_to_session()
    notify_unless_shown(
        session,
        "Added the selection or file to the chat context"
    )
end

--- Notify how many diagnostics were added, or `none_message` when none were.
--- @param session agentic.SessionManager
--- @param count integer
--- @param none_message string
local function notify_diagnostics_added(session, count, none_message)
    if count > 0 then
        notify_unless_shown(
            session,
            string.format("Added %d diagnostics to the chat context", count)
        )
    else
        Logger.notify(none_message, vim.log.levels.INFO)
    end
end

--- Add diagnostics at the current cursor line to the Chat context
function Agentic.add_current_line_diagnostics()
    local session = SessionRegistry.get_or_create()
    if not session then
        return
    end
    notify_diagnostics_added(
        session,
        session:add_current_line_diagnostics_to_context(),
        "No diagnostics found on the current line"
    )
end

--- Add all diagnostics from the current buffer to the Chat context
function Agentic.add_buffer_diagnostics()
    local session = SessionRegistry.get_or_create()
    if not session then
        return
    end
    notify_diagnostics_added(
        session,
        session:add_buffer_diagnostics_to_context(),
        "No diagnostics found in the current buffer"
    )
end

--- @class agentic.ui.NewSessionOpts : agentic.OpenOpts
--- @field provider? agentic.UserConfig.ProviderName

--- Start another session and show its chat. The previous sessions stay
--- alive.
--- @param opts agentic.ui.NewSessionOpts|nil
--- @return agentic.SessionManager|nil session Nil when none could be created
function Agentic.new_session(opts)
    opts = opts or {}
    if opts.provider then
        Config.provider = opts.provider
    end

    local session = SessionRegistry.create()
    if session then
        if opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        session.widget:show(opts.mods, SessionRegistry.target_win())
    end
    return session
end

--- Load an existing ACP session by full UUID into a new session, show its
--- chat (`ChatWidget:show`) and send session/load to the agent. When a
--- session already holds `session_id`, show its chat instead.
--- @param session_id string
--- @param cwd? string Original working directory for the session (from JSONL).
---   When nil, the cwd recorded in the saved session file, else vim.fn.getcwd().
--- @param model? string Model id saved with the session.
--- @param mods? vim.api.keyset.cmd_mods Command modifiers. A split or tab modifier shows the chat in a new window.
function Agentic.load_acp_session(session_id, cwd, model, mods)
    local open_session = SessionRegistry.session_for_acp_id(session_id)
    if open_session then
        open_session.widget:show(mods, SessionRegistry.target_win())
        return
    end
    if Config.session_restore.cd_on_load and cwd then
        local st = vim.uv.fs_stat(cwd)
        if st and st.type == "directory" then
            vim.api.nvim_set_current_dir(cwd)
        end
    end
    local session = SessionRegistry.create()
    if not session then
        return
    end
    session:load_acp_session(session_id, cwd, model)
    session.widget:show(mods, SessionRegistry.target_win())
end

--- Resolve a session reference to a cached session
--- (`SessionRestore.resolve_query`).
--- @param query string
--- @param callback fun(session_id?: string, cwd?: string, model?: string)
function Agentic.resolve_session(query, callback)
    SessionRestore.resolve_query(query, callback)
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
    local session = SessionRegistry.get_or_create()
    if not session then
        return
    end
    session:on_user_submit()
    session:_handle_input_submit(text)
    notify_unless_shown(session, "Sent the prompt to the chat")
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
        -- In place: every module holds a reference to this one Config table.
        Object.deep_merge_into(Config, opts or {})
    end)

    if not ok then
        Logger.notify(
            "[Agentic] Error in user configuration: " .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic: user config merge error" }
        )
    end
    PermissionStructured.validate_auto_approve_tier()
    WidgetLayout.validate_stack()
end

return Agentic

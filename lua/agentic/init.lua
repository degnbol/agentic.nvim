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
--- @field auto_add_to_context? boolean Add the current selection or file to the context (default true)

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
--- @param opts agentic.OpenOpts|nil
function Agentic.open(opts)
    opts = opts or {}
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
    local session = SessionRegistry.create(opts.provider)
    if session then
        if opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        session.widget:show(opts.mods, SessionRegistry.target_win())
    end
    return session
end

--- Resume the saved session `session_id` on its saved provider and show its
--- chat. When a session already holds `session_id`, show that chat instead.
--- @param session_id string Full UUID
--- @param cwd string|nil Working directory of the session. When nil, the saved one, else vim.fn.getcwd()
--- @param model string|nil Model id. When nil, the saved one
--- @param mods vim.api.keyset.cmd_mods|nil Command modifiers. A split or tab modifier shows the chat in a new window
function Agentic.load_acp_session(session_id, cwd, model, mods)
    SessionRestore.resume(
        { session_id = session_id, cwd = cwd, model = model },
        mods
    )
end

--- Saved sessions of all projects whose id starts with `query`, else whose
--- title equals `query` (case-insensitive).
--- @param query string
--- @param callback fun(matches: agentic.ui.ChatHistory.SessionMeta[])
function Agentic.resolve_session(query, callback)
    SessionRestore.find(query, callback)
end

--- Resume the saved session that `query` matches by id prefix, else by exact
--- title. Several matches, no match, or a nil `query` show a picker, which
--- marks the session that owns the current buffer.
--- @param query string|nil
--- @param mods vim.api.keyset.cmd_mods|nil
function Agentic.resume_session(query, mods)
    local owner = SessionRegistry.owner_of_buf(vim.api.nvim_get_current_buf())
    SessionRestore.pick(query, {
        mods = mods,
        marked_id = owner and owner.session_id,
    })
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

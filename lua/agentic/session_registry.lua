local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ACPHealth = require("agentic.acp.acp_health")

--- @class agentic.SessionRegistry
--- @field by_id table<integer, agentic.SessionManager> Live sessions by `SessionManager.id`. Removed only by `destroy`
--- @field tab_bindings table<integer, integer> tab_page_id -> session id of the session whose widget the tab shows. The only record of a session's tab
local SessionRegistry = {
    by_id = {},
    tab_bindings = {},
}

--- The session bound to a tabpage.
--- @param tab_page_id integer
--- @return agentic.SessionManager|nil
function SessionRegistry.bound_session(tab_page_id)
    local id = SessionRegistry.tab_bindings[tab_page_id]
    return id and SessionRegistry.by_id[id]
end

--- The tabpage a session is bound to.
--- @param id integer `SessionManager.id`
--- @return integer|nil tab_page_id
function SessionRegistry.tab_of(id)
    for tab, bound_id in pairs(SessionRegistry.tab_bindings) do
        if bound_id == id then
            return tab
        end
    end
    return nil
end

--- Bind a session to a tabpage. A session has at most one tab and a tab at
--- most one session, so this drops the session's previous binding and the
--- tab's previous session.
--- @param tab_page_id integer
--- @param session agentic.SessionManager
function SessionRegistry.bind(tab_page_id, session)
    local previous_tab = SessionRegistry.tab_of(session.id)
    if previous_tab then
        SessionRegistry.tab_bindings[previous_tab] = nil
    end
    SessionRegistry.tab_bindings[tab_page_id] = session.id
end

--- The live session owning an Agentic buffer.
--- @param bufnr integer
--- @return agentic.SessionManager|nil
function SessionRegistry.owner_of_buf(bufnr)
    local id = vim.b[bufnr].agentic_session_id
    return id and SessionRegistry.by_id[id]
end

--- The tab's bound session, creating and binding one when there is none.
--- @param tab_page_id integer|nil Nil = current tabpage
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil session valid session instance or nil on failure
function SessionRegistry.get_session_for_tab_page(tab_page_id, callback)
    tab_page_id = tab_page_id or vim.api.nvim_get_current_tabpage()
    local instance = SessionRegistry.bound_session(tab_page_id)

    if not instance then
        if not ACPHealth.check_configured_provider() then
            Logger.debug("Session creation aborted: No configured ACP provider")
            return nil
        end

        local SessionManager = require("agentic.session_manager")

        instance = SessionManager:new() --[[@as agentic.SessionManager|nil]]
        if instance ~= nil then
            SessionRegistry.by_id[instance.id] = instance
            SessionRegistry.bind(tab_page_id, instance)
        end
    end

    if instance and callback then
        local ok, err = pcall(callback, instance)

        if not ok then
            Logger.notify("Session create callback error: " .. vim.inspect(err))
        end
    end

    return instance
end

--- Destroys the tab's bound session, if any, and creates and binds a new one
--- @param tab_page_id integer|nil Nil = current tabpage
--- @return agentic.SessionManager|nil
function SessionRegistry.new_session(tab_page_id)
    tab_page_id = tab_page_id or vim.api.nvim_get_current_tabpage()

    local bound = SessionRegistry.bound_session(tab_page_id)
    if bound then
        SessionRegistry.destroy(bound)
    end

    return SessionRegistry.get_session_for_tab_page(tab_page_id)
end

--- Destroy a session and drop it and its tab binding from the registry. The
--- one destroy path. A no-op on a session already destroyed.
--- @param session agentic.SessionManager
function SessionRegistry.destroy(session)
    if session.destroyed then
        return
    end

    local ok, err = pcall(session.destroy, session)
    if not ok then
        Logger.notify(
            "Session destroy error: " .. tostring(err),
            vim.log.levels.ERROR
        )
    end

    SessionRegistry.by_id[session.id] = nil
    local tab = SessionRegistry.tab_of(session.id)
    if tab then
        SessionRegistry.tab_bindings[tab] = nil
    end
end

--- Find the session whose ACP session id is `session_id`, across all sessions
--- (hence all providers — one bridge per provider, all sharing the same
--- $AGENTIC_SOCK, so a hook RPC must resolve globally).
--- Linear scan; there is at most a handful of live sessions.
--- @param session_id string
--- @return agentic.SessionManager|nil
function SessionRegistry.session_for_acp_id(session_id)
    for _, session in pairs(SessionRegistry.by_id) do
        if session.session_id == session_id then
            return session
        end
    end
    return nil
end

--- @param on_selected fun(provider_name: agentic.UserConfig.ProviderName|nil) Callback that will be called with the selected provider name, if any
function SessionRegistry.select_provider(on_selected)
    local available_providers = ACPHealth.get_default_provider_names()

    --- @class _ProviderStatus
    --- @field name string
    --- @field installed boolean

    --- @type _ProviderStatus[]
    local sorted_providers = {}

    --- @type _ProviderStatus[]
    local not_installed = {}

    for _, provider_name in ipairs(available_providers) do
        local provider_config = Config.acp_providers[provider_name]
        if
            provider_config
            and ACPHealth.is_command_available(provider_config.command)
        then
            sorted_providers[#sorted_providers + 1] = {
                name = provider_name,
                installed = true,
            }
        else
            not_installed[#not_installed + 1] = {
                name = provider_name,
                installed = false,
            }
        end
    end

    vim.list_extend(sorted_providers, not_installed)

    vim.ui.select(sorted_providers, {
        prompt = "Select ACP provider (new session)",
        --- @param item _ProviderStatus
        format_item = function(item)
            local label = item.name

            if label == Config.provider then
                label = label .. " (current)"
            elseif label == DefaultConfig.provider then
                label = label .. " (default)"
            end

            label = label
                .. (item.installed and " ✓ available" or " ✗ not installed")

            return label
        end,
    }, function(selected_provider)
        on_selected(selected_provider and selected_provider.name)
    end)
end

return SessionRegistry

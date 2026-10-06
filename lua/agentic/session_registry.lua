local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ACPHealth = require("agentic.acp.acp_health")

--- @class agentic.SessionRegistry
--- @field by_id table<integer, agentic.SessionManager> Live sessions by `SessionManager.id`. Removed only by `destroy`
--- @field last_active_id? integer `SessionManager.id` of the session created or whose buffer was entered last
local SessionRegistry = {
    by_id = {},
}

--- Record `session` as the last active one.
--- @param session agentic.SessionManager
function SessionRegistry.set_active(session)
    SessionRegistry.last_active_id = session.id
end

--- The live session owning an Agentic buffer.
--- @param bufnr integer
--- @return agentic.SessionManager|nil
function SessionRegistry.owner_of_buf(bufnr)
    local id = vim.b[bufnr].agentic_session_id
    return id and SessionRegistry.by_id[id]
end

--- The owner of the current buffer, else the last active session.
--- @return agentic.SessionManager|nil
function SessionRegistry.current()
    local owner = SessionRegistry.owner_of_buf(vim.api.nvim_get_current_buf())
    local id = SessionRegistry.last_active_id
    return owner or (id and SessionRegistry.by_id[id])
end

--- Create, register and activate a new session. Nil when no provider is
--- configured or creation fails.
--- @return agentic.SessionManager|nil
function SessionRegistry.create()
    if not ACPHealth.check_configured_provider() then
        Logger.debug("Session creation aborted: No configured ACP provider")
        return nil
    end

    local SessionManager = require("agentic.session_manager")
    local session = SessionManager:new() --[[@as agentic.SessionManager|nil]]
    if session then
        SessionRegistry.by_id[session.id] = session
        SessionRegistry.set_active(session)
    end
    return session
end

--- `current()`, else `create()`.
--- @return agentic.SessionManager|nil
function SessionRegistry.get_or_create()
    return SessionRegistry.current() or SessionRegistry.create()
end

--- Destroy a session and drop it from the registry. When it was the last
--- active session, the newest remaining one becomes last active. The one
--- destroy path. A no-op on a session already destroyed.
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
    if SessionRegistry.last_active_id == session.id then
        local ids = vim.tbl_keys(SessionRegistry.by_id)
        SessionRegistry.last_active_id = #ids > 0 and math.max(unpack(ids))
            or nil
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
        prompt = "Select ACP provider",
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

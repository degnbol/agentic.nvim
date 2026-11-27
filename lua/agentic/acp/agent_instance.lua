local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.AgentInstance
local AgentInstance = {}

--- The client for attended sessions, and the one for unattended sessions
--- @private
--- @type table<"attended"|"unattended", agentic.AgentClient|nil>
AgentInstance._instances = {}

--- The pi client, created on first use. A cached client whose process died
--- or failed to initialize, and that no session uses, is restarted.
--- @param on_ready fun(client: agentic.AgentClient)|nil Called when the client is ready, at once for a ready cached client
--- @param unattended boolean|nil Use the separate client that leaves every tool call's permission to the plugin
--- @return agentic.AgentClient|nil client Nil with a notify when that client cannot be configured
function AgentInstance.get_instance(on_ready, unattended)
    local key = unattended and "unattended" or "attended"
    local client = AgentInstance._instances[key]

    if client then
        if
            (client.state == "disconnected" or client.state == "error")
            and not next(client.subscribers)
        then
            client:restart()
        end
        if on_ready then
            client:when_ready(on_ready)
        end
        return client
    end

    local PiClient = require("agentic.pi.pi_client")
    local config = Config.pi

    if unattended then
        local env, err = PiClient:unattended_env(config.env or {})
        if not env then
            Logger.notify(config.name .. ": " .. err, vim.log.levels.ERROR)
            return nil
        end
        config = vim.deepcopy(config)
        config.env = vim.tbl_extend("force", config.env or {}, env)
    end

    Logger.debug("Creating new agent instance: " .. key)

    client = PiClient:new(config, on_ready)
    client.provider_name = "pi"
    AgentInstance._instances[key] = client

    return client
end

--- Cleanup all active instances and processes.
--- Called automatically on VimLeavePre (covers :q, :qa, :qa!, :cq),
--- SIGTERM, and SIGINT. Each process is killed with SIGTERM then SIGKILL,
--- and each usage-limit timer stops.
function AgentInstance:cleanup_all()
    for _name, instance in pairs(self._instances) do
        if instance then
            instance.usage_limit:stop()
            pcall(function()
                instance:stop()
            end)
        end
    end

    self._instances = {}
end

return AgentInstance

-- According to the ACP protocol, a single agent process can handle multiple sessions.
-- A session is an isolated conversation with its own state and context.
-- This file maintains one agent process per provider, and one more per
-- provider for unattended sessions.
-- We should NOT spawn more agent processes, but create new sessions instead.
-- Documentation for reference: https://agentclientprotocol.com/protocol/session-setup.md

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- Adapter module of each provider
--- @type table<agentic.UserConfig.ProviderName, string>
local ADAPTERS = {
    ["claude-agent-acp"] = "agentic.acp.adapters.claude_agent_acp_adapter",
    ["codex-acp"] = "agentic.acp.adapters.codex_acp_adapter",
    ["gemini-acp"] = "agentic.acp.adapters.gemini_acp_adapter",
    ["opencode-acp"] = "agentic.acp.adapters.opencode_acp_adapter",
    ["cursor-acp"] = "agentic.acp.adapters.cursor_acp_adapter",
    ["auggie-acp"] = "agentic.acp.adapters.auggie_acp_adapter",
    ["mistral-vibe-acp"] = "agentic.acp.adapters.mistral_vibe_acp_adapter",
}

--- @class agentic.acp.AgentInstance
--- @field chat_widget agentic.ui.ChatWidget
--- @field agent_client agentic.acp.ACPClient

--- @class agentic.acp.AgentInstance
local AgentInstance = {}

--- Agent instances keyed by provider name, with `#unattended` appended for
--- the unattended process
--- @private
--- @type table<string, agentic.acp.ACPClient|nil>
AgentInstance._instances = {}

--- The client of `provider_name`'s process, started on first use. A cached
--- client whose process died and that no session uses is restarted.
--- Raises for a provider without config or adapter.
--- @param provider_name agentic.UserConfig.ProviderName
--- @param on_ready fun(client: agentic.acp.ACPClient)|nil Called when the process is ready, at once for a live cached client
--- @param unattended boolean|nil Use the provider's separate process that leaves every tool call's permission to the client
--- @return agentic.acp.ACPClient|nil client Nil with a notify when that process cannot be configured
function AgentInstance.get_instance(provider_name, on_ready, unattended)
    local key = unattended and provider_name .. "#unattended" or provider_name
    local client = AgentInstance._instances[key]

    if client then
        if
            (client.state == "disconnected" or client.state == "error")
            and not next(client.subscribers)
        then
            client:restart(on_ready or function() end)
        elseif on_ready then
            on_ready(client)
        end
        return client
    end

    local config = Config.acp_providers[provider_name]

    if not config then
        error("No ACP provider configuration found for: " .. provider_name)
    end

    local adapter_module = ADAPTERS[provider_name]
    if not adapter_module then
        error("Unsupported ACP provider: " .. provider_name)
    end
    local Adapter = require(adapter_module)

    if unattended then
        local env, err = Adapter:unattended_env(config.env or {})
        if not env then
            Logger.notify(provider_name .. ": " .. err, vim.log.levels.ERROR)
            return nil
        end
        config = vim.deepcopy(config)
        config.env = vim.tbl_extend("force", config.env or {}, env)
    end

    Logger.debug("Creating new ACP agent instance for: " .. key)

    client = Adapter:new(config, on_ready)
    client.provider_name = provider_name
    AgentInstance._instances[key] = client

    return client
end

--- Cleanup all active instances and processes.
--- Called automatically on VimLeavePre (covers :q, :qa, :qa!, :cq),
--- SIGTERM, and SIGINT. Each transport is killed with SIGTERM then SIGKILL,
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

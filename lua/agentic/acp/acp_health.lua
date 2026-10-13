local DefaultConfig = require("agentic.config_default")
local Config = require("agentic.config")

--- Health check utilities for ACP providers and dependencies
--- @class agentic.acp.ACPHealth
local ACPHealth = {}

--- Check if a command exists and is executable
--- Handles command names (e.g., "node"), absolute paths (e.g., "/usr/bin/node"),
--- and tilde paths (e.g., "~/.local/bin/node")
--- @param command string|nil The command name or path to check
--- @return boolean exists Whether the command exists and is executable
function ACPHealth.is_command_available(command)
    if not command or command == "" then
        return false
    end
    local expanded = vim.fn.expand(command)
    return vim.fn.executable(expanded) == 1
end

--- @return agentic.UserConfig.ProviderName[] provider_names
function ACPHealth.get_default_provider_names()
    local available_providers = {}

    -- Using default config to avoid using potentially broken user config when checking providers
    for key, _ in pairs(DefaultConfig.acp_providers) do
        table.insert(available_providers, key)
    end

    table.sort(available_providers)

    return available_providers
end

--- Check if the configured ACP provider is available
--- Shows a warning window if not available
--- @return boolean available
function ACPHealth.check_configured_provider()
    local provider_name = Config.provider
    local provider_config = Config.acp_providers[provider_name]

    --- Markdown formatted lines to be shown in the warning window
    local lines = {}

    if not provider_config then
        vim.list_extend(lines, {
            string.format(
                "‼️ Provider **%s** not found in configuration.",
                provider_name
            ),
            "",
            "- Consider if it's not a typo 🤷",
            "",
        })
    elseif not ACPHealth.is_command_available(provider_config.command) then
        vim.list_extend(lines, {
            string.format(
                "‼️ **%s** (command: `%s`) is not installed or not executable.",
                provider_config.name or provider_name,
                provider_config.command or "unknown"
            ),
            "",
            "- If it's the first time you're using Agentic.nvim, you might have **NEVER** installed it",
            "",
            "- Have you switched your **Node.js version**?",
            "  - Globally installed packages are lost when switching versions with tools like nvm, fnm, etc...(out of this plugin's control)",
            "",
        })
    else
        return true
    end

    table.insert(
        lines,
        "Supported providers: (You must have the one you want to use installed!)"
    )

    local available_providers = ACPHealth.get_default_provider_names()

    for _, provider in ipairs(available_providers) do
        local provider_cfg = Config.acp_providers[provider]
        local is_installed = false
        local command = "nil"

        if provider_cfg and provider_cfg.command then
            command = provider_cfg.command
            is_installed = ACPHealth.is_command_available(command)
        end

        local status = is_installed and "✅ installed" or "❌ not installed"

        table.insert(
            lines,
            string.format("- %s `%s`: %s", provider, command, status)
        )
    end

    vim.list_extend(lines, {
        "",
        "Check the `Requirements` section in the README for installation instructions:",
        "",
        "https://github.com/carlos-algms/agentic.nvim?tab=readme-ov-file#-requirements",
        "",
        "**PLEASE NOTE**: Agentic.nvim does NOT install any ACP providers on your behalf, for security and privacy reasons.",
        "",
        "Run `:checkhealth agentic` for more information.",
    })

    -- Build final message with header, error content, and footer
    local merged_lines = {
        "# Welcome to Agentic.nvim!",
        "",
        "🚨 **There're issues with your configuration or missing dependencies.** 🚨",
        "",
    }
    vim.list_extend(merged_lines, lines)

    local FloatingMessage = require("agentic.ui.floating_message")
    FloatingMessage.show({
        title = " Agentic.nvim - Warning ",
        body = merged_lines,
    })

    return false
end

return ACPHealth

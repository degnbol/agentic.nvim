local States = require("agentic.states")

--- Stored slash command structure
--- @class agentic.acp.SlashCommand
--- @field word string Command name (without leading /)
--- @field menu string Short description
--- @field info string Full description

--- @class agentic.acp.SlashCommands
local SlashCommands = {}

--- Replace all commands with new list.
--- Validates each command has required fields, skips invalid commands and commands with spaces.
--- Automatically adds `/new` command if not provided by agent.
--- @param bufnr integer
--- @param available_commands agentic.acp.AvailableCommand[]
function SlashCommands.setCommands(bufnr, available_commands)
    --- @type agentic.acp.SlashCommand[]
    local commands = {}

    --- Commands that should always be available regardless of what the
    --- provider advertises. All three are intercepted locally in
    --- SessionManager before reaching the provider.
    --- @type table<string, agentic.acp.SlashCommand>
    local builtins = {
        new = {
            word = "new",
            menu = "Start a new session",
            info = "Start a new session",
        },
        context = {
            word = "context",
            menu = "Show context usage",
            info = "Show context usage",
        },
        clear = {
            word = "clear",
            menu = "Clear conversation",
            info = "Clear conversation",
        },
        rename = {
            word = "rename",
            menu = "Rename session",
            info = "Rename session: /rename <new name>",
        },
    }

    for _, cmd in ipairs(available_commands) do
        if cmd.name and cmd.description and not cmd.name:match("%s") then
            -- Provider-supplied command overrides builtin description
            builtins[cmd.name] = nil

            --- @type agentic.acp.SlashCommand
            local item = {
                word = cmd.name,
                menu = cmd.description,
                info = cmd.description,
            }
            table.insert(commands, item)
        end
    end

    -- Append any builtins the provider didn't supply
    for _, cmd in pairs(builtins) do
        table.insert(commands, cmd)
    end

    -- must be set at the end, as it gets serialized and loses the reference
    States.setSlashCommands(bufnr, commands)
end

return SlashCommands

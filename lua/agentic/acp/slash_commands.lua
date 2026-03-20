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
--- Filters out `clear` command (handled by specific agents internally).
--- Automatically adds `/new` command if not provided by agent.
--- @param bufnr integer
--- @param available_commands agentic.acp.AvailableCommand[]
function SlashCommands.setCommands(bufnr, available_commands)
    --- @type agentic.acp.SlashCommand[]
    local commands = {}

    local has_new_command = false

    for _, cmd in ipairs(available_commands) do
        if
            cmd.name
            and cmd.description
            and not cmd.name:match("%s")
            and cmd.name ~= "clear"
        then
            if cmd.name == "new" then
                has_new_command = true
            end

            --- @type agentic.acp.SlashCommand
            local item = {
                word = cmd.name,
                menu = cmd.description,
                info = cmd.description,
            }
            table.insert(commands, item)
        end
    end

    -- Add /new command if not provided by agent
    if not has_new_command then
        --- @type agentic.acp.SlashCommand
        local new_command = {
            word = "new",
            menu = "Start a new session",
            info = "Start a new session",
        }
        table.insert(commands, new_command)
    end

    -- must be set at the end, as it gets serialized and loses the reference
    States.setSlashCommands(bufnr, commands)
end

return SlashCommands

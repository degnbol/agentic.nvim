local States = require("agentic.states")

--- Stored slash command structure
--- @class agentic.acp.SlashCommand
--- @field word string Command name (without leading /)
--- @field menu string Short description
--- @field info string Full description

--- @class agentic.acp.SlashCommands
local SlashCommands = {}

--- Commands that should always be available regardless of what the
--- provider advertises. All of them are intercepted locally in
--- SessionManager before reaching the provider.
--- @type table<string, agentic.acp.SlashCommand>
local builtins = {
    new = {
        word = "new",
        menu = "Start a new session",
        info = "Start a new session, optionally named: /new [name]",
    },
    context = {
        word = "context",
        menu = "Show context usage",
        info = "Show context usage",
    },
    clear = {
        word = "clear",
        menu = "Clear conversation",
        info = "Clear conversation, optionally named: /clear [name]",
    },
    rename = {
        word = "rename",
        menu = "Rename session",
        info = "Rename session: /rename <new name>",
    },
    delete = {
        word = "delete",
        menu = "Delete current session",
        info = "Delete the current session from disk and clear the UI",
    },
    grant = {
        word = "grant",
        menu = "Grant edits under a path",
        info = "Auto-approve recoverable edits under a path or glob. `.` is the cwd, `root` its git root, `off` clears every grant; no argument opens a picker",
    },
    login = {
        word = "login",
        menu = "Log in to the provider",
        info = "Run one of the provider's login methods: /login [method id]. No argument: the configured or only method, else a choice",
    },
}

--- Add a builtin to every command list set from now on.
--- @param name string Command name (without leading /)
--- @param description string Completion menu and info text
function SlashCommands.register_builtin(name, description)
    builtins[name] = { word = name, menu = description, info = description }
end

--- Replace all commands with new list.
--- Validates each command has required fields, skips invalid commands and commands with spaces.
--- Adds the builtins the provider does not supply.
--- @param bufnr integer
--- @param available_commands agentic.acp.AvailableCommand[]
function SlashCommands.setCommands(bufnr, available_commands)
    --- @type agentic.acp.SlashCommand[]
    local commands = {}

    --- @type table<string, true>
    local supplied = {}

    for _, cmd in ipairs(available_commands) do
        if cmd.name and cmd.description and not cmd.name:match("%s") then
            -- Provider-supplied command overrides builtin description
            supplied[cmd.name] = true

            --- @type agentic.acp.SlashCommand
            local item = {
                word = cmd.name,
                menu = cmd.description,
                info = cmd.description,
            }
            table.insert(commands, item)
        end
    end

    for name, cmd in pairs(builtins) do
        if not supplied[name] then
            table.insert(commands, cmd)
        end
    end

    -- must be set at the end, as it gets serialized and loses the reference
    States.setSlashCommands(bufnr, commands)
end

return SlashCommands

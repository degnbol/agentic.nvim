local Logger = require("agentic.utils.logger")

--- pi extension dialogs (`extension_ui_request`) shown with Neovim's own
--- prompts.
--- @class agentic.pi.PiDialogs
local M = {}

--- @type table<string, integer>
local NOTIFY_LEVELS = {
    info = vim.log.levels.INFO,
    warning = vim.log.levels.WARN,
    error = vim.log.levels.ERROR,
}

--- Show an extension UI request and answer it. Fire-and-forget requests get
--- no answer: `notify` is shown, the others are dropped.
--- @param request table An `extension_ui_request`
--- @param respond fun(response: table) Sends the `extension_ui_response` fields
function M.show(request, respond)
    local method = request.method
    local title = request.title or ""
    if method == "select" then
        vim.ui.select(
            request.options or {},
            { prompt = title },
            function(choice)
                respond(choice and { value = choice } or { cancelled = true })
            end
        )
    elseif method == "confirm" then
        local text = request.message and (title .. "\n" .. request.message)
            or title
        respond({ confirmed = vim.fn.confirm(text, "&Yes\n&No", 2) == 1 })
    elseif method == "input" or method == "editor" then
        vim.ui.input({
            prompt = title .. " ",
            default = request.prefill,
        }, function(value)
            respond(value and { value = value } or { cancelled = true })
        end)
    elseif method == "notify" then
        Logger.notify(
            request.message or "",
            NOTIFY_LEVELS[request.notifyType] or vim.log.levels.INFO,
            { title = "pi" }
        )
    end
end

return M

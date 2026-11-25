local PiToolCalls = require("agentic.pi.pi_tool_calls")

--- Permission requests from the `agentic.ts` pi extension, which asks about
--- every tool call through an extension `select` dialog.
--- @class agentic.pi.PiPermission
local M = {}

--- Prefix of the dialog title. The JSON of the call follows it.
M.TITLE_PREFIX = "agentic-permission:"

--- The dialog's options, in the order the extension offers them.
M.OPTION_IDS = { "allow_once", "allow_always", "reject_once", "reject_always" }

--- @type table<string, string>
local OPTION_NAMES = {
    allow_once = "Allow once",
    allow_always = "Allow always",
    reject_once = "Reject once",
    reject_always = "Reject always",
}

--- A tool call the extension asks about.
--- @class agentic.pi.PiPermission.Call
--- @field toolCallId string
--- @field toolName string
--- @field input table The call's arguments after pi's normalisation

--- The call an extension UI request asks permission for.
--- @param request table An `extension_ui_request`
--- @return agentic.pi.PiPermission.Call|nil call Nil for any other request
function M.parse(request)
    local title = request.title
    if
        request.method ~= "select"
        or type(title) ~= "string"
        or title:sub(1, #M.TITLE_PREFIX) ~= M.TITLE_PREFIX
    then
        return nil
    end
    local ok, call = pcall(vim.json.decode, title:sub(#M.TITLE_PREFIX + 1))
    if not ok or type(call) ~= "table" or type(call.toolCallId) ~= "string" then
        return nil
    end
    if type(call.input) ~= "table" then
        call.input = {}
    end
    return call
end

--- The permission request for `call`, with its `path` resolved.
--- @param session_id string
--- @param call agentic.pi.PiPermission.Call
--- @param cwd string Absolute working directory of the session
--- @return agentic.acp.RequestPermission
function M.to_request(session_id, call, cwd)
    local input = vim.deepcopy(call.input)
    if type(input.path) == "string" then
        input.path = PiToolCalls.resolve_path(input.path, cwd)
    end
    --- @type agentic.acp.PermissionOption[]
    local options = {}
    for _, id in ipairs(M.OPTION_IDS) do
        table.insert(
            options,
            { optionId = id, name = OPTION_NAMES[id], kind = id }
        )
    end
    --- @type agentic.acp.RequestPermission
    local request = {
        sessionId = session_id,
        toolCall = {
            toolCallId = call.toolCallId,
            kind = PiToolCalls.kind(call.toolName),
            rawInput = input,
        },
        options = options,
    }
    return request
end

--- The dialog response for the option the user chose.
--- @param option_id string|nil Nil when the request was cancelled
--- @return table response
function M.to_response(option_id)
    if option_id then
        return { value = option_id }
    end
    return { cancelled = true }
end

return M

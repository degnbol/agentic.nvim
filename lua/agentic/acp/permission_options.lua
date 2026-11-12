local AcpKind = require("agentic.utils.acp_kind")

local M = {}

--- The kind of the permission option `option_id` names, normalised.
--- @param options agentic.acp.PermissionOption[]
--- @param option_id string|nil
--- @return string kind Trimmed and lowercased, or "" when no option has the id
function M.option_kind(options, option_id)
    for _, option in ipairs(options) do
        if option.optionId == option_id then
            return AcpKind.normalise(option.kind)
        end
    end
    return ""
end

return M

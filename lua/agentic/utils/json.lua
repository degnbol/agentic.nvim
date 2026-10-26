--- @class agentic.utils.json
local M = {}

--- `value`, with a JSON `null` (`vim.NIL` from `vim.json.decode`) read as
--- absent.
--- @generic T
--- @param value T|vim.NIL
--- @return T|nil
function M.present(value)
    if value == vim.NIL then
        return nil
    end
    return value
end

return M

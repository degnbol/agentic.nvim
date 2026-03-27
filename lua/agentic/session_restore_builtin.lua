--- Fallback session picker using vim.ui.select (no external deps).
--- @class agentic.SessionRestoreBuiltin
local M = {}

--- @param items agentic.SessionRestore.PickerItem[]
--- @param on_select fun(session_id: string)
function M.show(items, on_select)
    vim.ui.select(items, {
        prompt = "Select session to restore:",
        format_item = function(item)
            return item.display
        end,
    }, function(choice)
        if choice then
            on_select(choice.session_id)
        end
    end)
end

return M

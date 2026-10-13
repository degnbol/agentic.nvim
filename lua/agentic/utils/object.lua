--- @class agentic.utils.object
local M = {}

--- Whether `vim.tbl_deep_extend` merges into `value` rather than replacing it:
--- a table that is not a non-empty list.
--- @param value any
--- @return boolean
local function can_merge(value)
    return type(value) == "table"
        and (vim.tbl_isempty(value) or not vim.islist(value))
end

--- Recursively merge each source into `target` in place, later sources
--- winning. Lists and non-table values replace, as in `vim.tbl_deep_extend`,
--- which returns a new table instead of mutating `target`.
--- @param target table
--- @param ... table
--- @return table target
function M.deep_merge_into(target, ...)
    for _, source in ipairs({ ... }) do
        for k, v in pairs(source) do
            if can_merge(v) and can_merge(target[k]) then
                M.deep_merge_into(target[k], v)
            else
                target[k] = v
            end
        end
    end
    return target
end

return M

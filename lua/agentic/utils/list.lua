local M = {}

--- Remove and return the first element of `list` that `matches` accepts.
--- @generic T
--- @param list T[]
--- @param matches fun(element: T): boolean
--- @return T|nil element nil when none matches
function M.take_first(list, matches)
    for i, element in ipairs(list) do
        if matches(element) then
            return table.remove(list, i)
        end
    end
    return nil
end

return M

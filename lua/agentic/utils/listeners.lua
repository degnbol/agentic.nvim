local Logger = require("agentic.utils.logger")

--- An ordered list of callbacks run together. A callback that errors is
--- reported and does not stop the rest.
--- @class agentic.utils.Listeners
--- @field _list function[]
local Listeners = {}
Listeners.__index = Listeners

--- @return agentic.utils.Listeners
function Listeners:new()
    return setmetatable({ _list = {} }, self)
end

--- Add `listener` at the end.
--- @param listener function
--- @return fun() remove Removes `listener`; a no-op after the first call
function Listeners:add(listener)
    table.insert(self._list, listener)
    return function()
        for i, fn in ipairs(self._list) do
            if fn == listener then
                table.remove(self._list, i)
                return
            end
        end
    end
end

--- Run every listener with `...`, in order. Listeners added or removed
--- during the run take effect from the next one.
--- @param ... any
function Listeners:call(...)
    for _, fn in ipairs(vim.list_slice(self._list)) do
        local ok, err = pcall(fn, ...)
        if not ok then
            Logger.notify(
                "Listener error: " .. tostring(err),
                vim.log.levels.ERROR
            )
        end
    end
end

return Listeners

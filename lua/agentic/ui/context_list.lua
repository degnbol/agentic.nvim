local BufHelpers = require("agentic.utils.buf_helpers")

--- A list of items shown in a buffer, one or more rows per item. Only
--- `render` writes the buffer. Subclasses implement `__rows` and their own
--- `add`.
--- @class agentic.ui.ContextList
--- @field protected __items table[] In insertion order. Subclasses append, then call `render`
--- @field protected __bufnr integer
--- @field _spans { first: integer, last: integer, item: table }[] 1-indexed first/last row of each item in the buffer, as last written
--- @field _on_change fun(list: agentic.ui.ContextList)
local ContextList = {}
ContextList.__index = ContextList

--- Binds `d` in `bufnr`: in normal mode it removes the item under the
--- cursor, in visual mode the items under the selection, then leaves visual
--- mode.
--- @generic T : agentic.ui.ContextList
--- @param self T
--- @param bufnr integer
--- @param on_change fun(list: T) Called after each render that wrote the buffer
--- @return T
function ContextList.new(self, bufnr, on_change)
    local instance = setmetatable({
        __items = {},
        __bufnr = bufnr,
        _spans = {},
        _on_change = on_change,
    }, self)

    BufHelpers.keymap_set(bufnr, "n", "d", function()
        local row = vim.api.nvim_win_get_cursor(0)[1]
        instance:remove_rows(row, row)
    end, { nowait = true })

    BufHelpers.keymap_set(bufnr, "v", "d", function()
        instance:remove_rows(vim.fn.getpos("v")[2], vim.fn.getpos(".")[2])
        BufHelpers.feed_ESC_key()
    end, { nowait = true })

    return instance
end

--- The buffer rows of `item`.
--- @protected
--- @param _item table
--- @return string[] rows
function ContextList:__rows(_item)
    error("ContextList subclass must implement __rows")
end

--- @return integer
function ContextList:count()
    return #self.__items
end

--- @return boolean
function ContextList:is_empty()
    return #self.__items == 0
end

--- Empty the list and return the items it held. Renders once.
--- @return table[] items In insertion order
function ContextList:take()
    local items = self.__items
    self:clear()
    return items
end

function ContextList:clear()
    self.__items = {}
    self:render()
end

--- Write every item's rows to the buffer, then call `on_change` if the
--- write succeeded.
function ContextList:render()
    local lines = {}
    local spans = {}
    for _, item in ipairs(self.__items) do
        local rows = self:__rows(item)
        table.insert(
            spans,
            { first = #lines + 1, last = #lines + #rows, item = item }
        )
        vim.list_extend(lines, rows)
    end

    local written = BufHelpers.with_modifiable(self.__bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return true
    end)

    if written then
        self._spans = spans
        self._on_change(self)
    end
end

--- Remove every item with a row in `first..last` (1-indexed, inclusive, in
--- either order). Renders only when something was removed.
--- @param first integer
--- @param last integer
function ContextList:remove_rows(first, last)
    if first > last then
        first, last = last, first
    end

    --- @type table<any, true>
    local hit = {}
    for _, span in ipairs(self._spans) do
        if span.first <= last and span.last >= first then
            hit[span.item] = true
        end
    end

    local kept = vim.tbl_filter(function(item)
        return not hit[item]
    end, self.__items)

    if #kept < #self.__items then
        self.__items = kept
        self:render()
    end
end

return ContextList

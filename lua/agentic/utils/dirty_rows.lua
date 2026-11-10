local Intervals = require("agentic.utils.intervals")

--- The rows of a buffer that an edit or a change of its root tree touched
--- since the last `take`.
--- @class agentic.utils.DirtyRows
--- @field _bufnr integer
--- @field _spans [integer, integer][] Dirty rows, 0-indexed and inclusive, in no order and possibly overlapping. A span's end can lie past the last line.
--- @field _attached boolean Whether `on_bytes` reaches `_spans`
--- @field _parser? vim.treesitter.LanguageTree Parser whose root tree changes reach `_spans`
local DirtyRows = {}
DirtyRows.__index = DirtyRows

--- 0-indexed last row a node covers.
--- @param range Range6
--- @return integer
local function last_row(range)
    -- An end column of 0 means the node stops before the first byte of that
    -- row, so the row is not part of it.
    return range[5] == 0 and range[4] - 1 or range[4]
end

--- Add rows `first`..`last` to the dirty rows.
--- @param first integer 0-indexed
--- @param last integer 0-indexed, inclusive
function DirtyRows:_mark(first, last)
    table.insert(self._spans, { first, math.max(first, last) })
end

--- Apply one `on_bytes` edit: dirty rows below the replaced ones shift by the
--- edit's line delta, dirty rows inside them move to its first row, and every
--- row the new text touches becomes dirty, its end row included: a `set_text`
--- changes part of that row, and a `set_lines` ends at column 0 of the row
--- after it.
--- @param start_row integer `on_bytes` start row, 0-indexed
--- @param old_rows integer `on_bytes` old end row (offset from start row)
--- @param new_rows integer `on_bytes` new end row (offset from start row)
function DirtyRows:_splice(start_row, old_rows, new_rows)
    local delta = new_rows - old_rows
    --- @param row integer
    --- @return integer
    local function moved(row)
        if row < start_row then
            return row
        end
        return row >= start_row + old_rows and row + delta or start_row
    end
    for _, span in ipairs(self._spans) do
        span[1], span[2] = moved(span[1]), moved(span[2])
    end
    self:_mark(start_row, start_row + new_rows)
end

--- Mark rows dirty on each edit of the buffer, and the whole buffer on a
--- reload or an unload.
function DirtyRows:_attach()
    self._attached = vim.api.nvim_buf_attach(self._bufnr, false, {
        on_bytes = function(_, _, _, start_row, _, _, old_rows, _, _, new_rows)
            self:_splice(start_row, old_rows, new_rows)
        end,
        on_reload = function()
            self:mark_all()
        end,
        on_detach = function()
            self._attached = false
            self:mark_all()
        end,
    })
end

--- From now on, mark each range of `parser`'s root tree that changes dirty,
--- for as long as `parser` is `_parser`.
--- @param parser vim.treesitter.LanguageTree
function DirtyRows:_watch_parser(parser)
    self._parser = parser
    parser:register_cbs({
        --- @param changes Range6[]
        on_changedtree = function(changes)
            -- Callbacks cannot be unregistered.
            if self._parser ~= parser then
                return
            end
            for _, range in ipairs(changes) do
                self:_mark(range[1], last_row(range))
            end
        end,
    }, false)
end

--- Watch `bufnr`'s edits and its root parser's tree changes, starting clean.
--- @param bufnr integer
--- @return agentic.utils.DirtyRows
function DirtyRows.watch(bufnr)
    local self = setmetatable(
        { _bufnr = bufnr, _spans = {}, _attached = false },
        DirtyRows
    )
    self:_attach()
    local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
    if parser then
        self:_watch_parser(parser)
    end
    return self
end

--- Mark the whole buffer dirty.
function DirtyRows:mark_all()
    self._spans = { { 0, math.huge } }
end

--- Parse the root tree, then return the dirty rows and clear them. The whole
--- buffer when the buffer was unloaded or its parser replaced since the last
--- `take`. Watching then resumes on the buffer and on the new parser.
--- @return [integer, integer][]|nil spans 0-indexed inclusive rows within the buffer, disjoint and ascending. nil when clean or the buffer has no parser, and the rows stay dirty in the second case.
function DirtyRows:take()
    if #self._spans == 0 then
        return nil
    end
    local parser =
        vim.treesitter.get_parser(self._bufnr, nil, { error = false })
    if not parser then
        return nil
    end
    if not self._attached then
        self:_attach()
        self:mark_all()
    end
    if parser ~= self._parser then
        self:_watch_parser(parser)
        self:mark_all()
    end
    -- Fires `on_changedtree`, which adds rows.
    parser:parse()

    local last = vim.api.nvim_buf_line_count(self._bufnr) - 1
    --- @type [integer, integer][]
    local spans = {}
    for _, span in ipairs(self._spans) do
        table.insert(
            spans,
            { math.min(span[1], last), math.min(span[2], last) }
        )
    end
    self._spans = {}
    return Intervals.union(spans)
end

return DirtyRows

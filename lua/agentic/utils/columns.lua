--- Text laid out in aligned columns.
--- @class agentic.utils.Columns
local M = {}

--- The display width of each column's widest cell.
--- @param rows string[][] Cells of each row; rows may differ in length
--- @return integer[] widths One per column
function M.widths(rows)
    --- @type integer[]
    local widths = {}
    for _, row in ipairs(rows) do
        for col, cell in ipairs(row) do
            widths[col] =
                math.max(widths[col] or 0, vim.api.nvim_strwidth(cell))
        end
    end
    return widths
end

--- Join each row's cells with `sep`, every cell padded with spaces to the
--- display width of its column's widest cell. A column empty on every row is
--- left out, and the last column left is not padded.
--- @param rows string[][] Rows of the same number of cells
--- @param sep string
--- @return string[] lines
function M.align(rows, sep)
    local widths = M.widths(rows)
    --- @type integer[]
    local kept = {}
    for col, width in ipairs(widths) do
        if width > 0 then
            table.insert(kept, col)
        end
    end
    return vim.tbl_map(function(row)
        --- @type string[]
        local cells = {}
        for i, col in ipairs(kept) do
            local cell = row[col]
            local padding = i < #kept
                    and widths[col] - vim.api.nvim_strwidth(cell)
                or 0
            table.insert(cells, cell .. string.rep(" ", padding))
        end
        return table.concat(cells, sep)
    end, rows)
end

return M

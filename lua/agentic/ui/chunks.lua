local Columns = require("agentic.utils.columns")

--- @alias agentic.ui.Chunk { [1]: string, [2]: string|nil } Text and highlight group

--- Lists of text chunks, each with an optional highlight group.
--- @class agentic.ui.Chunks
local Chunks = {}

--- The concatenated text of `chunks`, without highlights.
--- @param chunks agentic.ui.Chunk[]
--- @return string
function Chunks.text(chunks)
    return table.concat(vim.tbl_map(function(chunk)
        return chunk[1]
    end, chunks))
end

--- Rows of cells laid out in aligned columns. Cell `i` of a row goes in
--- column `i`, padded with spaces to the display width of the column's
--- widest cell: before the cell in a `right` column, else after it. A row
--- ends after its last cell, without padding. Padding has no highlight.
--- @param rows agentic.ui.Chunk[][] Cells of each row
--- @param right table<integer, boolean> Columns aligned to the right
--- @return agentic.ui.Chunk[][] rows Chunks of each row, without empty chunks
function Chunks.columns(rows, right)
    local widths = Columns.widths(vim.tbl_map(function(cells)
        return vim.tbl_map(function(cell)
            return cell[1]
        end, cells)
    end, rows))
    return vim.tbl_map(function(cells)
        --- @type agentic.ui.Chunk[]
        local chunks = {}
        for i, cell in ipairs(cells) do
            local padding = {
                string.rep(" ", widths[i] - vim.api.nvim_strwidth(cell[1])),
            }
            if right[i] then
                table.insert(chunks, padding)
            end
            table.insert(chunks, cell)
            if not right[i] and i < #cells then
                table.insert(chunks, padding)
            end
        end
        return vim.tbl_filter(function(chunk)
            return chunk[1] ~= ""
        end, chunks)
    end, rows)
end

return Chunks

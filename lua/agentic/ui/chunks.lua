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

return Chunks

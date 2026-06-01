local NS_FOLDS = vim.api.nvim_create_namespace("agentic_tool_folds")

--- Custom foldtext for the chat buffer.
--- Shows a line count summary styled as Comment.
--- @return {[1]: string, [2]: string}[]
local function foldtext()
    local line_count = vim.v.foldend - vim.v.foldstart - 1
    local text = string.format("    ··· %d lines ···", line_count)
    return { { text, "Comment" } }
end

--- Fold expression for the chat buffer. Reads NS_FOLDS extmarks set by the
--- message writer — extmark presence at a row declares that row folds.
--- Ignores buffer content entirely, so coincidental `{{{`/`}}}` in search
--- hits or grep output never trigger unintended folds.
--- @return string
local function foldexpr()
    local row = vim.v.lnum - 1
    local marks = vim.api.nvim_buf_get_extmarks(
        0,
        NS_FOLDS,
        { row, 0 },
        { row, -1 },
        { overlap = true, details = true }
    )
    for _, m in ipairs(marks) do
        local start_row = m[2]
        local end_row = m[4].end_row
        if row == start_row then
            return ">1"
        end
        if row == end_row then
            return "<1"
        end
        if row > start_row and row < end_row then
            return "1"
        end
    end
    return "0"
end

return {
    foldtext = foldtext,
    foldexpr = foldexpr,
    NS_FOLDS = NS_FOLDS,
}

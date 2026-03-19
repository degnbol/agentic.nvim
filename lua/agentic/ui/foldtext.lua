--- Custom foldtext for the chat buffer.
--- Shows a line count summary styled as Comment.
--- @return {[1]: string, [2]: string}[]
return function()
    local line_count = vim.v.foldend - vim.v.foldstart - 1
    local text = string.format("    ··· %d lines ···", line_count)
    return { { text, "Comment" } }
end

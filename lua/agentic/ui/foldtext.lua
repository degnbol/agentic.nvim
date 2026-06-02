--- Custom foldtext for the chat buffer.
--- Shows a line count summary styled as Comment. Folds are produced by the
--- built-in `vim.treesitter.foldexpr()` over the chat's `agentic` folds query
--- (queries/agentic/folds.scm), so this module no longer owns a foldexpr — it
--- only styles the closed-fold line. The fold spans the `code_fence_content`
--- node (body only, delimiters excluded), so foldend - foldstart + 1 is the
--- fold's line count.
--- @return {[1]: string, [2]: string}[]
local function foldtext()
    local line_count = vim.v.foldend - vim.v.foldstart + 1
    local text = string.format("    ··· %d lines ···", line_count)
    return { { text, "Comment" } }
end

return {
    foldtext = foldtext,
}

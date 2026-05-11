local bufnr = vim.api.nvim_get_current_buf()

-- `#` is markdown heading syntax here, not a comment. HTML comments are
-- the standard in markdown and survive a markdown renderer.
vim.bo[bufnr].commentstring = "<!-- %s -->"

-- Re-enable vim syntax after vim.treesitter.start() (called in chat_widget
-- after ftplugin) which clears vim.bo.syntax. Deferred so it runs after the
-- current event loop iteration, at which point treesitter setup is complete.
-- "ON" sources syntax/AgenticInput.vim for the buffer's filetype.
vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].syntax = "ON"
    end
end)

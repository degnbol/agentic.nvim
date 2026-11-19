local BufHelpers = require("agentic.utils.buf_helpers")

-- The default wheel scroll can put the cursor on a zero-height line (fence
-- rows, `agentic.ui.FenceRows`). Its 'scrolloff' check counts a closed fold
-- that ends in such a line as no row, and then undoes the scroll (neovim
-- skill `references/rendering.md` § `conceal_lines`).
for _, d in ipairs({ "Up", "Down" }) do
    local dir = d == "Up" and -1 or 1
    vim.keymap.set({ "n", "v", "i" }, "<ScrollWheel" .. d .. ">", function()
        local count = tonumber(vim.o.mousescroll:match("ver:(%d+)") or "3")
        BufHelpers.scroll_lines(0, dir * count)
    end, { buffer = 0 })
end

-- Re-enable vim syntax after vim.treesitter.start() (called in chat_widget
-- after ftplugin) which clears vim.bo.syntax. Deferred so it runs after the
-- current event loop iteration, at which point treesitter setup is complete.
-- "ON" sources syntax/AgenticChat.vim for the buffer's filetype.
local bufnr = vim.api.nvim_get_current_buf()

-- `#` is markdown heading syntax here, not a comment. HTML comments are
-- the standard in markdown and survive a markdown renderer.
vim.bo[bufnr].commentstring = "<!-- %s -->"
vim.bo[bufnr].includeexpr = require("agentic.goto_file").EXPR

vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].syntax = "ON"
    end
end)

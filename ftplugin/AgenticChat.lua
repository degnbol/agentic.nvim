-- Trackpad scroll workaround: at conceallevel=2, treesitter's conceal_lines
-- makes fenced_code_block_delimiter lines (```) zero-height. Combined with
-- concealcursor="n", the cursor on such a line is in an invalid visual state
-- that blocks all further scrolling. Fix: skip past zero-height lines both
-- before scrolling (unstick) and after (prevent re-sticking).
local function skip_concealed_line(dir)
    if vim.wo.conceallevel < 2 then
        return
    end
    local lnum = vim.fn.line(".")
    if not vim.fn.getline(lnum):match("^```") then
        return
    end
    local last = vim.fn.line("$")
    local target = lnum + dir
    while
        target >= 1
        and target <= last
        and vim.fn.getline(target):match("^```")
    do
        target = target + dir
    end
    if target >= 1 and target <= last then
        vim.fn.cursor(target, 1)
    end
end

local ctrl_y = vim.api.nvim_replace_termcodes("<C-y>", true, false, true)
local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)

for _, d in ipairs({ "Up", "Down" }) do
    local dir = d == "Up" and -1 or 1
    local scroll_key = d == "Up" and ctrl_y or ctrl_e
    vim.keymap.set({ "n", "v", "i" }, "<ScrollWheel" .. d .. ">", function()
        skip_concealed_line(dir)
        -- Respect mousescroll ver:N setting for scroll speed
        local count = vim.o.mousescroll:match("ver:(%d+)") or "3"
        vim.cmd.normal({ count .. scroll_key, bang = true })
        skip_concealed_line(dir)
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

vim.schedule(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.bo[bufnr].syntax = "ON"
    end
end)

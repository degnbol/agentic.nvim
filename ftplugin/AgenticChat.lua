-- Trackpad scroll workaround: rows the window draws at zero height (fence
-- delimiters, `agentic.ui.FenceRows`) stay zero-height under the cursor with
-- concealcursor="n", and the cursor on one blocks all further scrolling. Fix:
-- skip past zero-height rows both before scrolling (unstick) and after
-- (prevent re-sticking).

--- @param lnum integer 1-indexed
--- @return boolean
local function zero_height(lnum)
    return vim.api.nvim_win_text_height(
        0,
        { start_row = lnum - 1, end_row = lnum - 1 }
    ).all == 0
end

--- Move the cursor off a zero-height row to the nearest drawn row in
--- direction `dir`, if there is one.
--- @param dir integer -1 for up, 1 for down
local function skip_zero_height_rows(dir)
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    if not zero_height(lnum) then
        return
    end
    local last = vim.api.nvim_buf_line_count(0)
    local target = lnum + dir
    while target >= 1 and target <= last and zero_height(target) do
        target = target + dir
    end
    if target >= 1 and target <= last then
        vim.api.nvim_win_set_cursor(0, { target, 0 })
    end
end

local ctrl_y = vim.api.nvim_replace_termcodes("<C-y>", true, false, true)
local ctrl_e = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)

for _, d in ipairs({ "Up", "Down" }) do
    local dir = d == "Up" and -1 or 1
    local scroll_key = d == "Up" and ctrl_y or ctrl_e
    vim.keymap.set({ "n", "v", "i" }, "<ScrollWheel" .. d .. ">", function()
        skip_zero_height_rows(dir)
        -- Respect mousescroll ver:N setting for scroll speed
        local count = vim.o.mousescroll:match("ver:(%d+)") or "3"
        vim.cmd.normal({ count .. scroll_key, bang = true })
        skip_zero_height_rows(dir)
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

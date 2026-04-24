-- Minimal config to reproduce agentic.nvim bugs on a clean neovim.
-- Run from the agentic.nvim repo root:
--   nvim --clean -u repro/repro.lua
-- `--clean` excludes user dirs from 'runtimepath' so your own config
-- does not interfere.

local plugin_root =
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

require("agentic").setup({
    windows = { position = "tab" },
})

-- Defer via vim.schedule: plain VimEnter fires before the rest of startup
-- completes, and windows opened there race with neovim's post-VimEnter tail.
vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
        vim.schedule(function()
            require("agentic").open({ auto_add_to_context = false })
        end)
    end,
})

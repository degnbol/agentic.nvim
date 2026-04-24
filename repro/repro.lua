-- Minimal config to reproduce agentic.nvim bugs on a clean neovim.
-- Run from the agentic.nvim repo root:
--   nvim --clean -u repro/repro.lua
-- `--clean` excludes user dirs from 'runtimepath' so your own config
-- does not interfere.

local plugin_root =
    vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.rtp:prepend(plugin_root)

require("agentic").setup({})

vim.keymap.set({ "n", "v", "i" }, "<C-\\>", function()
    require("agentic").toggle()
end, { desc = "Agentic toggle", silent = true })

vim.keymap.set({ "n", "v" }, "<C-'>", function()
    require("agentic").add_selection_or_file_to_context()
end, { desc = "Agentic add selection/file", silent = true })

vim.keymap.set({ "n", "v", "i" }, "<C-,>", function()
    require("agentic").new_session()
end, { desc = "Agentic new session", silent = true })

-- Mini.test runner with Busted-style emulation
local deps_path = vim.fn.getcwd() .. "/deps"
local mini_path = deps_path .. "/mini.nvim"

-- Bootstrap mini.nvim
if not vim.uv.fs_stat(mini_path) then
    vim.fn.mkdir(deps_path, "p")

    local output = vim.fn.system({
        "git",
        "clone",
        "--depth=1",
        "https://github.com/echasnovski/mini.nvim",
        mini_path,
    })

    if vim.v.shell_error ~= 0 then
        error(
            string.format(
                "Failed to clone mini.nvim (exit code: %d):\n%s",
                vim.v.shell_error,
                output
            )
        )
    end
end

vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(vim.fn.getcwd())

-- Strip the user's outer nvim config from rtp so its plugin/, ftplugin/,
-- and autocmd files don't auto-source into the test environment. Test
-- runs must depend only on this project's code and mini.nvim.
local xdg = os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")
local user_nvim = xdg .. "/nvim"
local user_nvim_after = xdg .. "/nvim/after"
local rtp = vim.api.nvim_get_option_value("runtimepath", {})
local cleaned = {}
for entry in vim.gsplit(rtp, ",", { plain = true }) do
    if entry ~= user_nvim and entry ~= user_nvim_after then
        table.insert(cleaned, entry)
    end
end
vim.api.nvim_set_option_value("runtimepath", table.concat(cleaned, ","), {})

local MiniTest = require("mini.test")

MiniTest.setup({
    collect = {
        emulate_busted = true,
        find_files = function()
            local files = {}
            -- Co-located unit tests: *.test.lua anywhere in lua/
            vim.list_extend(
                files,
                vim.fn.globpath("lua", "**/*.test.lua", true, true)
            )
            -- Integration tests in tests/: *_test.lua or test_*.lua
            vim.list_extend(
                files,
                vim.fn.globpath("tests", "**/*_test.lua", true, true)
            )
            vim.list_extend(
                files,
                vim.fn.globpath("tests", "**/test_*.lua", true, true)
            )
            return files
        end,
    },
})

--- Health check for agentic.nvim
--- This file is auto-discovered by :checkhealth
--- Users can run :checkhealth agentic to see only agentic.nvim health
--- @class agentic.Health
local M = {}
local vim_health = vim.health

function M.check()
    local Config = require("agentic.config")

    vim_health.start("agentic.nvim")
    local nvim_version = vim.version()
    local required_version = { 0, 12, 0 }
    if
        nvim_version.major > required_version[1]
        or (
            nvim_version.major == required_version[1]
            and nvim_version.minor >= required_version[2]
        )
    then
        vim_health.ok(
            string.format(
                "Neovim version %d.%d.%d",
                nvim_version.major,
                nvim_version.minor,
                nvim_version.patch
            )
        )
    else
        vim_health.error(
            string.format(
                "Neovim >= %d.%d.%d required (current: %d.%d.%d)",
                required_version[1],
                required_version[2],
                required_version[3],
                nvim_version.major,
                nvim_version.minor,
                nvim_version.patch
            )
        )
    end

    vim_health.start("pi")
    local command = Config.pi.command
    if vim.fn.executable(vim.fn.expand(command)) == 1 then
        vim_health.ok(string.format("%s: installed", command))
    else
        vim_health.error(
            string.format("%s: not found in PATH or not executable", command),
            { "Install pi: npm install -g @earendil-works/pi-coding-agent" }
        )
    end

    vim_health.start("Optional Dependencies")
    local Clipboard = require("agentic.ui.clipboard")
    if Clipboard.is_img_clip_installed() then
        vim_health.ok("hakonharnes/img-clip.nvim: installed")
    else
        vim_health.info(
            "hakonharnes/img-clip.nvim: not installed (optional - enables image pasting from clipboard)"
        )
    end
end

return M

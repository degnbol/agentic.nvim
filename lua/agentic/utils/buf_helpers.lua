local Logger = require("agentic.utils.logger")

--- @class agentic.utils.BufHelpers
local BufHelpers = {}

--- Executes a callback with the buffer set to modifiable.
--- Returns false when the buffer is invalid or the callback errors.
--- Otherwise returns the callback's own return value.
--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|false result
function BufHelpers.with_modifiable(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    local original_modifiable =
        vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
    vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
    local ok, response = pcall(callback, bufnr)

    vim.api.nvim_set_option_value(
        "modifiable",
        original_modifiable,
        { buf = bufnr }
    )

    if not ok then
        Logger.notify(
            "Error in with_modifiable: \n" .. tostring(response),
            vim.log.levels.ERROR,
            { title = "🐞 Error with modifiable callback" }
        )
        return false
    end

    return response
end

function BufHelpers.start_insert_on_last_char()
    vim.cmd("normal! G$")
    vim.cmd("startinsert!")
end

--- @generic T
--- @param bufnr integer
--- @param callback fun(bufnr: integer): T|nil
--- @return T|nil
function BufHelpers.execute_on_buffer(bufnr, callback)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    return vim.api.nvim_buf_call(bufnr, function()
        return callback(bufnr)
    end)
end

--- Sets a keymap for a specific buffer.
--- @param bufnr integer
--- @param mode string|string[]
--- @param lhs string
--- @param rhs string|fun():any
--- @param opts vim.keymap.set.Opts|nil
function BufHelpers.keymap_set(bufnr, mode, lhs, rhs, opts)
    opts = opts or {}
    opts.buf = bufnr
    vim.keymap.set(mode, lhs, rhs, opts)
end

--- @param keymaps agentic.UserConfig.KeymapValue|nil
--- @return boolean
function BufHelpers.is_keymap_disabled(keymaps)
    if keymaps == nil or keymaps == false or keymaps == "" then
        return true
    end
    if type(keymaps) == "table" and #keymaps == 0 then
        return true
    end
    return false
end

--- Sets multiple keymaps from a KeymapValue config entry for a specific buffer.
--- Normalizes the config value (string, string[], or array of string/KeymapEntry)
--- and calls keymap_set for each binding.
--- @param keymaps agentic.UserConfig.KeymapValue
--- @param bufnr integer
--- @param callback fun():any
--- @param opts vim.keymap.set.Opts|nil
--- @param default_mode? string|string[] Mode for bare-string entries when no explicit mode (default "n")
function BufHelpers.multi_keymap_set(
    keymaps,
    bufnr,
    callback,
    opts,
    default_mode
)
    if type(keymaps) == "string" then
        keymaps = { keymaps }
    end

    default_mode = default_mode or "n"

    for _, key in ipairs(keymaps) do
        --- @type string|string[]
        local modes = default_mode
        --- @type string
        local keymap

        if type(key) == "table" and key.mode then
            modes = key.mode
            keymap = key[1]
        else
            keymap = key --[[@as string]]
        end

        BufHelpers.keymap_set(bufnr, modes, keymap, callback, opts)
    end
end

--- @param bufnr integer
--- @return boolean
function BufHelpers.is_buffer_empty(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

    if #lines == 0 then
        return true
    end

    -- Check if buffer contains only whitespace or a single empty line
    if #lines == 1 and lines[1]:match("^%s*$") then
        return true
    end

    -- Check if all lines are whitespace
    for _, line in ipairs(lines) do
        if line:match("%S") then
            return false
        end
    end

    return true
end

function BufHelpers.feed_ESC_key()
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
        "nx",
        false
    )
end

--- Move the viewport forward to follow the buffer's last line as
--- content streams in. Never scrolls upward.
---
--- `max_topline` caps the forward target. Callers use this to hold
--- the start of a prose run at the top of the viewport (passing the
--- run's first line); the cap is in effect for as long as the caller
--- keeps passing it.
--- @param winid integer
--- @param max_topline? integer 1-indexed buffer line; topline must not exceed it
function BufHelpers.scroll_down(winid, max_topline)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end
    local Config = require("agentic.config")
    if Config.auto_scroll and Config.auto_scroll.enabled == false then
        return
    end

    local ok, info = pcall(vim.fn.getwininfo, winid)
    if not ok or not info[1] then
        return
    end
    local old_topline = info[1].topline
    local winheight = info[1].height
    local last_line =
        vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))

    -- Single decision: smallest topline that puts last_line at the bottom
    -- row, clamped to a valid topline (≥ 1, ≤ max_topline), and never
    -- below the current topline. When the buffer already fits in view
    -- (`last_line - winheight + 1 ≤ 1`) the inner max collapses to 1,
    -- and the outer max keeps us at `old_topline` — no jump.
    local target = math.max(
        old_topline,
        math.min(max_topline or math.huge, math.max(1, last_line - winheight + 1))
    )
    if target == old_topline then
        return
    end

    local scrolloff = vim.api.nvim_get_option_value("scrolloff", {
        win = winid,
    })
    local cursor_lnum =
        math.min(last_line, target + winheight - 1 - scrolloff)
    vim.api.nvim_win_call(winid, function()
        vim.fn.winrestview({
            topline = target,
            lnum = cursor_lnum,
            col = 0,
        })
    end)
end

return BufHelpers

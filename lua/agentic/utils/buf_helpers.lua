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

--- Scroll a window to the bottom, but only if it wouldn't scroll upward.
--- Prevents the jarring jump when `G0zb` overshoots on short buffers.
--- When `max_topline` is provided and the natural scroll would push the view
--- past that buffer line, the topline is clamped to it. This pins a target
--- line at the top of the viewport (e.g. the start of a prose run) instead
--- of letting auto-scroll drag it off-screen. The clamp only applies when
--- `old_topline <= max_topline` — if the user has manually scrolled past
--- the anchor, normal scroll resumes.
--- @param winid integer
--- @param has_virt_lines? boolean Whether virtual lines (status animation) are active
--- @param max_topline? integer Buffer line (0-indexed in the API but 1-indexed here to match `topline`) above which the viewport must not scroll
function BufHelpers.scroll_down_only(winid, has_virt_lines, max_topline)
    if not vim.api.nvim_win_is_valid(winid) then
        return
    end

    local Config = require("agentic.config")
    if Config.auto_scroll and Config.auto_scroll.enabled == false then
        return
    end

    -- Skip when user is in insert mode — executing normal! commands via
    -- nvim_win_call during insert mode can corrupt input state and crash.
    local mode = vim.api.nvim_get_mode().mode
    if mode:find("^i") or mode:find("^R") then
        return
    end

    local ok, old_info = pcall(vim.fn.getwininfo, winid)
    if not ok or not old_info[1] then
        return
    end
    local old_topline = old_info[1].topline

    vim.api.nvim_win_call(winid, function()
        if has_virt_lines then
            vim.cmd("normal! G0zb\5") -- \5 = <C-e>
        else
            vim.cmd("normal! G0zb")
        end
    end)

    ok, old_info = pcall(vim.fn.getwininfo, winid)
    if not ok or not old_info[1] then
        return
    end
    local new_topline = old_info[1].topline

    -- "Don't scroll backward" only applies when we don't have a pin.
    -- With max_topline set, the caller wants the topline at exactly that
    -- line whenever it would otherwise drift past — preserving the
    -- pre-scroll view here would silently bypass the pin in cases where
    -- vim's view management has already shifted the topline.
    if not max_topline and new_topline < old_topline then
        vim.api.nvim_win_call(winid, function()
            vim.fn.winrestview({ topline = old_topline })
        end)
        return
    end

    if max_topline and new_topline > max_topline then
        -- Always clamp when the natural scroll would overflow the anchor.
        -- The previous `old_topline <= max_topline` precondition broke the
        -- common case: in interactive mode, vim redraws between chunks and
        -- continuously auto-corrects topline as the buffer grows past the
        -- viewport (cursor was parked at last_line by the prior G0zb). By
        -- the time the deferred scroll fires, `old_topline` is already
        -- past the anchor, so the precondition silently bailed and the
        -- pin never engaged at all. The "user scrolled past anchor" case
        -- the precondition guarded against is now handled at the caller
        -- by detecting a pin-state mismatch and releasing the pin (so
        -- max_topline arrives nil here).
        --
        -- `G0zb` above moved cursor to the last buffer line. Restoring
        -- only `topline` leaves the cursor off-screen, and vim re-corrects
        -- topline back to last_line - winheight + 1 on the next redraw.
        -- Park cursor inside the pinned viewport so the clamp survives.
        --
        -- `scrolloff` matters: vim insists on that many context lines
        -- between cursor and the top/bottom edge of the WINDOW. Park the
        -- cursor at `max_topline + winheight - 1 - scrolloff` so the
        -- below-cursor margin is already satisfied; otherwise vim shifts
        -- topline forward by `scrolloff` to honour it, breaking the pin
        -- by exactly that many lines. Default scrolloff is 0 — but users
        -- often set it globally (e.g. 4 or 8) and the chat window
        -- inherits that.
        local winheight = vim.api.nvim_win_get_height(winid)
        local last_line =
            vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))
        local scrolloff = vim.api.nvim_get_option_value("scrolloff", {
            win = winid,
        })
        local cursor_lnum = math.min(
            last_line,
            math.max(max_topline, max_topline + winheight - 1 - scrolloff)
        )
        vim.api.nvim_win_call(winid, function()
            vim.fn.winrestview({
                topline = max_topline,
                lnum = cursor_lnum,
                col = 0,
            })
        end)
    end
end

return BufHelpers

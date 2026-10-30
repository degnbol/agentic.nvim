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

--- Rename a buffer without leaking a buffer under its old name.
--- `nvim_buf_set_name` keeps the old name alive as an unlisted, unloaded
--- alternate-file buffer; this wipes it. Raises E95 when a loaded buffer
--- already has `name`.
--- @param bufnr integer
--- @param name string
function BufHelpers.rename(bufnr, name)
    local old_name = vim.api.nvim_buf_get_name(bufnr)
    vim.api.nvim_buf_set_name(bufnr, name)
    if old_name == "" then
        return
    end
    for _, other in ipairs(vim.api.nvim_list_bufs()) do
        if
            other ~= bufnr
            and not vim.api.nvim_buf_is_loaded(other)
            and vim.api.nvim_buf_get_name(other) == old_name
        then
            vim.api.nvim_buf_delete(other, { force = true })
        end
    end
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

--- Set a buffer-local keymap over any buffer-local map of the same lhs.
--- @param bufnr integer
--- @param mode string
--- @param lhs string
--- @param rhs fun():any
--- @param opts vim.keymap.set.Opts|nil
--- @return fun() restore Deletes the map and puts back the one it replaced,
---   if any. Does nothing once the buffer is invalid or the map on `lhs` is
---   no longer this one (unloaded by `:bdelete`, or rebound).
function BufHelpers.shadow_keymap(bufnr, mode, lhs, rhs, opts)
    local replaced = vim.api.nvim_buf_call(bufnr, function()
        return vim.fn.maparg(lhs, mode, false, true)
    end)
    BufHelpers.keymap_set(bufnr, mode, lhs, rhs, opts)

    return function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
            return
        end
        vim.api.nvim_buf_call(bufnr, function()
            local current = vim.fn.maparg(lhs, mode, false, true)
            if current.buffer ~= 1 or current.callback ~= rhs then
                return
            end
            vim.keymap.del(mode, lhs, { buf = bufnr })
            if replaced.buffer == 1 then
                vim.fn.mapset(replaced)
            end
        end)
    end
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
--- and calls keymap_set for each binding. Binds nothing for a disabled value
--- (`is_keymap_disabled`).
--- @param keymaps agentic.UserConfig.KeymapValue|nil
--- @param bufnr integer
--- @param callback fun(lhs: string):any
--- @param opts vim.keymap.set.Opts|nil
--- @param default_mode? string|string[] Mode for bare-string entries when no explicit mode (default "n")
function BufHelpers.multi_keymap_set(
    keymaps,
    bufnr,
    callback,
    opts,
    default_mode
)
    if BufHelpers.is_keymap_disabled(keymaps) then
        return
    end
    --- @cast keymaps -nil
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

        BufHelpers.keymap_set(bufnr, modes, keymap, function()
            return callback(keymap)
        end, opts)
    end
end

--- Bind `keymaps` on `bufnr` to focus `input_win()`, then feed the pressed
--- key there with its count and register, remapped. No-op when `input_win()`
--- returns nil.
--- @param keymaps string|string[]|nil
--- @param bufnr integer
--- @param input_win fun(): integer|nil
function BufHelpers.bind_to_input(keymaps, bufnr, input_win)
    BufHelpers.multi_keymap_set(keymaps, bufnr, function(lhs)
        local count = vim.v.count
        local register = vim.v.register
        local winid = input_win()
        if not winid then
            return
        end
        vim.api.nvim_set_current_win(winid)
        -- `"=` would prompt for a new expression; `<CR>` reuses the last.
        if register == "=" then
            register = "=\r"
        end
        local keys = (count > 0 and count or "")
            .. '"'
            .. register
            .. vim.keycode(lhs)
        vim.api.nvim_feedkeys(keys, "mi", false)
    end, { desc = "Agentic: Run key in the input" })
end

--- Whether a buffer is an unnamed, unmodified normal buffer with no text, as
--- startup, `:enew` and `:tabnew` leave.
--- @param bufnr integer
--- @return boolean
function BufHelpers.is_blank_unnamed(bufnr)
    return vim.api.nvim_buf_get_name(bufnr) == ""
        and vim.bo[bufnr].buftype == ""
        and not vim.bo[bufnr].modified
        and BufHelpers.is_buffer_blank(bufnr)
end

--- Whether every line of the buffer is empty or whitespace only.
--- @param bufnr integer
--- @return boolean
function BufHelpers.is_buffer_blank(bufnr)
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if line:match("%S") then
            return false
        end
    end

    return true
end

--- Add lines to the end of a buffer as a paragraph of their own: they replace
--- a buffer with no text, and follow a blank line otherwise. In a buffer with
--- text, the change `on_bytes` reports starts on the row after the last line,
--- so it covers no existing row.
--- @param bufnr integer
--- @param lines string[]
--- @return integer first_row 0-indexed row of lines[1]
function BufHelpers.append_paragraph(bufnr, lines)
    if BufHelpers.is_buffer_blank(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return 0
    end
    local first_row = vim.api.nvim_buf_line_count(bufnr)
    local last = vim.api.nvim_buf_get_lines(bufnr, -2, -1, false)[1]
    if last:match("%S") then
        lines = vim.list_extend({ "" }, lines)
        first_row = first_row + 1
    end
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
    return first_row
end

--- Insert lines in the current window's buffer, before the cursor, or in place
--- of the selection in visual and select mode (a block's text goes once, at
--- its top-left corner). The cursor ends on the character after the text, as
--- `gP` leaves it, and typing continues there in insert mode. A selection
--- ends in the mode it started from, as an operator does: normal mode, or
--- insert mode after `i_CTRL-O`. Reads and writes no register.
--- @param lines string[]
function BufHelpers.insert_text(lines)
    if vim.api.nvim_get_mode().mode:match("^[sS\19]") then
        -- `normal!` in select mode types its keys as text.
        vim.cmd("normal! \7")
    end
    local mode = vim.api.nvim_get_mode().mode:sub(1, 1)

    --- @type integer[] (1,0)-indexed start of the text
    local pos
    if mode == "V" then
        local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
        local first = math.min(vim.fn.line("v"), cursor_row)
        local last = math.max(vim.fn.line("v"), cursor_row)
        vim.cmd("normal! \27")
        -- Not `"_d` and a put: that leaves an extra empty line when the
        -- selection is the whole buffer.
        vim.api.nvim_buf_set_lines(0, first - 1, last, false, lines)
        pos = { first, 0 }
    elseif mode == "v" or mode == "\22" then
        local tick = vim.b.changedtick
        vim.cmd('normal! "_d')
        -- '[ over the cursor: a delete to the end of the line leaves the
        -- cursor one character left. A delete of nothing leaves '[ unset or
        -- stale.
        pos = vim.b.changedtick == tick and vim.api.nvim_win_get_cursor(0)
            or vim.api.nvim_buf_get_mark(0, "[")
        local row = pos[1] - 1
        vim.api.nvim_buf_set_text(0, row, pos[2], row, pos[2], lines)
    else
        vim.api.nvim_put(lines, "c", false, true)
        return
    end
    -- set_lines and set_text, unlike nvim_put, do not move the cursor
    -- after the text.
    local end_col = (#lines == 1 and pos[2] or 0) + #lines[#lines]
    vim.api.nvim_win_set_cursor(0, { pos[1] + #lines - 1, end_col })
end

--- Add lines to the start of a buffer as a paragraph of their own: they
--- replace a buffer with no text, and precede a blank line otherwise.
--- @param bufnr integer
--- @param lines string[]
function BufHelpers.prepend_paragraph(bufnr, lines)
    if BufHelpers.is_buffer_blank(bufnr) then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return
    end
    local first = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    if first:match("%S") then
        lines = vim.list_extend(vim.list_slice(lines), { "" })
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, lines)
end

--- Add text to the start of a draft buffer as a paragraph of its own, then set
--- the buffer's `modified` to whether it holds text. Leading and trailing empty
--- lines of the text are dropped. Text with no lines left changes nothing.
--- @param bufnr integer
--- @param text string
function BufHelpers.prepend_draft(bufnr, text)
    local lines = vim.split(text, "\n", { trimempty = true })
    if #lines == 0 then
        return
    end
    BufHelpers.prepend_paragraph(bufnr, lines)
    BufHelpers.sync_modified(bufnr)
end

--- Set a buffer's `modified` to whether it holds text, for a buffer whose
--- text is unsent rather than unwritten.
--- @param bufnr integer
function BufHelpers.sync_modified(bufnr)
    vim.bo[bufnr].modified = not BufHelpers.is_buffer_blank(bufnr)
end

--- Count the blank (whitespace-only) rows that end a buffer.
--- @param bufnr integer
--- @param max integer Stop counting at this many
--- @return integer count Blank rows ending the buffer, at most `max`
function BufHelpers.trailing_blank_rows(bufnr, max)
    local rows = vim.api.nvim_buf_get_lines(bufnr, -max - 1, -1, false)
    local count = 0
    for i = #rows, 1, -1 do
        if count == max or rows[i]:match("%S") then
            break
        end
        count = count + 1
    end
    return count
end

function BufHelpers.feed_ESC_key()
    vim.api.nvim_feedkeys(
        vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
        "nx",
        false
    )
end

--- Repaint pending screen updates if the command-line is open.
--- Neovim skips the pre-input-block redraw while in cmdline mode
--- (src/nvim/state.c state_enter, `(State & MODE_CMDLINE) == 0` guard),
--- so async buffer writes are not painted until CmdlineLeave. Forcing a
--- redraw here paints them live. No-op in every other mode, where the
--- redraw runs automatically before each input block.
---
--- Only matches `c` (cmdline). The sibling more-prompt/hit-enter state
--- (`mode()` `r`/`rm`) defers by the same mechanism but is not a path
--- this plugin drives; widen only if that changes.
function BufHelpers.redraw_if_cmdline()
    if vim.fn.mode():sub(1, 1) == "c" then
        vim.cmd("redraw")
    end
end

--- Whether neovim is in Insert or Replace mode, where it skips fold updates.
--- @return boolean
function BufHelpers.in_insert_mode()
    return vim.api.nvim_get_mode().mode:match("^[iR]") ~= nil
end

--- Recompute a window's expression folds now, keeping each fold's open or
--- closed state. Call outside insert mode, which drops the recompute. Fires
--- OptionSet for 'foldexpr'.
--- @param winid integer
function BufHelpers.recompute_folds(winid)
    local opts = { win = winid, scope = "local" }
    local foldexpr = vim.api.nvim_get_option_value("foldexpr", opts)
    vim.api.nvim_set_option_value("foldexpr", foldexpr, opts)
    -- Setting 'foldexpr' only marks the folds invalid for a lazy recompute;
    -- `foldlevel()` runs it at once.
    vim.api.nvim_win_call(winid, function()
        vim.fn.foldlevel(1)
    end)
end

--- Open the fold that starts at `lnum` in `winid` when `open`, else close it,
--- leaving every other fold's state as it was. A bare `:foldopen`/`:foldclose`
--- would act on the outermost closed or innermost open fold at `lnum`.
---
--- `lnum` must lie outside any fold that ends at `lnum - 1`: a fold that
--- starts right after a same-level sibling counts as no fold here. No two
--- folds may start on the same line, and no fold may be small enough for
--- 'foldminlines' to show it open.
--- @param winid integer
--- @param lnum integer 1-indexed first line of the fold
--- @param open boolean
--- @return string|nil err E490 when no fold starts at `lnum`, or the error of a fold command
function BufHelpers.set_fold(winid, lnum, open)
    --- @param cmd "foldopen"|"foldclose"
    --- @param line integer
    local function fold_cmd(cmd, line)
        vim.api.nvim_cmd({ cmd = cmd, range = { line } }, {})
    end

    return vim.api.nvim_win_call(winid, function()
        if vim.fn.foldlevel(lnum) <= vim.fn.foldlevel(lnum - 1) then
            return string.format("E490: No fold starts at line %d", lnum)
        end
        --- Closed folds around `lnum`, outermost first, opened to reach it.
        --- @type integer[]
        local enclosing = {}
        local ok, err = pcall(function()
            local closed = vim.fn.foldclosed(lnum)
            while closed ~= -1 and closed ~= lnum do
                table.insert(enclosing, closed)
                fold_cmd("foldopen", closed)
                closed = vim.fn.foldclosed(lnum)
            end
            if open and closed == lnum then
                fold_cmd("foldopen", lnum)
            elseif not open and closed == -1 then
                fold_cmd("foldclose", lnum)
            end
        end)
        -- Outside the first pcall, so a failed op still restores them.
        local reclosed, reclose_err = pcall(function()
            for i = #enclosing, 1, -1 do
                fold_cmd("foldclose", enclosing[i])
            end
        end)
        return not ok and err or not reclosed and reclose_err or nil
    end)
end

--- Screen rows of lines `first` through `last` in `winid`, fold-aware.
--- @param winid integer
--- @param first integer 1-indexed
--- @param last integer 1-indexed, inclusive; 0 rows when below `first`
--- @param max_height integer Stop counting past this many rows
--- @return integer rows
local function screen_rows(winid, first, last, max_height)
    if last < first then
        return 0
    end
    return vim.api.nvim_win_text_height(winid, {
        start_row = first - 1,
        end_row = last - 1,
        max_height = max_height,
    }).all
end

--- The smallest topline, at least `lower`, from which the lines through
--- `last` fit in `rows` screen rows of `winid`. `last + 1` when even `last`
--- alone does not fit.
--- @param winid integer
--- @param lower integer 1-indexed, at most `last + 1`
--- @param last integer 1-indexed
--- @param rows integer
--- @return integer topline 1-indexed
local function fitting_topline(winid, lower, last, rows)
    -- The height to `last` is monotonically non-increasing in the topline,
    -- so binary search.
    local lo, hi = lower, last + 1
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        -- Capped one row past `rows`, making each measurement O(rows) rather
        -- than O(buffer): with conceal active, height depends on a per-line
        -- treesitter query, and an uncapped near-whole-buffer measurement on
        -- every streamed update is O(n²) across a stream. The capped height
        -- may overshoot (the boundary line is counted whole), but only once
        -- it is already past `rows`, so the comparison holds.
        if screen_rows(winid, mid, last, rows + 1) > rows then
            lo = mid + 1
        else
            hi = mid
        end
    end
    return lo
end

--- The smallest topline, at least `lower`, from which the lines through the
--- last fit in `rows` screen rows of `winid`. The last line when even it
--- alone does not fit.
--- @param winid integer
--- @param lower integer 1-indexed, at most the last line
--- @param rows integer
--- @return integer topline 1-indexed
local function bottom_topline(winid, lower, rows)
    local last_line =
        vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))
    return math.min(fitting_topline(winid, lower, last_line, rows), last_line)
end

--- Screen rows of `winid` left for text: its height less `padding`, at least
--- 1.
--- @param winid integer
--- @param padding integer Rows to keep empty below the buffer's last line
--- @return integer rows
local function text_room(winid, padding)
    return math.max(1, vim.api.nvim_win_get_height(winid) - padding)
end

--- Bring rows `start_row` through `end_row` of `winid`'s buffer into view. A
--- span that fits is centred, moved down as far as needed to show no empty
--- rows past the end of the buffer; a taller one starts at the top. May
--- scroll up or down.
---
--- Fold-aware: closed folds count as one row. A cursor that would not stay
--- `scrolloff` rows inside the new view moves to the first line that does
--- (to the start of a closed fold there), so vim does not move the view to
--- fit the cursor.
--- @param winid integer
--- @param padding integer Rows to keep empty below the buffer's last line
--- @param start_row integer 0-indexed
--- @param end_row integer 0-indexed, inclusive
function BufHelpers.show_rows(winid, padding, start_row, end_row)
    local height = vim.api.nvim_win_get_height(winid)
    local room = text_room(winid, padding)
    local first, last = start_row + 1, end_row + 1
    local span = screen_rows(winid, first, last, room + 1)

    local topline = first
    if span <= room then
        -- The rows above the span fill half the slack.
        local above = math.floor((room - span) / 2)
        local centre = fitting_topline(winid, 1, first - 1, above)
        topline = math.min(centre, bottom_topline(winid, 1, room))
    end

    local so = math.min(
        vim.api.nvim_get_option_value("scrolloff", { win = winid }),
        math.floor((height - 1) / 2)
    )
    local last_line =
        vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))
    vim.api.nvim_win_call(winid, function()
        local function fold_start(lnum)
            local start = vim.fn.foldclosed(lnum)
            return start > 0 and start or lnum
        end
        local cursor = fold_start(vim.api.nvim_win_get_cursor(winid)[1])
        local inside = cursor >= topline
            and screen_rows(winid, topline, cursor - 1, so + 1) >= so
            and screen_rows(winid, topline, cursor, height + 1)
                <= height - so
        --- @type vim.fn.winrestview.dict
        local view = { topline = topline }
        if not inside then
            local lnum, rows = topline, 0
            while rows < so and lnum < last_line do
                local fold_end = vim.fn.foldclosedend(lnum)
                local next_lnum = (fold_end > 0 and fold_end or lnum) + 1
                rows = rows + screen_rows(winid, lnum, next_lnum - 1, so + 1)
                lnum = next_lnum
            end
            view.lnum = fold_start(lnum)
            view.col = 0
        end
        vim.fn.winrestview(view)
    end)
end

--- Move the viewport forward to follow the buffer's last line as
--- content streams in. Never scrolls upward.
---
--- `max_topline` caps the forward target. Callers use this to hold
--- the start of a prose run at the top of the viewport (passing the
--- run's first line); the cap is in effect for as long as the caller
--- keeps passing it.
---
--- Topline and cursor placement are fold-aware: target is the smallest
--- line whose [target..last_line] range fits within the window's screen
--- rows (closed folds collapse to one row), and the cursor lands inside
--- the visible viewport so vim does not auto-correct topline. The cursor
--- goes to the last line, unless the cap holds the view short of it: then
--- a cursor on the last line or outside the viewport moves into it, even
--- when the viewport does not move.
--- @param winid integer
--- @param padding integer Rows to keep empty below the buffer's last line
--- @param max_topline integer|nil 1-indexed buffer line; topline must not exceed it
--- @return boolean held Whether the cap holds the view short of the last line
function BufHelpers.scroll_down(winid, padding, max_topline)
    if not vim.api.nvim_win_is_valid(winid) then
        return false
    end

    local info = vim.fn.getwininfo(winid)[1]
    local old_topline = info.topline
    local winheight = info.height
    local last_line =
        vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(winid))

    -- Return early where the viewport stays as-is: scroll_down never
    -- scrolls upward.
    if max_topline and max_topline < old_topline then
        return true -- viewport already past the cap
    end
    if old_topline >= last_line then
        -- Tail line is already at/above the top: no forward scroll is
        -- possible (reachable when the last line alone overflows the
        -- window). Returning here also guarantees `old_topline <
        -- last_line` below, keeping every measurement range in bounds; a
        -- buffer that shrinks below its topline never gets this far
        -- because vim clamps the reported topline back into range first.
        return false
    end
    local natural_target =
        bottom_topline(winid, old_topline, text_room(winid, padding))

    local held = max_topline ~= nil and max_topline < natural_target
    local target = held and max_topline or natural_target

    -- Cursor stays inside the visible viewport so vim's redraw does not
    -- override `target`. Unless held, last_line is in view, so the cursor
    -- sits on it and follows the writes. Held, locate the
    -- largest line above last_line whose row from `target` stays within
    -- `winheight - scrolloff`, then snap to the start of any closed fold it
    -- falls inside (otherwise the cursor would open it). Not last_line
    -- itself: a write at the end of the buffer moves a cursor there along
    -- with the new text, below the viewport, and the redraw then scrolls
    -- past the cap. A cursor already between `target` and that line stays.
    --- @type integer|nil
    local cursor_lnum = last_line
    if held then
        local scrolloff = vim.api.nvim_get_option_value("scrolloff", {
            win = winid,
        })
        local cursor_height = math.max(1, winheight - scrolloff)
        local lo, hi = target, math.max(target, last_line - 1)
        while lo < hi do
            local mid = math.ceil((lo + hi) / 2)
            local h = vim.api.nvim_win_text_height(winid, {
                start_row = target - 1,
                end_row = mid - 1,
                max_height = cursor_height + 1,
            }).all
            if h > cursor_height then
                hi = mid - 1
            else
                lo = mid
            end
        end
        local park_lnum = lo
        vim.api.nvim_win_call(winid, function()
            local fold_start = vim.fn.foldclosed(park_lnum)
            if fold_start > 0 then
                park_lnum = fold_start
            end
        end)
        local current = vim.api.nvim_win_get_cursor(winid)[1]
        cursor_lnum = nil
        if current < target or current > park_lnum then
            cursor_lnum = park_lnum
        end
    end

    local view = { topline = target }
    if cursor_lnum then
        view.lnum = cursor_lnum
        view.col = 0
    end
    vim.api.nvim_win_call(winid, function()
        vim.fn.winrestview(view)
    end)
    return held
end

return BufHelpers

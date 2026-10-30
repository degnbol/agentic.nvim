local Conceal = require("agentic.utils.conceal")
local Treesitter = require("agentic.utils.treesitter")

--- Horizontal scroll by displayed columns in chat windows.
---
--- With 'nowrap', `leftcol` counts raw columns, concealed ones included
--- (expected behaviour upstream: neovim/neovim#30324). A row with K concealed cells left of `leftcol` moves
--- only `leftcol - K` displayed cells, so rows padded to line up after
--- conceal, e.g. markdown tables, drift apart under horizontal scroll.
---
--- A decoration provider evens this out: on each redraw of a scrolled chat
--- window it hides, per drawn row, the first K displayed cells right of
--- the scroll edge with an ephemeral `conceal = ""` extmark. Every row then
--- moves `leftcol` displayed cells. Ephemeral marks apply to the window
--- being drawn only, so another window on the same buffer is unaffected,
--- and the buffer text never changes.
---
--- `leftcol` is clamped by the cursor's raw column, so it can exceed the
--- cursor line's displayed length. When the hidden range on the current
--- window's cursor row would reach the line end, it therefore ends before
--- the cursor byte; that row misaligns rather than going blank around the
--- cursor. A cursor on a hidden byte elsewhere is drawn on the next
--- displayed cell. Where Neovim leaves the cursor line unconcealed
--- ('concealcursor'), this conceal is suppressed with the rest.
---
--- The first frame after an edit may read treesitter trees the highlighter
--- has not reparsed yet; its redraw on parse completion corrects it.
---
--- @class agentic.ui.EdgeConceal
local EdgeConceal = {}

local NS = vim.api.nvim_create_namespace("agentic_edge_conceal")

--- Above every other conceal, so no replacement from another range starting
--- inside the hidden range is drawn.
local PRIORITY = 65535

--- Byte range to hide so the row moves `leftcol` displayed cells.
---
--- The range starts at the first character at raw vcol >= `leftcol` and
--- covers K displayed cells, K being `leftcol` minus that character's
--- displayed vcol. A double-width character that overshoots K is included.
--- The range stops at the line end and before the first inline virt text
--- anchor inside it. A range that reaches the line end also stops before
--- `cursor_col`, when given.
--- @param columns agentic.utils.Conceal.Columns
--- @param leftcol integer
--- @param cursor_col integer|nil byte of the cursor on this row
--- @return integer|nil start_col nil when there is nothing to hide
--- @return integer|nil end_col exclusive
function EdgeConceal.hide_range(columns, leftcol, cursor_col)
    local starts, shown = columns.starts, columns.shown
    local i_first
    for i, byte in ipairs(starts) do
        if columns.raw[byte] >= leftcol then
            i_first = i
            break
        end
    end
    if not i_first then
        return nil, nil
    end

    local start_col = starts[i_first]
    local n_hide = leftcol - shown[start_col]
    local end_col = start_col
    if n_hide > 0 then
        for i = i_first + 1, #starts do
            local byte = starts[i]
            end_col = byte
            if
                columns.inline_at[byte]
                or shown[byte] - shown[start_col] >= n_hide
            then
                break
            end
        end
    end
    if cursor_col and end_col == starts[#starts] then
        end_col = math.min(end_col, cursor_col)
    end
    if end_col <= start_col then
        return nil, nil
    end
    return start_col, end_col
end

--- @class agentic.ui.EdgeConceal.WinState
--- @field leftcol integer
--- @field trees agentic.utils.Treesitter.HighlightTree[] trees on the window's rows

--- Set an ephemeral conceal mark so `row` of `winid` moves `leftcol`
--- displayed cells.
--- @param winid integer
--- @param bufnr integer
--- @param row integer 0-based
--- @param state agentic.ui.EdgeConceal.WinState
local function conceal_edge(winid, bufnr, row, state)
    -- Extmark ranges first: at equal priority Neovim draws treesitter
    -- conceal after persistent marks (its `_subpriority` is above theirs).
    local ranges = Conceal.extmark_ranges(bufnr, row, row + 1)
    vim.list_extend(
        ranges,
        Treesitter.conceal_ranges(bufnr, state.trees, row, row + 1)
    )
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    local columns = Conceal.columns(
        line,
        ranges,
        Conceal.inline_widths(bufnr, row, row + 1)[row] or {},
        vim.bo[bufnr].tabstop
    )

    local cursor_col
    if winid == vim.api.nvim_get_current_win() then
        local cursor = vim.api.nvim_win_get_cursor(winid)
        cursor_col = cursor[1] - 1 == row and cursor[2] or nil
    end

    local start_col, end_col =
        EdgeConceal.hide_range(columns, state.leftcol, cursor_col)
    if start_col then
        vim.api.nvim_buf_set_extmark(bufnr, NS, row, start_col, {
            end_col = end_col,
            conceal = "",
            ephemeral = true,
            priority = PRIORITY,
        })
    end
end

--- State of each window being redrawn whose rows need a mark, set by
--- `on_win` and read by `on_range` in the same redraw. The trees are
--- collected once per window: walking every tree per row costs ~10 ms per
--- redraw in a chat of ~1000 trees.
--- @type table<integer, agentic.ui.EdgeConceal.WinState>
local state_by_win = {}

--- Register the decoration provider. It acts on the drawn rows of
--- AgenticChat windows with 'nowrap', 'conceallevel' >= 2 and a nonzero
--- `leftcol`; rows inside closed folds are not drawn and cost nothing.
--- Registering again replaces it.
function EdgeConceal.register()
    vim.api.nvim_set_decoration_provider(NS, {
        on_win = function(_, winid, bufnr, toprow, botrow)
            state_by_win[winid] = nil
            if
                vim.bo[bufnr].filetype ~= "AgenticChat"
                or vim.wo[winid].wrap
                or vim.wo[winid].conceallevel < 2
            then
                return false
            end
            local leftcol = vim.fn.getwininfo(winid)[1].leftcol
            if leftcol == 0 then
                return false
            end
            state_by_win[winid] = {
                leftcol = leftcol,
                trees = Treesitter.highlight_trees(bufnr, toprow, botrow + 1),
            }
            return true
        end,
        on_range = function(_, winid, bufnr, begin_row, _, end_row, end_col)
            local state = state_by_win[winid]
            local last_row = end_col > 0 and end_row or end_row - 1
            for row = begin_row, last_row do
                conceal_edge(winid, bufnr, row, state)
            end
        end,
    })
end

return EdgeConceal

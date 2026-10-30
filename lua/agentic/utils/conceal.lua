--- Display columns of a line under conceal.
---
--- Follows how Neovim draws conceal at `conceallevel >= 2` (`decor_redraw_col`
--- in src/nvim/decoration.c, the conceal block in src/nvim/drawline.c):
--- - A byte is hidden if any conceal range covers it.
--- - The ranges covering a byte are ordered by priority, then insertion
---   order; the last one decides. A replacement cell is drawn at a byte only
---   when that deciding range starts at this byte, on this row, with a
---   non-empty text.
--- - Inline virt text is not hidden by conceal and counts as raw columns.
---
--- @class agentic.utils.Conceal
local Conceal = {}

--- Priority of an extmark set without one (`DECOR_PRIORITY_BASE` in
--- src/nvim/decoration_defs.h). `nvim_buf_get_extmarks` reports a mark's
--- priority only when it has an `hl_group`, so a conceal-only mark is
--- assumed to have this one.
local DEFAULT_PRIORITY = 4096

--- @class agentic.utils.Conceal.Range
--- @field row integer 0-based
--- @field col integer 0-based start byte on `row`
--- @field end_col integer exclusive end byte on `row`; `v:maxcol` for the line end
--- @field text string replacement; "" hides
--- @field priority integer
--- @field starts_on_row boolean false for a range continued from an earlier row

--- @class agentic.utils.Conceal.Inline
--- @field col integer byte the virt text sits before
--- @field width integer display cells

--- @class agentic.utils.Conceal.Columns
--- @field starts integer[] 0-based start byte of each character, then the line length
--- @field raw table<integer, integer> raw vcol at each byte of `starts`
--- @field shown table<integer, integer> displayed vcol at each byte of `starts`
--- @field inline_at table<integer, true> bytes with inline virt text anchored before them

--- Split a conceal that may span rows into one range per row, limited to
--- rows srow..erow-1. A range that runs to its row's end gets
--- `end_col = v:maxcol`. Empty ranges are dropped.
--- @param range Range4 0-based start row, start col, end row, end col (exclusive)
--- @param text string
--- @param priority integer
--- @param srow integer
--- @param erow integer exclusive
--- @return agentic.utils.Conceal.Range[]
function Conceal.split_rows(range, text, priority, srow, erow)
    local start_row, start_col, end_row, end_col = unpack(range)
    --- @type agentic.utils.Conceal.Range[]
    local pieces = {}
    for row = math.max(start_row, srow), math.min(end_row, erow - 1) do
        local piece_col = row == start_row and start_col or 0
        local piece_end = row == end_row and end_col or vim.v.maxcol
        if piece_end > piece_col then
            pieces[#pieces + 1] = {
                row = row,
                col = piece_col,
                end_col = piece_end,
                text = text,
                priority = priority,
                starts_on_row = row == start_row,
            }
        end
    end
    return pieces
end

--- Conceal ranges of persistent extmarks in all namespaces on rows
--- srow..erow-1. Invalid marks and marks without an end are skipped.
--- @param bufnr integer
--- @param srow integer
--- @param erow integer exclusive
--- @return agentic.utils.Conceal.Range[]
function Conceal.extmark_ranges(bufnr, srow, erow)
    local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        -1,
        { srow, 0 },
        { erow - 1, -1 },
        { details = true, overlap = true, type = "highlight" }
    )
    --- @type agentic.utils.Conceal.Range[]
    local ranges = {}
    for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4] or {}
        if details.conceal and details.end_row and not details.invalid then
            vim.list_extend(
                ranges,
                Conceal.split_rows(
                    { row, col, details.end_row, details.end_col },
                    details.conceal,
                    details.priority or DEFAULT_PRIORITY,
                    srow,
                    erow
                )
            )
        end
    end
    return ranges
end

--- Inline virt text widths on rows srow..erow-1, keyed by row. Invalid
--- marks are skipped.
--- @param bufnr integer
--- @param srow integer
--- @param erow integer exclusive
--- @return table<integer, agentic.utils.Conceal.Inline[]>
function Conceal.inline_widths(bufnr, srow, erow)
    local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        -1,
        { srow, 0 },
        { erow - 1, -1 },
        { details = true, type = "virt_text" }
    )
    --- @type table<integer, agentic.utils.Conceal.Inline[]>
    local by_row = {}
    for _, mark in ipairs(marks) do
        local row, col, details = mark[2], mark[3], mark[4] or {}
        if details.virt_text_pos == "inline" and not details.invalid then
            local width = 0
            for _, chunk in ipairs(details.virt_text) do
                width = width + vim.api.nvim_strwidth(chunk[1])
            end
            by_row[row] = by_row[row] or {}
            table.insert(by_row[row], { col = col, width = width })
        end
    end
    return by_row
end

--- The range deciding how `byte` draws: the last covering one in `order`.
--- @param ranges agentic.utils.Conceal.Range[]
--- @param order integer[] indices into `ranges`, in drawing order
--- @param byte integer
--- @return agentic.utils.Conceal.Range|nil
local function deciding_range(ranges, order, byte)
    for i = #order, 1, -1 do
        local range = ranges[order[i]]
        if range.col <= byte and byte < range.end_col then
            return range
        end
    end
    return nil
end

--- Raw and displayed vcol of every character of `line`, per the drawing rules
--- in the module docstring. Assumes `conceallevel >= 2`. Tabs are counted at
--- their unconcealed width.
--- @param line string
--- @param ranges agentic.utils.Conceal.Range[] this row's ranges, in insertion order
--- @param inlines agentic.utils.Conceal.Inline[]
--- @param tabstop integer
--- @return agentic.utils.Conceal.Columns
function Conceal.columns(line, ranges, inlines, tabstop)
    local order = {}
    for i = 1, #ranges do
        order[i] = i
    end
    table.sort(order, function(a, b)
        local priority_a, priority_b = ranges[a].priority, ranges[b].priority
        if priority_a ~= priority_b then
            return priority_a < priority_b
        end
        return a < b
    end)

    local inline_width = {}
    --- @type agentic.utils.Conceal.Columns
    local columns = { starts = {}, raw = {}, shown = {}, inline_at = {} }
    for _, inline in ipairs(inlines) do
        inline_width[inline.col] = (inline_width[inline.col] or 0)
            + inline.width
        columns.inline_at[inline.col] = true
    end

    local raw, shown, byte = 0, 0, 0
    while true do
        raw = raw + (inline_width[byte] or 0)
        shown = shown + (inline_width[byte] or 0)
        columns.starts[#columns.starts + 1] = byte
        columns.raw[byte] = raw
        columns.shown[byte] = shown
        if byte >= #line then
            return columns
        end

        local next_byte = byte + vim.str_utf_end(line, byte + 1) + 1
        local char = line:sub(byte + 1, next_byte)
        local width
        if char == "\t" then
            width = tabstop - raw % tabstop
        elseif char:match("^[ -~]$") then
            width = 1
        else
            width = vim.fn.strdisplaywidth(char)
        end
        raw = raw + width
        local decider = deciding_range(ranges, order, byte)
        if not decider then
            shown = shown + width
        elseif decider.col == byte and decider.starts_on_row then
            shown = shown + vim.api.nvim_strwidth(decider.text)
        end
        byte = next_byte
    end
end

return Conceal

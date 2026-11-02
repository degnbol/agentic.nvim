local MarkdownInline = require("agentic.utils.markdown_inline")

--- GFM pipe tables: escaping raw text into cells and laying out aligned
--- rows, with cells measured by a given `Measure`.
--- @class agentic.utils.MarkdownTable
local M = {}

--- Display cells of markdown cell text.
--- @alias agentic.utils.MarkdownTable.Measure fun(cell: string): integer

--- Raw text as markdown cell text: `|` becomes `\|`, with the backslashes
--- directly before it doubled.
--- @param text string single line
--- @return string cell
function M.cell(text)
    return (
        text:gsub("(\\*)|", function(backslashes)
            return backslashes .. backslashes .. "\\|"
        end)
    )
end

--- Delimiter cell of a given width, keeping the alignment colons of `align`.
--- @param align string delimiter cell, e.g. `:---:`, `---:`, or `""`
--- @param width integer
--- @return string
local function delimiter_cell(align, width)
    local left = align:match("^:") and ":" or ""
    local right = align:match(":$") and ":" or ""
    return left .. ("-"):rep(width - #left - #right) .. right
end

--- Words joined by spaces, each run of words from one span wrapped in its
--- markup, with any text glued to the span outside that.
--- @param words agentic.utils.MarkdownInline.Word[] in display order
--- @return string line
local function join_words(words)
    local parts = {}
    local i = 1
    while i <= #words do
        local first, span = words[i], words[i].span
        local texts = {}
        while words[i] and words[i].span == span do
            texts[#texts + 1] = words[i].text
            i = i + 1
        end
        local run = table.concat(texts, " ")
        parts[#parts + 1] = span
                and (first.prefix or "") .. span.open .. run .. span.close .. (words[i - 1].suffix or "")
            or run
    end
    return table.concat(parts, " ")
end

--- Wrap cell text into lines at most `width` display cells wide, as
--- `measure` counts them. Breaks only between `MarkdownInline.words`. Words of
--- one span that share a line are wrapped in the span's markup, so a link
--- becomes one link per line with the same URL. A word wider than `width`
--- gets a line of its own.
--- @param cell string markdown cell text
--- @param width integer display cells
--- @param measure agentic.utils.MarkdownTable.Measure
--- @return string[] lines at least one, `{ "" }` for an empty cell
function M.wrap_cell(cell, width, measure)
    local lines = {}
    local line_words = {} --- @type agentic.utils.MarkdownInline.Word[]
    for _, word in ipairs(MarkdownInline.words(cell)) do
        line_words[#line_words + 1] = word
        if #line_words > 1 and measure(join_words(line_words)) > width then
            line_words[#line_words] = nil
            lines[#lines + 1] = join_words(line_words)
            line_words = { word }
        end
    end
    lines[#lines + 1] = join_words(line_words)
    return lines
end

--- Narrowest width the cell can wrap to: the widest line of
--- `wrap_cell(cell, 1, measure)`.
--- @param cell string markdown cell text
--- @param measure agentic.utils.MarkdownTable.Measure
--- @return integer width display cells
function M.min_width(cell, measure)
    local widest = 0
    for _, line in ipairs(M.wrap_cell(cell, 1, measure)) do
        widest = math.max(widest, measure(line))
    end
    return widest
end

--- Column widths that fit `budget`. Starts at `natural`. While the sum
--- exceeds `budget`, narrows the widest column still above its `minimum`
--- by one cell, leftmost on ties. Stops at `minimum` when `budget` cannot
--- be met.
--- @param natural integer[] preferred width per column, display cells
--- @param minimum integer[] least width per column, display cells
--- @param budget integer most the widths may sum to, display cells
--- @return integer[] widths per column, display cells
function M.column_widths(natural, minimum, budget)
    local widths = vim.list_slice(natural)
    local total = 0
    for _, width in ipairs(widths) do
        total = total + width
    end
    while total > budget do
        local i_widest --- @type integer|nil
        for c, width in ipairs(widths) do
            if
                width > minimum[c]
                and (not i_widest or width > widths[i_widest])
            then
                i_widest = c
            end
        end
        if not i_widest then
            break
        end
        widths[i_widest] = widths[i_widest] - 1
        total = total - 1
    end
    return widths
end

--- Aligned GFM pipe table. Every column is padded to its widest cell in
--- display cells as `measure` counts them, and is at least 3 wide. Every row
--- has a leading and a trailing pipe. Rows shorter than the widest row get
--- empty cells.
---
--- With `max_width`, columns narrow toward it, each no narrower than its
--- header or its widest word. A body cell wider than its column wraps onto
--- continuation rows whose other cells are empty. The header never wraps:
--- GFM reads only the line above the delimiter row as the header.
--- @param header string[] header cells, as markdown cell text
--- @param rows string[][] body cells per row, as markdown cell text
--- @param align string[]|nil delimiter cells whose alignment colons to keep, nil for plain dashes
--- @param max_width integer|nil display cells per line, nil or ≤ 0 for natural widths
--- @param measure agentic.utils.MarkdownTable.Measure
--- @return string[] lines header row, delimiter row, then the body rows
--- @return integer[] row_ends 1-based index in `lines` of the last line of every body row, when some body row wrapped, else {}
function M.lines(header, rows, align, max_width, measure)
    local all_rows = { header }
    vim.list_extend(all_rows, rows)

    local widths = {} --- @type integer[]
    for _, row in ipairs(all_rows) do
        for c = 1, #row do
            widths[c] = math.max(widths[c] or 3, measure(row[c]))
        end
    end

    if max_width and max_width > 0 then
        local minimum = {} --- @type integer[]
        for c = 1, #widths do
            minimum[c] = math.max(3, measure(header[c] or ""))
        end
        for _, row in ipairs(rows) do
            for c = 1, #row do
                minimum[c] = math.max(minimum[c], M.min_width(row[c], measure))
            end
        end
        widths = M.column_widths(widths, minimum, max_width - (3 * #widths + 1))
    end

    --- @param cells string[]
    --- @return string
    local function row_line(cells)
        local padded = {}
        for c, width in ipairs(widths) do
            local cell = cells[c] or ""
            padded[c] = cell .. (" "):rep(width - measure(cell))
        end
        return "| " .. table.concat(padded, " | ") .. " |"
    end

    local delimiters = {}
    for c, width in ipairs(widths) do
        delimiters[c] = delimiter_cell(align and align[c] or "", width)
    end

    local lines =
        { row_line(header), "| " .. table.concat(delimiters, " | ") .. " |" }
    local row_ends = {} --- @type integer[]
    local wrapped = false
    for _, row in ipairs(rows) do
        local cell_lines = {} --- @type string[][]
        local height = 1
        for c, width in ipairs(widths) do
            local cell = row[c] or ""
            cell_lines[c] = measure(cell) > width
                    and M.wrap_cell(cell, width, measure)
                or { cell }
            height = math.max(height, #cell_lines[c])
        end
        wrapped = wrapped or height > 1
        for i = 1, height do
            local cells = {}
            for c = 1, #widths do
                cells[c] = cell_lines[c][i] or ""
            end
            lines[#lines + 1] = row_line(cells)
        end
        row_ends[#row_ends + 1] = #lines
    end
    return lines, wrapped and row_ends or {}
end

return M

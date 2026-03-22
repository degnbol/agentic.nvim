--- Hard-wrap prose lines to a target width, preserving code blocks untouched.
--- @class agentic.utils.TextWrap
local M = {}

--- Wrap a single line of prose at word boundaries.
--- Preserves leading whitespace and list markers on continuation lines.
--- @param line string
--- @param width integer
--- @return string[]
local function wrap_line(line, width)
    if #line <= width then
        return { line }
    end

    -- Detect leading prefix (whitespace + optional list marker) for continuation
    local prefix = line:match("^(%s*%d+%.%s)") -- "  1. "
        or line:match("^(%s*[%-%*]%s)") -- "- ", "* "
        or line:match("^(%s*>%s?)") -- "> "
        or line:match("^(%s+)") -- plain indent
        or ""
    local continuation_indent = string.rep(" ", #prefix)

    local result = {}
    local current = ""
    local first = true

    for word in line:gmatch("%S+") do
        local sep = current == "" and "" or " "
        if current == "" then
            current = (first and "" or continuation_indent) .. word
        elseif #current + #sep + #word <= width then
            current = current .. sep .. word
        else
            result[#result + 1] = current
            first = false
            current = continuation_indent .. word
        end
    end
    if current ~= "" then
        result[#result + 1] = current
    end

    return result
end

--- Check if a line is a markdown table row (starts with optional whitespace then `|`).
--- @param line string
--- @return boolean
local function is_table_line(line)
    return line:match("^%s*|") ~= nil
end

--- Parse a markdown table row into cells (content between pipes).
--- @param line string
--- @return string[]
local function parse_table_row(line)
    local cells = {}
    -- Strip leading/trailing pipes and split on |
    local inner = line:match("^%s*|(.*)$")
    if not inner then
        return cells
    end
    -- Remove trailing pipe if present
    inner = inner:match("^(.-)%s*|?%s*$")
    for cell in (inner .. "|"):gmatch("(.-)|") do
        cells[#cells + 1] = vim.trim(cell)
    end
    return cells
end

--- Check if a row is a separator row (all cells are dashes/colons like `---`, `:---:`, `---:`).
--- @param cells string[]
--- @return boolean
local function is_separator_row(cells)
    for _, cell in ipairs(cells) do
        if not cell:match("^:?%-+:?$") then
            return false
        end
    end
    return #cells > 0
end

--- Build a separator cell of given width preserving alignment markers.
--- @param original string  Original separator cell (e.g. ":---:", "---:", ":---")
--- @param width integer    Target content width (excluding padding spaces)
--- @return string
local function build_separator_cell(original, width)
    local left = original:match("^:") and ":" or ""
    local right = original:match(":$") and ":" or ""
    local dashes = width - #left - #right
    if dashes < 1 then
        dashes = 1
    end
    return left .. string.rep("-", dashes) .. right
end

--- Format a contiguous block of markdown table lines with aligned columns.
--- @param table_lines string[]
--- @return string[]
local function format_table(table_lines)
    -- Parse all rows
    local rows = {}
    for _, line in ipairs(table_lines) do
        rows[#rows + 1] = parse_table_row(line)
    end

    -- Find max column count and column widths
    local num_cols = 0
    for _, row in ipairs(rows) do
        if #row > num_cols then
            num_cols = #row
        end
    end
    if num_cols == 0 then
        return table_lines
    end

    local col_widths = {}
    for c = 1, num_cols do
        col_widths[c] = 0
    end

    -- Find separator row index for width calculation (exclude separator dashes from width)
    local sep_idx = nil
    for i, row in ipairs(rows) do
        if is_separator_row(row) then
            sep_idx = i
            break
        end
    end

    for idx, row in ipairs(rows) do
        if idx ~= sep_idx then
            for c = 1, num_cols do
                local cell = row[c] or ""
                if #cell > col_widths[c] then
                    col_widths[c] = #cell
                end
            end
        end
    end

    -- Ensure minimum width of 3 for separator dashes
    for c = 1, num_cols do
        if col_widths[c] < 3 then
            col_widths[c] = 3
        end
    end

    -- Rebuild each row with padded cells
    local result = {}
    for _, row in ipairs(rows) do
        local parts = {}
        local is_sep = is_separator_row(row)
        for c = 1, num_cols do
            local cell = row[c] or ""
            if is_sep then
                parts[#parts + 1] = build_separator_cell(cell, col_widths[c])
            else
                parts[#parts + 1] = cell
                    .. string.rep(" ", col_widths[c] - #cell)
            end
        end
        result[#result + 1] = "| " .. table.concat(parts, " | ") .. " |"
    end

    return result
end

--- Wrap a single prose line at word boundaries.
--- Returns the original line unchanged (in a table) if it fits within width,
--- is blank, or looks like a code fence / table row.
--- @param line string
--- @param width integer
--- @return string[]
function M.wrap_single_line(line, width)
    if
        width <= 0
        or #line <= width
        or line:match("^%s*$")
        or line:match("^%s*```")
        or is_table_line(line)
    then
        return { line }
    end
    return wrap_line(line, width)
end

--- Hard-wrap prose in a block of lines, skipping fenced code blocks and
--- formatting markdown tables with aligned columns.
--- @param lines string[]
--- @param width integer Target width in columns
--- @return string[]
function M.wrap_prose(lines, width)
    if width <= 0 then
        return lines
    end

    local out = {}
    local in_fence = false
    local table_buf = {} ---@type string[]

    for _, line in ipairs(lines) do
        -- Toggle code fence state on ``` lines
        if line:match("^%s*```") then
            -- Flush any buffered table lines before entering/leaving a fence
            if #table_buf > 0 then
                for _, tl in ipairs(format_table(table_buf)) do
                    out[#out + 1] = tl
                end
                table_buf = {}
            end
            in_fence = not in_fence
            out[#out + 1] = line
        elseif in_fence then
            out[#out + 1] = line
        elseif is_table_line(line) then
            table_buf[#table_buf + 1] = line
        else
            -- Flush any buffered table lines before prose
            if #table_buf > 0 then
                for _, tl in ipairs(format_table(table_buf)) do
                    out[#out + 1] = tl
                end
                table_buf = {}
            end
            if line:match("^%s*$") then
                out[#out + 1] = line
            else
                local wrapped = wrap_line(line, width)
                for _, wl in ipairs(wrapped) do
                    out[#out + 1] = wl
                end
            end
        end
    end

    -- Flush trailing table lines
    if #table_buf > 0 then
        for _, tl in ipairs(format_table(table_buf)) do
            out[#out + 1] = tl
        end
    end

    return out
end

return M

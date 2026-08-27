--- Hard-wrap prose lines to a target width, preserving code blocks untouched.
--- @class agentic.utils.TextWrap
local M = {}

--- @class agentic.utils.TextWrap.Offset
--- @field orig_start integer 0-indexed byte position in the original line
---   where this sub-line's content (after the continuation indent) starts.
--- @field indent_len integer Number of leading indent bytes in the sub-line
---   that do NOT correspond to bytes in the original (added by the wrapper
---   on continuation lines). Always 0 for the first sub-line.

--- Wrap a single line of prose at word boundaries.
--- Preserves leading whitespace and list markers on continuation lines.
--- Returns sub-lines plus offset metadata so callers can map sub-line
--- local byte columns back to the original unwrapped line.
--- @param line string
--- @param width integer
--- @return string[] sub_lines
--- @return agentic.utils.TextWrap.Offset[] offsets
local function wrap_line(line, width)
    if #line <= width then
        return { line }, { { orig_start = 0, indent_len = 0 } }
    end

    -- Detect leading prefix (whitespace + optional list marker) for continuation
    local prefix = line:match("^(%s*%d+%.%s)") -- "  1. "
        or line:match("^(%s*[%-%*]%s)") -- "- ", "* "
        or line:match("^(%s*>%s?)") -- "> "
        or line:match("^(%s+)") -- plain indent
        or ""
    local continuation_indent = string.rep(" ", #prefix)
    local indent_len = #continuation_indent

    -- Walk words with byte positions so we can map sub-lines back to the
    -- original. gmatch gives us words but not positions; find in a loop does.
    -- Inline code spans (`...`) and inline math (`$...$`) are kept as a single
    -- word even when they contain spaces — a wrap must never fall inside
    -- backticks or dollar-math.
    local words = {} ---@type { text: string, start: integer }[]
    local len = #line
    local pos = 1
    while pos <= len do
        local s = line:find("%S", pos)
        if not s then
            break
        end
        -- Consume a maximal non-space run, but swallow whitespace that lives
        -- inside a closed backtick or dollar-math span so the span stays atomic.
        local i = s
        while i <= len do
            local ch = line:sub(i, i)
            if ch == "`" or ch == "$" then
                local run_end = i
                while run_end <= len and line:sub(run_end, run_end) == ch do
                    run_end = run_end + 1
                end
                local delim = line:sub(i, run_end - 1)
                local _, close_e = line:find(delim, run_end, true)
                if close_e then
                    i = close_e + 1
                else
                    i = run_end -- unclosed: treat delimiter run as literal text
                end
            elseif ch:match("%s") then
                break
            else
                i = i + 1
            end
        end
        words[#words + 1] = { text = line:sub(s, i - 1), start = s - 1 }
        pos = i
    end

    local result = {}
    local offsets = {}
    local current = ""
    local current_orig_start = 0
    local current_indent = 0
    local first = true

    for _, w in ipairs(words) do
        if current == "" then
            current = (first and "" or continuation_indent) .. w.text
            current_orig_start = w.start
            current_indent = first and 0 or indent_len
        elseif #current + 1 + #w.text <= width then
            current = current .. " " .. w.text
        else
            result[#result + 1] = current
            offsets[#offsets + 1] = {
                orig_start = current_orig_start,
                indent_len = current_indent,
            }
            first = false
            current = continuation_indent .. w.text
            current_orig_start = w.start
            current_indent = indent_len
        end
    end
    if current ~= "" then
        result[#result + 1] = current
        offsets[#offsets + 1] = {
            orig_start = current_orig_start,
            indent_len = current_indent,
        }
    end

    return result, offsets
end

--- Check if a line is a markdown table row (starts with optional whitespace then `|`).
--- @param line string
--- @return boolean
local function is_table_line(line)
    return line:match("^%s*|") ~= nil
end

--- Check if a line is a display-math fence: a line whose only content is `$$`.
--- This is the standard way multi-line display blocks are opened and closed;
--- matching only the bare `$$` line (not `$$x$$` inline) keeps single-line
--- display math on the per-line scanner path and avoids `$`-counting.
--- @param line string
--- @return boolean
local function is_math_fence(line)
    return line:match("^%s*%$%$%s*$") ~= nil
end

--- Check if a line is an ATX heading (1-6 `#` followed by a space or EOL).
--- Headings must never be wrapped — a wrapped continuation line is no longer
--- part of the heading.
--- @param line string
--- @return boolean
local function is_heading(line)
    local hashes = line:match("^%s*(#+)%s") or line:match("^%s*(#+)$")
    return hashes ~= nil and #hashes <= 6
end

--- Split a string on unescaped `|` delimiters.
--- `\|` is a literal pipe (not a delimiter), `\\` is a literal backslash
--- (so `\\|` is a literal backslash followed by a delimiter).
--- @param s string
--- @return string[]
local function split_on_pipes(s)
    local parts = {}
    local cur = ""
    local i = 1
    local len = #s
    while i <= len do
        local ch = s:sub(i, i)
        if ch == "\\" and i < len then
            local next_ch = s:sub(i + 1, i + 1)
            if next_ch == "|" or next_ch == "\\" then
                cur = cur .. ch .. next_ch
                i = i + 2
            else
                cur = cur .. ch
                i = i + 1
            end
        elseif ch == "|" then
            parts[#parts + 1] = cur
            cur = ""
            i = i + 1
        else
            cur = cur .. ch
            i = i + 1
        end
    end
    parts[#parts + 1] = cur
    return parts
end

--- Parse a markdown table row into cells (content between pipes).
--- @param line string
--- @return string[]
local function parse_table_row(line)
    local cells = {}
    -- Strip leading whitespace and leading pipe
    local inner = line:match("^%s*|(.*)$")
    if not inner then
        return cells
    end
    -- Split on unescaped pipes — gives empty strings for leading/trailing delimiters
    local parts = split_on_pipes(inner)
    -- Drop trailing empty part from the closing `|`
    if #parts > 0 and vim.trim(parts[#parts]) == "" then
        parts[#parts] = nil
    end
    for _, cell in ipairs(parts) do
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

--- Visual width of a table cell accounting for multibyte characters and
--- concealed markdown delimiters. At conceallevel=2 (the chat window default),
--- treesitter conceals emphasis_delimiter and code_span_delimiter nodes, so
--- delimiter characters are visually absent. Strikethrough is special: the
--- `~` chars only conceal for the genuine `~~double~~` case (which parses as
--- a strikethrough nested in another strikethrough); stray single tildes
--- stay visible because the parser pairs them spuriously (`~14 vs ~7`). The
--- nested-only conceal lives in the parent config's
--- `after/queries/markdown_inline/highlights.scm`.
--- @param cell string
--- @return integer
local function cell_visual_width(cell)
    -- Strip concealed delimiters to get visual content, then measure.
    -- Order matters: code spans first (protects content), then longest
    -- emphasis delimiters before shorter ones to avoid partial matches.
    local s = cell
    s = s:gsub("`([^`]+)`", "%1") -- code spans
    s = s:gsub("%*%*%*(.-)%*%*%*", "%1") -- bold+italic ***
    s = s:gsub("%*%*(.-)%*%*", "%1") -- bold **
    s = s:gsub("%*(.-)%*", "%1") -- italic *
    s = s:gsub("~~(.-)~~", "%1") -- ~~double~~ only
    return vim.api.nvim_strwidth(s)
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
                local vw = cell_visual_width(cell)
                if vw > col_widths[c] then
                    col_widths[c] = vw
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
                    .. string.rep(" ", col_widths[c] - cell_visual_width(cell))
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
    local sub_lines = M.wrap_single_line_with_offsets(line, width)
    return sub_lines
end

--- Same as `wrap_single_line` but also returns byte-offset metadata for each
--- sub-line, enabling callers to map sub-line local columns back to positions
--- in the original unwrapped line (for per-sub-line diff highlighting).
--- @param line string
--- @param width integer
--- @return string[] sub_lines
--- @return agentic.utils.TextWrap.Offset[] offsets
function M.wrap_single_line_with_offsets(line, width)
    if
        width <= 0
        or #line <= width
        or line:match("^%s*$")
        or line:match("^%s*```")
        or is_table_line(line)
        or is_heading(line)
    then
        return { line }, { { orig_start = 0, indent_len = 0 } }
    end
    return wrap_line(line, width)
end

--- Truncate a string to a display-column budget, marking the cut with `…`.
--- The ellipsis occupies the last column of `width`, so the result never
--- exceeds it. Returns the string unchanged when it already fits, or when
--- `width` is too small to say anything (under 4 columns an ellipsis is most of
--- the output).
--- @param s string
--- @param width integer Display columns available, ellipsis included
--- @return string
function M.truncate_to_width(s, width)
    if width < 4 or vim.fn.strdisplaywidth(s) <= width then
        return s
    end
    -- Character count is an upper bound on display width, so cut by characters
    -- first and shrink while the result is still too wide (double-width chars).
    local budget = width - 1
    local out = vim.fn.strcharpart(s, 0, budget)
    while #out > 0 and vim.fn.strdisplaywidth(out) > budget do
        out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1)
    end
    return out .. "…"
end

--- Find a fenced code block that is opened but never closed, and return the
--- delimiter that would close it.
---
--- Follows the markdown rule rather than `wrap_prose`'s fence toggle, which is
--- deliberately lenient (see the comment in its loop) and flips on any ` ``` `
--- line. tree-sitter-markdown does not: a closer must use the opener's own
--- delimiter character, carry no info string, and be at least as long as the
--- opener — so a typed ` ```zsh ` line never closes an open fence. A backtick
--- opener's info string may not contain a backtick (a tilde opener's may).
--- Callers balancing buffer text against the parser need the parser's rule; the
--- lenient one disagrees in exactly the cases that matter.
--- @param lines string[]
--- @return string|nil open_fence Delimiter run of the unterminated opener, nil when balanced
--- @return integer|nil open_index 1-based index of that opener in `lines`
function M.unclosed_fence(lines)
    --- @type string|nil, integer|nil
    local open_fence, open_index
    for i, line in ipairs(lines) do
        -- Up to 3 leading spaces; 4+ (or a tab) is an indented code block.
        local indent, delim, rest = line:match("^( *)([`~]+)(.*)$")
        if delim and #indent <= 3 and #delim >= 3 then
            if open_fence then
                if
                    delim:sub(1, 1) == open_fence:sub(1, 1)
                    and #delim >= #open_fence
                    and rest:match("^%s*$")
                then
                    open_fence, open_index = nil, nil
                end
            elseif delim:sub(1, 1) == "~" or not rest:find("`", 1, true) then
                open_fence, open_index = delim, i
            end
        end
    end
    return open_fence, open_index
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
    local in_math = false
    local table_buf = {} ---@type string[]

    --- Emit any buffered table lines (formatted) before a non-table line.
    local function flush_table()
        if #table_buf > 0 then
            for _, tl in ipairs(format_table(table_buf)) do
                out[#out + 1] = tl
            end
            table_buf = {}
        end
    end

    for _, line in ipairs(lines) do
        -- A ``` fence only toggles when we're not inside display math, and a
        -- `$$` fence only toggles when we're not inside a code fence — so the
        -- two block delimiters never corrupt each other's state. Everything
        -- inside either block (including a stray ``` or `$$`) passes through
        -- untouched; display math is authored pre-formatted and never re-wrapped.
        local code_fence = line:match("^%s*```") and not in_math
        local math_fence = is_math_fence(line) and not in_fence
        if code_fence then
            flush_table()
            in_fence = not in_fence
            out[#out + 1] = line
        elseif math_fence then
            flush_table()
            in_math = not in_math
            out[#out + 1] = line
        elseif in_fence or in_math then
            out[#out + 1] = line
        elseif is_table_line(line) then
            table_buf[#table_buf + 1] = line
        else
            flush_table()
            if line:match("^%s*$") or is_heading(line) then
                out[#out + 1] = line
            else
                local wrapped = wrap_line(line, width)
                for _, wl in ipairs(wrapped) do
                    out[#out + 1] = wl
                end
            end
        end
    end

    flush_table()

    return out
end

return M

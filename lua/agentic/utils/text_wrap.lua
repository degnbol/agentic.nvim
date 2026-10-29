local MarkdownTable = require("agentic.utils.markdown_table")

--- Fitting text to a display width: hard-wrapping prose (code blocks left
--- untouched), truncating to a column budget, abbreviating a count, and the
--- fence bookkeeping wrapping needs to know where prose stops.
--- @class agentic.utils.TextWrap
local M = {}

--- Wrap a single line of prose at word boundaries. Continuation lines are
--- indented to align after the line's leading whitespace and list or quote
--- marker.
--- @param line string
--- @param width integer
--- @return string[] sub_lines
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

    -- Inline code spans (`...`) and inline math (`$...$`) are kept as a single
    -- word even when they contain spaces — a wrap must never fall inside
    -- backticks or dollar-math.
    local words = {} ---@type string[]
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
        words[#words + 1] = line:sub(s, i - 1)
        pos = i
    end

    local result = {}
    local current = ""

    for _, word in ipairs(words) do
        if current == "" then
            current = (#result == 0 and "" or continuation_indent) .. word
        elseif #current + 1 + #word <= width then
            current = current .. " " .. word
        else
            result[#result + 1] = current
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

--- Format a contiguous block of markdown table lines with aligned columns.
--- A block whose second row is not a delimiter row is no table to the
--- markdown parser, and is returned unchanged.
--- @param table_lines string[]
--- @return string[]
local function format_table(table_lines)
    local rows = {}
    for _, line in ipairs(table_lines) do
        rows[#rows + 1] = parse_table_row(line)
    end
    if not (rows[2] and is_separator_row(rows[2])) then
        return table_lines
    end
    return MarkdownTable.lines(rows[1], vim.list_slice(rows, 3), rows[2])
end

--- Wrap a single prose line at word boundaries.
--- Returns the line unchanged if it fits within `width` (or `width` is not
--- positive), is blank, or looks like a code fence, table row or heading.
--- @param line string
--- @param width integer
--- @return string[]
function M.wrap_single_line(line, width)
    if
        width <= 0
        or line:match("^%s*$")
        or line:match("^%s*```")
        or is_table_line(line)
        or is_heading(line)
    then
        return { line }
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

--- Abbreviate a count for a display where the digits compete for width: a plain
--- integer below a thousand, `k`-suffixed to one decimal above it.
---
--- The plain branch is not cosmetic — `%.1fk` renders every count under a
--- thousand as some fraction of `0.9k`, which reads as "about none" for figures
--- that are routinely in the hundreds.
--- @param n number
--- @return string
function M.abbreviate_count(n)
    if n < 1000 then
        return string.format("%d", n)
    end
    return string.format("%.1fk", n / 1000)
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

--- Whether a line is a fence delimiter — the opening or closing ` ``` ` of a
--- fenced code block.
---
--- Applies `unclosed_fence`'s parser rule to a single line: up to 3 leading
--- spaces, a run of at least 3 backticks or tildes, and (for backticks) no
--- backtick in the info string. A closer, having no info string, always
--- qualifies.
---
--- The markdown highlights query sets `conceal_lines` on these, so at
--- conceallevel=2 the row is zero-height and anything anchored to it — a sign,
--- a fold marker — never renders.
--- @param line string
--- @return boolean
function M.is_fence_delimiter(line)
    local indent, delim, rest = line:match("^( *)([`~]+)(.*)$")
    if not delim or #indent > 3 or #delim < 3 then
        return false
    end
    return delim:sub(1, 1) == "~" or not rest:find("`", 1, true)
end

--- The first non-blank line of `text`, and the lines after it with blank
--- lines at both edges removed. Nil and `{}` for a text with no non-blank line.
--- @param text string
--- @return string|nil head
--- @return string[] rest
function M.head_and_rest(text)
    local lines = vim.split(text, "\n", { plain = true })
    local function blank(i)
        return lines[i]:match("^%s*$") ~= nil
    end
    local i_head = 1
    while i_head <= #lines and blank(i_head) do
        i_head = i_head + 1
    end
    if i_head > #lines then
        return nil, {}
    end
    local i_first, i_last = i_head + 1, #lines
    while i_first <= i_last and blank(i_first) do
        i_first = i_first + 1
    end
    while i_last >= i_first and blank(i_last) do
        i_last = i_last - 1
    end
    return lines[i_head], vim.list_slice(lines, i_first, i_last)
end

--- Split a line into its first sentence and the rest. A sentence ends at a
--- `.`, `!` or `?` followed by a word that does not start lowercase (so
--- `e.g. the` does not end one), outside balanced parentheses and inline code.
--- A line with no sentence end splits before a parenthetical that ends it,
--- unless that is the whole line.
--- @param line string
--- @return string head
--- @return string|nil tail Nil when the line does not split
function M.split_sentence(line)
    local function blank_out(span)
        return ("_"):rep(#span)
    end
    local masked = line:gsub("%b()", blank_out):gsub("`[^`]*`", blank_out)
    local i_end = masked:find("[.!?]%s+[^%l%s]")
    if i_end then
        return line:sub(1, i_end), vim.trim(line:sub(i_end + 1))
    end
    local head, parenthetical = line:match("^(.-%S)%s+(%b())%s*$")
    if head then
        return head, parenthetical
    end
    return line, nil
end

--- Prepend the newlines `text` needs to start a new paragraph: one blank line
--- after what precedes it.
--- @param text string Text that starts a new paragraph
--- @param trailing_newlines integer Newlines already ending what precedes `text`
--- @return string text `text` behind the newlines that make up the blank line
function M.paragraph_break(text, trailing_newlines)
    return string.rep("\n", math.max(0, 2 - trailing_newlines)) .. text
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

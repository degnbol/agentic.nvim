--- GFM pipe tables: escaping raw text into cells, measuring cells as they
--- show at `conceallevel = 2`, and laying out aligned rows.
--- @class agentic.utils.MarkdownTable
local M = {}

--- Entities the markdown_inline highlights query conceals to one character.
local ENTITIES = {
    "&nbsp;",
    "&lt;",
    "&gt;",
    "&amp;",
    "&quot;",
    "&ensp;",
    "&emsp;",
}

--- Display width of markdown cell text after the markdown_inline conceal:
--- code-span and emphasis delimiters, link and image syntax around the link
--- text, and replaced entities. A pattern measure, not a parse; nested or
--- overlapping constructs may measure wide.
---
--- Strikethrough `~` only conceals for the genuine `~~double~~` case (which
--- parses as a strikethrough nested in another strikethrough); stray single
--- tildes stay visible because the parser pairs them spuriously (`~14 vs ~7`).
--- The nested-only conceal lives in the parent config's
--- `after/queries/markdown_inline/highlights.scm`.
--- @param cell string markdown cell text
--- @return integer width display cells
function M.width(cell)
    -- A code span's content shows verbatim: replace it with inert filler of
    -- its width so the later patterns cannot touch it.
    local s = cell:gsub("(`+)([^`].-)%1", function(_, content)
        return ("x"):rep(vim.api.nvim_strwidth(content))
    end)
    -- A backslash escape shows both characters, and its punctuation never
    -- delimits.
    s = s:gsub("\\%p", "xx")
    for _, entity in ipairs(ENTITIES) do
        s = s:gsub(vim.pesc(entity), "x")
    end
    s = s:gsub("!?%[([^%]]*)%]%b()", "%1") -- inline link, image
    s = s:gsub("%[([^%]]*)%]%[[^%]]*%]", "%1") -- full and collapsed reference
    s = s:gsub("%[([^%]]*)%]", "%1") -- shortcut reference
    -- `*` emphasis opens before and closes after a non-space, so `2 * 3 * 4`
    -- and `*.lua, *.md` keep their stars.
    for _, stars in ipairs({ "%*%*%*", "%*%*", "%*" }) do
        s = s:gsub(stars .. "(%S.-%S)" .. stars, "%1")
            :gsub(stars .. "(%S)" .. stars, "%1")
    end
    -- `_` emphasis only opens and closes at a word edge, so `snake_case`
    -- keeps its underscores.
    s = (" " .. s .. " ")
        :gsub("(%W)___([^%s_].-)___(%W)", "%1%2%3")
        :gsub("(%W)__([^%s_].-)__(%W)", "%1%2%3")
        :gsub("(%W)_([^%s_].-)_(%W)", "%1%2%3")
    s = s:gsub("~~(.-)~~", "%1")
    return vim.api.nvim_strwidth(s) - 2
end

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

--- Aligned GFM pipe table. Every column is padded to its widest cell in
--- display cells after conceal, and is at least 3 wide; every row has a
--- leading and a trailing pipe. Rows shorter than the widest row get empty
--- cells.
--- @param header string[] header cells, as markdown cell text
--- @param rows string[][] body cells per row, as markdown cell text
--- @param align string[]|nil delimiter cells whose alignment colons to keep, nil for plain dashes
--- @return string[] lines header row, delimiter row, one line per body row
function M.lines(header, rows, align)
    local all_rows = { header }
    vim.list_extend(all_rows, rows)

    local widths = {} --- @type integer[]
    for _, row in ipairs(all_rows) do
        for c = 1, #row do
            widths[c] = math.max(widths[c] or 3, M.width(row[c]))
        end
    end

    --- @param cells string[]
    --- @return string
    local function row_line(cells)
        local padded = {}
        for c, width in ipairs(widths) do
            local cell = cells[c] or ""
            padded[c] = cell .. (" "):rep(width - M.width(cell))
        end
        return "| " .. table.concat(padded, " | ") .. " |"
    end

    local delimiters = {}
    for c, width in ipairs(widths) do
        delimiters[c] = delimiter_cell(align and align[c] or "", width)
    end

    local lines =
        { row_line(header), "| " .. table.concat(delimiters, " | ") .. " |" }
    for _, row in ipairs(rows) do
        lines[#lines + 1] = row_line(row)
    end
    return lines
end

return M

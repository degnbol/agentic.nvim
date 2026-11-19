local DirtyRows = require("agentic.utils.dirty_rows")
local Intervals = require("agentic.utils.intervals")
local Treesitter = require("agentic.utils.treesitter")

--- Zero-height fence delimiter rows of one markdown-grammar buffer: a
--- `conceal_lines` extmark on each.
---
--- A replacement for the `conceal_lines` metadata of the markdown highlights
--- query. A highlighter whose query has that metadata measures each row after
--- an edit by parsing the row alone, injected trees included
--- (`_on_conceal_line` in $VIMRUNTIME/lua/vim/treesitter/highlighter.lua).
--- Here a row's height is an extmark lookup.
---
--- Rows come from the root tree, and from each fence body whose language
--- resolves to markdown, recursively. Markdown that another language injects
--- (a heredoc, a docstring) keeps its delimiter rows.
--- @class agentic.ui.FenceRows
--- @field _bufnr integer
--- @field _dirty agentic.utils.DirtyRows
local FenceRows = {}
FenceRows.__index = FenceRows

--- Namespace of the marks.
FenceRows.NS = vim.api.nvim_create_namespace("agentic_fence_rows")

--- `fenced_code_block` nodes of the root tree of `parser` meeting rows
--- `first`..`last`.
--- @param parser vim.treesitter.LanguageTree A parsed markdown-grammar tree
--- @param first integer 0-indexed
--- @param last integer 0-indexed, inclusive
--- @return TSNode[]
local function blocks_in(parser, first, last)
    return Treesitter.captures_in(
        parser,
        "(fenced_code_block) @block",
        first,
        last
    )
end

--- Whether fence info-string `word` resolves to markdown once its fold marker
--- (`-fold`, `-foldnext`) is stripped.
--- @param word string
--- @return boolean
local function is_markdown(word)
    local base = word:gsub("%-foldnext$", ""):gsub("%-fold$", "")
    return Treesitter.resolve_lang(base) == "markdown"
end

--- Content of `block` when its info string's language resolves to markdown.
--- @param block TSNode A `fenced_code_block`
--- @param source integer|string
--- @return TSNode|nil content The block's `code_fence_content`
local function markdown_content(block, source)
    local lang, content
    for child in block:iter_children() do
        if child:type() == "info_string" then
            lang = child:named_child(0)
        elseif child:type() == "code_fence_content" then
            content = child
        end
    end
    if not (lang and content) then
        return nil
    end
    if not is_markdown(vim.treesitter.get_node_text(lang, source)) then
        return nil
    end
    return content
end

--- Memo of `text_delimiter_rows` results, inserted newest first.
--- @type { text: string, rows: integer[] }[]
local measured = {}

--- Entries `measured` keeps. One edit measures the same body a few times.
local MEASURED_MAX = 4

local delimiter_rows

--- 0-indexed rows of the fence delimiters of markdown `text`, and of the
--- delimiters in each markdown body in it. Do not modify the result: it is
--- shared with later calls.
--- @param text string
--- @return integer[]
local function text_delimiter_rows(text)
    for _, entry in ipairs(measured) do
        if entry.text == text then
            return entry.rows
        end
    end
    local body = vim.treesitter.get_string_parser(text, "markdown")
    local body_last = select(3, body:parse()[1]:root():range())
    local rows = delimiter_rows(body, 0, body_last)
    table.insert(measured, 1, { text = text, rows = rows })
    measured[MEASURED_MAX + 1] = nil
    return rows
end

--- 0-indexed rows of the fence delimiters in rows `first`..`last` of the root
--- tree of `parser`, and of the delimiters in each markdown body there.
--- @param parser vim.treesitter.LanguageTree A parsed markdown-grammar tree
--- @param first integer 0-indexed
--- @param last integer 0-indexed, inclusive
--- @return integer[]
delimiter_rows = function(parser, first, last)
    local rows = vim.tbl_map(
        function(node)
            return (node:start())
        end,
        Treesitter.captures_in(
            parser,
            "(fenced_code_block_delimiter) @delimiter",
            first,
            last
        )
    )
    for _, block in ipairs(blocks_in(parser, first, last)) do
        local content = markdown_content(block, parser:source())
        if content then
            local text = vim.treesitter.get_node_text(content, parser:source())
            for _, row in ipairs(text_delimiter_rows(text)) do
                table.insert(rows, content:start() + row)
            end
        end
    end
    return rows
end

--- Last row in `first`..`last` that is not in `rows`.
--- @param rows integer[]
--- @param first integer
--- @param last integer inclusive
--- @return integer row `first - 1` when every row is in `rows`
local function last_row_outside(rows, first, last)
    --- @type table<integer, true>
    local set = {}
    for _, row in ipairs(rows) do
        set[row] = true
    end
    while last >= first and set[last] do
        last = last - 1
    end
    return last
end

--- Last row in `first`..`last` that `FenceRows` does not hide: not a fence
--- delimiter row of the root tree of `parser`, nor of a markdown body there.
--- @param parser vim.treesitter.LanguageTree A parsed markdown-grammar tree
--- @param first integer 0-indexed
--- @param last integer 0-indexed, inclusive
--- @return integer row 0-indexed, `first - 1` when every row is a delimiter
function FenceRows.last_drawn_row(parser, first, last)
    return last_row_outside(delimiter_rows(parser, first, last), first, last)
end

--- Number of rows of a markdown fence body from its first row through its
--- last row that `FenceRows` does not hide.
--- @param rows string[]
--- @return integer count
function FenceRows.drawn_count(rows)
    -- As the body's `code_fence_content` text reads, which ends in a newline.
    local text = table.concat(rows, "\n") .. "\n"
    return last_row_outside(text_delimiter_rows(text), 0, #rows - 1) + 1
end

--- Watch `bufnr`. The first `sync` marks the whole buffer.
--- @param bufnr integer
--- @return agentic.ui.FenceRows
function FenceRows:new(bufnr)
    local dirty = DirtyRows.watch(bufnr)
    dirty:mark_all()
    return setmetatable({ _bufnr = bufnr, _dirty = dirty }, self)
end

--- Bring the marks up to date with the rows changed since the last `sync`.
--- Parses the buffer. A no-op when the buffer is invalid or has no parser.
function FenceRows:sync()
    if not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end
    local spans = self._dirty:take()
    if not spans then
        return
    end
    -- `take` parsed it.
    local parser = assert(vim.treesitter.get_parser(self._bufnr))

    -- Widened to the fenced blocks each span meets: an edit inside a block
    -- can change which body rows outside it are nested delimiters, while the
    -- root tree sees only content there and reports no change.
    local widened = vim.tbl_map(function(span)
        local first, last = span[1], span[2]
        for _, block in ipairs(blocks_in(parser, first, last)) do
            first = math.min(first, (block:start()))
            last = math.max(last, Treesitter.last_row(block))
        end
        return { first, last }
    end, spans)
    for _, span in ipairs(Intervals.union(widened)) do
        vim.api.nvim_buf_clear_namespace(
            self._bufnr,
            FenceRows.NS,
            span[1],
            span[2] + 1
        )
        for _, row in ipairs(delimiter_rows(parser, span[1], span[2])) do
            vim.api.nvim_buf_set_extmark(
                self._bufnr,
                FenceRows.NS,
                row,
                0,
                { conceal_lines = "" }
            )
        end
    end
end

--- Whether `row` carries a mark, after a `sync`.
--- @param row integer 0-indexed
--- @return boolean
function FenceRows:marked(row)
    self:sync()
    return #vim.api.nvim_buf_get_extmarks(
        self._bufnr,
        FenceRows.NS,
        { row, 0 },
        { row, -1 },
        { limit = 1 }
    ) > 0
end

--- Make the next `sync` mark the whole buffer again, as needed after `NS`
--- was cleared outside `sync`.
function FenceRows:invalidate()
    self._dirty:mark_all()
end

return FenceRows

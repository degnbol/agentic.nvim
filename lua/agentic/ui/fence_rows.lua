local DirtyRows = require("agentic.utils.dirty_rows")
local Intervals = require("agentic.utils.intervals")
local ToolCallLayout = require("agentic.ui.tool_call_layout")
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
    local word = vim.treesitter.get_node_text(lang, source)
    if
        Treesitter.resolve_lang(ToolCallLayout.base_lang(word)) ~= "markdown"
    then
        return nil
    end
    return content
end

--- 0-indexed rows of the fence delimiters in rows `first`..`last` of the root
--- tree of `parser`, and of the delimiters in each markdown body there.
--- @param parser vim.treesitter.LanguageTree A parsed markdown-grammar tree
--- @param first integer 0-indexed
--- @param last integer 0-indexed, inclusive
--- @return integer[]
local function delimiter_rows(parser, first, last)
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
            local body = vim.treesitter.get_string_parser(text, "markdown")
            local body_last = select(3, body:parse()[1]:root():range())
            for _, row in ipairs(delimiter_rows(body, 0, body_last)) do
                table.insert(rows, content:start() + row)
            end
        end
    end
    return rows
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
            first = math.min(first, block:start())
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

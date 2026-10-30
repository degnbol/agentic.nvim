local TextWrap = require("agentic.utils.text_wrap")

--- Fold levels and fold text for the chat buffer.
---
--- The chat window folds with this module's `foldexpr`, not
--- `vim.treesitter.foldexpr()`. Core's version folds *every* tree in the buffer
--- (`parser:for_each_tree`), so each injected language contributes its own
--- `folds.scm`: zsh's `heredoc_redirect` / `if_statement` / `for_statement`
--- inside an execute block's command fence, lua's `arguments` inside a code
--- fence. Those are noise in a transcript, and in a streamed buffer they are
--- also unbounded — core caches one fold level per line and only ever
--- recomputes the edited range, seeding it from the cached level above, so a
--- level stamped while an injected tree was stale stays baked into every line
--- below it for the rest of the session. That is how a heredoc's fold ends up
--- swallowing the rest of the transcript.
---
--- The injected trees exist here regardless — `MessageWriter`'s
--- `materialize_injections` creates them on every content write. What excludes
--- them is iterating `parser:parse()`'s return value, which is this
--- LanguageTree's own trees only (`LanguageTree:trees()` — "Does not include
--- child languages"). Core reaches the children because `_fold.lua` walks
--- `parser:for_each_tree` instead.
---
--- So folds here come only from `queries/agentic/folds.scm` — one per
--- writer-marked `*-fold` / `-difffold` body (a `*-fold` body runs on
--- through a `console` body right after it), and the writer always appends a body with both its fences
--- in a single `nvim_buf_set_lines`, so such a fold is never transiently
--- unterminated. Levels are recomputed for the whole buffer whenever
--- `b:changedtick` moves, the caching strategy `:help fold-expr-slow`
--- prescribes — once per streamed chunk, inside redraw,
--- costing 0.75 ms at 2820 lines and 2.9 ms at 11280 (measured, linear in
--- buffer size, query walk dominating the parse). An incremental version is
--- possible here in a way it is not for core, because a row's level depends
--- only on which `code_fence_content` covers it, with no level to seed from
--- the row above; it would need `on_bytes` to track the lowest dirty row.
local M = {}

--- @class agentic.ui.Folds.Levels
--- @field tick integer `b:changedtick` the levels were computed at
--- @field levels string[] Foldexpr value per 1-indexed line
--- @field joined table<integer, true> 1-indexed first line of each fold that runs through a second fence (`@fold.end`)

--- @type table<integer, agentic.ui.Folds.Levels>
local cache = {}

--- 1-indexed last row a node covers.
--- @param range Range6
--- @return integer
local function last_row(range)
    -- An end column of 0 means the node stops before the first byte of that
    -- row, so the row is not part of it.
    return range[5] == 0 and range[4] or range[4] + 1
end

--- Foldexpr value for every line of a buffer, from its `folds` query over the
--- root tree only — injected languages contribute nothing. A match folds
--- from the start of its `@fold` capture to the end of its `@fold.end`
--- capture when that fence opens on the row after `@fold`'s fence closes,
--- else to the end of `@fold`.
--- @param bufnr integer
--- @return string[] levels `">1"` on a fold's first line, `"1"` on its remaining lines, `"0"` outside any fold; indexed by 1-indexed line number
--- @return table<integer, true> joined 1-indexed first line of each fold that ends at a `@fold.end` capture
function M.levels(bufnr)
    local levels = {}
    for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
        levels[lnum] = "0"
    end
    --- @type table<integer, true>
    local joined = {}

    local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
    if not parser then
        return levels, joined
    end
    local query = vim.treesitter.query.get(parser:lang(), "folds")
    if not query then
        return levels, joined
    end

    for _, tree in pairs(parser:parse() or {}) do
        for _, match, metadata in query:iter_matches(tree:root(), bufnr, 0, -1) do
            --- @type table<string, Range6|nil>
            local ranges = {}
            for id, nodes in pairs(match) do
                ranges[query.captures[id]] =
                    vim.treesitter.get_range(nodes[1], bufnr, metadata[id])
            end
            local start, tail = ranges.fold, ranges["fold.end"]
            -- The `.` anchor skips blank lines, which form no node, so a
            -- second fence joins only when it opens on the row right after
            -- the first one closes.
            if start then
                if tail and tail[1] ~= last_row(start) + 2 then
                    tail = nil
                end
                local first = start[1] + 1
                local last = last_row(tail or start)
                -- Vim cannot close a one-line fold at 'foldminlines' = 1,
                -- which `chat_win_opts` pins for exactly this reason.
                -- Every fold is level 1: a joined match's range contains
                -- the one-fence match of its first fence, and folds.scm
                -- must stay otherwise non-nesting (its top comment says so).
                if last > first then
                    levels[first] = ">1"
                    for lnum = first + 1, last do
                        levels[lnum] = "1"
                    end
                    if tail then
                        joined[first] = true
                    end
                end
            end
        end
    end

    return levels, joined
end

--- 'foldexpr' for the chat buffer. See the module docstring for why the levels
--- are ours rather than `vim.treesitter.foldexpr()`'s.
--- @return string level Foldexpr value for `v:lnum`
function M.foldexpr()
    local bufnr = vim.api.nvim_get_current_buf()
    local cached = cache[bufnr]
    if not cached then
        -- A level array is one entry per buffer line; release it with the
        -- buffer rather than waiting for some later buffer to sweep it. Core
        -- caches its own fold levels the same way (`_fold.lua`).
        vim.api.nvim_create_autocmd("BufUnload", {
            buffer = bufnr,
            once = true,
            callback = function()
                cache[bufnr] = nil
            end,
        })
    end

    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    if not cached or cached.tick ~= tick then
        local levels, joined = M.levels(bufnr)
        cached = { tick = tick, levels = levels, joined = joined }
        cache[bufnr] = cached
    end

    return cached.levels[vim.v.lnum] or "0"
end

--- Namespace in which a writer marks a fold's opening fence row to have the
--- foldtext count the body's characters.
M.NS_CHAR_COUNT = vim.api.nvim_create_namespace("agentic_fold_char_count")

--- Whether a 0-indexed row carries a mark in `NS_CHAR_COUNT`.
--- @param bufnr integer
--- @param row integer
--- @return boolean
local function counts_chars(bufnr, row)
    local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        M.NS_CHAR_COUNT,
        { row, 0 },
        { row, -1 },
        { limit = 1 }
    )
    return #marks > 0
end

--- The name a fold's opening fence gives its content, or nil when it gives
--- none.
--- @param bufnr integer
--- @param fold_start integer 1-indexed first row of the fold
--- @return string|nil
local function fence_source(bufnr, fold_start)
    -- The fold spans `code_fence_content`, so the row above it is always the
    -- opening fence; the writer puts the name in its info string, after the
    -- language (`MessageWriter:_write_collapsed_region`).
    local fence = vim.api.nvim_buf_get_lines(
        bufnr,
        fold_start - 2,
        fold_start - 1,
        false
    )[1]
    return fence and fence:match("^`+%S*fold%s+(%S+)%s*$")
end

local FOLDTEXT_LEAD, FOLDTEXT_TAIL = "    ··· ", " ···"

--- 'foldtext' for the chat buffer: a line-count summary styled as Comment. A
--- fold spans `code_fence_content` nodes, so its line count is the rows of
--- content `zo` shows: a joined fold (`M.levels`) leaves out the two fence
--- rows between its fences.
---
--- A named body leads with its name — one hook block's summary is otherwise
--- indistinguishable from the next. A joined fold leads with its first row,
--- cut so the fold text fits the window's text width: a closed execute block
--- shows which command ran. A fold whose opening fence row is marked in
--- `NS_CHAR_COUNT` adds the body's character count. All figures are read back
--- out of the folded rows rather than recorded at write time, so they describe
--- what `zo` will actually show.
--- @return {[1]: string, [2]: string}[] chunks
function M.foldtext()
    local bufnr = vim.api.nvim_get_current_buf()
    local first, last = vim.v.foldstart, vim.v.foldend
    local cached = cache[bufnr]
    local joined = cached ~= nil and cached.joined[first] == true
    local summary =
        string.format("%d lines", last - first + 1 - (joined and 2 or 0))

    local source = fence_source(bufnr, first)
    if joined then
        local row = vim.trim(
            vim.api.nvim_buf_get_lines(bufnr, first - 1, first, false)[1]
        )
        local frame = vim.fn.strdisplaywidth(
            FOLDTEXT_LEAD .. " · " .. summary .. FOLDTEXT_TAIL
        )
        local winid = vim.api.nvim_get_current_win()
        local text_width = vim.api.nvim_win_get_width(winid)
            - vim.fn.getwininfo(winid)[1].textoff
        summary = TextWrap.truncate_to_width(row, text_width - frame)
            .. " · "
            .. summary
    elseif source then
        summary = source .. " · " .. summary
    end

    -- `first` is 1-indexed, so the 0-indexed fence row above it is first - 2.
    if counts_chars(bufnr, first - 2) then
        local body = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
        -- strchars, not `#`: thought text is full of dashes, middots and
        -- box-drawing, whose byte counts overstate it by a third.
        local chars = vim.fn.strchars(table.concat(body, "\n"))
        summary = summary
            .. " · "
            .. TextWrap.abbreviate_count(chars)
            .. " chars"
    end

    return { { FOLDTEXT_LEAD .. summary .. FOLDTEXT_TAIL, "Comment" } }
end

return M

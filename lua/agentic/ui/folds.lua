local Glyphs = require("agentic.glyphs")
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
--- writer-marked `*-fold` / `-difffold` body, and the writer always appends a
--- body with both its fences in a single `nvim_buf_set_lines`, so such a fold
--- is never transiently unterminated. Levels are recomputed for the whole
--- buffer whenever `b:changedtick` moves, the caching strategy
--- `:help fold-expr-slow` prescribes — once per streamed chunk, inside redraw,
--- costing 0.75 ms at 2820 lines and 2.9 ms at 11280 (measured, linear in
--- buffer size, query walk dominating the parse). An incremental version is
--- possible here in a way it is not for core, because a row's level depends
--- only on which `code_fence_content` covers it, with no level to seed from
--- the row above; it would need `on_bytes` to track the lowest dirty row.
local M = {}

--- @class agentic.ui.Folds.Levels
--- @field tick integer `b:changedtick` the levels were computed at
--- @field levels string[] Foldexpr value per 1-indexed line

--- @type table<integer, agentic.ui.Folds.Levels>
local cache = {}

--- Foldexpr value for every line of a buffer, from its `folds` query over the
--- root tree only — injected languages contribute nothing.
--- @param bufnr integer
--- @return string[] levels `">1"` on a fold's first line, `"1"` on its remaining lines, `"0"` outside any fold; indexed by 1-indexed line number
function M.levels(bufnr)
    local levels = {}
    for lnum = 1, vim.api.nvim_buf_line_count(bufnr) do
        levels[lnum] = "0"
    end

    local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
    if not parser then
        return levels
    end
    local query = vim.treesitter.query.get(parser:lang(), "folds")
    if not query then
        return levels
    end

    for _, tree in pairs(parser:parse() or {}) do
        for _, match, metadata in query:iter_matches(tree:root(), bufnr, 0, -1) do
            for id, nodes in pairs(match) do
                if query.captures[id] == "fold" then
                    local range =
                        vim.treesitter.get_range(nodes[1], bufnr, metadata[id])
                    local first = range[1] + 1
                    -- An end column of 0 means the node stops before the first
                    -- byte of that row, so the row is not part of the fold.
                    local last = range[5] == 0 and range[4] or range[4] + 1
                    -- Vim cannot close a one-line fold at 'foldminlines' = 1,
                    -- which `chat_win_opts` pins for exactly this reason.
                    -- Every match is level 1: `code_fence_content` cannot
                    -- nest, and folds.scm must stay non-nesting to keep that
                    -- true (its top comment says so).
                    if last > first then
                        levels[first] = ">1"
                        for lnum = first + 1, last do
                            levels[lnum] = "1"
                        end
                    end
                end
            end
        end
    end

    return levels
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
        cached = { tick = tick, levels = M.levels(bufnr) }
        cache[bufnr] = cached
    end

    return cached.levels[vim.v.lnum] or "0"
end

--- The sign stamped on `row`, or nil when the row carries none.
---
--- Read across every namespace: a fold's summary is keyed on what the region
--- *is*, which the chat buffer states in the sign column and nowhere else, and
--- the writers that place those signs are not otherwise this module's business.
--- `type = "sign"` is not just the cheaper query (10× over an unfiltered one on
--- a row of ANSI highlights, and this runs per closed fold per redraw) — it is
--- also what makes the row unambiguous, a dim range starting at the same
--- `(row, 0)` being otherwise indistinguishable by anything but creation order.
--- @param bufnr integer
--- @param row integer 0-indexed buffer row
--- @return string|nil sign_text
local function sign_at(bufnr, row)
    local marks = vim.api.nvim_buf_get_extmarks(
        bufnr,
        -1,
        { row, 0 },
        { row, -1 },
        { details = true, type = "sign" }
    )
    for _, mark in ipairs(marks) do
        if mark[4].sign_text then
            return mark[4].sign_text
        end
    end
    return nil
end

--- 'foldtext' for the chat buffer: a line-count summary styled as Comment. The
--- fold spans the `code_fence_content` node (body only, delimiters excluded),
--- so foldend - foldstart + 1 is the body's line count.
---
--- A thought run adds the character count, because lines are a weak proxy for
--- how much thinking happened and no provider reports thinking tokens. Both
--- figures are read back out of the folded rows rather than recorded at write
--- time, so they describe what `zo` will actually show.
--- @return {[1]: string, [2]: string}[] chunks
function M.foldtext()
    local bufnr = vim.api.nvim_get_current_buf()
    local first, last = vim.v.foldstart, vim.v.foldend
    local summary = string.format("%d lines", last - first + 1)

    if sign_at(bufnr, first - 1) == Glyphs.THINKING_SIGN then
        local body = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
        -- strchars, not `#`: thought text is full of dashes, middots and
        -- box-drawing, whose byte counts overstate it by a third.
        local chars = vim.fn.strchars(table.concat(body, "\n"))
        summary = summary
            .. " · "
            .. TextWrap.abbreviate_count(chars)
            .. " chars"
    end

    return { { "    ··· " .. summary .. " ···", "Comment" } }
end

return M

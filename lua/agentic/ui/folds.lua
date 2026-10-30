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
--- writer-marked `*-fold` / `-difffold` body, and one from each `*-foldnext`
--- body through the `console` body right after it, which encloses that
--- body's own fold. The writer always appends a body with both its fences in a
--- single `nvim_buf_set_lines`, so such a fold is never transiently
--- unterminated.
---
--- Levels are kept per buffer and recomputed only where an edit can change
--- them. A row's level is the number of fold ranges covering it, with no level
--- seeded from the row above as core does, and folds nest only by containment
--- (a command fold around its output fold). Whether a fold exists also depends
--- on its opening fence row, whose info string the query reads; call a fold's
--- rows plus that row its footprint. Footprints nest or are disjoint, so after
--- an edit only these rows can change level:
---
--- 1. the rows the edit replaced (`on_bytes`),
--- 2. the rows whose root tree changed (`on_changedtree`), which reach far
---    from the edit when a fence opener is written before its closer,
--- 3. the rest of the outermost footprint around each of those, in its old and
---    its new extent.
---
--- Every other row keeps its level, shifted by the edit's line delta.
local M = {}

--- @class agentic.ui.Folds.State
--- @field levels string[] Foldexpr value per 1-indexed line
--- @field joined table<integer, true> 1-indexed first line of each fold that ends at a `@fold.end` capture
--- @field parser? vim.treesitter.LanguageTree Parser the callbacks are registered on
--- @field dirty_first? integer First 1-indexed row whose level is unknown
--- @field dirty_last? integer Last 1-indexed row whose level is unknown

-- Not a field of `M`: `v:lua.require(…).foldexpr()` converts the module to a
-- Vimscript dict on every call, and a parser in it fails the conversion.
--- @type table<integer, agentic.ui.Folds.State>
local states = {}

--- Fold state of `bufnr`, for tests.
--- @private
--- @param bufnr integer
--- @return agentic.ui.Folds.State|nil
function M._state(bufnr)
    return states[bufnr]
end

--- 1-indexed last row a node covers.
--- @param range Range6
--- @return integer
local function last_row(range)
    -- An end column of 0 means the node stops before the first byte of that
    -- row, so the row is not part of it.
    return range[5] == 0 and range[4] or range[4] + 1
end

--- Foldexpr value per line for fold ranges that are disjoint or nested: each
--- line's depth is the number of ranges covering it, with `">" .. depth` on
--- the first line of each range.
--- @param ranges [integer, integer][] 1-indexed first and last line of each range
--- @param line_count integer
--- @return string[] levels indexed by 1-indexed line number
function M.levels_of_ranges(ranges, line_count)
    --- @type integer[]
    local depths = {}
    --- @type table<integer, true>
    local starts = {}
    for lnum = 1, line_count do
        depths[lnum] = 0
    end
    for _, range in ipairs(ranges) do
        starts[range[1]] = true
        for lnum = range[1], range[2] do
            depths[lnum] = depths[lnum] + 1
        end
    end
    --- @type string[]
    local levels = {}
    for lnum = 1, line_count do
        levels[lnum] = (starts[lnum] and ">" or "") .. depths[lnum]
    end
    return levels
end

--- Fold ranges of every `folds` match whose footprint (the fold's rows and the
--- opening fence row above them) meets rows `first`..`last`, each over its
--- whole extent. Matches come from the root tree only, so injected languages
--- contribute nothing. A match folds from the start of its `@fold` capture to
--- the end of its `@fold.end` capture. A match with a `@fold.end` capture
--- forms no fold unless that fence opens on the row after `@fold`'s fence
--- closes.
--- @param bufnr integer
--- @param first integer 1-indexed first row
--- @param last integer 1-indexed last row, inclusive
--- @return [integer, integer][] ranges 1-indexed first and last line
--- @return table<integer, true> joined first line of each range that ends at a `@fold.end` capture
local function ranges_in(bufnr, first, last)
    --- @type [integer, integer][]
    local ranges = {}
    --- @type table<integer, true>
    local joined = {}

    local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
    local query = parser and vim.treesitter.query.get(parser:lang(), "folds")
    if not parser or not query then
        return ranges, joined
    end

    for _, tree in pairs(parser:parse() or {}) do
        -- The matches meeting the rows are a superset: a `-foldnext` match's
        -- root is the section holding it, so every match in that section
        -- comes back.
        for _, match, metadata in
            query:iter_matches(tree:root(), bufnr, first - 1, last)
        do
            --- @type table<string, Range6|nil>
            local captured = {}
            for id, nodes in pairs(match) do
                captured[query.captures[id]] =
                    vim.treesitter.get_range(nodes[1], bufnr, metadata[id])
            end
            local start = assert(
                captured.fold,
                "a folds.scm pattern lacks a @fold capture"
            )
            local tail = captured["fold.end"]
            -- The `.` anchor skips blank lines, which form no node, so a
            -- second fence joins only when it opens on the row right after
            -- the first one closes.
            local adjacent = not tail or tail[1] == last_row(start) + 2
            local fold_first = start[1] + 1
            local fold_last = last_row(tail or start)
            local meets = fold_first - 1 <= last and fold_last >= first
            -- Vim cannot close a one-line fold at 'foldminlines' = 1,
            -- which `chat_win_opts` pins for exactly this reason.
            if meets and adjacent and fold_last > fold_first then
                table.insert(ranges, { fold_first, fold_last })
                if tail then
                    joined[fold_first] = true
                end
            end
        end
    end

    return ranges, joined
end

--- Foldexpr value for every line of a buffer, from its `folds` query over the
--- root tree only.
--- @param bufnr integer
--- @return string[] levels foldexpr value per 1-indexed line number: the line's fold depth, prefixed `>` on a fold's first line
--- @return table<integer, true> joined 1-indexed first line of each fold that ends at a `@fold.end` capture
function M.levels(bufnr)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local ranges, joined = ranges_in(bufnr, 1, line_count)
    return M.levels_of_ranges(ranges, line_count), joined
end

--- Rows `first`..`last` widened to the footprints (a fold's rows and the
--- opening fence row above them) of the folds meeting them, and the fold
--- ranges meeting the widened rows.
--- @param bufnr integer
--- @param first integer 1-indexed first row
--- @param last integer 1-indexed last row, inclusive
--- @return integer span_first 1-indexed
--- @return integer span_last 1-indexed, inclusive
--- @return [integer, integer][] ranges 1-indexed first and last line
--- @return table<integer, true> joined first line of each range that ends at a `@fold.end` capture
local function fold_span(bufnr, first, last)
    local span_first, span_last = first, last
    for _, range in ipairs((ranges_in(bufnr, first, last))) do
        span_first = math.min(span_first, range[1] - 1)
        span_last = math.max(span_last, range[2])
    end
    -- Footprints nest or are disjoint, so this finds every range the widened
    -- rows need and widens nothing further.
    local ranges, joined = ranges_in(bufnr, span_first, span_last)
    return span_first, span_last, ranges, joined
end

--- Recompute the levels and `joined` entries of `state` over rows
--- `first`..`last`, widened to the footprints of the folds meeting them.
--- @param bufnr integer
--- @param state agentic.ui.Folds.State
--- @param first integer 1-indexed first row
--- @param last integer 1-indexed last row, inclusive
local function stamp(bufnr, state, first, last)
    local span_first, span_last, ranges, joined = fold_span(bufnr, first, last)
    local offset = span_first - 1
    --- @type [integer, integer][]
    local local_ranges = {}
    for i, range in ipairs(ranges) do
        local_ranges[i] = { range[1] - offset, range[2] - offset }
    end
    local levels = M.levels_of_ranges(local_ranges, span_last - offset)
    for row = span_first, span_last do
        state.levels[row] = levels[row - offset]
        state.joined[row] = joined[row]
    end
end

--- Widen the dirty range to include rows `first`..`last`.
--- @param state agentic.ui.Folds.State
--- @param first integer 1-indexed
--- @param last integer 1-indexed, inclusive
local function mark_dirty(state, first, last)
    state.dirty_first = math.min(state.dirty_first or first, first)
    state.dirty_last = math.max(state.dirty_last or last, last)
end

--- Make `state.levels` `line_count` rows long, new rows at `"0"`, and clamp
--- the dirty range to those rows.
--- @param state agentic.ui.Folds.State
--- @param line_count integer
local function fit(state, line_count)
    for row = #state.levels + 1, line_count do
        state.levels[row] = "0"
    end
    for row = #state.levels, line_count + 1, -1 do
        state.levels[row] = nil
    end
    if state.dirty_first then
        state.dirty_last = math.min(state.dirty_last, line_count)
        state.dirty_first = math.min(state.dirty_first, state.dirty_last)
    end
end

--- Apply one `on_bytes` edit: shift the levels, `joined` entries and dirty
--- range below the replaced rows by the edit's line delta, put `"0"` in the
--- new rows, drop the replaced rows' `joined` entries, and mark dirty every
--- row the new text touches, its end row included: a `set_text` changes part
--- of that row, and a `set_lines` ends at column 0 of the row after it.
--- @param bufnr integer
--- @param state agentic.ui.Folds.State
--- @param start_row integer `on_bytes` start row, 0-indexed
--- @param old_rows integer `on_bytes` old end row (offset from start row)
--- @param new_rows integer `on_bytes` new end row (offset from start row)
local function splice(bufnr, state, start_row, old_rows, new_rows)
    local levels = state.levels
    local count = #levels
    local delta = new_rows - old_rows
    -- 1-indexed first row below the replaced ones, before the edit.
    local below = start_row + old_rows + 1
    -- O(rows) per edit, small next to one query.
    if delta > 0 then
        for row = count, below, -1 do
            levels[row + delta] = levels[row]
        end
    elseif delta < 0 then
        for row = below, count do
            levels[row + delta] = levels[row]
        end
        for row = count + delta + 1, count do
            levels[row] = nil
        end
    end
    for row = start_row + 1, start_row + new_rows do
        levels[row] = "0"
    end

    --- @param row integer 1-indexed row before the edit
    --- @return integer row 1-indexed row after the edit
    local function moved(row)
        if row <= start_row then
            return row
        end
        return row >= below and row + delta or start_row + 1
    end
    --- @type table<integer, true>
    local joined = {}
    for row in pairs(state.joined) do
        if row <= start_row or row >= below then
            joined[moved(row)] = true
        end
    end
    state.joined = joined
    if state.dirty_first then
        state.dirty_first = moved(state.dirty_first)
        state.dirty_last = moved(state.dirty_last)
    end

    mark_dirty(state, start_row + 1, start_row + new_rows + 1)
    -- `on_bytes` reports an append with `start_row` one past the last line,
    -- and a delete of the only line leaves one line (measured), so the row
    -- arithmetic above can miss the line count.
    fit(state, vim.api.nvim_buf_line_count(bufnr))
end

--- From now on, mark each range of `parser`'s root tree that changes dirty in
--- `state`, for as long as `parser` is `state.parser`.
--- @param state agentic.ui.Folds.State
--- @param parser vim.treesitter.LanguageTree
local function watch(state, parser)
    parser:register_cbs({
        --- @param changes Range6[]
        on_changedtree = function(changes)
            -- Callbacks cannot be unregistered.
            if state.parser ~= parser then
                return
            end
            for _, range in ipairs(changes) do
                local first = range[1] + 1
                mark_dirty(state, first, math.max(first, last_row(range)))
            end
        end,
        -- Not recursive: a change in an injected tree changes no level.
    }, false)
end

--- State of `bufnr`, created on first use with the full levels and attached
--- to the buffer and its parser, or nil when the buffer has no parser.
--- @param bufnr integer
--- @return agentic.ui.Folds.State|nil
local function state_of(bufnr)
    local existing = states[bufnr]
    if existing then
        return existing
    end
    local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
    if not parser then
        return nil
    end

    local levels, joined = M.levels(bufnr)
    --- @type agentic.ui.Folds.State
    local state = { levels = levels, joined = joined, parser = parser }
    watch(state, parser)
    local attached = vim.api.nvim_buf_attach(bufnr, false, {
        on_bytes = function(
            _,
            buf,
            _,
            start_row,
            _,
            _,
            old_rows,
            _,
            _,
            new_rows
        )
            splice(buf, state, start_row, old_rows, new_rows)
        end,
        on_reload = function(_, buf)
            state.joined = {}
            local line_count = vim.api.nvim_buf_line_count(buf)
            fit(state, line_count)
            mark_dirty(state, 1, line_count)
        end,
        on_detach = function(_, buf)
            state.parser = nil
            states[buf] = nil
        end,
    })
    assert(attached, "cannot attach fold levels to buffer " .. bufnr)
    states[bufnr] = state
    return state
end

--- Recompute the levels and `joined` entries of `state` over its dirty rows,
--- widened to the outermost footprints around them before and after the
--- edits, and clear the dirty range. A parser other than `state.parser` is
--- watched instead and all levels are recomputed, so a parser replaced
--- without an edit takes effect at the next edit.
--- @param bufnr integer
--- @param state agentic.ui.Folds.State
local function refresh(bufnr, state)
    local parser = vim.treesitter.get_parser(bufnr, nil, { error = false })
    if not parser or parser ~= state.parser then
        state.parser = parser
        if parser then
            watch(state, parser)
        end
        state.levels, state.joined = M.levels(bufnr)
        state.dirty_first, state.dirty_last = nil, nil
        return
    end

    -- Fires `on_changedtree`, which widens the dirty range.
    parser:parse()
    local levels = state.levels
    local first, last = state.dirty_first, state.dirty_last
    assert(first and last, "no dirty rows to refresh")
    last = math.min(last, #levels)
    state.dirty_first, state.dirty_last = nil, nil
    -- Up from a row in a fold to its outermost fold's first row, then the
    -- fence row above that.
    if levels[first - 1] and levels[first - 1] ~= "0" then
        first = first - 1
        while first > 1 and levels[first] ~= ">1" do
            first = first - 1
        end
        first = math.max(first - 1, 1)
    end
    -- A last row that may be the fence of the fold below takes that fold,
    -- then down over the rest of the outermost fold.
    if levels[last + 1] == ">1" then
        last = last + 1
    end
    while
        levels[last + 1]
        and levels[last + 1] ~= "0"
        and levels[last + 1] ~= ">1"
    do
        last = last + 1
    end

    stamp(bufnr, state, first, last)
end

--- 'foldexpr' for the chat buffer. See the module docstring for why the levels
--- are ours rather than `vim.treesitter.foldexpr()`'s.
--- @return string level Foldexpr value for `v:lnum`
function M.foldexpr()
    local bufnr = vim.api.nvim_get_current_buf()
    local state = state_of(bufnr)
    if not state then
        return "0"
    end
    if state.dirty_first then
        refresh(bufnr, state)
    end
    return state.levels[vim.v.lnum] or "0"
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
    local state = states[bufnr]
    local joined = state ~= nil and state.joined[first] == true
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

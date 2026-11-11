local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local PromptBlocks = require("agentic.utils.prompt_blocks")
local PromptInput = require("agentic.ui.prompt_input")
local Theme = require("agentic.theme")

--- Highlight namespace for queued input regions.
local NS_QUEUED = vim.api.nvim_create_namespace("agentic_queued_region")

--- Submit, partial send and the queue of one input buffer.
--- @class agentic.ui.InputDispatch
--- @field on_submit fun(prompt: string, opts: agentic.SessionManager.SubmitOpts): boolean false: deferred, so the range is tagged
--- @field _bufnr integer
--- @field _on_sent fun() Runs after a submit dispatches
--- @field _draining? boolean guard so a dispatch's own buffer edits don't self-untag
local InputDispatch = {}
InputDispatch.__index = InputDispatch

--- @type table<integer, agentic.ui.InputDispatch> input bufnr -> dispatch
local _dispatches = {}

--- @class agentic.ui.InputDispatch.SendDeleteRange
--- @field sr integer 0-indexed start row
--- @field sc integer 0-indexed start column (byte)
--- @field er integer 0-indexed end row
--- @field ec integer 0-indexed end column (byte, exclusive)
--- @field mode "line"|"char"

--- @class agentic.ui.InputDispatch.SendOpts
--- @field text string
--- @field delete_range agentic.ui.InputDispatch.SendDeleteRange

--- @class agentic.ui.InputDispatch.SubmitOpts
--- @field send? agentic.ui.InputDispatch.SendOpts Slice to submit; the whole input buffer when absent

--- A linewise or charwise region of a buffer.
--- @class agentic.ui.InputDispatch.Span
--- @field sr integer 0-indexed start row
--- @field sc integer 0-indexed start byte column; 0 for a line span
--- @field er integer 0-indexed end row
--- @field ec_incl integer 0-indexed byte column of the last char, inclusive, not clamped; 0 for a line span
--- @field mode "line"|"char"

--- Make the dispatch of an input buffer, for its send and queue operators,
--- and drop the tag of a queued region when insert mode starts on one of its
--- lines. Edits drop tags too once `attach_untag` runs, so a tag that
--- survives covers unedited text.
---
--- The autocmds and the operator registration survive `:bd`. Call once per
--- buffer.
--- @param bufnr integer
--- @param on_submit fun(prompt: string, opts: agentic.SessionManager.SubmitOpts): boolean
--- @param on_sent fun()
--- @return agentic.ui.InputDispatch
function InputDispatch:new(bufnr, on_submit, on_sent)
    self = setmetatable({
        on_submit = on_submit,
        _bufnr = bufnr,
        _on_sent = on_sent,
    }, self)

    _dispatches[bufnr] = self
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        once = true,
        callback = function(ev)
            _dispatches[ev.buf] = nil
        end,
    })

    -- No bytes change yet, but the user is about to edit the region.
    vim.api.nvim_create_autocmd("InsertEnter", {
        buffer = bufnr,
        callback = function()
            local row = vim.api.nvim_win_get_cursor(0)[1] - 1
            self:_clear_queued_in_range(row, row)
        end,
    })

    return self
end

--- Drop the tag of each queued region that a buffer edit, in any mode,
--- intersects. An unload detaches this, so call on each buffer load.
function InputDispatch:attach_untag()
    vim.api.nvim_buf_attach(self._bufnr, false, {
        on_bytes = function(_, _, _, start_row, _, _, old_end_row)
            if self._draining then
                return
            end
            -- textlock permits extmark get/del inside on_bytes (metadata, not
            -- buffer content); do not mutate buffer text here.
            self:_clear_queued_in_range(start_row, start_row + old_end_row)
        end,
    })
end

--- Copy sent text into `Config.settings.send_register` if configured.
--- @param text string What was dispatched, which is one block of the selection
--- @param mode "line"|"char"
local function copy_to_send_register(text, mode)
    local reg = Config.settings and Config.settings.send_register
    if type(reg) ~= "string" or reg == "" then
        return
    end
    vim.fn.setreg(reg, text, mode == "line" and "l" or "c")
end

--- The blocks a submit dispatches, with rows in buffer coordinates.
--- @param text string
--- @param range agentic.ui.InputDispatch.SendDeleteRange
--- @return agentic.utils.PromptBlocks.Block[]
local function submit_blocks(text, range)
    if range.mode == "char" then
        -- A charwise range dispatches whole: it can start and end mid-line, so
        -- its blocks would have no lines of their own to delete. Trimmed by the
        -- same rule as a block, or an indented `/word` would classify one way
        -- charwise and the other linewise.
        local trimmed = PromptBlocks.trim_lines(vim.split(text, "\n"))
        if trimmed == "" then
            return {}
        end
        return { { text = trimmed, sr = range.sr, er = range.er } }
    end
    local blocks = PromptBlocks.split(vim.split(text, "\n"))
    -- Rows come back relative to the lines that were split.
    for _, block in ipairs(blocks) do
        block.sr = block.sr + range.sr
        block.er = block.er + range.sr
    end
    return blocks
end

--- The whole input buffer as a line-mode slice.
--- @return agentic.ui.InputDispatch.SendOpts
function InputDispatch:_whole_input_send()
    local lines = vim.api.nvim_buf_get_lines(self._bufnr, 0, -1, false)
    --- @type agentic.ui.InputDispatch.SendOpts
    local send = {
        text = table.concat(lines, "\n"),
        delete_range = {
            sr = 0,
            sc = 0,
            er = math.max(0, #lines - 1),
            ec = 0,
            mode = "line",
        },
    }
    return send
end

--- Submit a prompt. With no `send`, submits the whole input buffer; with it,
--- submits that slice and saves it to the send register.
---
--- The submitted lines split into blocks (`PromptBlocks.split`) and only the
--- first one dispatches now; the rest stay in the buffer as a queued region
--- and drain one per turn, so buffer order is the whole record of the
--- sequence.
---
--- The session decides whether the first block goes now. If it defers, the
--- lines stay put and are tagged as a queued region instead of being deleted.
--- A charwise range widens to whole lines, since a tag is line-granular.
--- @param opts? agentic.ui.InputDispatch.SubmitOpts
function InputDispatch:submit(opts)
    opts = opts or {}
    vim.cmd("stopinsert")

    local send = opts.send or self:_whole_input_send()
    local range = send.delete_range

    local blocks = submit_blocks(send.text, range)
    local head = blocks[1]
    if not head then
        return
    end
    local next_block = blocks[2]

    -- Any tag on the head's own lines is superseded: they dispatch now, and
    -- the delete that follows suppresses untagging, so a mark left there would
    -- collapse onto whatever text moved into its place.
    self:_clear_queued_in_range(range.sr, head.er)

    -- The rest is tagged before the head dispatches, not after: dispatching it
    -- can ask for the next block on its way out, so the region has to be
    -- readable by then.
    if next_block then
        self:_queue_line_range(next_block.sr, range.er)
    end

    local dispatched = self.on_submit(head.text, { from_buffer = true })
    if not dispatched then
        self:_queue_line_range(range.sr, head.er)
        -- The text is held, not sent: it stays modified.
        BufHelpers.sync_modified(self._bufnr)
        return
    end

    if opts.send then
        copy_to_send_register(head.text, range.mode)
    end
    self:_delete_dispatched({
        sr = range.sr,
        sc = range.sc,
        -- Up to the next block, so the head's own blank lines go with it.
        er = next_block and next_block.sr - 1 or range.er,
        ec = range.ec,
        mode = range.mode,
    })

    self._on_sent()
end

--- Delete a range from the input buffer and sync 'modified'. A linewise
--- delete keeps the queued tags around the range.
--- @param range agentic.ui.InputDispatch.SendDeleteRange
function InputDispatch:_delete_dispatched(range)
    if range.mode == "line" then
        -- Even with no queued region in this submit: a plain line delete
        -- untags the region below that it abuts.
        self:_delete_dispatched_lines(range.sr, range.er)
        return
    end
    vim.api.nvim_buf_set_text(
        self._bufnr,
        range.sr,
        range.sc,
        range.er,
        range.ec,
        {}
    )
    BufHelpers.sync_modified(self._bufnr)
end

--- Clamp (sr, sc, er, ec) to a valid char-mode range for
--- `nvim_buf_get_text`, converting the end-inclusive `ec` to exclusive.
--- Handles `selection=exclusive` and clamps both endpoints to their line
--- lengths (covers INT_MAX sentinels from `'>` on empty/blank lines and
--- stale marks that sit past line end).
--- @param bufnr integer
--- @param sr integer
--- @param sc integer
--- @param er integer
--- @param ec integer
--- @return integer sc
--- @return integer ec_ex
--- @return boolean ok false if the range collapses to empty after clamping
local function clamp_char_range(bufnr, sr, sc, er, ec)
    local start_line = vim.api.nvim_buf_get_lines(bufnr, sr, sr + 1, false)[1]
        or ""
    local end_line = sr == er and start_line
        or vim.api.nvim_buf_get_lines(bufnr, er, er + 1, false)[1]
        or ""
    if sc > #start_line then
        sc = #start_line
    end
    local ec_ex = (vim.o.selection == "exclusive") and ec or (ec + 1)
    if ec_ex > #end_line then
        ec_ex = #end_line
    end
    local ok = sr < er or sc < ec_ex
    return sc, ec_ex, ok
end

--- `vim.v.count1` lines from the cursor, clamped to the buffer end.
--- @param bufnr integer
--- @return agentic.ui.InputDispatch.Span
local function cursor_span(bufnr)
    local sr = vim.api.nvim_win_get_cursor(0)[1] - 1
    local er =
        math.min(sr + vim.v.count1 - 1, vim.api.nvim_buf_line_count(bufnr) - 1)
    --- @type agentic.ui.InputDispatch.Span
    local span = { sr = sr, sc = 0, er = er, ec_incl = 0, mode = "line" }
    return span
end

--- The span of the last operator motion, from the `'[`/`']` marks.
--- @param bufnr integer
--- @param type "char"|"line"|"block"
--- @return agentic.ui.InputDispatch.Span|nil span Nil for a blockwise motion or unset marks
local function motion_span(bufnr, type)
    if type == "block" then
        Logger.debug("blockwise motion ignored")
        return nil
    end
    local start_mark = vim.api.nvim_buf_get_mark(bufnr, "[")
    local end_mark = vim.api.nvim_buf_get_mark(bufnr, "]")
    local sr = start_mark[1] - 1
    local er = end_mark[1] - 1
    if sr < 0 or er < 0 then
        return nil
    end
    --- @type agentic.ui.InputDispatch.Span
    local span = type == "line"
            and { sr = sr, sc = 0, er = er, ec_incl = 0, mode = "line" }
        or {
            sr = sr,
            sc = start_mark[2],
            er = er,
            ec_incl = end_mark[2],
            mode = "char",
        }
    return span
end

--- The live charwise or linewise visual selection, start before end.
--- @return agentic.ui.InputDispatch.Span|nil span Nil outside charwise and linewise visual mode
local function visual_span()
    local mode = vim.api.nvim_get_mode().mode
    if mode == "\22" then
        Logger.debug("blockwise visual ignored")
        return nil
    end
    if mode ~= "v" and mode ~= "V" then
        return nil
    end

    -- `'<`/`'>` marks only update when visual mode exits, so they are stale
    -- inside an x-mode mapping callback. `getpos("v")` returns the anchor
    -- (opposite end from cursor) and is live during visual mode.
    local anchor = vim.fn.getpos("v")
    local cursor = vim.fn.getpos(".")
    local anchor_r, anchor_c = anchor[2] - 1, anchor[3] - 1
    local cursor_r, cursor_c = cursor[2] - 1, cursor[3] - 1

    local sr, sc, er, ec
    if
        anchor_r < cursor_r
        or (anchor_r == cursor_r and anchor_c <= cursor_c)
    then
        sr, sc, er, ec = anchor_r, anchor_c, cursor_r, cursor_c
    else
        sr, sc, er, ec = cursor_r, cursor_c, anchor_r, anchor_c
    end

    --- @type agentic.ui.InputDispatch.Span
    local span = mode == "V"
            and { sr = sr, sc = 0, er = er, ec_incl = 0, mode = "line" }
        or { sr = sr, sc = sc, er = er, ec_incl = ec, mode = "char" }
    return span
end

--- The text and delete range of a span.
--- @param bufnr integer
--- @param span agentic.ui.InputDispatch.Span
--- @return agentic.ui.InputDispatch.SendOpts|nil send Nil when the span collapses or holds no printable text
local function send_opts(bufnr, span)
    local sr, er = span.sr, span.er
    --- @type string
    local text
    --- @type agentic.ui.InputDispatch.SendDeleteRange
    local delete_range
    if span.mode == "line" then
        local lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
        text = table.concat(lines, "\n")
        delete_range = { sr = sr, sc = 0, er = er, ec = 0, mode = "line" }
    else
        local sc, ec_ex, ok =
            clamp_char_range(bufnr, sr, span.sc, er, span.ec_incl)
        if not ok then
            return nil
        end
        local parts = vim.api.nvim_buf_get_text(bufnr, sr, sc, er, ec_ex, {})
        text = table.concat(parts, "\n")
        delete_range = { sr = sr, sc = sc, er = er, ec = ec_ex, mode = "char" }
    end
    if not text:match("%S") then
        return nil
    end
    --- @type agentic.ui.InputDispatch.SendOpts
    local send = { text = text, delete_range = delete_range }
    return send
end

--- Whether lines [sr, er] (0-indexed, inclusive) contain any printable content.
--- @param buf integer
--- @param sr integer
--- @param er integer
--- @return boolean
local function span_has_content(buf, sr, er)
    local lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
    return #lines > 0 and table.concat(lines, "\n"):match("%S") ~= nil
end

--- Send `vim.v.count1` lines from the cursor.
function InputDispatch:_send_line()
    local send = send_opts(self._bufnr, cursor_span(self._bufnr))
    if send then
        self:submit({ send = send })
    end
end

--- Operatorfunc callback for partial-send. Called by neovim after `g@{motion}`.
--- @param type "char"|"line"|"block"
function InputDispatch:_send_operator(type)
    local span = motion_span(self._bufnr, type)
    local send = span and send_opts(self._bufnr, span)
    if send then
        self:submit({ send = send })
    end
end

--- Send the visual selection.
function InputDispatch:_send_visual()
    local span = visual_span()
    local send = span and send_opts(self._bufnr, span)
    if not send then
        return
    end
    -- Exit visual so the buffer mutation doesn't happen inside an active
    -- selection (which would otherwise trigger vim's own selection edit).
    vim.cmd("normal! \27")
    self:submit({ send = send })
end

--- Queue N lines (vim.v.count1) from the cursor. Always tags, so the binding's
--- meaning does not depend on whether a turn happens to be running.
function InputDispatch:_queue_line()
    local span = cursor_span(self._bufnr)
    if span_has_content(self._bufnr, span.sr, span.er) then
        self:_queue_line_range(span.sr, span.er)
    end
end

--- Operatorfunc callback for queueing (after `<S-CR>{motion}`). Queues the
--- full line(s) the motion covers.
--- @param type "char"|"line"|"block"
function InputDispatch:_queue_operator(type)
    local span = motion_span(self._bufnr, type)
    if span and span_has_content(self._bufnr, span.sr, span.er) then
        self:_queue_line_range(span.sr, span.er)
    end
end

--- Queue the selected line(s).
function InputDispatch:_queue_visual()
    local span = visual_span()
    if not span or not span_has_content(self._bufnr, span.sr, span.er) then
        return
    end
    vim.cmd("normal! \27")
    self:_queue_line_range(span.sr, span.er)
end

--- Delete every queued-region extmark whose line span intersects [sr, er]
--- (0-indexed, inclusive).
--- @param sr integer
--- @param er integer
function InputDispatch:_clear_queued_in_range(sr, er)
    local buf = self._bufnr
    local marks =
        vim.api.nvim_buf_get_extmarks(buf, NS_QUEUED, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
        if mark[2] <= er and sr <= mark[4].end_row then
            vim.api.nvim_buf_del_extmark(buf, NS_QUEUED, mark[1])
        end
    end
end

--- Tag lines [sr, er] (0-indexed, inclusive) as a queued region, leaving the
--- text in place. The extmark IS the region — its range stays accurate for
--- drain because any edit inside it drops the tag, so a still-tagged mark has
--- never been edited since tagging. Re-queueing over existing tags replaces
--- them, so regions never overlap.
--- @param sr integer
--- @param er integer
--- @return integer mark_id
function InputDispatch:_queue_line_range(sr, er)
    self:_clear_queued_in_range(sr, er)
    local buf = self._bufnr
    local last = vim.api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ""
    return vim.api.nvim_buf_set_extmark(buf, NS_QUEUED, sr, 0, {
        end_row = er,
        end_col = #last,
        hl_group = Theme.HL_GROUPS.QUEUED_REGION,
        hl_eol = true,
    })
end

--- Delete lines [sr, er] (0-indexed, inclusive) as dispatched, leaving the
--- queued tags around them alone. `on_bytes` cannot tell a dispatch's own
--- delete from a user edit inside a region, and the edit that consumes one
--- block abuts the region holding the next.
--- @param sr integer
--- @param er integer
function InputDispatch:_delete_dispatched_lines(sr, er)
    self._draining = true
    vim.api.nvim_buf_set_lines(self._bufnr, sr, er + 1, false, {})
    self._draining = false
    -- TextChanged waits for the input to be the current buffer.
    BufHelpers.sync_modified(self._bufnr)
end

--- The blocks a region's lines hold, with rows in buffer coordinates.
--- @param buf integer
--- @param sr integer
--- @param er integer
--- @return agentic.utils.PromptBlocks.Block[]
local function region_blocks(buf, sr, er)
    local blocks =
        PromptBlocks.split(vim.api.nvim_buf_get_lines(buf, sr, er + 1, false))
    for _, block in ipairs(blocks) do
        block.sr = block.sr + sr
        block.er = block.er + sr
    end
    return blocks
end

--- The queue's head: the first block of the topmost region that still holds
--- one, with that region's mark and span. Regions left with nothing but blank
--- lines are skipped, so one can never wedge the queue.
--- @param buf integer
--- @return { block: agentic.utils.PromptBlocks.Block, mark_id: integer, sr: integer, er: integer, last: boolean }|nil
local function queue_head(buf)
    -- get_extmarks returns marks in ascending position order, which is the
    -- dispatch order: top-to-bottom is priority.
    local marks =
        vim.api.nvim_buf_get_extmarks(buf, NS_QUEUED, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
        local sr = mark[2]
        local er = mark[4].end_row --[[@as integer]]
        local blocks = region_blocks(buf, sr, er)
        if blocks[1] then
            return {
                block = blocks[1],
                mark_id = mark[1],
                sr = sr,
                er = er,
                last = #blocks == 1,
            }
        end
    end
    return nil
end

--- The input buffer while it is valid, else nil.
--- @return integer|nil bufnr
function InputDispatch:_valid_buf()
    return vim.api.nvim_buf_is_valid(self._bufnr) and self._bufnr or nil
end

--- The next queued block in buffer order, or nil when nothing is queued. Reads
--- only, so a caller that decides not to dispatch leaves the region tagged and
--- visible. A wiped input holds no queue.
--- @return agentic.utils.PromptBlocks.Block|nil
function InputDispatch:next_queued_block()
    local buf = self:_valid_buf()
    local head = buf and queue_head(buf)
    return head and head.block or nil
end

--- How many blocks the queue still holds, across every region. A wiped input
--- holds no queue.
--- @return integer
function InputDispatch:queued_block_count()
    local buf = self:_valid_buf()
    if not buf then
        return 0
    end
    local count = 0
    local marks =
        vim.api.nvim_buf_get_extmarks(buf, NS_QUEUED, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
        local er = mark[4].end_row --[[@as integer]]
        count = count + #region_blocks(buf, mark[2], er)
    end
    return count
end

--- Delete the next queued block's lines from the input buffer and return the
--- block that was deleted, mirroring partial-send: a dispatched block leaves
--- the input buffer. Nil when nothing is queued.
---
--- The caller must dispatch what this returns rather than what
--- `next_queued_block` reported: the two calls read the queue independently,
--- and anything that runs between them (a modal prompt lets scheduled
--- callbacks and timers run) can move the head on.
---
--- Consuming a region's last block takes the whole region and its mark with
--- it. The mark has to go: a fully-consumed region collapses to zero width at
--- the deletion point, and the next read would take the untagged draft line
--- that followed it as a queued block.
--- @return agentic.utils.PromptBlocks.Block|nil
function InputDispatch:consume_queued_block()
    local buf = self:_valid_buf()
    if not buf then
        return nil
    end
    local head = queue_head(buf)
    if not head then
        return nil
    end
    if head.last then
        vim.api.nvim_buf_del_extmark(buf, NS_QUEUED, head.mark_id)
        self:_delete_dispatched_lines(head.sr, head.er)
    else
        -- Up to the block's end, so any blank lines above it go with it.
        self:_delete_dispatched_lines(head.sr, head.block.er)
    end
    return head.block
end

--- Add text to the input as a queued paragraph of its own, at the end unless
--- `first` is set. Leaves focus, mode, cursor and the other regions' tags
--- alone. Leading and trailing empty lines of the text are dropped.
--- @param text string
--- @param opts { first?: boolean }|nil first: put the paragraph above the first queued region, or at the top of the input when none is queued
--- @return integer|nil mark_id The region's tag, or nil when the text has no lines or the input is wiped
function InputDispatch:queue_paragraph(text, opts)
    local lines = vim.split(text, "\n", { trimempty = true })
    local buf = self:_valid_buf()
    if #lines == 0 or not buf then
        return nil
    end
    local row = vim.api.nvim_buf_line_count(buf)
    if opts and opts.first then
        local head = vim.api.nvim_buf_get_extmarks(
            buf,
            NS_QUEUED,
            0,
            -1,
            { limit = 1 }
        )[1]
        row = head and head[2] or 0
    end
    -- Lines inserted at a region's first row would untag it.
    self._draining = true
    local first_row = BufHelpers.insert_paragraph(buf, row, lines)
    self._draining = false
    BufHelpers.sync_modified(buf)
    return self:_queue_line_range(first_row, first_row + #lines - 1)
end

--- Add text to the top of the input as a draft paragraph (see
--- `BufHelpers.prepend_draft`), keeping the queued regions tagged.
--- @param text string
function InputDispatch:prepend_draft(text)
    local buf = self:_valid_buf()
    if not buf then
        return
    end
    -- Lines inserted at a region's first row would untag it.
    self._draining = true
    BufHelpers.prepend_draft(buf, text)
    self._draining = false
end

--- Delete the queued region `mark_id` tags if its lines are exactly `text`,
--- with the blank row that separates it from the paragraph above, or below
--- when it starts the input. No-op when the tag is gone (any edit to the
--- region removes it) or names other text.
--- @param mark_id integer
--- @param text string
function InputDispatch:delete_queued_region(mark_id, text)
    local buf = self:_valid_buf()
    if not buf then
        return
    end
    local mark = vim.api.nvim_buf_get_extmark_by_id(
        buf,
        NS_QUEUED,
        mark_id,
        { details = true }
    )
    if #mark == 0 then
        return
    end
    local sr, er = mark[1], mark[3].end_row --[[@as integer]]
    local lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
    if not vim.deep_equal(lines, vim.split(text, "\n")) then
        return
    end
    vim.api.nvim_buf_del_extmark(buf, NS_QUEUED, mark_id)
    local separator = sr > 0 and sr - 1 or er + 1
    local separator_line =
        vim.api.nvim_buf_get_lines(buf, separator, separator + 1, false)[1]
    if separator_line and not separator_line:match("%S") then
        sr, er = math.min(sr, separator), math.max(er, separator)
    end
    self:_delete_dispatched_lines(sr, er)
end

--- Drop every queued region, leaving the text as ordinary draft in place.
function InputDispatch:cancel_queue()
    local buf = self:_valid_buf()
    if buf then
        vim.api.nvim_buf_clear_namespace(buf, NS_QUEUED, 0, -1)
    end
end

--- Make an 'operatorfunc' target that runs `operate` on the current buffer's
--- dispatch, and does nothing in a buffer without one. 'operatorfunc' takes
--- only a named function, not a closure, so the target finds its dispatch
--- from the buffer `g@` ran in.
--- @param operate fun(dispatch: agentic.ui.InputDispatch, type: "char"|"line"|"block")
--- @return fun(type: "char"|"line"|"block")
local function operator_dispatch(operate)
    return function(type)
        local dispatch = _dispatches[vim.api.nvim_get_current_buf()]
        if dispatch then
            operate(dispatch, type)
        end
    end
end

InputDispatch._send_operator_dispatch =
    operator_dispatch(InputDispatch._send_operator)

InputDispatch._queue_operator_dispatch =
    operator_dispatch(InputDispatch._queue_operator)

--- The send and queue maps, keyed into `Config.keymaps.prompt`.
local BINDINGS = {
    {
        line_key = "send_line",
        operator_key = "send_operator",
        visual_key = "send_visual",
        line = InputDispatch._send_line,
        visual = InputDispatch._send_visual,
        operatorfunc = "v:lua.require'agentic.ui.input_dispatch'._send_operator_dispatch",
        line_desc = "Agentic: Send line",
        operator_desc = "Agentic: Send motion",
        visual_desc = "Agentic: Send visual",
    },
    {
        line_key = "queue_line",
        operator_key = "queue_operator",
        visual_key = "queue_visual",
        line = InputDispatch._queue_line,
        visual = InputDispatch._queue_visual,
        operatorfunc = "v:lua.require'agentic.ui.input_dispatch'._queue_operator_dispatch",
        line_desc = "Agentic: Queue line",
        operator_desc = "Agentic: Queue motion",
        visual_desc = "Agentic: Queue visual",
    },
}

--- Bind submit, the send and queue maps and `cancel_queue` on the input
--- buffer. `:bd` clears the maps, so call again after one.
function InputDispatch:bind()
    local bufnr = self._bufnr
    local keymaps = Config.keymaps.prompt

    PromptInput.bind_submit(bufnr, function()
        self:submit()
    end)

    for _, binding in ipairs(BINDINGS) do
        BufHelpers.multi_keymap_set(keymaps[binding.line_key], bufnr, function()
            binding.line(self)
        end, { desc = binding.line_desc })

        BufHelpers.multi_keymap_set(
            keymaps[binding.operator_key],
            bufnr,
            function()
                vim.o.operatorfunc = binding.operatorfunc
                return "g@"
            end,
            { desc = binding.operator_desc, expr = true, silent = true }
        )

        BufHelpers.multi_keymap_set(
            keymaps[binding.visual_key],
            bufnr,
            function()
                binding.visual(self)
            end,
            { desc = binding.visual_desc },
            "x"
        )
    end

    BufHelpers.multi_keymap_set(keymaps.cancel_queue, bufnr, function()
        self:cancel_queue()
    end, { desc = "Agentic: Cancel queue" })
end

return InputDispatch

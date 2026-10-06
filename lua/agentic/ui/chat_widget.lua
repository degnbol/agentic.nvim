local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local ChatBuffer = require("agentic.ui.chat_buffer")
local Logger = require("agentic.utils.logger")
local LspServer = require("agentic.completion.lsp_server")
local MessageWriter = require("agentic.ui.message_writer")
local PromptBlocks = require("agentic.utils.prompt_blocks")
local PromptInput = require("agentic.ui.prompt_input")
local TextWrap = require("agentic.utils.text_wrap")
local Theme = require("agentic.theme")
local WindowDecoration = require("agentic.ui.window_decoration")
local WidgetLayout = require("agentic.ui.widget_layout")

--- Highlight namespace for queued input regions. Extmarks are buffer-scoped,
--- so a module-level (global) namespace is fine (see multi-tabpage rules).
local NS_QUEUED = vim.api.nvim_create_namespace("agentic_queued_region")

--- @alias agentic.ui.ChatWidget.PanelNames "chat"|"todos"|"code"|"files"|"input"|"diagnostics"|"activity"|"subagent"|"message"

--- Runtime header parts with dynamic context
--- @class agentic.ui.ChatWidget.HeaderParts
--- @field title string Main header text
--- @field context? string Dynamic info (managed internally)
--- @field session_name? string Custom session name (set by /rename or first message)
--- @field trust? string Active /trust scope display (set by /trust)
--- @field badge? string Attention badge (e.g. "[idle]", "[?]")

--- @alias agentic.ui.ChatWidget.BufNrs table<agentic.ui.ChatWidget.PanelNames, integer>
--- @alias agentic.ui.ChatWidget.WinNrs table<agentic.ui.ChatWidget.PanelNames, integer|nil>

--- @alias agentic.ui.ChatWidget.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts>

--- A session's buffers: the chat, shown in any window, and the panels, which
--- attach below the chat's home window in `Config.windows.stack` order.
--- @class agentic.ui.ChatWidget
--- @field _owner_id integer `SessionManager.id` of the owning session
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs Panel windows
--- @field on_submit_input fun(prompt: string, opts?: agentic.SessionManager.SubmitOpts): boolean external callback for a submitted prompt; false means it was deferred and the range should be tagged
--- @field on_refresh? fun() external callback for manual refresh (reset stale state)
--- @field on_goto_bottom? fun(winid: integer) external callback that moves a window showing the chat or a transcript to its last line
--- @field _draining? boolean guard so drain's own buffer edits don't self-untag
--- @field _home_win? integer The window the panels attach to
--- @field _home_closed_autocmd? integer The WinClosed autocmd of `_home_win`
local ChatWidget = {}
ChatWidget.__index = ChatWidget

--- @type table<integer, agentic.ui.ChatWidget> input_bufnr -> widget
local _send_widgets = {}

--- Dispatch target for `operatorfunc`. Invoked via `v:lua` after `g@{motion}`
--- because `operatorfunc` is a string option that accepts only named Lua refs,
--- not closures. Resolves the widget from the current buffer — `operatorfunc`
--- runs with cursor still in the input buffer that invoked `g@`. Keying on
--- bufnr rather than a module-level singleton keeps concurrent widgets on
--- other tabpages from clobbering each other.
--- @param type "char"|"line"|"block"
function ChatWidget._send_operator_dispatch(type)
    local widget = _send_widgets[vim.api.nvim_get_current_buf()]
    if widget then
        widget:_send_operator(type)
    end
end

--- Dispatch target for the queue operator (`operatorfunc` after `<S-CR>{motion}`).
--- Same widget resolution as `_send_operator_dispatch`.
--- @param type "char"|"line"|"block"
function ChatWidget._queue_operator_dispatch(type)
    local widget = _send_widgets[vim.api.nvim_get_current_buf()]
    if widget then
        widget:_queue_operator(type)
    end
end

--- @param owner_id integer `SessionManager.id` of the session owning the widget
--- @param on_submit_input fun(prompt: string, opts: agentic.SessionManager.SubmitOpts|nil): boolean
function ChatWidget:new(owner_id, on_submit_input)
    self = setmetatable({}, self)

    self.win_nrs = {}

    self.on_submit_input = on_submit_input
    self._owner_id = owner_id

    self:_initialize()

    return self
end

--- The widget's `panel` window, while it shows that panel's buffer.
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @return integer|nil winid
function ChatWidget:panel_win(panel)
    return WidgetLayout.panel_win(self.win_nrs, self.buf_nrs, panel)
end

--- The home window while it is valid and shows the chat, else nil.
--- @return integer|nil winid
function ChatWidget:home_win()
    local winid = self._home_win
    if
        winid
        and vim.api.nvim_win_is_valid(winid)
        and vim.api.nvim_win_get_buf(winid) == self.buf_nrs.chat
    then
        return winid
    end
    return nil
end

--- Make `winid` home, closing the panels of a previous home, and sync the
--- content panels. When `winid` closes, its panels close and the home clears.
--- No-op for a floating window.
--- @param winid integer
function ChatWidget:_adopt_home(winid)
    -- A float has no column to stack panels in.
    if vim.api.nvim_win_get_config(winid).relative ~= "" then
        return
    end
    if self._home_win ~= winid then
        self:close_panels()
        self._home_win = winid
        if self._home_closed_autocmd then
            pcall(vim.api.nvim_del_autocmd, self._home_closed_autocmd)
        end
        self._home_closed_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
            pattern = tostring(winid),
            once = true,
            callback = function()
                self._home_closed_autocmd = nil
                -- WinClosed does not nest: a panel closed in here would not
                -- run its own WinClosed.
                vim.schedule(function()
                    self:_release_home(winid)
                end)
            end,
        })
    end
    self:sync_panels()
end

--- Close the panels and clear the home, while `winid` is the home.
--- @param winid integer
function ChatWidget:_release_home(winid)
    if self._home_win == winid then
        self:close_panels()
        self._home_win = nil
    end
end

--- Show the chat in `winid`, with its chat window options and follow mode,
--- make `winid` home unless it floats, closing the panels of a previous home,
--- and sync the content panels. Deletes the buffer the chat replaces when it
--- is blank and unnamed (`BufHelpers.is_blank_unnamed`) and no other window
--- shows it. Notifies when the window refuses the buffer (`'winfixbuf'`).
--- @param winid integer
function ChatWidget:show_in(winid)
    local replaced = vim.api.nvim_win_get_buf(winid)
    -- With autocmds: the chat's BufWinEnter sets its window options and
    -- follow mode.
    local ok, err =
        pcall(vim.api.nvim_win_set_buf, winid, self.buf_nrs.chat)
    if not ok then
        Logger.notify(
            "Cannot show the chat here: " .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic" }
        )
        return
    end
    if
        replaced ~= self.buf_nrs.chat
        and BufHelpers.is_blank_unnamed(replaced)
        and #vim.fn.win_findbuf(replaced) == 0
    then
        vim.api.nvim_buf_delete(replaced, {})
    end
    self:_adopt_home(winid)
end

--- The home window when it is in the current tabpage, else a window there
--- showing the chat, the current one first, made home. Nil when the current
--- tabpage shows the chat in no window that can be home.
--- @return integer|nil winid
function ChatWidget:_home_in_tab()
    local tab = vim.api.nvim_get_current_tabpage()
    local home = self:home_win()
    if home and vim.api.nvim_win_get_tabpage(home) == tab then
        return home
    end
    --- @type integer[]
    local winids = { vim.api.nvim_get_current_win() }
    vim.list_extend(winids, vim.fn.win_findbuf(self.buf_nrs.chat))
    for _, winid in ipairs(winids) do
        if
            vim.api.nvim_win_get_buf(winid) == self.buf_nrs.chat
            and vim.api.nvim_win_get_tabpage(winid) == tab
        then
            self:_adopt_home(winid)
            if self:home_win() == winid then
                return winid
            end
        end
    end
    return nil
end

--- Focus a window in the current tabpage showing the chat, the home window
--- first. Without one, show the chat in the current window and make it home.
function ChatWidget:reveal()
    local tab = vim.api.nvim_get_current_tabpage()
    local home = self:home_win()
    --- @type integer[]
    local winids = home and { home } or {}
    vim.list_extend(winids, vim.fn.win_findbuf(self.buf_nrs.chat))
    for _, winid in ipairs(winids) do
        if vim.api.nvim_win_get_tabpage(winid) == tab then
            vim.api.nvim_set_current_win(winid)
            return
        end
    end
    self:show_in(vim.api.nvim_get_current_win())
end

--- Open or close each content panel (code, files, diagnostics, and todos
--- when `Config.windows.todos.display`) to match its buffer. No-op without a
--- home window.
function ChatWidget:sync_panels()
    local home = self:home_win()
    if not home then
        return
    end
    for _, panel in ipairs(Config.windows.stack) do
        local is_content = panel ~= "input" and panel ~= "activity"
        if
            is_content and (panel ~= "todos" or Config.windows.todos.display)
        then
            WidgetLayout.sync_panel(self.win_nrs, self.buf_nrs, home, panel)
        end
    end
end

--- Close the panel windows, keeping the buffers. Leaves insert mode when the
--- current window is one of them.
function ChatWidget:close_panels()
    local current = vim.api.nvim_get_current_win()
    if vim.list_contains(vim.tbl_values(self.win_nrs), current) then
        vim.cmd("stopinsert")
    end
    WidgetLayout.close(self.win_nrs, self.buf_nrs)
end

--- The panels with an open window.
--- @return agentic.ui.ChatWidget.StackPanel[]
function ChatWidget:_open_panels()
    return vim.tbl_filter(function(panel)
        return self:panel_win(panel) ~= nil
    end, Config.windows.stack)
end

--- Close the `panel` window.
--- @param panel agentic.ui.ChatWidget.StackPanel
function ChatWidget:close_panel(panel)
    WidgetLayout.close_panel(self.win_nrs, self.buf_nrs, panel)
end

--- Clears every panel buffer's content without destroying them, except
--- `input` — it holds the user's unsent draft, which is not conversation
--- state and must survive session resets/swaps.
---
--- Leaves the extmarks over the chat text, and a MessageWriter's
--- tool call trackers — those are the writer's, out of reach from here. Clear
--- the chat through `SessionManager:clear_chat`, which resets the writers too;
--- a tracker or mark outliving its text resolves to row 0 of whatever
--- replaces it.
---
--- Leaves each buffer's `modified` as it was: clearing the render loses
--- nothing that its owner has not accounted for.
function ChatWidget:clear()
    for name, bufnr in pairs(self.buf_nrs) do
        if name ~= "input" then
            local was_modified = vim.bo[bufnr].modified
            BufHelpers.with_modifiable(bufnr, function()
                local ok = pcall(
                    vim.api.nvim_buf_set_lines,
                    bufnr,
                    0,
                    -1,
                    false,
                    { "" }
                )
                if not ok then
                    Logger.debug(
                        string.format(
                            "Failed to clear buffer '%s' with id: %d",
                            name,
                            bufnr
                        )
                    )
                end
            end)
            vim.bo[bufnr].modified = was_modified
        end
    end
end

--- Wipes every buffer. This instance is no longer usable after calling this
--- method.
---
--- The chat is wiped on the next tick, so this can run from the chat's own
--- `BufDelete`, where wiping the chat raises E937.
function ChatWidget:destroy()
    if self._home_closed_autocmd then
        pcall(vim.api.nvim_del_autocmd, self._home_closed_autocmd)
        self._home_closed_autocmd = nil
    end
    self._home_win = nil
    local chat = self.buf_nrs.chat
    for name, bufnr in pairs(self.buf_nrs) do
        self.buf_nrs[name] = nil
        if bufnr ~= chat and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end

    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(chat) then
            vim.api.nvim_buf_delete(chat, { force = true })
        end
    end)
end

--- @class agentic.ui.ChatWidget.SendDeleteRange
--- @field sr integer 0-indexed start row
--- @field sc integer 0-indexed start column (byte)
--- @field er integer 0-indexed end row
--- @field ec integer 0-indexed end column (byte, exclusive)
--- @field mode "line"|"char"

--- @class agentic.ui.ChatWidget.SendOpts
--- @field text string
--- @field delete_range agentic.ui.ChatWidget.SendDeleteRange

--- @class agentic.ui.ChatWidget.SubmitOpts
--- @field send? agentic.ui.ChatWidget.SendOpts Slice to submit; the whole input buffer when absent
--- @field force? boolean Send now even if the session would defer the prompt

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

--- Delete a dispatched charwise range from the input buffer. Whole lines go
--- through `ChatWidget:_delete_dispatched_lines` instead, which keeps the
--- queued tags around them.
--- @param bufnr integer
--- @param range agentic.ui.ChatWidget.SendDeleteRange
local function delete_sent_chars(bufnr, range)
    vim.api.nvim_buf_set_text(bufnr, range.sr, range.sc, range.er, range.ec, {})
end

--- The blocks a submit dispatches, with rows in buffer coordinates.
--- @param text string
--- @param range agentic.ui.ChatWidget.SendDeleteRange
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

--- Submit a prompt. With no `text`, submits the whole input buffer; with it,
--- submits that slice and saves it to the send register. Single submit
--- entrypoint — the submit keymap and `:w` (BufWriteCmd) both funnel through
--- here.
---
--- The submitted lines split into blocks (`utils/prompt_blocks.lua`) and only
--- the first one dispatches now; the rest stay in the buffer as a queued
--- region and drain one per turn, so buffer order is the whole record of the
--- sequence. Prose-only text is a single block, which is every submit that
--- names no command.
---
--- The session decides whether the first block goes now. If it defers, the
--- lines stay put and are tagged as a queued region instead of being deleted.
--- A charwise range widens to whole lines, since a tag is line-granular.
--- @param opts? agentic.ui.ChatWidget.SubmitOpts
function ChatWidget:submit(opts)
    opts = opts or {}
    vim.cmd("stopinsert")

    --- @type string
    local text
    --- @type agentic.ui.ChatWidget.SendDeleteRange
    local range
    local send = opts.send
    if send then
        text = send.text
        range = send.delete_range
    else
        local lines =
            vim.api.nvim_buf_get_lines(self.buf_nrs.input, 0, -1, false)
        text = table.concat(lines, "\n")
        range = {
            sr = 0,
            sc = 0,
            er = math.max(0, #lines - 1),
            ec = 0,
            mode = "line",
        }
    end

    local blocks = submit_blocks(text, range)
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

    local dispatched = self.on_submit_input(
        head.text,
        { from_buffer = true, force = opts.force }
    )
    if not dispatched then
        self:_queue_line_range(range.sr, head.er)
        -- The text is held, not sent: it stays modified.
        BufHelpers.sync_modified(self.buf_nrs.input)
        return
    end

    if send then
        copy_to_send_register(head.text, range.mode)
    end
    if range.mode == "line" then
        -- Up to the next block, so the head's own blank lines go with it. Via
        -- the tag-preserving delete even when nothing follows in this submit:
        -- a plain line delete untags a region *below* it, which is how a
        -- partial-send above a queued one used to drop it to draft.
        self:_delete_dispatched_lines(
            range.sr,
            next_block and next_block.sr - 1 or range.er
        )
    else
        delete_sent_chars(self.buf_nrs.input, range)
    end
    BufHelpers.sync_modified(self.buf_nrs.input)

    if Config.settings.move_cursor_to_chat_on_submit then
        self:move_cursor_to("chat")
    end
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

function ChatWidget:_send_line()
    local count = vim.v.count1
    local cursor = vim.api.nvim_win_get_cursor(0)
    local sr = cursor[1] - 1
    local er = sr + count - 1
    local lines =
        vim.api.nvim_buf_get_lines(self.buf_nrs.input, sr, er + 1, false)
    if #lines == 0 then
        return
    end
    local text = table.concat(lines, "\n")
    if not text:match("%S") then
        return
    end
    self:submit({
        send = {
            text = text,
            delete_range = { sr = sr, sc = 0, er = er, ec = 0, mode = "line" },
        },
    })
end

--- Operatorfunc callback for partial-send. Called by neovim after `g@{motion}`.
--- @param type "char"|"line"|"block"
function ChatWidget:_send_operator(type)
    if type == "block" then
        Logger.debug("partial-send: blockwise motion ignored")
        return
    end
    local buf = self.buf_nrs.input
    local start_mark = vim.api.nvim_buf_get_mark(buf, "[")
    local end_mark = vim.api.nvim_buf_get_mark(buf, "]")
    local sr = start_mark[1] - 1
    local sc = start_mark[2]
    local er = end_mark[1] - 1
    local ec = end_mark[2]
    if sr < 0 or er < 0 then
        return
    end
    --- @type string
    local text
    --- @type agentic.ui.ChatWidget.SendDeleteRange
    local delete_range
    if type == "line" then
        local lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
        text = table.concat(lines, "\n")
        delete_range = { sr = sr, sc = 0, er = er, ec = 0, mode = "line" }
    else
        local sc_c, ec_ex, ok = clamp_char_range(buf, sr, sc, er, ec)
        if not ok then
            return
        end
        local parts = vim.api.nvim_buf_get_text(buf, sr, sc_c, er, ec_ex, {})
        text = table.concat(parts, "\n")
        delete_range =
            { sr = sr, sc = sc_c, er = er, ec = ec_ex, mode = "char" }
    end
    if not text:match("%S") then
        return
    end
    self:submit({ send = { text = text, delete_range = delete_range } })
end

function ChatWidget:_send_visual()
    -- `\'<`/`\'>` marks only update when visual mode exits, so they are stale
    -- inside an x-mode mapping callback. `getpos("v")` returns the anchor
    -- (opposite end from cursor) and is live during visual mode.
    local mode = vim.api.nvim_get_mode().mode
    if mode == "\22" then
        Logger.debug("partial-send: blockwise visual ignored")
        return
    end
    if mode ~= "v" and mode ~= "V" then
        return
    end

    local buf = self.buf_nrs.input
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

    --- @type string
    local text
    --- @type agentic.ui.ChatWidget.SendDeleteRange
    local delete_range
    if mode == "V" then
        local lines = vim.api.nvim_buf_get_lines(buf, sr, er + 1, false)
        text = table.concat(lines, "\n")
        delete_range = { sr = sr, sc = 0, er = er, ec = 0, mode = "line" }
    else
        local sc_c, ec_ex, ok = clamp_char_range(buf, sr, sc, er, ec)
        if not ok then
            return
        end
        local parts = vim.api.nvim_buf_get_text(buf, sr, sc_c, er, ec_ex, {})
        text = table.concat(parts, "\n")
        delete_range =
            { sr = sr, sc = sc_c, er = er, ec = ec_ex, mode = "char" }
    end
    if not text:match("%S") then
        return
    end

    -- Exit visual so the buffer mutation doesn't happen inside an active
    -- selection (which would otherwise trigger vim's own selection edit).
    vim.cmd("normal! \27")

    self:submit({ send = { text = text, delete_range = delete_range } })
end

--- Delete every queued-region extmark whose line span intersects [sr, er]
--- (0-indexed, inclusive).
--- @param sr integer
--- @param er integer
function ChatWidget:_clear_queued_in_range(sr, er)
    local buf = self.buf_nrs.input
    local marks =
        vim.api.nvim_buf_get_extmarks(buf, NS_QUEUED, 0, -1, { details = true })
    for _, mark in ipairs(marks) do
        if mark[2] <= er and sr <= mark[4].end_row then
            vim.api.nvim_buf_del_extmark(buf, NS_QUEUED, mark[1])
        end
    end
end

--- Tag lines [sr, er] (0-indexed, inclusive) as a queued region: a full-width
--- (hl_eol) background extmark that leaves the text in place. The extmark IS
--- the region — its range stays accurate for drain because any edit inside it
--- drops the tag (see _setup_queue), so a still-tagged mark has never been
--- edited since tagging. Re-queueing over existing tags replaces them, so
--- regions never overlap or double-highlight.
--- @param sr integer
--- @param er integer
function ChatWidget:_queue_line_range(sr, er)
    self:_clear_queued_in_range(sr, er)
    local buf = self.buf_nrs.input
    local last = vim.api.nvim_buf_get_lines(buf, er, er + 1, false)[1] or ""
    vim.api.nvim_buf_set_extmark(buf, NS_QUEUED, sr, 0, {
        end_row = er,
        end_col = #last,
        hl_group = Theme.HL_GROUPS.QUEUED_REGION,
        hl_eol = true,
    })
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

--- Queue N lines (vim.v.count1) from the cursor. Always tags, so the binding's
--- meaning does not depend on whether a turn happens to be running.
function ChatWidget:_queue_line()
    local buf = self.buf_nrs.input
    local sr = vim.api.nvim_win_get_cursor(0)[1] - 1
    local er =
        math.min(sr + vim.v.count1 - 1, vim.api.nvim_buf_line_count(buf) - 1)
    if span_has_content(buf, sr, er) then
        self:_queue_line_range(sr, er)
    end
end

--- Operatorfunc callback for queueing (after `<S-CR>{motion}`). Queues the
--- full line(s) the motion covers.
--- @param type "char"|"line"|"block"
function ChatWidget:_queue_operator(type)
    if type == "block" then
        Logger.debug("queue: blockwise motion ignored")
        return
    end
    local buf = self.buf_nrs.input
    local sr = vim.api.nvim_buf_get_mark(buf, "[")[1] - 1
    local er = vim.api.nvim_buf_get_mark(buf, "]")[1] - 1
    if sr < 0 or er < 0 then
        return
    end
    if span_has_content(buf, sr, er) then
        self:_queue_line_range(sr, er)
    end
end

--- Queue the selected line(s).
function ChatWidget:_queue_visual()
    local mode = vim.api.nvim_get_mode().mode
    if mode == "\22" then
        Logger.debug("queue: blockwise visual ignored")
        return
    end
    if mode ~= "v" and mode ~= "V" then
        return
    end
    local buf = self.buf_nrs.input
    local anchor = vim.fn.getpos("v")[2] - 1
    local cursor = vim.fn.getpos(".")[2] - 1
    local sr = math.min(anchor, cursor)
    local er = math.max(anchor, cursor)
    if not span_has_content(buf, sr, er) then
        return
    end
    vim.cmd("normal! \27")
    self:_queue_line_range(sr, er)
end

--- Delete lines [sr, er] (0-indexed, inclusive) as dispatched, leaving the
--- queued tags around them alone. `on_bytes` cannot tell a dispatch's own
--- delete from a user edit inside a region, and the edit that consumes one
--- block abuts the region holding the next.
--- @param sr integer
--- @param er integer
function ChatWidget:_delete_dispatched_lines(sr, er)
    self._draining = true
    vim.api.nvim_buf_set_lines(self.buf_nrs.input, sr, er + 1, false, {})
    self._draining = false
    -- TextChanged waits for the input to be the current buffer.
    BufHelpers.sync_modified(self.buf_nrs.input)
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

--- The next queued block in buffer order, or nil when nothing is queued. Reads
--- only, so a caller that decides not to dispatch leaves the region tagged and
--- visible.
--- @return agentic.utils.PromptBlocks.Block|nil
function ChatWidget:next_queued_block()
    local head = queue_head(self.buf_nrs.input)
    return head and head.block or nil
end

--- How many blocks the queue still holds, across every region.
--- @return integer
function ChatWidget:queued_block_count()
    local buf = self.buf_nrs.input
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
function ChatWidget:consume_queued_block()
    local buf = self.buf_nrs.input
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

--- Drop every queued region, leaving the text as ordinary draft in place.
function ChatWidget:cancel_queue()
    vim.api.nvim_buf_clear_namespace(self.buf_nrs.input, NS_QUEUED, 0, -1)
end

--- On the next tick, focus the `panel` window, the home window for the chat,
--- and, unless it is the chat, scroll it to the bottom, then run `callback`.
--- No-op when no window shows the panel then.
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @param callback fun()|nil
function ChatWidget:move_cursor_to(panel, callback)
    vim.schedule(function()
        local winid = panel == "chat" and self:home_win()
            or self:panel_win(panel)
        if winid then
            vim.api.nvim_set_current_win(winid)

            -- Follow owns the chat's view, which a held tool call may keep
            -- short of the bottom.
            if panel ~= "chat" then
                BufHelpers.scroll_down(winid, 0)
            end

            if callback then
                callback()
            end
        end
    end)
end

--- The window to type into: the input's window in the current tabpage, else
--- the input panel of the chat in the current tabpage (`_home_in_tab`), else a
--- split below the current window. Opens the window when there is none.
--- @return integer|nil winid Nil when the input panel fails to open
function ChatWidget:input_win()
    local input = self.buf_nrs.input
    local shown = vim.fn.bufwinid(input)
    if shown ~= -1 then
        return shown
    end
    local home = self:_home_in_tab()
    if home then
        return WidgetLayout.open_panel(
            self.win_nrs,
            self.buf_nrs,
            home,
            "input"
        )
    end
    return WidgetLayout.open_input_below(input)
end

--- Focus `input_win()` and start insert on the input's last character.
--- No-op when the input panel fails to open.
function ChatWidget:focus_input()
    local winid = self:input_win()
    if winid then
        vim.api.nvim_set_current_win(winid)
        BufHelpers.start_insert_on_last_char()
    end
end

--- Buffer-local autocmds on the chat that tie the home window to it: a
--- window the chat enters becomes home while there is none, a home that
--- shows another buffer loses its panels, and `:q` on the home closes its
--- panels first, so it quits as on a single window.
--- @param chat integer
function ChatWidget:_track_home(chat)
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = chat,
        callback = function()
            local winid = vim.api.nvim_get_current_win()
            if self:home_win() or vim.api.nvim_win_get_buf(winid) ~= chat then
                return
            end
            self:_adopt_home(winid)
        end,
    })

    vim.api.nvim_create_autocmd("BufLeave", {
        buffer = chat,
        callback = function()
            -- The window shows its new buffer once the leave is done.
            vim.schedule(function()
                local home = self._home_win
                if
                    home
                    and vim.api.nvim_win_is_valid(home)
                    and not self:home_win()
                then
                    self:_release_home(home)
                end
            end)
        end,
    })

    vim.api.nvim_create_autocmd("QuitPre", {
        buffer = chat,
        callback = function()
            local home = self:home_win()
            if vim.api.nvim_get_current_win() ~= home then
                return
            end
            local open_panels = self:_open_panels()
            self:close_panels()
            -- The home is still open when vim refused the quit (E37, E162).
            vim.schedule(function()
                if self:home_win() ~= home then
                    return
                end
                for _, panel in ipairs(open_panels) do
                    WidgetLayout.open_panel(
                        self.win_nrs,
                        self.buf_nrs,
                        home,
                        panel
                    )
                end
            end)
        end,
    })
end

function ChatWidget:_initialize()
    self.buf_nrs = self:_create_buf_nrs()

    self:_bind_keymaps()
    self:_setup_queue()
    self:_attach_input()
    self:_track_home(self.buf_nrs.chat)

    local input = self.buf_nrs.input
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = input,
        callback = function()
            BufHelpers.sync_modified(self.buf_nrs.input)
        end,
    })

    -- `:e!` discards the draft, which is what the bang means; the unload
    -- detached what `_attach_input` attached.
    vim.api.nvim_create_autocmd("BufReadCmd", {
        buffer = input,
        callback = function()
            self:_attach_input()
        end,
    })
end

--- Wire up [[ / ]] navigation between the rows recording a user action in the
--- chat buffer: prompts, and the notices confirming a local command. Those rows
--- are marked with extmarks in NS_USER_ACTIONS at write time (see
--- MessageWriter:write_user_prompt and :write_notice); each row's identity sign
--- rides on the same mark. Navigation reads the marks, so agent-authored `## `
--- headings are never treated as prompts.
--- @param chat_buf integer The chat buffer
function ChatWidget:_setup_prompt_navigation(chat_buf)
    --- Row of the nearest user-action marker relative to the cursor.
    --- @param forward boolean true = smallest row > cursor, false = greatest < cursor
    --- @return integer|nil row 0-indexed
    local function adjacent_prompt_row(forward)
        local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
        local marks = vim.api.nvim_buf_get_extmarks(
            chat_buf,
            MessageWriter.NS_USER_ACTIONS,
            0,
            -1,
            {}
        )
        local best
        for _, mark in ipairs(marks) do
            local row = mark[2]
            if forward then
                if row > cur and (not best or row < best) then
                    best = row
                end
            else
                if row < cur and (not best or row > best) then
                    best = row
                end
            end
        end
        return best
    end

    local function jump_prompt(forward)
        local row = adjacent_prompt_row(forward)
        if row then
            vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
        end
    end

    BufHelpers.multi_keymap_set(
        Config.keymaps.chat and Config.keymaps.chat.prev_prompt or "[[",
        chat_buf,
        function()
            jump_prompt(false)
        end,
        { desc = "Agentic: Previous prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.chat and Config.keymaps.chat.next_prompt or "]]",
        chat_buf,
        function()
            jump_prompt(true)
        end,
        { desc = "Agentic: Next prompt" }
    )
end

--- Jump the windows in the current tabpage showing the session's chat or a
--- transcript to their last line, through `on_goto_bottom`, without moving
--- focus.
--- @private
function ChatWidget:_goto_transcripts_bottom()
    if not self.on_goto_bottom then
        return
    end
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local panel = vim.b[bufnr].agentic_window
        if
            vim.b[bufnr].agentic_session_id == self._owner_id
            and (panel == "chat" or panel == "subagent")
        then
            self.on_goto_bottom(winid)
        end
    end
end

function ChatWidget:_bind_keymaps()
    for panel, bufnr in pairs(self.buf_nrs) do
        self:_bind_buf_keymaps(panel, bufnr)
    end
end

--- Bind the widget's buffer-local maps on one panel's buffer.
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @param bufnr integer
function ChatWidget:_bind_buf_keymaps(panel, bufnr)
    if panel == "input" then
        PromptInput.bind_submit(bufnr, function(opts)
            self:submit(opts)
        end)

        self:_bind_send_keymaps(bufnr)
        self:_bind_queue_keymaps(bufnr)

        BufHelpers.multi_keymap_set(
            Config.keymaps.prompt.paste_image,
            bufnr,
            function()
                vim.schedule(function()
                    local Clipboard = require("agentic.ui.clipboard")
                    local res = Clipboard.paste_image()

                    if res ~= nil then
                        -- call vim.paste directly to avoid coupling to the file list logic
                        vim.paste({ res }, -1)
                    end
                end)
            end,
            { desc = "Agentic: Paste image from clipboard" }
        )
    elseif panel == "chat" then
        self:_setup_prompt_navigation(bufnr)
    end

    if panel ~= "message" then
        self:_bind_canned_prompt_keymaps(bufnr)
    end

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.refresh,
        bufnr,
        function()
            if self.on_refresh then
                self.on_refresh()
            end
        end,
        { desc = "Agentic: Refresh chat (reset stale state)" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.toggle_follow,
        bufnr,
        function()
            Config.follow.enabled = not Config.follow.enabled
            Logger.notify(
                "Follow " .. (Config.follow.enabled and "enabled" or "disabled"),
                vim.log.levels.INFO,
                { title = "Agentic" }
            )
        end,
        { desc = "Agentic: Toggle follow" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.widget.goto_bottom,
        bufnr,
        function()
            self:_goto_transcripts_bottom()
        end,
        { desc = "Agentic: Scroll transcripts to bottom" }
    )

    -- A transcript's keys depend on its agent; its session binds them.
    if panel ~= "input" and panel ~= "message" and panel ~= "subagent" then
        self:_bind_insert_keymaps(bufnr)
    end
end

--- Bind each `Config.keymaps.prompts` entry on a buffer to send its prompt.
--- @param bufnr integer
function ChatWidget:_bind_canned_prompt_keymaps(bufnr)
    for lhs, spec in pairs(Config.keymaps.prompts) do
        local prompt
        if type(spec) == "string" then
            prompt = spec
        elseif type(spec) == "table" then
            prompt = spec.prompt
        end

        -- vim.NIL, nil, and "" all fall through to skip. is_keymap_disabled
        -- is unusable here: it reports `#{prompt=...} == 0` as disabled,
        -- silently dropping every table-form entry.
        if prompt and prompt ~= "" then
            local km = (type(spec) == "table" and spec.mode)
                    and { { lhs, mode = spec.mode } }
                or lhs
            local desc = (type(spec) == "table" and spec.desc)
                or ("Prompt: " .. prompt:gsub("%s+", " "):sub(1, 40))

            -- Send via this widget's own session (self.on_submit_input ==
            -- session:_handle_input_submit), not send_prompt: a buffer-local
            -- map only fires from a focused widget window, so the session
            -- already exists and is visible — avoids send_prompt's
            -- get_session_for_tab_page(nil, …) auto-spawn branch.
            BufHelpers.multi_keymap_set(km, bufnr, function()
                self.on_submit_input(prompt)
            end, { desc = desc })
        end
    end
end

--- Bind the insert keys and `p`/`P` on a read-only panel buffer to type and
--- paste into the input.
--- @param bufnr integer
function ChatWidget:_bind_insert_keymaps(bufnr)
    for _, key in ipairs(BufHelpers.INSERT_KEYS) do
        BufHelpers.keymap_set(bufnr, "n", key, function()
            self:focus_input()
        end)
    end

    for _, key in ipairs({ "p", "P" }) do
        BufHelpers.keymap_set(bufnr, "n", key, function()
            local input_win = self:input_win()
            if input_win then
                vim.api.nvim_set_current_win(input_win)
                vim.cmd("normal! " .. key)
            end
        end)
    end
end

--- @param bufnr integer The input buffer
function ChatWidget:_bind_send_keymaps(bufnr)
    local keymaps = Config.keymaps.prompt

    BufHelpers.multi_keymap_set(keymaps.send_line, bufnr, function()
        self:_send_line()
    end, { desc = "Agentic: Send line" })

    BufHelpers.multi_keymap_set(keymaps.send_operator, bufnr, function()
        vim.o.operatorfunc =
            "v:lua.require'agentic.ui.chat_widget'._send_operator_dispatch"
        return "g@"
    end, {
        desc = "Agentic: Send motion",
        expr = true,
        silent = true,
    })

    BufHelpers.multi_keymap_set(keymaps.send_visual, bufnr, function()
        self:_send_visual()
    end, { desc = "Agentic: Send visual" }, "x")
end

--- @param bufnr integer The input buffer
function ChatWidget:_bind_queue_keymaps(bufnr)
    local keymaps = Config.keymaps.prompt

    BufHelpers.multi_keymap_set(keymaps.queue_line, bufnr, function()
        self:_queue_line()
    end, { desc = "Agentic: Queue line" })

    BufHelpers.multi_keymap_set(keymaps.queue_operator, bufnr, function()
        vim.o.operatorfunc =
            "v:lua.require'agentic.ui.chat_widget'._queue_operator_dispatch"
        return "g@"
    end, {
        desc = "Agentic: Queue motion",
        expr = true,
        silent = true,
    })

    BufHelpers.multi_keymap_set(keymaps.queue_visual, bufnr, function()
        self:_queue_visual()
    end, { desc = "Agentic: Queue visual" }, "x")

    BufHelpers.multi_keymap_set(keymaps.cancel_queue, bufnr, function()
        self:cancel_queue()
    end, { desc = "Agentic: Cancel queue" })
end

--- Register the input buffer for operatorfunc dispatch (shared by send and
--- queue operators) and wire auto-unqueue: any edit intersecting a queued
--- region drops its tag, so a region can never be dispatched mid-edit and a
--- surviving tag's range is always pristine. Two triggers:
---   • on_bytes — catch-all for buffer changes in any mode, attached by
---     `_attach_input`.
---   • InsertEnter with cursor in a region — entering insert changes no bytes
---     yet, but the user is poised to edit, so the region is no longer committed.
function ChatWidget:_setup_queue()
    local buf = self.buf_nrs.input

    _send_widgets[buf] = self
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        once = true,
        callback = function(ev)
            _send_widgets[ev.buf] = nil
        end,
    })

    vim.api.nvim_create_autocmd("InsertEnter", {
        buffer = buf,
        callback = function()
            local row = vim.api.nvim_win_get_cursor(0)[1] - 1
            self:_clear_queued_in_range(row, row)
        end,
    })
end

--- Attach what a buffer load provides and an unload detaches: the markdown
--- parser, the queue's `on_bytes` tracker, and the completion LSP.
function ChatWidget:_attach_input()
    local buf = self.buf_nrs.input

    pcall(vim.treesitter.start, buf, "markdown")

    vim.api.nvim_buf_attach(buf, false, {
        on_bytes = function(_, _, _, start_row, _, _, old_end_row)
            if self._draining then
                return
            end
            -- textlock permits extmark get/del inside on_bytes (metadata, not
            -- buffer content); do not mutate buffer text here.
            self:_clear_queued_in_range(start_row, start_row + old_end_row)
        end,
    })

    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
            LspServer.attach(buf)
        end
    end)
end

--- A panel's buffer options, except `buflisted`, which only creation sets.
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @return table<string, any>
local function panel_buf_opts(panel)
    --- @type table<agentic.ui.ChatWidget.PanelNames, table<string, any>>
    local panel_opts = {
        -- `acwrite` so `modified` blocks `:qa` while the history is unsaved.
        chat = { filetype = "AgenticChat", buftype = "acwrite" },
        subagent = { filetype = "AgenticChat", buftype = "acwrite" },
        todos = { filetype = "AgenticTodos" },
        code = { filetype = "AgenticCode" },
        files = { filetype = "AgenticFiles" },
        diagnostics = { filetype = "AgenticDiagnostics" },
        activity = { filetype = "AgenticActivity" },
        -- `acwrite` makes `:w` submit, and an unsent prompt block `:qa`.
        input = {
            filetype = "AgenticInput",
            buftype = Config.settings.write_submit and "acwrite" or "nofile",
            modifiable = true,
        },
    }
    -- A subagent's message input.
    panel_opts.message = panel_opts.input
    return vim.tbl_extend("force", {
        swapfile = false,
        buftype = "nofile",
        bufhidden = "hide",
        modifiable = false,
    }, panel_opts[panel])
end

--- @return agentic.ui.ChatWidget.BufNrs
function ChatWidget:_create_buf_nrs()
    -- The chat stands for the session: listed so `:ls`, `:bd` and buffer
    -- pickers reach it (`:bd` on an unlisted buffer only unloads it).
    local chat = self:_create_new_buf("chat", true)
    local todos = self:_create_new_buf("todos", false)
    local code = self:_create_new_buf("code", false)
    local files = self:_create_new_buf("files", false)
    local diagnostics = self:_create_new_buf("diagnostics", false)
    local activity = self:_create_new_buf("activity", false)
    local input = self:_create_new_buf("input", false)

    ChatBuffer.setup(chat)

    pcall(vim.treesitter.start, todos, "markdown")
    pcall(vim.treesitter.start, code, "markdown")
    pcall(vim.treesitter.start, files, "markdown")
    pcall(vim.treesitter.start, diagnostics, "markdown")

    --- @type agentic.ui.ChatWidget.BufNrs
    local buf_nrs = {
        chat = chat,
        todos = todos,
        code = code,
        files = files,
        diagnostics = diagnostics,
        activity = activity,
        input = input,
    }

    return buf_nrs
end

--- @param panel agentic.ui.ChatWidget.PanelNames
--- @param listed boolean
--- @return integer bufnr
function ChatWidget:_create_new_buf(panel, listed)
    local bufnr = vim.api.nvim_create_buf(listed, true)
    self:_apply_buf_opts(bufnr, panel)
    -- A `scheme://` name passes through `vim.uri_from_bufnr` unchanged, so the
    -- input's name is also its document URI for the completion LSP.
    BufHelpers.rename(bufnr, WindowDecoration.buffer_name(bufnr))
    -- The header renders into the windows showing the buffer when it changes;
    -- a window that starts showing it later needs it too.
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = bufnr,
        callback = function()
            WindowDecoration.render_header(bufnr)
        end,
    })
    return bufnr
end

--- Set a panel's buffer options, except `buflisted`, and its b-vars.
--- @param bufnr integer
--- @param panel agentic.ui.ChatWidget.PanelNames
function ChatWidget:_apply_buf_opts(bufnr, panel)
    vim.b[bufnr].agentic_session_id = self._owner_id
    -- The panel the buffer is, so a buffer alone names its header; `chat` and
    -- `subagent` share a filetype.
    vim.b[bufnr].agentic_window = panel
    for key, value in pairs(panel_buf_opts(panel)) do
        vim.api.nvim_set_option_value(key, value, { buf = bufnr })
    end
end

--- Give a buffer a panel's options (except `buflisted`), b-vars and the
--- widget's buffer-local maps, but not the owning session's maps. An unload by
--- `:bd` resets all three.
--- @param bufnr integer
--- @param panel agentic.ui.ChatWidget.PanelNames
function ChatWidget:setup_panel_buf(bufnr, panel)
    self:_apply_buf_opts(bufnr, panel)
    self:_bind_buf_keymaps(panel, bufnr)
end

--- `setup_panel_buf` for one of the widget's own panel buffers.
--- @param panel agentic.ui.ChatWidget.PanelNames
function ChatWidget:apply_buf_state(panel)
    self:setup_panel_buf(self.buf_nrs[panel], panel)
end

--- Set a panel's header context and render it.
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil Shown after the title; nil for none
function ChatWidget:render_header(window_name, context)
    local bufnr = self.buf_nrs[window_name]
    if not bufnr then
        return
    end
    local header = WindowDecoration.get_header(bufnr)
    header.context = context
    WindowDecoration.set_header(bufnr, header)
end

--- Set a buffer's attention badge (e.g. "[idle]", "[?]"), shown in its header.
--- @param badge string|nil Nil clears it
--- @param bufnr integer|nil The buffer to badge; nil = the chat
function ChatWidget:set_badge(badge, bufnr)
    bufnr = bufnr or self.buf_nrs.chat
    -- Nil once the widget is destroyed.
    if not bufnr then
        return
    end
    local header = WindowDecoration.get_header(bufnr)
    if header.badge == badge then
        return
    end
    header.badge = badge
    WindowDecoration.set_header(bufnr, header)
end

--- Clear the chat's `[idle]` badge. A `[?]` stays until its prompt is answered.
function ChatWidget:clear_idle_badge()
    local chat = self.buf_nrs.chat
    if chat and WindowDecoration.get_header(chat).badge == "[idle]" then
        self:set_badge(nil)
    end
end

--- Set the chat's title, shown in its header and as the tail of its buffer
--- name.
--- @param title string|nil New title, or nil to reset to default
function ChatWidget:set_chat_title(title)
    local chat = self.buf_nrs.chat
    -- Nil once the widget is destroyed.
    if not chat then
        return
    end
    local header = WindowDecoration.get_header(chat)

    if title and title ~= "" then
        -- Keep the buffer name short. Cut by display width, not bytes: a
        -- byte-slice can halve a codepoint and put invalid UTF-8 into the
        -- buffer name and winbar.
        local display = TextWrap.truncate_to_width(title, 31)
        header.title = "󰻞 " .. display
        header.session_name = display
    else
        header.title = "󰻞 Agentic Chat"
        header.session_name = nil
    end

    WindowDecoration.set_header(chat, header)
    BufHelpers.rename(
        chat,
        WindowDecoration.buffer_name(chat, header.session_name)
    )
end

--- @return boolean
function ChatWidget:is_activity_window_open()
    return self:panel_win("activity") ~= nil
end

--- Show or hide the file activity panel. `on_open` runs before the window
--- appears, so a caller can reconcile the rows first; `on_close` after it goes,
--- to record that the rows have been seen. Unlike the content panels, the
--- buffer's rows never open or close it. Acts on the panels of the chat in
--- the current tabpage, moving them to a window there that shows it
--- (`_home_in_tab`). Notifies when the current tabpage shows no chat.
--- @param on_open fun()|nil
--- @param on_close fun()|nil
function ChatWidget:toggle_activity_window(on_open, on_close)
    local home = self:_home_in_tab()
    if not home then
        Logger.notify(
            "Show the chat to open the file activity panel.",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return
    end

    if self:is_activity_window_open() then
        self:close_panel("activity")
        if on_close then
            on_close()
        end
        return
    end

    if on_open then
        on_open()
    end
    WidgetLayout.open_panel(self.win_nrs, self.buf_nrs, home, "activity")
end

--- Keep the open activity panel's height matched to its row count. No-op while
--- the panel is closed, which is its normal state during a turn.
function ChatWidget:resize_activity_window()
    WidgetLayout.resize_panel(self.win_nrs, self.buf_nrs, "activity")
end

return ChatWidget

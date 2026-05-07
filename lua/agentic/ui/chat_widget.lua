local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local DiffPreview = require("agentic.ui.diff_preview")
local Logger = require("agentic.utils.logger")
local WindowDecoration = require("agentic.ui.window_decoration")
local WidgetLayout = require("agentic.ui.widget_layout")

--- @alias agentic.ui.ChatWidget.PanelNames "chat"|"todos"|"code"|"files"|"input"|"diagnostics"

--- Runtime header parts with dynamic context
--- @class agentic.ui.ChatWidget.HeaderParts
--- @field title string Main header text
--- @field context? string Dynamic info (managed internally)
--- @field session_name? string Custom session name (set by /rename or first message)
--- @field trust? string Active /trust scope display (set by /trust)

--- @alias agentic.ui.ChatWidget.BufNrs table<agentic.ui.ChatWidget.PanelNames, integer>
--- @alias agentic.ui.ChatWidget.WinNrs table<agentic.ui.ChatWidget.PanelNames, integer|nil>

--- @alias agentic.ui.ChatWidget.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts>

--- Options for controlling widget display behavior
--- @class agentic.ui.ChatWidget.AddToContextOpts
--- @field focus_prompt? boolean

--- Options for showing the widget
--- @class agentic.ui.ChatWidget.ShowOpts : agentic.ui.ChatWidget.AddToContextOpts
--- @field auto_add_to_context? boolean Automatically add current selection or file to context when opening
--- @field position? agentic.UserConfig.Windows.Position Override `windows.position` for this call only

--- A sidebar-style chat widget with multiple windows stacked vertically
--- The main chat window is the first, and contains the width, the below ones adapt to its size
--- @class agentic.ui.ChatWidget
--- @field tab_page_id integer
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field on_submit_input fun(prompt: string) external callback to be called when user submits the input
--- @field on_refresh? fun() external callback for manual refresh (reset stale state, scroll)
--- @field on_hide? fun() external callback called after the widget is hidden
--- @field _hiding boolean re-entrancy guard for hide()
--- @field _unread_badge? string Badge appended to chat buffer name (e.g. "[done]", "[?]")
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

--- @param tab_page_id integer
--- @param on_submit_input fun(prompt: string)
function ChatWidget:new(tab_page_id, on_submit_input)
    self = setmetatable({}, self)

    self.win_nrs = {}

    self.on_submit_input = on_submit_input
    self.tab_page_id = tab_page_id

    self:_initialize()

    return self
end

function ChatWidget:is_open()
    local win_id = self.win_nrs.chat
    return (win_id and vim.api.nvim_win_is_valid(win_id)) or false
end

--- Check if the cursor is currently in one of the widget's buffers
--- @return boolean
function ChatWidget:is_cursor_in_widget()
    if not self:is_open() then
        return false
    end

    return self:_is_widget_buffer(vim.api.nvim_get_current_buf())
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|agentic.ui.ChatWidget.AddToContextOpts|nil
function ChatWidget:show(opts)
    opts = opts or {}

    WidgetLayout.open({
        tab_page_id = self.tab_page_id,
        buf_nrs = self.buf_nrs,
        win_nrs = self.win_nrs,
        focus_prompt = opts.focus_prompt,
        position = opts.position,
    })
end

--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function ChatWidget:rotate_layout(layouts)
    if not layouts or #layouts == 0 then
        layouts = { "right", "bottom", "left" }
    end

    if #layouts == 1 then
        Logger.notify(
            "Only one layout defined for rotation, it'll always show the same: "
                .. layouts[1],
            vim.log.levels.WARN,
            { title = "Agentic: rotate layout" }
        )
    end

    local current = Config.windows.position
    local next_layout = layouts[1]

    for i, layout in ipairs(layouts) do
        if layout == current then
            local next_index = i % #layouts + 1
            if layouts[next_index] then
                next_layout = layouts[next_index]
            end
            break
        end
    end

    Config.windows.position = next_layout

    local previous_mode = vim.fn.mode()
    local previous_buf = vim.api.nvim_get_current_buf()

    local saved_on_hide = self.on_hide
    self.on_hide = nil
    self:hide()
    self.on_hide = saved_on_hide
    self:show({
        focus_prompt = false,
    })

    vim.schedule(function()
        local win = vim.fn.bufwinid(previous_buf)
        if win ~= -1 then
            vim.api.nvim_set_current_win(win)
        end
        if previous_mode == "i" then
            vim.cmd("startinsert")
        end
    end)
end

--- Closes all windows but keeps buffers in memory
function ChatWidget:hide()
    if self._hiding then
        return
    end
    self._hiding = true

    vim.cmd("stopinsert")

    -- Check if we're on the correct tabpage before trying to find/create fallback window
    local current_tabpage = vim.api.nvim_get_current_tabpage()
    local should_create_fallback = current_tabpage == self.tab_page_id

    if should_create_fallback then
        local fallback_winid = self:find_first_non_widget_window()

        if not fallback_winid then
            -- Fallback: create a new left window to avoid closing the last window error
            fallback_winid = self:open_left_window()
            if not fallback_winid then
                Logger.notify(
                    "Failed to create fallback window; cannot hide widget safely, run `:tabclose` to close the tab instead.",
                    vim.log.levels.ERROR
                )
                self._hiding = false
                return
            end
        end

        -- Focus fallback so closing widget windows doesn't trigger E444
        vim.api.nvim_set_current_win(fallback_winid)
    end

    local was_open = self:is_open()

    -- Clear modified flag on input buffer so hidden buffer doesn't block :q
    if self.buf_nrs.input and vim.api.nvim_buf_is_valid(self.buf_nrs.input) then
        vim.bo[self.buf_nrs.input].modified = false
    end

    WidgetLayout.close(self.win_nrs)

    self._hiding = false

    if was_open and self.on_hide then
        self.on_hide()
    end
end

--- Cleans up all buffers content without destroying them
function ChatWidget:clear()
    for name, bufnr in pairs(self.buf_nrs) do
        BufHelpers.with_modifiable(bufnr, function()
            local ok =
                pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, { "" })
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
    end
end

--- Deletes all buffers and removes them from memory
--- This instance is no longer usable after calling this method
function ChatWidget:destroy()
    self:hide()

    for name, bufnr in pairs(self.buf_nrs) do
        self.buf_nrs[name] = nil
        local ok = pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to delete buffer '%s' with id: %d",
                    name,
                    bufnr
                )
            )
        end
    end
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

--- Copy sent text into `Config.settings.send_register` if configured.
--- @param opts agentic.ui.ChatWidget.SendOpts
local function copy_to_send_register(opts)
    local reg = Config.settings and Config.settings.send_register
    if type(reg) ~= "string" or reg == "" then
        return
    end
    local regtype = opts.delete_range.mode == "line" and "l" or "c"
    vim.fn.setreg(reg, opts.text, regtype)
end

--- Delete the sent range from the input buffer.
--- @param bufnr integer
--- @param range agentic.ui.ChatWidget.SendDeleteRange
local function apply_send_delete(bufnr, range)
    if range.mode == "line" then
        vim.api.nvim_buf_set_lines(bufnr, range.sr, range.er + 1, false, {})
    else
        vim.api.nvim_buf_set_text(
            bufnr,
            range.sr,
            range.sc,
            range.er,
            range.ec,
            {}
        )
    end
end

--- Submit the current prompt. With no argument, submits the whole input buffer
--- and clears it. With a send argument, submits a slice and deletes the sent
--- range (optionally saving to a register). Single submit entrypoint — the
--- submit keymap, `:w` (BufWriteCmd), and the `:Wq` / `:X` safeguards all funnel
--- through here.
--- @param send? agentic.ui.ChatWidget.SendOpts
function ChatWidget:submit(send)
    vim.cmd("stopinsert")

    --- @type string
    local prompt
    if send then
        prompt = send.text:match("^%s*(.-)%s*$")
    else
        local lines =
            vim.api.nvim_buf_get_lines(self.buf_nrs.input, 0, -1, false)
        prompt = table.concat(lines, "\n"):match("^%s*(.-)%s*$")
    end

    if not prompt or prompt == "" or not prompt:match("%S") then
        return
    end

    if send then
        copy_to_send_register(send)
        apply_send_delete(self.buf_nrs.input, send.delete_range)
    else
        vim.api.nvim_buf_set_lines(self.buf_nrs.input, 0, -1, false, {})
    end
    vim.bo[self.buf_nrs.input].modified = false

    BufHelpers.with_modifiable(self.buf_nrs.code, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.buf_nrs.files, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    BufHelpers.with_modifiable(self.buf_nrs.diagnostics, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    end)

    self.on_submit_input(prompt)

    self:close_optional_window("code")
    self:close_optional_window("files")
    self:close_optional_window("diagnostics")
    -- Move cursor to chat buffer after submit for easy access to permission requests
    self:move_cursor_to(self.win_nrs.chat)
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
        text = text,
        delete_range = { sr = sr, sc = 0, er = er, ec = 0, mode = "line" },
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
    self:submit({ text = text, delete_range = delete_range })
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

    self:submit({ text = text, delete_range = delete_range })
end

--- @param winid integer|nil
--- @param callback fun()|nil
function ChatWidget:move_cursor_to(winid, callback)
    vim.schedule(function()
        if winid and vim.api.nvim_win_is_valid(winid) then
            if Config.settings.move_cursor_to_chat_on_submit then
                vim.api.nvim_set_current_win(winid)
            end

            -- Scroll to bottom so the user can see the new message and
            -- auto-scroll will engage again. Only scroll downward — if the
            -- buffer is short, G0zb can overshoot and jump the view up.
            BufHelpers.scroll_down_only(winid)

            if callback then
                callback()
            end
        end
    end)
end

function ChatWidget:_initialize()
    self.buf_nrs = self:_create_buf_nrs()

    self:_bind_keymaps()
    self:_setup_write_submit()
    self:_setup_prompt_signs()

    -- I only want to trigger a full close of the chat widget when closing the chat or the input buffers, the others are auxiliary
    for _, bufnr in ipairs({
        self.buf_nrs.chat,
        self.buf_nrs.input,
    }) do
        vim.api.nvim_create_autocmd("BufWinLeave", {
            buffer = bufnr,
            callback = function()
                self:hide()
            end,
        })
    end

    -- Clear unread badge when user scrolls chat to bottom
    vim.api.nvim_create_autocmd("WinScrolled", {
        buffer = self.buf_nrs.chat,
        callback = function()
            if not self._unread_badge then
                return
            end
            local chat_win = self.win_nrs.chat
            if not chat_win or not vim.api.nvim_win_is_valid(chat_win) then
                return
            end
            local chat_buf = self.buf_nrs.chat
            local cursor_line = vim.api.nvim_win_get_cursor(chat_win)[1]
            local total_lines = vim.api.nvim_buf_line_count(chat_buf)
            local threshold = Config.auto_scroll
                    and Config.auto_scroll.threshold
                or 10
            if total_lines - cursor_line <= threshold then
                self:clear_unread_badge()
            end
        end,
    })
end

--- Make :w submit the prompt in the input buffer, and install muscle-memory
--- safeguards for :wq / :x so they don't silently close an active session.
function ChatWidget:_setup_write_submit()
    local input_buf = self.buf_nrs.input
    -- Schedule: _create_new_buf sets options in unordered loop,
    -- so buftype=nofile may be set after filetype triggers this.
    -- The buffer name ("agentic://prompt") is set unconditionally — it is also
    -- used as the LSP root for slash/mention completion (see completion/lsp_server.lua).
    vim.schedule(function()
        vim.api.nvim_buf_set_name(input_buf, "agentic://prompt")
        if Config.settings.write_submit then
            vim.bo[input_buf].buftype = "acwrite"
        end
    end)

    if not Config.settings.write_submit then
        return
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = input_buf,
        callback = function()
            self:submit()
        end,
    })

    -- Safeguard against muscle-memory `:wq` / `:x` — these would otherwise
    -- submit the prompt (via our BufWriteCmd) and then close the widget
    -- window, which is rarely the intent during an active session. Here we
    -- submit as usual but refuse to close. The `!` form (`:wq!` / `:x!`)
    -- is an explicit opt-in to close.
    -- User commands require uppercase, so lowercase forms are mapped via
    -- buffer-local `cnoreabbrev`.
    for _, pair in ipairs({ { "Wq", "wq" }, { "X", "x" } }) do
        vim.api.nvim_buf_create_user_command(input_buf, pair[1], function(opts)
            self:submit()
            if opts.bang then
                self:hide()
            else
                Logger.notify(
                    "Use :" .. pair[2] .. "! to close the session",
                    vim.log.levels.WARN
                )
            end
        end, { bang = true })
        vim.api.nvim_buf_call(input_buf, function()
            vim.cmd(
                string.format("cnoreabbrev <buffer> %s %s", pair[2], pair[1])
            )
        end)
    end
end

--- Mark user prompts with signs and [[ / ]] navigation in the chat buffer
function ChatWidget:_setup_prompt_signs()
    local PROMPT_NS = vim.api.nvim_create_namespace("agentic_prompt_signs")
    local chat_buf = self.buf_nrs.chat

    local function place_prompt_signs()
        vim.api.nvim_buf_clear_namespace(chat_buf, PROMPT_NS, 0, -1)
        local lines = vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false)
        for i, line in ipairs(lines) do
            if line == "##" then
                vim.api.nvim_buf_set_extmark(chat_buf, PROMPT_NS, i - 1, 0, {
                    sign_text = "❯ ",
                    sign_hl_group = "NonText",
                })
            end
        end
    end

    vim.api.nvim_create_autocmd("TextChanged", {
        buffer = chat_buf,
        callback = place_prompt_signs,
    })

    -- Jump between prompts
    BufHelpers.multi_keymap_set(
        Config.keymaps.chat and Config.keymaps.chat.prev_prompt or "[[",
        chat_buf,
        function()
            local row = vim.api.nvim_win_get_cursor(0)[1]
            local lines =
                vim.api.nvim_buf_get_lines(chat_buf, 0, row - 1, false)
            for i = #lines, 1, -1 do
                if lines[i] == "##" then
                    vim.api.nvim_win_set_cursor(0, { i, 0 })
                    return
                end
            end
        end,
        { desc = "Agentic: Previous prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.chat and Config.keymaps.chat.next_prompt or "]]",
        chat_buf,
        function()
            local row = vim.api.nvim_win_get_cursor(0)[1]
            local lines = vim.api.nvim_buf_get_lines(chat_buf, row, -1, false)
            for i, line in ipairs(lines) do
                if line == "##" then
                    vim.api.nvim_win_set_cursor(0, { row + i, 0 })
                    return
                end
            end
        end,
        { desc = "Agentic: Next prompt" }
    )

    local open_diff_file = Config.keymaps.chat
        and Config.keymaps.chat.open_diff_file
    if
        open_diff_file
        and not BufHelpers.is_keymap_disabled(open_diff_file)
    then
        local status_messages = {
            no_session = "No agentic session for this tab",
            no_block = "No tool call block under cursor",
            no_diff = "Tool call has no diff (not an Edit/Write)",
            no_target = "Could not locate diff hunks",
        }
        BufHelpers.multi_keymap_set(
            open_diff_file,
            chat_buf,
            function()
                local DiffJump = require("agentic.ui.diff_jump")
                local status = DiffJump.handle()
                if status ~= "ok" then
                    Logger.notify(
                        status_messages[status] or status,
                        vim.log.levels.INFO,
                        { title = "Agentic" }
                    )
                end
            end,
            { desc = "Agentic: Open diff file in new tab" }
        )
    end
end

function ChatWidget:_bind_keymaps()
    if not BufHelpers.is_keymap_disabled(Config.keymaps.prompt.submit) then
        BufHelpers.multi_keymap_set(
            Config.keymaps.prompt.submit,
            self.buf_nrs.input,
            function()
                self:submit()
            end,
            { desc = "Agentic: Submit prompt" }
        )
    end

    self:_bind_send_keymaps()

    BufHelpers.multi_keymap_set(
        Config.keymaps.prompt.paste_image,
        self.buf_nrs.input,
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

    for _, bufnr in pairs(self.buf_nrs) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.close,
            bufnr,
            function()
                require("agentic").close(self.tab_page_id)
            end,
            { desc = "Agentic: Close Chat widget" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_provider,
            bufnr,
            function()
                require("agentic").switch_provider()
            end,
            { desc = "Agentic: Switch provider" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.stop_generation,
            bufnr,
            function()
                require("agentic").stop_generation()
            end,
            { desc = "Agentic: Stop generation" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.continue,
            bufnr,
            function()
                require("agentic").send_prompt("Continue")
            end,
            { desc = "Agentic: Send 'Continue' prompt" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.restart_session,
            bufnr,
            function()
                require("agentic").restart_session()
            end,
            { desc = "Agentic: Restart session (cancel and restore)" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.restore_session,
            bufnr,
            function()
                require("agentic").restore_session()
            end,
            { desc = "Agentic: Restore previous session" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.refresh,
            bufnr,
            function()
                if self.on_refresh then
                    self.on_refresh()
                end
            end,
            {
                desc = "Agentic: Refresh chat (reset stale state, scroll to bottom)",
            }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.toggle_auto_scroll,
            bufnr,
            function()
                Config.auto_scroll.enabled = not Config.auto_scroll.enabled
                Logger.notify(
                    "Auto-scroll "
                        .. (
                            Config.auto_scroll.enabled and "enabled"
                            or "disabled"
                        ),
                    vim.log.levels.INFO,
                    { title = "Agentic" }
                )
            end,
            { desc = "Agentic: Toggle auto-scroll" }
        )
    end

    -- Add keybindings to chat, todos, code, and files buffers to jump back to input and start insert mode
    for panel_name, bufnr in pairs(self.buf_nrs) do
        if panel_name ~= "input" then
            for _, key in ipairs({
                "a",
                "A",
                "o",
                "O",
                "i",
                "I",
                "c",
                "C",
                "x",
                "X",
            }) do
                BufHelpers.keymap_set(bufnr, "n", key, function()
                    self:move_cursor_to(
                        self.win_nrs.input,
                        BufHelpers.start_insert_on_last_char
                    )
                end)
            end

            -- Paste in chat/panel → focus input window and paste there
            for _, key in ipairs({ "p", "P" }) do
                BufHelpers.keymap_set(bufnr, "n", key, function()
                    local input_win = self.win_nrs.input
                    if input_win and vim.api.nvim_win_is_valid(input_win) then
                        vim.api.nvim_set_current_win(input_win)
                        vim.cmd("normal! " .. key)
                    end
                end)
            end
        end
    end

    DiffPreview.setup_diff_navigation_keymaps(self.buf_nrs)
end

function ChatWidget:_bind_send_keymaps()
    local keymaps = Config.keymaps.prompt

    if not BufHelpers.is_keymap_disabled(keymaps.send_line) then
        BufHelpers.multi_keymap_set(
            keymaps.send_line,
            self.buf_nrs.input,
            function()
                self:_send_line()
            end,
            { desc = "Agentic: Send line" }
        )
    end

    if not BufHelpers.is_keymap_disabled(keymaps.send_operator) then
        _send_widgets[self.buf_nrs.input] = self
        vim.api.nvim_create_autocmd("BufWipeout", {
            buffer = self.buf_nrs.input,
            once = true,
            callback = function(ev)
                _send_widgets[ev.buf] = nil
            end,
        })
        BufHelpers.multi_keymap_set(
            keymaps.send_operator,
            self.buf_nrs.input,
            function()
                vim.o.operatorfunc =
                    "v:lua.require'agentic.ui.chat_widget'._send_operator_dispatch"
                return "g@"
            end,
            {
                desc = "Agentic: Send motion",
                expr = true,
                silent = true,
            }
        )
    end

    if not BufHelpers.is_keymap_disabled(keymaps.send_visual) then
        BufHelpers.multi_keymap_set(
            keymaps.send_visual,
            self.buf_nrs.input,
            function()
                self:_send_visual()
            end,
            { desc = "Agentic: Send visual" },
            "x"
        )
    end
end

--- @return agentic.ui.ChatWidget.BufNrs
function ChatWidget:_create_buf_nrs()
    local chat = self:_create_new_buf({
        filetype = "AgenticChat",
    })

    local todos = self:_create_new_buf({
        filetype = "AgenticTodos",
    })

    local code = self:_create_new_buf({
        filetype = "AgenticCode",
    })

    local files = self:_create_new_buf({
        filetype = "AgenticFiles",
    })

    local diagnostics = self:_create_new_buf({
        filetype = "AgenticDiagnostics",
    })

    local input = self:_create_new_buf({
        filetype = "AgenticInput",
        modifiable = true,
    })

    pcall(vim.treesitter.start, chat, "markdown")
    pcall(vim.treesitter.start, todos, "markdown")
    pcall(vim.treesitter.start, code, "markdown")
    pcall(vim.treesitter.start, files, "markdown")
    pcall(vim.treesitter.start, diagnostics, "markdown")
    pcall(vim.treesitter.start, input, "markdown")

    --- @type agentic.ui.ChatWidget.BufNrs
    local buf_nrs = {
        chat = chat,
        todos = todos,
        code = code,
        files = files,
        diagnostics = diagnostics,
        input = input,
    }

    return buf_nrs
end

--- @param opts table<string, any>
--- @return integer bufnr
function ChatWidget:_create_new_buf(opts)
    local bufnr = vim.api.nvim_create_buf(false, true)

    local config = vim.tbl_deep_extend("force", {
        swapfile = false,
        buftype = "nofile",
        bufhidden = "hide",
        buflisted = false,
        modifiable = false,
    }, opts)

    for key, value in pairs(config) do
        vim.api.nvim_set_option_value(key, value, { buf = bufnr })
    end

    return bufnr
end

--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil
function ChatWidget:render_header(window_name, context)
    local bufnr = self.buf_nrs[window_name]
    if not bufnr then
        return
    end

    WindowDecoration.render_header(bufnr, window_name, context)

    -- Re-apply unread badge to buffer name after header render resets it
    if window_name == "chat" and self._unread_badge then
        vim.schedule(function()
            self:_apply_badge_to_buf_name()
        end)
    end
end

--- Set an unread badge on the chat buffer name (e.g. "[done]", "[?]").
--- Cleared when the user scrolls to the bottom.
--- @param badge string
function ChatWidget:set_unread_badge(badge)
    if self._unread_badge == badge then
        return
    end
    self._unread_badge = badge
    self:_apply_badge_to_buf_name()
end

--- Clear the unread badge from the chat buffer name.
function ChatWidget:clear_unread_badge()
    if not self._unread_badge then
        return
    end
    self._unread_badge = nil
    self:_apply_badge_to_buf_name()
end

--- Apply or remove the badge suffix on the chat buffer name.
function ChatWidget:_apply_badge_to_buf_name()
    local bufnr = self.buf_nrs.chat
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end

    local name = vim.api.nvim_buf_get_name(bufnr)
    -- Strip any existing badge suffix
    name = name:gsub(" %[.-%]$", "")

    if self._unread_badge then
        name = name .. " " .. self._unread_badge
    end

    pcall(vim.api.nvim_buf_set_name, bufnr, name)
    vim.cmd.redrawstatus()
end

--- Update the chat panel's base title (shown in buffer name and winbar).
--- Truncates to keep the buffer name short.
--- @param title string|nil New title, or nil to reset to default
function ChatWidget:set_chat_title(title)
    local headers = WindowDecoration.get_headers_state(self.tab_page_id)
    if not headers.chat then
        return
    end

    if title and title ~= "" then
        -- Truncate long titles to keep buffer name short
        local max_len = 30
        local display = #title > max_len and title:sub(1, max_len) .. "…"
            or title
        headers.chat.title = "󰻞 " .. display
        headers.chat.session_name = display
    else
        headers.chat.title = "󰻞 Agentic Chat"
        headers.chat.session_name = nil
    end

    WindowDecoration.set_headers_state(self.tab_page_id, headers)

    -- Re-render to apply the new title to buffer name and winbar
    self:render_header("chat")
end

--- @param panel_name agentic.ui.ChatWidget.PanelNames
function ChatWidget:close_optional_window(panel_name)
    WidgetLayout.close_optional_window(self.win_nrs, panel_name)
end

--- Filetypes that should be excluded when finding fallback windows
local EXCLUDED_FILETYPES = {
    -- File explorers
    ["neo-tree"] = true,
    ["NvimTree"] = true,
    ["oil"] = true,
    -- Neovim special buffers
    ["qf"] = true, -- Quickfix
    ["help"] = true, -- Help buffers
    ["man"] = true, -- Man pages
    ["terminal"] = true, -- Terminal buffers
    -- Plugin special windows
    ["TelescopePrompt"] = true,
    ["DiffviewFiles"] = true,
    ["DiffviewFileHistory"] = true,
    ["fugitive"] = true,
    ["gitcommit"] = true,
    ["dashboard"] = true,
    ["alpha"] = true, -- Alpha dashboard
    ["starter"] = true, -- Mini.starter
    ["notify"] = true, -- nvim-notify
    ["noice"] = true, -- Noice popup
    ["aerial"] = true, -- Aerial outline
    ["Outline"] = true, -- symbols-outline
    ["trouble"] = true, -- Trouble diagnostics
    ["spectre_panel"] = true, -- nvim-spectre
    ["lazy"] = true, -- Lazy plugin manager
    ["mason"] = true, -- Mason installer
}

--- Close non-widget windows on the tabpage that hold empty unnamed buffers.
--- Mirrors the cleanup in Agentic.toggle_tab so the widget fills the tab
--- when restoring a session on a dedicated tab.
function ChatWidget:close_empty_non_widget_windows()
    local widget_win_ids = {}
    for _, winid in pairs(self.win_nrs) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(self.tab_page_id)) do
        if not widget_win_ids[winid] then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            local ft = vim.bo[bufnr].filetype
            local is_empty = (ft == "" or ft == "dashboard")
                and vim.fn.bufname(bufnr) == ""
            if is_empty then
                pcall(vim.api.nvim_win_close, winid, true)
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
    end
end

--- Finds the first window on the current tabpage that is NOT part of the chat widget
--- @return number|nil winid The first non-widget window ID, or nil if none found
function ChatWidget:find_first_non_widget_window()
    local all_windows = vim.api.nvim_tabpage_list_wins(self.tab_page_id)

    -- Build a set of widget window IDs for fast lookup
    local widget_win_ids = {}
    for _, winid in pairs(self.win_nrs) do
        if winid then
            widget_win_ids[winid] = true
        end
    end

    for _, winid in ipairs(all_windows) do
        if not widget_win_ids[winid] then
            local bufnr = vim.api.nvim_win_get_buf(winid)
            local ft = vim.bo[bufnr].filetype
            if not EXCLUDED_FILETYPES[ft] then
                return winid
            end
        end
    end

    return nil
end

--- Checks if a buffer belongs to this widget
--- @param bufnr number
--- @return boolean
function ChatWidget:_is_widget_buffer(bufnr)
    for _, widget_bufnr in pairs(self.buf_nrs) do
        if widget_bufnr == bufnr then
            return true
        end
    end
    return false
end

--- Opens a new window on the left side with full height
--- @param bufnr number|nil The buffer to display in the new window
--- @return number|nil winid The newly created window ID or nil on failure
function ChatWidget:open_left_window(bufnr)
    if bufnr == nil then
        -- Try alternate buffer first, but skip if it's a widget buffer or excluded filetype
        local alt_bufnr = vim.fn.bufnr("#")
        if
            alt_bufnr ~= -1
            and vim.api.nvim_buf_is_valid(alt_bufnr)
            and not self:_is_widget_buffer(alt_bufnr)
        then
            local ft = vim.bo[alt_bufnr].filetype
            if not EXCLUDED_FILETYPES[ft] then
                bufnr = alt_bufnr
            end
        end
    end

    if bufnr == nil then
        -- Fall back to first oldfile that exists in current directory
        local oldfiles = vim.v.oldfiles
        local cwd = vim.fn.getcwd()
        if oldfiles and #oldfiles > 0 then
            for _, filepath in ipairs(oldfiles) do
                -- Check if file exists and is under current working directory
                if
                    vim.startswith(filepath, cwd)
                    and vim.fn.filereadable(filepath) == 1
                then
                    local file_bufnr = vim.fn.bufnr(filepath)
                    if file_bufnr == -1 then
                        file_bufnr = vim.fn.bufadd(filepath)
                    end
                    bufnr = file_bufnr
                    break
                end
            end
        end
    end

    -- Last resort: create new scratch buffer
    if bufnr == nil then
        bufnr = vim.api.nvim_create_buf(false, true)
    end

    local ok, winid = pcall(vim.api.nvim_open_win, bufnr, true, {
        split = "left",
        win = -1,
    })

    if not ok then
        Logger.notify(
            "Failed to open window: " .. tostring(winid),
            vim.log.levels.WARN
        )
        return nil
    end

    return winid
end

return ChatWidget

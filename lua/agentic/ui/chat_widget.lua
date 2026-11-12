local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local BufferNames = require("agentic.utils.buffer_names")
local ChatBuffer = require("agentic.ui.chat_buffer")
local Logger = require("agentic.utils.logger")
local LspServer = require("agentic.completion.lsp_server")
local InputDispatch = require("agentic.ui.input_dispatch")
local MessageWriter = require("agentic.ui.message_writer")
local TextWrap = require("agentic.utils.text_wrap")
local WindowDecoration = require("agentic.ui.window_decoration")
local WidgetLayout = require("agentic.ui.widget_layout")

--- @alias agentic.ui.ChatWidget.PanelNames "agent"|"todos"|"code"|"files"|"input"|"diagnostics"|"activity"|"info"|"subagent"|"message"

--- Runtime header parts with dynamic context
--- @class agentic.ui.ChatWidget.HeaderParts
--- @field icon? string The panel's identity glyph
--- @field title string Main header text
--- @field context? string Dynamic info (managed internally)
--- @field session_name? string Custom session name (set by /rename or first message)
--- @field running? boolean The agent works
--- @field waiting? boolean A permission prompt waits unseen
--- @field idle? boolean A turn ended unseen

--- @alias agentic.ui.ChatWidget.BufNrs table<agentic.ui.ChatWidget.PanelNames, integer>
--- @alias agentic.ui.ChatWidget.WinNrs table<agentic.ui.ChatWidget.PanelNames, integer|nil>

--- @alias agentic.ui.ChatWidget.Headers table<agentic.ui.ChatWidget.PanelNames, agentic.ui.ChatWidget.HeaderParts>

--- A session's buffers: the chat, shown in any window, and the panels, which
--- attach below the chat's home window in `Config.windows.stack` order.
--- @class agentic.ui.ChatWidget
--- @field _owner_id integer `SessionManager.id` of the owning session
--- @field _name_key string The `key` of the session's buffer names
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs Panel windows
--- @field input_dispatch agentic.ui.InputDispatch Submit, partial send and the queue of the input buffer
--- @field _on_submit_input fun(prompt: string, opts: agentic.SessionManager.SubmitOpts): boolean Runs a prompt submitted from the input. False when it defers the prompt
--- @field on_refresh? fun() external callback for manual refresh (reset stale state)
--- @field on_goto_bottom? fun(winid: integer) external callback that moves a window showing the chat or a transcript to its last line
--- @field on_panel_buf? fun(panel: agentic.ui.ChatWidget.StackPanel, bufnr: integer) external callback for a buffer `panel_buf` made in place of a wiped one, already in `buf_nrs`
--- @field _home_win? integer The window the panels attach to
--- @field _home_closed_autocmd? integer The WinClosed autocmd of `_home_win`
local ChatWidget = {}
ChatWidget.__index = ChatWidget

--- @param owner_id integer `SessionManager.id` of the session owning the widget
--- @param name_key string See `agentic.BufferNames.Parts`
--- @param on_submit_input fun(prompt: string, opts: agentic.SessionManager.SubmitOpts): boolean
function ChatWidget:new(owner_id, name_key, on_submit_input)
    self = setmetatable({}, self)

    self.win_nrs = {}

    self._on_submit_input = on_submit_input
    self._owner_id = owner_id
    self._name_key = name_key

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
        and vim.api.nvim_win_get_buf(winid) == self.buf_nrs.agent
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
--- shows it. Notifies and returns false when the window refuses the buffer
--- (`'winfixbuf'`).
--- @param winid integer
--- @return boolean shown
function ChatWidget:show_in(winid)
    local replaced = vim.api.nvim_win_get_buf(winid)
    -- With autocmds: the chat's BufWinEnter sets its window options and
    -- follow mode.
    local ok, err = pcall(vim.api.nvim_win_set_buf, winid, self.buf_nrs.agent)
    if not ok then
        Logger.notify(
            "Cannot show the chat here: " .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic" }
        )
        return false
    end
    if
        replaced ~= self.buf_nrs.agent
        -- 'bufhidden=wipe' wipes it as the chat replaces it.
        and vim.api.nvim_buf_is_valid(replaced)
        and BufHelpers.is_blank_unnamed(replaced)
        and #vim.fn.win_findbuf(replaced) == 0
    then
        vim.api.nvim_buf_delete(replaced, {})
    end
    self:_adopt_home(winid)
    return true
end

--- The window to show the chat in: the current window, unless it shows an
--- input of any session (filetype `AgenticInput`) or a panel of this widget
--- other than the chat. Then the home window in this tabpage, else a window
--- in this tabpage that shows the chat, else nil.
--- @return integer|nil winid
function ChatWidget:target_win()
    local current = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(current)
    local is_panel = bufnr ~= self.buf_nrs.agent
        and vim.list_contains(vim.tbl_values(self.buf_nrs), bufnr)
    if not is_panel and vim.bo[bufnr].filetype ~= "AgenticInput" then
        return current
    end
    return self:_chat_win_in_tab()
end

--- The home window when it is in the current tabpage, else a window there
--- that shows the chat. Nil when the current tabpage shows no chat.
--- @return integer|nil winid
function ChatWidget:_chat_win_in_tab()
    local tab = vim.api.nvim_get_current_tabpage()
    local home = self:home_win()
    if home and vim.api.nvim_win_get_tabpage(home) == tab then
        return home
    end
    for _, winid in ipairs(vim.fn.win_findbuf(self.buf_nrs.agent)) do
        if vim.api.nvim_win_get_tabpage(winid) == tab then
            return winid
        end
    end
    return nil
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
    vim.list_extend(winids, vim.fn.win_findbuf(self.buf_nrs.agent))
    for _, winid in ipairs(winids) do
        if
            vim.api.nvim_win_get_buf(winid) == self.buf_nrs.agent
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

--- Focus a window in the current tabpage that shows the chat, the home
--- window first. Without one, show the chat in `target_win` and focus it.
--- Nil `target_win`: show it in a new split above the current window.
--- @param target_win integer|nil
function ChatWidget:reveal(target_win)
    local shown = self:_chat_win_in_tab()
    if shown then
        vim.api.nvim_set_current_win(shown)
    elseif not target_win then
        -- Not `:sbuffer`: 'switchbuf' could send it to another tabpage.
        local above = vim.api.nvim_open_win(
            self.buf_nrs.agent,
            true,
            { split = "above", win = 0 }
        )
        self:show_in(above)
    elseif self:show_in(target_win) then
        vim.api.nvim_set_current_win(target_win)
    end
end

--- Whether command modifiers open a new window: a split or tab modifier.
--- @param mods vim.api.keyset.cmd_mods|nil
--- @return boolean
local function opens_window(mods)
    return mods ~= nil
        and (
            (mods.tab or -1) ~= -1
            or (mods.split or "") ~= ""
            or mods.vertical == true
            or mods.horizontal == true
        )
end

--- Show the chat. With a split or tab modifier in `mods`, in a new window
--- (`:sbuffer`) that becomes home, else as `reveal(target_win)`.
--- @param mods vim.api.keyset.cmd_mods|nil
--- @param target_win integer|nil
function ChatWidget:show(mods, target_win)
    if not opens_window(mods) then
        self:reveal(target_win)
        return
    end
    vim.cmd.sbuffer({ args = { self.buf_nrs.agent }, mods = mods })
    self:show_in(vim.api.nvim_get_current_win())
end

--- The stack panels that only a key opens or closes, never their buffer's rows.
local TOGGLED_PANELS = { input = true, activity = true, info = true }

--- The stack panels shown with the markdown parser. The input starts its own
--- on each load (`_attach_input`).
local MARKDOWN_PANELS =
    { todos = true, code = true, files = true, diagnostics = true, info = true }

--- `bufnr` while it is a valid buffer, else nil.
--- @param bufnr integer|nil
--- @return integer|nil
local function valid_buf(bufnr)
    return bufnr and vim.api.nvim_buf_is_valid(bufnr) and bufnr or nil
end

--- Open or close each content panel (code, files, diagnostics, and todos
--- when `Config.windows.todos.display`) to match its buffer. No-op without a
--- home window. Skips a wiped buffer: the next write to the panel makes it
--- again.
function ChatWidget:sync_panels()
    local home = self:home_win()
    if not home then
        return
    end
    for _, panel in ipairs(Config.windows.stack) do
        local is_content = not TOGGLED_PANELS[panel]
        if
            is_content
            and (panel ~= "todos" or Config.windows.todos.display)
            and valid_buf(self.buf_nrs[panel])
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
--- `input` and the `code`, `files` and `diagnostics` panels. `input` holds
--- the user's unsent draft, which is not conversation state and must survive
--- session resets/swaps. The other three are written only by their
--- `ContextList`.
---
--- Leaves the extmarks over the chat text, and a MessageWriter's
--- tool call trackers — those are the writer's, out of reach from here. Clear
--- the chat through `SessionManager:clear_chat`, which resets the writers too;
--- a tracker or mark outliving its text resolves to row 0 of whatever
--- replaces it.
---
--- Leaves each buffer's `modified` as it was: clearing the render loses
--- nothing that its owner has not accounted for. Skips a wiped buffer.
function ChatWidget:clear()
    local kept = { input = true, code = true, files = true, diagnostics = true }
    for name, bufnr in pairs(self.buf_nrs) do
        if not kept[name] and valid_buf(bufnr) then
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
    -- Clear the chat first: `panel_buf` then gives nil, so an autocmd that
    -- the deletes below trigger makes no new panel buffer.
    local chat = self.buf_nrs.agent
    self.buf_nrs.agent = nil
    for name, bufnr in pairs(self.buf_nrs) do
        self.buf_nrs[name] = nil
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end

    vim.schedule(function()
        if vim.api.nvim_buf_is_valid(chat) then
            vim.api.nvim_buf_delete(chat, { force = true })
        end
    end)
end

--- On the next tick, focus the `panel` window, the home window for the chat,
--- and, unless it is the chat, scroll it to the bottom, then run `callback`.
--- No-op when no window shows the panel then.
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @param callback fun()|nil
function ChatWidget:move_cursor_to(panel, callback)
    vim.schedule(function()
        local winid = panel == "agent" and self:home_win()
            or self:panel_win(panel)
        if winid then
            vim.api.nvim_set_current_win(winid)

            -- Follow owns the chat's view, which a held tool call may keep
            -- short of the bottom.
            if panel ~= "agent" then
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
--- @return integer|nil winid Nil when the input panel fails to open, or after `destroy`
function ChatWidget:input_win()
    local input = self:panel_buf("input")
    if not input then
        return nil
    end
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
    -- The chat stands for the session: listed so `:ls`, `:bd` and buffer
    -- pickers reach it (`:bd` on an unlisted buffer only unloads it).
    local chat = self:_create_new_buf("agent", true)
    ChatBuffer.setup(chat)
    self.buf_nrs = { agent = chat }
    for _, panel in ipairs(Config.windows.stack) do
        self:_create_panel_buf(panel)
    end
    self:set_chat_title(nil)

    self:_bind_buf_keymaps("agent", chat)
    self:_track_home(chat)
end

--- Make the `panel` buffer and store it in `buf_nrs`, with what lasts for the
--- buffer's life: its autocmds, the widget's maps, and for a markdown panel
--- the parser. Renders nothing.
--- @param panel agentic.ui.ChatWidget.StackPanel
--- @return integer bufnr
function ChatWidget:_create_panel_buf(panel)
    local bufnr = self:_create_new_buf(panel, false)
    self.buf_nrs[panel] = bufnr
    if MARKDOWN_PANELS[panel] then
        pcall(vim.treesitter.start, bufnr, "markdown")
    end
    -- Before the maps: the input's maps come from the dispatch it makes.
    if panel == "input" then
        self:_setup_input()
    end
    self:_bind_buf_keymaps(panel, bufnr)
    return bufnr
end

--- The `panel` buffer. When it was wiped, makes a new one and passes it to
--- `on_panel_buf`. Nil after `destroy`.
--- @param panel agentic.ui.ChatWidget.StackPanel
--- @return integer|nil bufnr
function ChatWidget:panel_buf(panel)
    if not self.buf_nrs.agent then
        return nil
    end
    local bufnr = valid_buf(self.buf_nrs[panel])
    if bufnr then
        return bufnr
    end
    bufnr = self:_create_panel_buf(panel)
    if self.on_panel_buf then
        self.on_panel_buf(panel, bufnr)
    end
    return bufnr
end

--- Set up the input buffer for its dispatch, completion and the modified flag.
function ChatWidget:_setup_input()
    local input = self.buf_nrs.input
    self.input_dispatch = InputDispatch:new(
        input,
        self._on_submit_input,
        function()
            if Config.settings.move_cursor_to_agent_on_submit then
                self:move_cursor_to("agent")
            end
        end
    )
    self:_attach_input()

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

--- Wire up [[ / ]] navigation between the rows of a chat or transcript buffer
--- written outside the agent's stream: prompts and notices. Navigation reads
--- their `MessageWriter.NS_USER_ACTIONS` marks, so agent-authored `## `
--- headings are never treated as prompts.
--- @param bufnr integer
function ChatWidget:_setup_prompt_navigation(bufnr)
    --- Row of the nearest user-action marker relative to the cursor.
    --- @param forward boolean true = smallest row > cursor, false = greatest < cursor
    --- @return integer|nil row 0-indexed
    local function adjacent_prompt_row(forward)
        local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
        -- Row -1 is the buffer end to get_extmarks, not "above row 0".
        if not forward and cur == 0 then
            return nil
        end
        local start = forward and { cur + 1, 0 } or { cur - 1, -1 }
        local mark = vim.api.nvim_buf_get_extmarks(
            bufnr,
            MessageWriter.NS_USER_ACTIONS,
            start,
            forward and -1 or 0,
            { limit = 1 }
        )[1]
        return mark and mark[2]
    end

    local function jump_prompt(forward)
        local row = adjacent_prompt_row(forward)
        if row then
            vim.api.nvim_win_set_cursor(0, { row + 1, 0 })
        end
    end

    BufHelpers.multi_keymap_set(
        Config.keymaps.agent.prev_prompt,
        bufnr,
        function()
            jump_prompt(false)
        end,
        { desc = "Agentic: Previous prompt" }
    )

    BufHelpers.multi_keymap_set(
        Config.keymaps.agent.next_prompt,
        bufnr,
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
            and (panel == "agent" or panel == "subagent")
        then
            self.on_goto_bottom(winid)
        end
    end
end

--- Bind the widget's buffer-local maps on one panel's buffer.
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @param bufnr integer
function ChatWidget:_bind_buf_keymaps(panel, bufnr)
    if panel == "input" then
        self.input_dispatch:bind()

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
    elseif panel == "agent" or panel == "subagent" then
        self:_setup_prompt_navigation(bufnr)
    end

    if panel ~= "message" then
        self:_bind_canned_prompt_keymaps(bufnr)
    end

    BufHelpers.multi_keymap_set(Config.keymaps.widget.refresh, bufnr, function()
        if self.on_refresh then
            self.on_refresh()
        end
    end, { desc = "Agentic: Refresh chat (reset stale state)" })

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
        BufHelpers.bind_to_input(
            Config.keymaps.agent.to_input,
            bufnr,
            function()
                return self:input_win()
            end
        )
    end
end

--- Bind each `Config.keymaps.prompts` entry on a buffer to put its prompt in
--- the input.
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
                or ("Input prompt: " .. prompt:gsub("%s+", " "):sub(1, 40))

            BufHelpers.multi_keymap_set(km, bufnr, function()
                self:_stage_input(prompt)
            end, { desc = desc })
        end
    end
end

--- Put text in the input. With the input as the current buffer, the text goes
--- in at the cursor or replaces the selection. Otherwise it goes at the end of
--- the input as a paragraph of its own, and the input gets focus in normal
--- mode with the cursor on the text's first line. Leading and trailing empty
--- lines of the text are dropped.
--- @param text string
function ChatWidget:_stage_input(text)
    local lines = vim.split(text, "\n", { trimempty = true })
    local input = self:panel_buf("input")
    if #lines == 0 or not input then
        return
    end
    if vim.api.nvim_get_current_buf() == input then
        BufHelpers.insert_text(lines)
        return
    end
    local row = BufHelpers.insert_paragraph(
        input,
        vim.api.nvim_buf_line_count(input),
        lines
    )

    if vim.api.nvim_get_mode().mode:match("^[vVsS\22\19]") then
        vim.cmd("normal! \27")
    end
    vim.cmd("stopinsert")
    local winid = self:input_win()
    if not winid then
        return
    end
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_cursor(winid, { row + 1, 0 })
end

--- Attach what a buffer load provides and an unload detaches: the markdown
--- parser, the queue's `on_bytes` untag, and the completion LSP.
function ChatWidget:_attach_input()
    local buf = self.buf_nrs.input

    pcall(vim.treesitter.start, buf, "markdown")

    self.input_dispatch:attach_untag()

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
        agent = { filetype = "AgenticChat", buftype = "acwrite" },
        subagent = { filetype = "AgenticChat", buftype = "acwrite" },
        todos = { filetype = "AgenticTodos" },
        code = { filetype = "AgenticCode" },
        files = { filetype = "AgenticFiles" },
        diagnostics = { filetype = "AgenticDiagnostics" },
        activity = { filetype = "AgenticActivity" },
        info = { filetype = "AgenticInfo" },
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

--- A buffer with a panel's options, b-vars and name (`BufHelpers.claim_name`),
--- and an autocmd that renders its header in a window that starts showing it.
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @param listed boolean
--- @return integer bufnr
function ChatWidget:_create_new_buf(panel, listed)
    local bufnr = vim.api.nvim_create_buf(listed, true)
    self:_apply_buf_opts(bufnr, panel)
    -- A `scheme://` name passes through `vim.uri_from_bufnr` unchanged, so the
    -- input's name is also its document URI for the completion LSP.
    BufHelpers.claim_name(bufnr, self:_panel_name(panel))
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

--- The name of one of the session's buffers.
--- @param sub_id string|nil A subagent's session id, for its transcript or its message input
--- @param part string|nil See `agentic.BufferNames.Parts`
--- @return string
function ChatWidget:buffer_name(sub_id, part)
    return BufferNames.format({
        key = self._name_key,
        sub_id = sub_id and BufferNames.short_key(sub_id),
        part = part,
    })
end

--- The name of the widget's `panel` buffer.
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @return string
function ChatWidget:_panel_name(panel)
    return self:buffer_name(nil, panel ~= "agent" and panel or nil)
end

--- Name the widget's buffers after `key`. Buffers made later take it too.
--- @param key string See `agentic.BufferNames.Parts`
function ChatWidget:rename_buffers(key)
    self._name_key = key
    for panel, bufnr in pairs(self.buf_nrs) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            BufHelpers.claim_name(bufnr, self:_panel_name(panel))
        end
    end
end

--- Set a panel's buffer options, except `buflisted`, and its b-vars.
--- @param bufnr integer
--- @param panel agentic.ui.ChatWidget.PanelNames
function ChatWidget:_apply_buf_opts(bufnr, panel)
    vim.b[bufnr].agentic_session_id = self._owner_id
    -- The panel the buffer is, so a buffer alone names its header; `agent` and
    -- `subagent` share a filetype.
    vim.b[bufnr].agentic_window = panel
    -- A snacks picker opens its choice in a window that shows a file or a
    -- buffer with this b-var: so a transcript's window may take it, and a
    -- panel's window never does.
    if panel == "agent" or panel == "subagent" then
        vim.b[bufnr].snacks_main = true
    end
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

--- Set a panel's header context and render it. No-op while its buffer is
--- wiped.
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param context string|nil Shown after the title; nil for none
function ChatWidget:render_header(window_name, context)
    local bufnr = valid_buf(self.buf_nrs[window_name])
    if not bufnr then
        return
    end
    local header = WindowDecoration.get_header(bufnr)
    header.context = context
    WindowDecoration.set_header(bufnr, header)
end

--- Set a state fact of a buffer's header.
--- @param bufnr integer|nil Nil is a no-op
--- @param fact "running"|"waiting"|"idle"
--- @param value boolean
local function set_header_fact(bufnr, fact, value)
    if bufnr then
        WindowDecoration.set_header_fact(bufnr, fact, value)
    end
end

--- Mark a buffer's header as waiting on a hidden permission prompt, or clear it.
--- @param waiting boolean
--- @param bufnr integer|nil The buffer to mark; nil = the chat
function ChatWidget:set_waiting(waiting, bufnr)
    set_header_fact(bufnr or self.buf_nrs.agent, "waiting", waiting)
end

--- Mark the chat's header as having ended a turn unseen, or clear it.
--- @param idle boolean
function ChatWidget:set_idle(idle)
    set_header_fact(self.buf_nrs.agent, "idle", idle)
end

--- Mark the chat's header as running a turn, or clear it.
--- @param running boolean
function ChatWidget:set_running(running)
    set_header_fact(self.buf_nrs.agent, "running", running)
end

--- Set the chat's title, shown in its header after `#` and the owner id.
--- @param title string|nil New title, or nil to reset to default
function ChatWidget:set_chat_title(title)
    local chat = self.buf_nrs.agent
    -- Nil once the widget is destroyed.
    if not chat then
        return
    end
    local header = WindowDecoration.get_header(chat)

    local display = nil
    if title and title ~= "" then
        -- Keep the header short. Cut by display width, not bytes: a
        -- byte-slice can halve a codepoint and put invalid UTF-8 into the
        -- winbar.
        display = TextWrap.truncate_to_width(title, 31)
    end
    header.title = "#" .. self._owner_id .. " " .. (display or "Agentic Chat")
    header.session_name = display

    WindowDecoration.set_header(chat, header)
end

--- Show or hide `panel`. Only this call opens or closes it, never its buffer's
--- rows. `on_open` runs before the window opens, `on_close` after it closes.
--- Acts on the panels of the chat in the current tabpage, moving them to a
--- window there that shows the chat. Warns, and does nothing, when the current
--- tabpage shows no chat.
--- @param panel "activity"|"info"
--- @param on_open fun()|nil
--- @param on_close fun()|nil
function ChatWidget:toggle_panel(panel, on_open, on_close)
    local home = self:_home_in_tab()
    if not home then
        local title = WindowDecoration.default_header(panel).title
        Logger.notify(
            "Show the chat to open the " .. title .. " panel.",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return
    end

    if self:panel_win(panel) then
        self:close_panel(panel)
        if on_close then
            on_close()
        end
        return
    end

    if not self:panel_buf(panel) then
        return
    end
    if on_open then
        on_open()
    end
    WidgetLayout.open_panel(self.win_nrs, self.buf_nrs, home, panel)
end

--- Fit the open `panel` window to its buffer. No-op while it is closed.
--- @param panel agentic.ui.ChatWidget.StackPanel
function ChatWidget:resize_panel(panel)
    WidgetLayout.resize_panel(self.win_nrs, self.buf_nrs, panel)
end

return ChatWidget

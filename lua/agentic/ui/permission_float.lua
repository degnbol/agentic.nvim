local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- Normalize an ACP-sourced kind value: strip whitespace, lowercase.
--- @param k string|nil
--- @return string
local function kind_key(k)
    if not k then
        return ""
    end
    return vim.trim(k):lower()
end

--- @class agentic.ui.PermissionFloat
--- @field message_writer agentic.ui.MessageWriter
--- @field _buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field _tab_page_id integer
--- @field _winid? integer
--- @field _bufnr? integer
--- @field _autocmd_ids integer[]
--- @field _anchor "NE"|"NW"|"SE"|"SW" Cached anchor used for the open window
--- @field _width integer Cached width used for the open window
--- @field _height integer Cached height used for the open window
--- @field _row_offset integer Cached row offset used for the open window
--- @field _col_offset integer Cached column offset used for the open window
local PermissionFloat = {}
PermissionFloat.__index = PermissionFloat

--- @param message_writer agentic.ui.MessageWriter
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param tab_page_id integer
--- @return agentic.ui.PermissionFloat
function PermissionFloat:new(message_writer, buf_nrs, tab_page_id)
    local instance = setmetatable({
        message_writer = message_writer,
        _buf_nrs = buf_nrs,
        _tab_page_id = tab_page_id,
        _winid = nil,
        _bufnr = nil,
        _autocmd_ids = {},
        _anchor = "NE",
        _width = 0,
        _height = 0,
        _row_offset = 0,
        _col_offset = 0,
    }, self)

    return instance
end

--- Compute the (row, col) for nvim_open_win given an anchor corner of the
--- parent window. `row_offset` and `col_offset` are added directly to the
--- anchored corner — positive moves inward from the natural edge.
---
--- For NW: row = row_offset, col = col_offset.
--- For NE: row = row_offset, col = win_w + col_offset (use negative col_offset to inset).
--- For SW: row = win_h + row_offset, col = col_offset (use negative row_offset to inset).
--- For SE: row = win_h + row_offset, col = win_w + col_offset.
--- @param anchor "NE"|"NW"|"SE"|"SW"
--- @param win_w integer Chat window width (column count)
--- @param win_h integer Chat window height (row count)
--- @param row_offset integer
--- @param col_offset integer
--- @return integer row
--- @return integer col
function PermissionFloat._anchor_position(
    anchor,
    win_w,
    win_h,
    row_offset,
    col_offset
)
    local row, col
    if anchor == "NW" then
        row = row_offset
        col = col_offset
    elseif anchor == "NE" then
        row = row_offset
        col = win_w + col_offset
    elseif anchor == "SW" then
        row = win_h + row_offset
        col = col_offset
    else
        row = win_h + row_offset
        col = win_w + col_offset
    end
    return row, col
end

--- Find the chat window for this float's tab page. Returns nil if the
--- widget is hidden on this tab (no chat window in this tab page contains
--- the chat buffer).
--- @return integer|nil
function PermissionFloat:_find_chat_winid()
    local bufnr = self.message_writer.bufnr
    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_get_tabpage(winid) == self._tab_page_id then
            return winid
        end
    end
    return nil
end

--- Build the lines and option_mapping for the prompt body. Mirrors the
--- previous inline rendering but skips buffer concerns — pure transformation
--- from options to display lines.
--- @param options agentic.acp.PermissionOption[]
--- @return string[] lines
--- @return table<integer, string> option_mapping
local function build_lines(options)
    --- @type table<integer, string>
    local option_mapping = {}
    local lines = {}

    -- Insert a synthetic "Reject all" entry before reject_always when present;
    -- otherwise append it at the end. Position-by-severity: reject_all (local)
    -- before reject_always (permanent).
    local merged_options = {}
    local reject_all_inserted = false
    for _, option in ipairs(options) do
        if
            kind_key(option.kind) == "reject_always"
            and not reject_all_inserted
        then
            table.insert(merged_options, {
                kind = "__reject_all__",
                name = "Reject all",
                optionId = "__reject_all__",
            })
            reject_all_inserted = true
        end
        table.insert(merged_options, option)
    end
    if not reject_all_inserted then
        table.insert(merged_options, {
            kind = "__reject_all__",
            name = "Reject all",
            optionId = "__reject_all__",
        })
    end

    local permission_keys = Config.keymaps.permission or {}

    for i, option in ipairs(merged_options) do
        local key_label = permission_keys[i] or tostring(i)
        table.insert(
            lines,
            string.format(
                "%s. %s %s",
                key_label,
                Config.permission_icons[option.kind] or "",
                option.name
            )
        )
        option_mapping[i] = option.optionId
    end

    return lines, option_mapping
end

--- Resolve the float buffer. Reuses the existing buffer if it is still
--- valid (e.g. reopen between requests within one session) to avoid
--- churning buffer numbers on every prompt.
--- @return integer
function PermissionFloat:_resolve_buffer()
    if self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr) then
        return self._bufnr
    end
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "AgenticPermissionFloat"
    self._bufnr = bufnr
    return bufnr
end

--- Write `lines` into the float buffer.
--- @param bufnr integer
--- @param lines string[]
function PermissionFloat:_render(bufnr, lines)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
end

--- Register a WinClosed autocmd on the chat window so the float closes if
--- the chat window goes away mid-prompt.
--- @param chat_winid integer
function PermissionFloat:_register_chat_close_watcher(chat_winid)
    local id = vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(chat_winid),
        callback = function()
            self:close()
        end,
    })
    table.insert(self._autocmd_ids, id)
end

--- Register a WinResized autocmd that recomputes geometry whenever the chat
--- window (or any window) is resized. Covers VimResized-induced changes via
--- the same event.
--- @param chat_winid integer
function PermissionFloat:_register_resize_watcher(chat_winid)
    local id = vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
            if not self._winid or not vim.api.nvim_win_is_valid(self._winid) then
                return
            end
            if not vim.api.nvim_win_is_valid(chat_winid) then
                return
            end
            self:_reposition(chat_winid)
        end,
    })
    table.insert(self._autocmd_ids, id)
end

--- Apply geometry to the open float window. Called on open and on resize.
--- @param chat_winid integer
function PermissionFloat:_reposition(chat_winid)
    if not self._winid or not vim.api.nvim_win_is_valid(self._winid) then
        return
    end
    local win_w = vim.api.nvim_win_get_width(chat_winid)
    local win_h = vim.api.nvim_win_get_height(chat_winid)
    local row, col = PermissionFloat._anchor_position(
        self._anchor,
        win_w,
        win_h,
        self._row_offset,
        self._col_offset
    )
    pcall(vim.api.nvim_win_set_config, self._winid, {
        relative = "win",
        win = chat_winid,
        anchor = self._anchor,
        row = row,
        col = col,
        width = self._width,
        height = self._height,
    })
end

--- Open the permission float with the given sorted options. Returns the
--- option mapping (key index -> option id) used by PermissionManager to bind
--- widget keymaps.
---
--- No-op (returns nil) when the chat window is hidden on this tab. The
--- caller still records `current_request` so widget reopen can re-trigger
--- the prompt.
--- @param options agentic.acp.PermissionOption[]
--- @return table<integer, string>|nil option_mapping
function PermissionFloat:open(options)
    local chat_winid = self:_find_chat_winid()
    if not chat_winid then
        return nil
    end

    self:close()

    local lines, option_mapping = build_lines(options)

    local cfg = Config.permission_float
    local bufnr = self:_resolve_buffer()
    self:_render(bufnr, lines)

    self._anchor = cfg.anchor
    self._width = cfg.width
    self._height = #lines
    self._row_offset = cfg.row_offset
    self._col_offset = cfg.col_offset

    local win_w = vim.api.nvim_win_get_width(chat_winid)
    local win_h = vim.api.nvim_win_get_height(chat_winid)
    local row, col = PermissionFloat._anchor_position(
        self._anchor,
        win_w,
        win_h,
        self._row_offset,
        self._col_offset
    )

    local ok, winid_or_err = pcall(vim.api.nvim_open_win, bufnr, false, {
        relative = "win",
        win = chat_winid,
        anchor = self._anchor,
        width = self._width,
        height = self._height,
        row = row,
        col = col,
        border = cfg.border,
        style = "minimal",
        focusable = false,
        noautocmd = true,
    })
    if not ok then
        Logger.notify(
            "PermissionFloat: failed to open window: " .. tostring(winid_or_err),
            vim.log.levels.ERROR
        )
        return nil
    end

    self._winid = winid_or_err --[[@as integer]]
    vim.wo[self._winid].winblend = cfg.winblend

    self:_register_chat_close_watcher(chat_winid)
    self:_register_resize_watcher(chat_winid)

    return option_mapping
end

--- Close the float window and tear down associated state. Buffer deletion
--- is deferred via vim.schedule per the neovim skill's bufhidden=wipe
--- warning. Safe to call when already closed.
function PermissionFloat:close()
    for _, id in ipairs(self._autocmd_ids) do
        pcall(vim.api.nvim_del_autocmd, id)
    end
    self._autocmd_ids = {}

    if self._winid and vim.api.nvim_win_is_valid(self._winid) then
        pcall(vim.api.nvim_win_close, self._winid, true)
    end
    self._winid = nil

    local bufnr = self._bufnr
    self._bufnr = nil
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.schedule(function()
            if vim.api.nvim_buf_is_valid(bufnr) then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end)
    end
end

return PermissionFloat

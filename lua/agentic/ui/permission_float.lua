local AcpKind = require("agentic.utils.acp_kind")
local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.ui.PermissionFloat
--- @field message_writer agentic.ui.MessageWriter
--- @field _buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field _owner_id integer `SessionManager.id` of the owning session
--- @field _winid? integer
--- @field _bufnr? integer
--- @field _anchor_bufnr? integer Buffer the float anchors to while open
--- @field _anchor_winid? integer Window the float is placed against while shown
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
--- @param owner_id integer `SessionManager.id` of the owning session
--- @return agentic.ui.PermissionFloat
function PermissionFloat:new(message_writer, buf_nrs, owner_id)
    local instance = setmetatable({
        message_writer = message_writer,
        _buf_nrs = buf_nrs,
        _owner_id = owner_id,
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
--- @param win_w integer Parent width (column count)
--- @param win_h integer Parent height (row count)
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

--- Find a window showing `bufnr`: on the current tab page, else on the
--- owning session's, else on any. Nil when no window shows it.
--- @param bufnr integer
--- @return integer|nil
function PermissionFloat:_find_anchor_winid(bufnr)
    local winids = vim.fn.win_findbuf(bufnr)
    local function in_tab(tab)
        for _, winid in ipairs(winids) do
            if vim.api.nvim_win_get_tabpage(winid) == tab then
                return winid
            end
        end
        return nil
    end
    local owner_tab = SessionRegistry.tab_of(self._owner_id)
    return in_tab(vim.api.nvim_get_current_tabpage())
        or (owner_tab and in_tab(owner_tab))
        or winids[1]
end

--- Build the lines and option_mapping for the prompt body. Mirrors the
--- previous inline rendering but skips buffer concerns — pure transformation
--- from options to display lines.
--- @param options agentic.acp.PermissionOption[]
--- @return string[] lines
--- @return table<string, string> option_mapping Option id by the key that selects it (see `Config.keymaps.permission`)
local function build_lines(options)
    --- @type table<string, string>
    local option_mapping = {}
    local lines = {}

    -- Insert a synthetic "Reject all" entry before reject_always when present;
    -- otherwise append it at the end. Position-by-severity: reject_all (local)
    -- before reject_always (permanent).
    local merged_options = {}
    local reject_all_inserted = false
    for _, option in ipairs(options) do
        if
            AcpKind.normalise(option.kind) == "reject_always"
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

    local kind_keys = Config.keymaps.permission or {}

    for i, option in ipairs(merged_options) do
        local lhs = kind_keys[AcpKind.normalise(option.kind)]
        if not lhs or option_mapping[lhs] then
            lhs = "<localLeader>" .. i
        end
        table.insert(
            lines,
            string.format(
                "%s. %s %s",
                vim.fn.keytrans(vim.keycode(lhs)),
                Config.permission_icons[option.kind] or "",
                option.name
            )
        )
        option_mapping[lhs] = option.optionId
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
    -- A permission request arriving while `:`/`/` is held would otherwise
    -- show an unpainted float until CmdlineLeave; the float is not routed
    -- through MessageWriter's choke, so force the repaint here too.
    BufHelpers.redraw_if_cmdline()
end

--- Reapply the float's placement whenever any window is resized, including
--- by a resize of the editor.
--- @param anchor_winid integer Window the float is placed against
function PermissionFloat:_register_resize_watcher(anchor_winid)
    local id = vim.api.nvim_create_autocmd("WinResized", {
        callback = function()
            if
                not self._winid
                or not vim.api.nvim_win_is_valid(self._winid)
                or not vim.api.nvim_win_is_valid(anchor_winid)
            then
                return
            end
            pcall(
                vim.api.nvim_win_set_config,
                self._winid,
                self:_placement(anchor_winid)
            )
        end,
    })
    table.insert(self._autocmd_ids, id)
end

--- The float's position and size: at the configured corner of
--- `anchor_winid`.
--- @param anchor_winid integer
--- @return vim.api.keyset.win_config
function PermissionFloat:_placement(anchor_winid)
    local row, col = PermissionFloat._anchor_position(
        self._anchor,
        vim.api.nvim_win_get_width(anchor_winid),
        vim.api.nvim_win_get_height(anchor_winid),
        self._row_offset,
        self._col_offset
    )
    --- @type vim.api.keyset.win_config
    local placement = {
        relative = "win",
        win = anchor_winid,
        anchor = self._anchor,
        row = row,
        col = col,
        width = self._width,
        height = self._height,
    }
    return placement
end

--- Open the permission float listing `options` in order, replacing any open
--- float, and `place` it.
--- @param options agentic.acp.PermissionOption[]
--- @param anchor_bufnr? integer Buffer whose window the float anchors to (defaults to the main chat buffer)
--- @return table<string, string> option_mapping Option id by the key that selects it
function PermissionFloat:open(options, anchor_bufnr)
    self:close()

    local lines, option_mapping = build_lines(options)
    local cfg = Config.permission_float
    self:_render(self:_resolve_buffer(), lines)
    self._anchor = cfg.anchor
    self._width = cfg.width
    self._height = #lines
    self._row_offset = cfg.row_offset
    self._col_offset = cfg.col_offset
    self._anchor_bufnr = anchor_bufnr or self.message_writer.bufnr

    self:place()

    return option_mapping
end

--- Show the open float on a window showing its anchor buffer (see
--- `_find_anchor_winid`), or hide it while no window shows that buffer.
--- Never focusable. A no-op when no float is open or it is already where it
--- belongs.
function PermissionFloat:place()
    if not self._bufnr or not vim.api.nvim_buf_is_valid(self._bufnr) then
        return
    end
    local anchor_winid = self:_find_anchor_winid(self._anchor_bufnr)
    if self:is_shown() and self._anchor_winid == anchor_winid then
        return
    end
    self:_close_window()
    if not anchor_winid then
        return
    end

    local cfg = Config.permission_float
    local win_config = vim.tbl_extend("force", self:_placement(anchor_winid), {
        border = cfg.border,
        style = "minimal",
        focusable = false,
        noautocmd = true,
    })
    local ok, winid_or_err =
        pcall(vim.api.nvim_open_win, self._bufnr, false, win_config)
    if not ok then
        Logger.notify(
            "PermissionFloat: failed to open window: " .. tostring(winid_or_err),
            vim.log.levels.ERROR
        )
        return
    end

    self._winid = winid_or_err --[[@as integer]]
    self._anchor_winid = anchor_winid
    vim.wo[self._winid].winblend = cfg.winblend
    self:_register_resize_watcher(anchor_winid)
end

--- Whether the float's window is open, in any tab page.
--- @return boolean
function PermissionFloat:is_shown()
    return self._winid ~= nil and vim.api.nvim_win_is_valid(self._winid)
end

--- Whether the float is open in the current tabpage.
--- @return boolean
function PermissionFloat:is_visible_in_current_tab()
    return self:is_shown()
        and vim.api.nvim_win_get_tabpage(self._winid --[[@as integer]])
            == vim.api.nvim_get_current_tabpage()
end

--- Close the float's window and its watchers, keeping the buffer.
function PermissionFloat:_close_window()
    for _, id in ipairs(self._autocmd_ids) do
        pcall(vim.api.nvim_del_autocmd, id)
    end
    self._autocmd_ids = {}

    if self._winid and vim.api.nvim_win_is_valid(self._winid) then
        pcall(vim.api.nvim_win_close, self._winid, true)
    end
    self._winid = nil
    self._anchor_winid = nil
end

--- Close the float window and tear down associated state. Buffer deletion
--- is deferred via vim.schedule per the neovim skill's bufhidden=wipe
--- warning. Safe to call when already closed.
function PermissionFloat:close()
    self:_close_window()
    self._anchor_bufnr = nil

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

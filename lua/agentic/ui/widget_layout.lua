local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local BufHelpers = require("agentic.utils.buf_helpers")
local WindowDecoration = require("agentic.ui.window_decoration")
local Logger = require("agentic.utils.logger")

--- A panel that opens in the stack below the chat's home window.
--- @alias agentic.ui.ChatWidget.StackPanel "todos"|"code"|"files"|"diagnostics"|"activity"|"input"

--- @class agentic.ui.WidgetLayout
local WidgetLayout = {}

--- The window options of `nvim_open_win`'s `style = "minimal"`, except the
--- 'winhighlight' it sets. That style sets both the global and the local
--- value, so a buffer opened later in the window would keep them.
--- @return table<string, any>
local function minimal_win_opts()
    local opts = {
        number = false,
        relativenumber = false,
        cursorline = false,
        cursorcolumn = false,
        foldcolumn = "0",
        spell = false,
        list = false,
        signcolumn = "auto",
        colorcolumn = "",
        statuscolumn = "",
    }
    -- A local 'fillchars' replaces the global one whole: an item it leaves out
    -- takes its default, not the global value. So, as the style does, set one
    -- only to blank a visible `eob`.
    local fillchars = vim.opt_global.fillchars:get()
    if fillchars.eob ~= " " then
        fillchars.eob = " "
        local items = {}
        for name, char in pairs(fillchars) do
            table.insert(items, name .. ":" .. char)
        end
        opts.fillchars = table.concat(items, ",")
    end
    return opts
end

--- Window-local options for the input window.
--- @type table<string, any>
local INPUT_WIN_OPTS = {
    winfixheight = true,
    wrap = true,
    linebreak = true,
    conceallevel = 0,
}

--- Window-local options of each panel on top of `open_win`'s defaults.
--- @type table<agentic.ui.ChatWidget.StackPanel, table<string, any>>
local PANEL_WIN_OPTS = {
    -- The sign column carries the changed-since-last-viewed marks, and
    -- `open_win` would otherwise set it to `auto`.
    activity = { signcolumn = "yes:1" },
    input = INPUT_WIN_OPTS,
}

--- @param bufnr integer
--- @param enter boolean
--- @param opts vim.api.keyset.win_config
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param win_opts table<string, any>
--- @return integer
local function open_win(bufnr, enter, opts, window_name, win_opts)
    --- @type vim.api.keyset.win_config
    local default_opts = {
        split = "right",
        win = -1,
        noautocmd = true,
    }

    local config = vim.tbl_deep_extend("force", default_opts, opts)

    -- `noautocmd` would load an unloaded buffer (one left by `:bd`) without
    -- its `BufReadCmd`, which renders it.
    if not vim.api.nvim_buf_is_loaded(bufnr) then
        vim.fn.bufload(bufnr)
    end

    local winid = vim.api.nvim_open_win(bufnr, enter, config)

    local window_config = Config.windows[window_name] or {}
    local config_win_opts = window_config.win_opts or {}

    local merged_win_opts = vim.tbl_deep_extend(
        "force",
        minimal_win_opts(),
        { wrap = false, winfixheight = true },
        win_opts or {},
        config_win_opts
    )

    -- Local scope: a window split off this one inherits its global values, and
    -- passes them to every buffer it shows that set nothing of its own.
    for name, value in pairs(merged_win_opts) do
        vim.api.nvim_set_option_value(
            name,
            value,
            { win = winid, scope = "local" }
        )
    end

    return winid
end

--- Record `winid` as the widget's `name` window, and drop the handle when
--- that window closes, however it closes.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param name agentic.ui.ChatWidget.PanelNames
--- @param winid integer
local function track_window(win_nrs, name, winid)
    win_nrs[name] = winid
    vim.api.nvim_create_autocmd("WinClosed", {
        pattern = tostring(winid),
        once = true,
        callback = function()
            if win_nrs[name] == winid then
                win_nrs[name] = nil
            end
        end,
    })
end

--- The window in the `panel` slot of `win_nrs`, while it shows the widget's
--- `panel` buffer.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @return integer|nil winid Nil while the slot is empty, closed, or shows another buffer
function WidgetLayout.panel_win(win_nrs, buf_nrs, panel)
    local winid = win_nrs[panel]
    if
        not winid
        or not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= buf_nrs[panel]
    then
        return nil
    end
    return winid
end

--- The line count of a buffer plus `padding`, at most `max_height`.
--- @param bufnr integer
--- @param max_height integer
--- @param padding integer
--- @return integer
local function calculate_dynamic_height(bufnr, max_height, padding)
    return math.min(
        vim.api.nvim_buf_line_count(bufnr) + padding,
        math.max(1, max_height)
    )
end

--- The height of the `panel` window: the configured height for the input,
--- else fitted to its buffer.
--- @param bufnr integer The panel's buffer
--- @param panel agentic.ui.ChatWidget.StackPanel
--- @return integer
local function panel_height(bufnr, panel)
    if panel == "input" then
        return Config.windows.input.height
    end
    local padding = panel == "todos" and 0 or 1
    return calculate_dynamic_height(
        bufnr,
        Config.windows[panel].max_height,
        padding
    )
end

--- Check that `Config.windows.stack` lists every StackPanel exactly once.
--- Otherwise notify and reset it to the default.
function WidgetLayout.validate_stack()
    local expected = DefaultConfig.windows.stack
    local function sorted(list)
        local copy = vim.deepcopy(list)
        table.sort(copy, function(a, b)
            return tostring(a) < tostring(b)
        end)
        return copy
    end

    local stack = Config.windows.stack
    if
        type(stack) == "table" and vim.deep_equal(sorted(stack), sorted(expected))
    then
        return
    end
    Logger.notify(
        "windows.stack must list each of "
            .. table.concat(expected, ", ")
            .. " exactly once; using the default order.",
        vim.log.levels.WARN,
        { title = "Agentic" }
    )
    Config.windows.stack = vim.deepcopy(expected)
end

--- Where `panel` opens: above the nearest open panel after it in `stack`,
--- else below the nearest open panel before it, else below `home`.
--- @param stack agentic.ui.ChatWidget.StackPanel[]
--- @param open_wins table<agentic.ui.ChatWidget.StackPanel, integer> Open panel windows
--- @param panel agentic.ui.ChatWidget.StackPanel
--- @param home integer The window the stack hangs below
--- @return { win: integer, split: "above"|"below" }
function WidgetLayout.split_target(stack, open_wins, panel, home)
    local index = 0
    for i, name in ipairs(stack) do
        if name == panel then
            index = i
        end
    end
    for i = index + 1, #stack do
        if open_wins[stack[i]] then
            return { win = open_wins[stack[i]], split = "above" }
        end
    end
    for i = index - 1, 1, -1 do
        if open_wins[stack[i]] then
            return { win = open_wins[stack[i]], split = "below" }
        end
    end
    return { win = home, split = "below" }
end

--- Open `panel` in its `Config.windows.stack` position among the open panels
--- below `home`, and track it in `win_nrs`. Notifies a failed split (E36, a
--- floating `home`).
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param home integer The window the stack hangs below
--- @param panel agentic.ui.ChatWidget.StackPanel
--- @return integer|nil winid The panel's window, already open or new. Nil when the split fails.
function WidgetLayout.open_panel(win_nrs, buf_nrs, home, panel)
    local open = WidgetLayout.panel_win(win_nrs, buf_nrs, panel)
    if open then
        return open
    end

    local stack = Config.windows.stack
    --- @type table<agentic.ui.ChatWidget.StackPanel, integer>
    local open_wins = {}
    for _, name in ipairs(stack) do
        open_wins[name] = WidgetLayout.panel_win(win_nrs, buf_nrs, name)
    end
    local target = WidgetLayout.split_target(stack, open_wins, panel, home)

    local bufnr = buf_nrs[panel]
    local ok, result = pcall(open_win, bufnr, false, {
        win = target.win,
        split = target.split,
        height = panel_height(bufnr, panel),
    }, panel, PANEL_WIN_OPTS[panel] or {})
    if not ok then
        Logger.notify(
            string.format(
                "Cannot open the %s panel: %s",
                panel,
                tostring(result)
            ),
            vim.log.levels.ERROR,
            { title = "Agentic" }
        )
        return nil
    end
    track_window(win_nrs, panel, result)
    WindowDecoration.render_header(bufnr)
    return result
end

--- Fit the open `panel` window to its buffer. No-op when it is closed.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param panel agentic.ui.ChatWidget.StackPanel
function WidgetLayout.resize_panel(win_nrs, buf_nrs, panel)
    local winid = WidgetLayout.panel_win(win_nrs, buf_nrs, panel)
    if winid then
        vim.api.nvim_win_set_height(winid, panel_height(buf_nrs[panel], panel))
    end
end

--- Fit a content panel to its buffer: closed when the buffer is empty, else
--- open below `home` and sized to the buffer.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param home integer The window the stack hangs below
--- @param panel agentic.ui.ChatWidget.StackPanel
function WidgetLayout.sync_panel(win_nrs, buf_nrs, home, panel)
    if BufHelpers.is_buffer_empty(buf_nrs[panel]) then
        WidgetLayout.close_panel(win_nrs, buf_nrs, panel)
    elseif WidgetLayout.panel_win(win_nrs, buf_nrs, panel) then
        WidgetLayout.resize_panel(win_nrs, buf_nrs, panel)
    else
        WidgetLayout.open_panel(win_nrs, buf_nrs, home, panel)
    end
end

--- Close the `panel` window and empty its slot, leaving open a slot window
--- that shows another buffer.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param panel agentic.ui.ChatWidget.PanelNames
function WidgetLayout.close_panel(win_nrs, buf_nrs, panel)
    local winid = WidgetLayout.panel_win(win_nrs, buf_nrs, panel)
    if winid then
        vim.api.nvim_win_close(winid, true)
    end
    win_nrs[panel] = nil
end

--- Open an input buffer in a split below the current window, outside any
--- widget's panel slots.
--- @param input_buf integer
--- @return integer winid
function WidgetLayout.open_input_below(input_buf)
    local winid = open_win(input_buf, false, {
        win = 0,
        split = "below",
        height = Config.windows.input.height,
    }, "input", INPUT_WIN_OPTS)
    WindowDecoration.render_header(input_buf)
    return winid
end

--- The window in the current tabpage showing an input buffer, opening one
--- below the current window when there is none.
--- @param input_buf integer
--- @return integer winid
function WidgetLayout.input_win(input_buf)
    local winid = vim.fn.bufwinid(input_buf)
    if winid == -1 then
        winid = WidgetLayout.open_input_below(input_buf)
    end
    return winid
end

--- @alias agentic.ui.OpenHow "edit"|"split"|"vsplit"|"tab"

--- Open a buffer as the commands of the same name would, and focus its
--- window. "tab" opens a new last tabpage.
--- @param bufnr integer
--- @param how agentic.ui.OpenHow
--- @param edit_win integer|nil The window "edit" replaces; nil falls back to "split"
--- @return integer winid
function WidgetLayout.open_buf(bufnr, how, edit_win)
    if how == "edit" and edit_win then
        vim.api.nvim_win_set_buf(edit_win, bufnr)
        vim.api.nvim_set_current_win(edit_win)
        return edit_win
    end
    vim.cmd.sbuffer({
        args = { bufnr },
        mods = {
            vertical = how == "vsplit",
            tab = how == "tab" and #vim.api.nvim_list_tabpages() or nil,
        },
    })
    return vim.api.nvim_get_current_win()
end

--- Close the panel windows and empty every slot, leaving open a slot window
--- that shows another buffer.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
function WidgetLayout.close(win_nrs, buf_nrs)
    for name in pairs(win_nrs) do
        WidgetLayout.close_panel(win_nrs, buf_nrs, name)
    end
end

return WidgetLayout

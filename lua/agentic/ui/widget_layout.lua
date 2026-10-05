local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local BufHelpers = require("agentic.utils.buf_helpers")
local ChatBuffer = require("agentic.ui.chat_buffer")
local WindowDecoration = require("agentic.ui.window_decoration")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.WidgetLayout.Params
--- @field tab_page_id integer
--- @field buf_nrs agentic.ui.ChatWidget.BufNrs
--- @field win_nrs agentic.ui.ChatWidget.WinNrs
--- @field focus_prompt? boolean
--- @field position? agentic.UserConfig.Windows.Position Override `Config.windows.position` for this open. `"tab"` is handled at the `Agentic.*` dispatch level and never reaches here.

--- @class agentic.ui.WidgetLayout
local WidgetLayout = {}

--- @param size number|string
--- @param max_dimension integer
--- @param default_percentage number|string
--- @return integer
local function calculate_dimension(size, max_dimension, default_percentage)
    size = size or default_percentage

    if type(size) == "string" then
        local pct = string.sub(size, -1) == "%"
            and tonumber(string.sub(size, 1, -2))
        if not pct then
            -- Invalid string without % sign, fallback to default percentage
            Logger.notify(
                "Invalid size string: "
                    .. size
                    .. ", expected format like '40%'",
                vim.log.levels.WARN
            )

            return calculate_dimension(
                default_percentage,
                max_dimension,
                default_percentage
            )
        end
        return math.max(1, math.floor(max_dimension * pct / 100))
    end

    if size > 0 and size < 1 then
        return math.max(1, math.floor(max_dimension * size))
    end

    return math.max(1, math.floor(size))
end

--- @param size number|string
--- @return integer
function WidgetLayout.calculate_width(size)
    return calculate_dimension(size, vim.o.columns, DefaultConfig.windows.width)
end

--- @param size number|string
--- @return integer
function WidgetLayout.calculate_height(size)
    return calculate_dimension(size, vim.o.lines, DefaultConfig.windows.height)
end

--- @param bufnr integer
--- @param max_height integer
--- @param padding? integer Override default padding (1 for side, 2 for bottom)
--- @return integer
local function calculate_dynamic_height(bufnr, max_height, padding)
    max_height = math.max(1, max_height)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if padding == nil then
        -- Use 2 in bottom layout to prevent the file list from touching the screen edge
        padding = Config.windows.position == "bottom" and 2 or 1
    end
    return math.min(line_count + padding, max_height)
end

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

--- Whether `bufnr` is a `panel` buffer of the widget whose buffers are
--- `buf_nrs`: `buf_nrs[panel]` itself, or, for a panel with no buffer there,
--- any buffer marked as that panel of the chat's session. The subagent panel
--- is such a slot: it shows any of the session's transcripts.
--- @param bufnr integer
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @return boolean
local function is_panel_buf(bufnr, buf_nrs, panel)
    if buf_nrs[panel] then
        return bufnr == buf_nrs[panel]
    end
    local chat = buf_nrs.chat
    return chat ~= nil
        and vim.b[bufnr].agentic_window == panel
        and vim.b[bufnr].agentic_session_id == vim.b[chat].agentic_session_id
end

--- The window in the `panel` slot of `win_nrs`, while it shows one of the
--- widget's `panel` buffers.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param panel agentic.ui.ChatWidget.PanelNames
--- @return integer|nil winid Nil while the slot is empty, closed, or shows another buffer
function WidgetLayout.panel_win(win_nrs, buf_nrs, panel)
    local winid = win_nrs[panel]
    if
        not winid
        or not vim.api.nvim_win_is_valid(winid)
        or not is_panel_buf(vim.api.nvim_win_get_buf(winid), buf_nrs, panel)
    then
        return nil
    end
    return winid
end

--- @param params agentic.ui.WidgetLayout.Params
--- @param panel_name agentic.ui.ChatWidget.PanelNames
--- @param open_opts vim.api.keyset.win_config
--- @param win_opts table<string, any>
--- @return integer
local function get_or_create_window(params, panel_name, open_opts, win_opts)
    local win_nrs = params.win_nrs
    local cached_winid =
        WidgetLayout.panel_win(win_nrs, params.buf_nrs, panel_name)
    if cached_winid then
        return cached_winid
    end

    local bufnr = params.buf_nrs[panel_name]
    local new_winid =
        open_win(bufnr, false, open_opts, panel_name, win_opts or {})
    track_window(win_nrs, panel_name, new_winid)
    WindowDecoration.render_header(bufnr)
    return new_winid
end

--- @param params agentic.ui.WidgetLayout.Params
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param open_win_opts vim.api.keyset.win_config
--- @param max_height integer
--- @param padding? integer Override default padding for height calculation
local function open_or_resize_dynamic_window(
    params,
    window_name,
    open_win_opts,
    max_height,
    padding
)
    local win_nrs = params.win_nrs
    local bufnr = params.buf_nrs[window_name]
    local winid = WidgetLayout.panel_win(win_nrs, params.buf_nrs, window_name)

    if BufHelpers.is_buffer_empty(bufnr) then
        if winid then
            pcall(vim.api.nvim_win_close, winid, true)
        end
        win_nrs[window_name] = nil
        return
    end

    local height = calculate_dynamic_height(bufnr, max_height, padding)

    if not winid then
        open_win_opts.height = height
        track_window(
            win_nrs,
            window_name,
            open_win(bufnr, false, open_win_opts, window_name, {})
        )
    else
        vim.api.nvim_win_set_config(winid, { height = height })
    end

    WindowDecoration.render_header(bufnr)
end

--- Window-local options for the widget's `chat` and `subagent` windows: the
--- chat window options plus the widget's fixed size.
--- @param is_bottom boolean
--- @return table<string, any>
local function chat_win_opts(is_bottom)
    return vim.tbl_extend("force", ChatBuffer.win_opts(), {
        winfixheight = is_bottom,
        winfixwidth = not is_bottom,
    })
end

--- Window-local options for the input window.
--- @param is_bottom boolean
--- @return table<string, any>
local function input_win_opts(is_bottom)
    return {
        winfixheight = not is_bottom,
        wrap = true,
        linebreak = true,
        conceallevel = 0,
    }
end

--- Open or resize the widget windows in the current tabpage.
--- @param params agentic.ui.WidgetLayout.Params
--- @param position agentic.UserConfig.Windows.Position
--- @param should_focus boolean Move the cursor to the input window
local function show_layout(params, position, should_focus)
    local is_bottom = position == "bottom"
    local win_nrs = params.win_nrs

    local split_direction = is_bottom and "below"
        or (position == "left" and "left" or "right")

    --- @type vim.api.keyset.win_config
    local chat_opts = {
        win = -1,
        split = split_direction,
    }

    if is_bottom then
        chat_opts.height = WidgetLayout.calculate_height(Config.windows.height)
    else
        chat_opts.width = WidgetLayout.calculate_width(Config.windows.width)
    end

    get_or_create_window(params, "chat", chat_opts, chat_win_opts(is_bottom))

    -- Input window: right splits below chat with height, bottom splits right
    -- of chat with computed stack width
    --- @type vim.api.keyset.win_config
    local input_opts = { win = win_nrs.chat, fixed = true }
    if is_bottom then
        local chat_width = vim.api.nvim_win_get_width(win_nrs.chat)
        local ratio = tonumber(Config.windows.stack_width_ratio) or 0.4
        local raw_width = math.floor(chat_width * ratio)
        input_opts.split = "right"
        input_opts.width = math.max(1, math.min(raw_width, chat_width - 1))
    else
        input_opts.split = "below"
        input_opts.height = Config.windows.input.height
    end

    get_or_create_window(params, "input", input_opts, input_win_opts(is_bottom))

    -- Each slot laid out so far holds its panel's window or nil, so the
    -- anchors below read `win_nrs` directly.
    local padding = is_bottom and 2 or 1

    open_or_resize_dynamic_window(params, "code", {
        win = is_bottom and win_nrs.input or win_nrs.chat,
        split = "below",
    }, Config.windows.code.max_height, padding)

    local ref_win = is_bottom and (win_nrs.code or win_nrs.input)
        or win_nrs.input

    open_or_resize_dynamic_window(params, "files", {
        win = ref_win,
        split = is_bottom and "below" or "above",
    }, Config.windows.files.max_height, padding)

    ref_win = is_bottom and (win_nrs.files or win_nrs.code or win_nrs.input)
        or win_nrs.input

    open_or_resize_dynamic_window(params, "diagnostics", {
        win = ref_win,
        split = is_bottom and "below" or "above",
    }, Config.windows.diagnostics.max_height, padding)

    if Config.windows.todos.display then
        ref_win = is_bottom
                and (win_nrs.diagnostics or win_nrs.files or win_nrs.code or win_nrs.input)
            or win_nrs.chat

        open_or_resize_dynamic_window(params, "todos", {
            win = ref_win,
            split = "below",
        }, Config.windows.todos.max_height, 0)
    end

    if should_focus then
        vim.schedule(function()
            local winid =
                WidgetLayout.panel_win(win_nrs, params.buf_nrs, "input")
            if winid then
                vim.api.nvim_set_current_win(winid)
                vim.cmd("normal! G$")
            end
        end)
    end
end

--- Open an input buffer in a split below the current window, apart from any
--- widget layout.
--- @param input_buf integer
--- @return integer winid
function WidgetLayout.open_input_below(input_buf)
    local winid = open_win(input_buf, false, {
        win = 0,
        split = "below",
        height = Config.windows.input.height,
    }, "input", input_win_opts(false))
    WindowDecoration.render_header(input_buf)
    return winid
end

--- @param params agentic.ui.WidgetLayout.Params
function WidgetLayout.open(params)
    if
        not params.tab_page_id
        or not vim.api.nvim_tabpage_is_valid(params.tab_page_id)
    then
        Logger.notify(
            "Invalid tab_page_id in WidgetLayout.open: "
                .. tostring(params.tab_page_id),
            vim.log.levels.ERROR
        )
        return
    end

    local position = params.position or Config.windows.position

    if position == "tab" then
        position = "right"
    elseif
        position ~= "right"
        and position ~= "left"
        and position ~= "bottom"
    then
        Logger.notify(
            "Invalid windows.position config: "
                .. tostring(position)
                .. ', falling back to "right"',
            vim.log.levels.ERROR
        )

        position = "right"
    end

    local tab = params.tab_page_id
    local ok, err
    if tab == vim.api.nvim_get_current_tabpage() then
        ok, err =
            pcall(show_layout, params, position, params.focus_prompt ~= false)
    else
        -- `win = -1` splits the current tabpage, so lay out from inside the
        -- widget's own; never pull focus across tabpages.
        ok, err = pcall(
            vim.api.nvim_win_call,
            vim.api.nvim_tabpage_get_win(tab),
            function()
                show_layout(params, position, false)
            end
        )
    end
    if not ok then
        Logger.notify(
            string.format(
                "Failed to show %s layout (tab: %d): %s",
                position,
                params.tab_page_id,
                tostring(err)
            ),
            vim.log.levels.ERROR
        )
    end
end

--- Close the panel windows and empty every slot, leaving open a slot window
--- that shows another buffer.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
function WidgetLayout.close(win_nrs, buf_nrs)
    for name in pairs(win_nrs) do
        local winid = WidgetLayout.panel_win(win_nrs, buf_nrs, name)
        win_nrs[name] = nil
        if winid then
            local ok, err = pcall(vim.api.nvim_win_close, winid, true)
            if not ok then
                Logger.debug(
                    string.format(
                        "Failed to close window '%s' with id %d: %s",
                        name,
                        winid,
                        tostring(err)
                    )
                )
            end
        end
    end
end

--- Show `bufnr` in the subagent window. A closed one opens as a split beside
--- the chat window, with the chat's window options. No-op while the chat
--- window is not visible. An open one switches buffer with autocmds, so the
--- buffer's `BufWinEnter` runs.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param bufnr integer
function WidgetLayout.show_subagent(win_nrs, buf_nrs, bufnr)
    local subagent_winid = WidgetLayout.panel_win(win_nrs, buf_nrs, "subagent")
    if subagent_winid then
        vim.api.nvim_win_set_buf(subagent_winid, bufnr)
        return
    end

    local chat_winid = WidgetLayout.panel_win(win_nrs, buf_nrs, "chat")
    if not chat_winid then
        return
    end

    local is_bottom = Config.windows.position == "bottom"
    local chat_width = vim.api.nvim_win_get_width(chat_winid)
    local width = calculate_dimension(
        Config.windows.subagent.width,
        chat_width,
        DefaultConfig.windows.subagent.width
    )
    width = math.max(1, math.min(width, chat_width - 1))

    -- The chat's options, so tool-call blocks and folds render identically.
    -- The subagent is always a vertical (`right`) split, so its width must be
    -- fixed regardless of the chat's orientation — chat_win_opts leaves
    -- winfixwidth false in bottom layout (where the chat itself fixes height).
    local win_opts = chat_win_opts(is_bottom)
    win_opts.winfixwidth = true

    track_window(
        win_nrs,
        "subagent",
        open_win(
            bufnr,
            false,
            { win = chat_winid, split = "right", width = width },
            "subagent",
            win_opts
        )
    )
    WindowDecoration.render_header(bufnr)
end

--- Open the file activity panel next to the prompt, sized to its content.
---
--- Deliberately not on the `open_or_resize_dynamic_window` path the other list
--- panels use. That helper derives the window's existence from the buffer —
--- empty closes it, non-empty opens it — and runs inside `show_layout`, i.e. on
--- every `ChatWidget:show()`. A tally on that path would force itself open the
--- moment the agent touches a file and shut again whenever the list is empty,
--- which is the opposite of a toggle. `show_layout` never touches this window,
--- so an imperative open survives re-layout.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
function WidgetLayout.open_activity(win_nrs, buf_nrs)
    if WidgetLayout.panel_win(win_nrs, buf_nrs, "activity") then
        return
    end

    local anchor = WidgetLayout.panel_win(win_nrs, buf_nrs, "input")
    if not anchor then
        return
    end

    local is_bottom = Config.windows.position == "bottom"
    local bufnr = buf_nrs.activity
    local height = calculate_dynamic_height(
        bufnr,
        Config.windows.activity.max_height,
        is_bottom and 2 or 1
    )

    -- The sign column carries the changed-since-last-viewed marks, and
    -- `open_win` would otherwise set it to `auto`.
    track_window(
        win_nrs,
        "activity",
        open_win(bufnr, false, {
            win = anchor,
            split = is_bottom and "below" or "above",
            height = height,
        }, "activity", { signcolumn = "yes:1" })
    )
    WindowDecoration.render_header(buf_nrs.activity)
end

--- Resize the activity panel to its current content. No-op when closed.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
function WidgetLayout.resize_activity(win_nrs, buf_nrs)
    local winid = WidgetLayout.panel_win(win_nrs, buf_nrs, "activity")
    if not winid then
        return
    end

    vim.api.nvim_win_set_config(winid, {
        height = calculate_dynamic_height(
            buf_nrs.activity,
            Config.windows.activity.max_height,
            Config.windows.position == "bottom" and 2 or 1
        ),
    })
end

--- Close the `window_name` panel window and empty its slot, leaving open a
--- slot window that shows another buffer.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
function WidgetLayout.close_optional_window(win_nrs, buf_nrs, window_name)
    local winid = WidgetLayout.panel_win(win_nrs, buf_nrs, window_name)

    -- Capture chat height before closing so we can restore it.
    -- In bottom layout, Neovim redistributes freed height to siblings.
    local chat_winid = WidgetLayout.panel_win(win_nrs, buf_nrs, "chat")
    local chat_height = nil
    if Config.windows.position == "bottom" and chat_winid then
        chat_height = vim.api.nvim_win_get_height(chat_winid)
    end

    if winid then
        pcall(vim.api.nvim_win_close, winid, true)
    end
    win_nrs[window_name] = nil

    -- Restore chat height when in bottom layout, since closing a sibling window redistributes height.
    if chat_height then
        ---@cast chat_winid integer if we have height, then chat_winid must be valid integer
        vim.api.nvim_win_set_config(chat_winid, { height = chat_height })
    end
end

return WidgetLayout

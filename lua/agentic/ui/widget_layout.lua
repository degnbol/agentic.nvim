local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local BufHelpers = require("agentic.utils.buf_helpers")
local WindowDecoration = require("agentic.ui.window_decoration")
local Logger = require("agentic.utils.logger")
local Theme = require("agentic.theme")

-- Tone down markdown heading highlights in the chat window only. The markdown
-- highlighter captures `@markup.heading.N` over the whole heading line (the
-- only capture covering the `##`/`###` marker) and `@text.titleN` over just
-- the text after the marker — and `@text.titleN` wins on the overlap. So dim
-- the marker (→ AgenticHeading) while leaving the heading text neutral
-- (→ Normal). The tool-call name is a markdown_inline code span (`@markup.raw`)
-- that wins over both and keeps its own colour. Levels 2 (## prompt) and 3
-- (### tool call) are the only heading levels the writer emits. Scoping this to
-- the chat window (rather than nvim_set_hl globally) leaves real markdown
-- buffers untouched.
local CHAT_WINHIGHLIGHT = table.concat({
    "@markup.heading.2.agentic:" .. Theme.HL_GROUPS.HEADING,
    "@markup.heading.3.agentic:" .. Theme.HL_GROUPS.HEADING,
    "@text.title2.agentic:Normal",
    "@text.title3.agentic:Normal",
}, ",")

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
        style = "minimal",
    }

    local config = vim.tbl_deep_extend("force", default_opts, opts)

    local winid = vim.api.nvim_open_win(bufnr, enter, config)

    local window_config = Config.windows[window_name] or {}
    local config_win_opts = window_config.win_opts or {}

    local merged_win_opts = vim.tbl_deep_extend("force", {
        wrap = false,
        winfixbuf = true,
        winfixheight = true,
    }, win_opts or {}, config_win_opts)

    for name, value in pairs(merged_win_opts) do
        vim.api.nvim_set_option_value(name, value, { win = winid })
    end

    return winid
end

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param panel_name string
--- @param bufnr integer
--- @param open_opts vim.api.keyset.win_config
--- @param win_opts table<string, any>
--- @return integer
local function get_or_create_window(
    win_nrs,
    panel_name,
    bufnr,
    open_opts,
    win_opts
)
    local cached_winid = win_nrs[panel_name]
    if cached_winid and vim.api.nvim_win_is_valid(cached_winid) then
        return cached_winid
    end

    local new_winid =
        open_win(bufnr, false, open_opts, panel_name, win_opts or {})
    win_nrs[panel_name] = new_winid
    WindowDecoration.render_header(bufnr, panel_name)
    return new_winid
end

--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
--- @param open_win_opts vim.api.keyset.win_config
--- @param max_height integer
--- @param padding? integer Override default padding for height calculation
local function open_or_resize_dynamic_window(
    buf_nrs,
    win_nrs,
    window_name,
    open_win_opts,
    max_height,
    padding
)
    local bufnr = buf_nrs[window_name]
    local winid = win_nrs[window_name]

    if BufHelpers.is_buffer_empty(bufnr) then
        if winid and vim.api.nvim_win_is_valid(winid) then
            pcall(vim.api.nvim_win_close, winid, true)
        end
        win_nrs[window_name] = nil
        return
    end

    local height = calculate_dynamic_height(bufnr, max_height, padding)

    if not winid or not vim.api.nvim_win_is_valid(winid) then
        open_win_opts.height = height
        win_nrs[window_name] =
            open_win(bufnr, false, open_win_opts, window_name, {})
    else
        vim.api.nvim_win_set_config(winid, { height = height })
    end

    WindowDecoration.render_header(bufnr, window_name)
end

--- Window-local options for a chat-style scrolling buffer (folds, conceal,
--- signcolumn). Shared by the main `chat` window and the `subagent` split so
--- both render tool-call blocks and folds identically.
--- @param is_bottom boolean
--- @return table<string, any>
local function chat_win_opts(is_bottom)
    return {
        scrolloff = 4,
        winfixheight = is_bottom,
        winfixwidth = not is_bottom,
        signcolumn = "yes:1",
        foldmethod = "expr",
        foldexpr = 'v:lua.require("agentic.ui.folds").foldexpr()',
        foldenable = true,
        -- Set foldlevel high so nothing auto-closes: `*-fold` blocks default
        -- open and the writer closes them imperatively via :foldclose. This
        -- must be set explicitly — a new window inherits window-local foldlevel
        -- from the window it splits off, NOT the global default, so opening
        -- Agentic from a window with a low foldlevel would otherwise collapse
        -- every block.
        foldlevel = 99,
        -- Same inheritance hazard as foldlevel: `agentic.ui.folds` drops
        -- one-line bodies on the assumption vim could not close them anyway,
        -- which only holds at 1.
        foldminlines = 1,
        foldcolumn = "0",
        conceallevel = 2,
        concealcursor = "n",
        foldtext = 'v:lua.require("agentic.ui.folds").foldtext()',
        winhighlight = CHAT_WINHIGHLIGHT,
    }
end

--- @param params agentic.ui.WidgetLayout.Params
--- @param position agentic.UserConfig.Windows.Position
local function show_layout(params, position)
    local is_bottom = position == "bottom"
    local win_nrs = params.win_nrs
    local buf_nrs = params.buf_nrs
    local should_focus = (
        params.focus_prompt == nil and true or params.focus_prompt
    ) == true

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

    get_or_create_window(
        win_nrs,
        "chat",
        buf_nrs.chat,
        chat_opts,
        chat_win_opts(is_bottom)
    )

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

    get_or_create_window(win_nrs, "input", buf_nrs.input, input_opts, {
        winfixheight = not is_bottom,
        wrap = true,
        linebreak = true,
        conceallevel = 0,
    })

    local padding = is_bottom and 2 or 1

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "code", {
        win = is_bottom and win_nrs.input or win_nrs.chat,
        split = "below",
    }, Config.windows.code.max_height, padding)

    local ref_win = is_bottom and (win_nrs.code or win_nrs.input)
        or win_nrs.input

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "files", {
        win = ref_win,
        split = is_bottom and "below" or "above",
    }, Config.windows.files.max_height, padding)

    ref_win = is_bottom and (win_nrs.files or win_nrs.code or win_nrs.input)
        or win_nrs.input

    open_or_resize_dynamic_window(buf_nrs, win_nrs, "diagnostics", {
        win = ref_win,
        split = is_bottom and "below" or "above",
    }, Config.windows.diagnostics.max_height, padding)

    if Config.windows.todos.display then
        ref_win = is_bottom
                and (win_nrs.diagnostics or win_nrs.files or win_nrs.code or win_nrs.input)
            or win_nrs.chat

        open_or_resize_dynamic_window(buf_nrs, win_nrs, "todos", {
            win = ref_win,
            split = "below",
        }, Config.windows.todos.max_height, 0)
    end

    if should_focus then
        vim.schedule(function()
            local winid = win_nrs.input
            if winid and vim.api.nvim_win_is_valid(winid) then
                vim.api.nvim_set_current_win(winid)
                vim.cmd("normal! G$")
            end
        end)
    end
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

    local ok, err = pcall(show_layout, params, position)
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

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
function WidgetLayout.close(win_nrs)
    for name, winid in pairs(win_nrs) do
        win_nrs[name] = nil
        local ok = pcall(vim.api.nvim_win_close, winid, true)
        if not ok then
            Logger.debug(
                string.format(
                    "Failed to close window '%s' with id: %d",
                    name,
                    winid
                )
            )
        end
    end
end

--- Open the subagent split beside the chat window, reusing the chat window
--- options so it renders tool-call blocks and folds identically. No-op when
--- already open or when the chat window is not visible.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
function WidgetLayout.open_subagent(win_nrs, buf_nrs)
    local existing = win_nrs.subagent
    if existing and vim.api.nvim_win_is_valid(existing) then
        return
    end

    local chat_winid = win_nrs.chat
    if not chat_winid or not vim.api.nvim_win_is_valid(chat_winid) then
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

    -- The subagent is always a vertical (`right`) split, so its width must be
    -- fixed regardless of the chat's orientation — chat_win_opts leaves
    -- winfixwidth false in bottom layout (where the chat itself fixes height).
    local win_opts = chat_win_opts(is_bottom)
    win_opts.winfixwidth = true

    win_nrs.subagent = open_win(
        buf_nrs.subagent,
        false,
        { win = chat_winid, split = "right", width = width },
        "subagent",
        win_opts
    )
    WindowDecoration.render_header(buf_nrs.subagent, "subagent")
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
    local existing = win_nrs.activity
    if existing and vim.api.nvim_win_is_valid(existing) then
        return
    end

    local anchor = win_nrs.input
    if not anchor or not vim.api.nvim_win_is_valid(anchor) then
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
    -- `style = "minimal"` in `open_win` would otherwise force it off.
    win_nrs.activity = open_win(bufnr, false, {
        win = anchor,
        split = is_bottom and "below" or "above",
        height = height,
    }, "activity", { signcolumn = "yes:1" })
    WindowDecoration.render_header(buf_nrs.activity, "activity")
end

--- Resize the activity panel to its current content. No-op when closed.
--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param buf_nrs agentic.ui.ChatWidget.BufNrs
function WidgetLayout.resize_activity(win_nrs, buf_nrs)
    local winid = win_nrs.activity
    if not winid or not vim.api.nvim_win_is_valid(winid) then
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

--- @param win_nrs agentic.ui.ChatWidget.WinNrs
--- @param window_name agentic.ui.ChatWidget.PanelNames
function WidgetLayout.close_optional_window(win_nrs, window_name)
    local winid = win_nrs[window_name]

    -- Capture chat height before closing so we can restore it.
    -- In bottom layout, Neovim redistributes freed height to siblings.
    local chat_winid = win_nrs.chat
    local chat_height = nil
    if
        Config.windows.position == "bottom"
        and chat_winid
        and vim.api.nvim_win_is_valid(chat_winid)
    then
        chat_height = vim.api.nvim_win_get_height(chat_winid)
    end

    if winid and vim.api.nvim_win_is_valid(winid) then
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

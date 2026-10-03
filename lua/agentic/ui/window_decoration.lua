--- Window decoration: per-buffer header state, the winbars it renders, and
--- buffer naming.

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.WindowDecoration
local WindowDecoration = {}

--- @type agentic.ui.ChatWidget.Headers
local WINDOW_HEADERS = {
    chat = {
        title = "󰻞 Agentic Chat",
    },
    subagent = {
        title = "󰚩 Subagents",
    },
    input = { title = "󰦨 Prompt" },
    code = {
        title = "󰪸 Selected Code Snippets",
    },
    files = {
        title = " File Injections",
    },
    diagnostics = {
        title = " Diagnostics",
    },
    activity = {
        title = " Files",
    },
    todos = {
        title = " Tasks list",
    },
}

--- Concatenates header parts (title, badge, context) into a single string
--- @param parts agentic.ui.ChatWidget.HeaderParts
--- @return string header_text
local function concat_header_parts(parts)
    local title = parts.title
    if parts.badge then
        title = title .. " " .. parts.badge
    end
    local pieces = { title }
    if parts.context ~= nil then
        table.insert(pieces, parts.context)
    end
    return table.concat(pieces, " | ")
end

--- The header state of an Agentic buffer, `vim.b[bufnr].agentic_header`, or
--- its panel's default when none is set. A copy: write it back with
--- `set_header`.
--- @param bufnr integer
--- @return agentic.ui.ChatWidget.HeaderParts
function WindowDecoration.get_header(bufnr)
    return vim.b[bufnr].agentic_header
        or vim.deepcopy(WINDOW_HEADERS[vim.b[bufnr].agentic_window])
        or { title = "" }
end

--- Store an Agentic buffer's header state, announce it with the
--- `AgenticHeadersChanged` User autocmd, and render it.
--- @param bufnr integer
--- @param header agentic.ui.ChatWidget.HeaderParts
function WindowDecoration.set_header(bufnr, header)
    vim.b[bufnr].agentic_header = header
    vim.api.nvim_exec_autocmds("User", {
        pattern = "AgenticHeadersChanged",
        data = { buf = bufnr },
    })
    WindowDecoration.render_header(bufnr)
end

--- Resolves the final header text applying user customization
--- Returns the header text and an error message if user function failed
--- @param dynamic_header agentic.ui.ChatWidget.HeaderParts Runtime header parts
--- @param window_name string Window name for Config.headers lookup and error messages
--- @return string|nil header_text The resolved header text or nil for empty
--- @return string|nil error_message Error message if user function failed
local function resolve_header_text(dynamic_header, window_name)
    local user_header = Config.headers and Config.headers[window_name]
    -- No user customization: use default parts
    if user_header == nil then
        return concat_header_parts(dynamic_header), nil
    end

    -- User function: call it and validate return
    if type(user_header) == "function" then
        local ok, result = pcall(user_header, dynamic_header)
        if not ok then
            return concat_header_parts(dynamic_header),
                string.format(
                    "Error in custom header function for '%s': %s",
                    window_name,
                    result
                )
        end
        if result == nil or result == "" then
            return nil, nil -- User explicitly wants no header
        end
        if type(result) ~= "string" then
            return concat_header_parts(dynamic_header),
                string.format(
                    "Custom header function for '%s' must return string|nil, got %s",
                    window_name,
                    type(result)
                )
        end
        return result, nil
    end

    -- User table: merge with dynamic header
    if type(user_header) == "table" then
        local merged = vim.tbl_extend("force", dynamic_header, user_header) --[[@as agentic.ui.ChatWidget.HeaderParts]]
        return concat_header_parts(merged), nil
    end

    -- Invalid type: warn and use default
    return concat_header_parts(dynamic_header),
        string.format(
            "Header for '%s' must be function|table|nil, got %s",
            window_name,
            type(user_header)
        )
end

--- Name for an Agentic buffer: `agentic://<id>/<panel>`, or with a title
--- `agentic://<id>/<panel>/<title>`, from the buffer's `agentic_session_id`
--- and `agentic_window`. The id keeps names unique across sessions, the panel
--- keeps a title from taking another panel's name, and the tail is the title
--- when there is one.
--- @param bufnr integer
--- @param title string|nil
--- @return string name
function WindowDecoration.buffer_name(bufnr, title)
    local name = string.format(
        "agentic://%d/%s",
        vim.b[bufnr].agentic_session_id,
        vim.b[bufnr].agentic_window
    )
    if not title then
        return name
    end
    -- A `/` would make only the text after it the tail.
    return name .. "/" .. (title:gsub("/", "-"))
end

--- Render an Agentic buffer's header as the winbar of every window showing
--- it, set with local scope so it leaves with the buffer.
--- @param bufnr integer
function WindowDecoration.render_header(bufnr)
    if not Config.winbar then
        return
    end

    local header_text, err = resolve_header_text(
        WindowDecoration.get_header(bufnr),
        vim.b[bufnr].agentic_window
    )
    if err then
        Logger.notify(err)
    end
    -- Escape % to %% for statusline format.
    local winbar = header_text and header_text:gsub("%%", "%%%%") or ""

    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        vim.api.nvim_set_option_value(
            "winbar",
            winbar,
            { win = winid, scope = "local" }
        )
    end
end

return WindowDecoration

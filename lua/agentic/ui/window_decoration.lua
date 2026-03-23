--- Window decoration module for managing window titles and buffer naming.

local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

--- @class agentic.ui.WindowDecoration
local WindowDecoration = {}

--- @type agentic.ui.ChatWidget.Headers
local WINDOW_HEADERS = {
    chat = {
        title = "󰻞 Agentic Chat",
    },
    input = { title = "󰦨 Prompt" },
    code = {
        title = "󰪸 Selected Code Snippets",
    },
    files = {
        title = " Referenced Files",
    },
    diagnostics = {
        title = " Diagnostics",
    },
    todos = {
        title = " Tasks list",
    },
}

--- Concatenates header parts (title, context) into a single string
--- @param parts agentic.ui.ChatWidget.HeaderParts
--- @return string header_text
local function concat_header_parts(parts)
    local pieces = { parts.title }
    if parts.context ~= nil then
        table.insert(pieces, parts.context)
    end
    return table.concat(pieces, " | ")
end

--- Gets or initializes headers for a tabpage
--- @param tab_page_id integer
--- @return agentic.ui.ChatWidget.Headers
function WindowDecoration.get_headers_state(tab_page_id)
    if vim.t[tab_page_id].agentic_headers == nil then
        vim.t[tab_page_id].agentic_headers = WINDOW_HEADERS
    end
    return vim.t[tab_page_id].agentic_headers
end

--- Sets headers for a tabpage
--- @param tab_page_id integer
--- @param headers agentic.ui.ChatWidget.Headers
function WindowDecoration.set_headers_state(tab_page_id, headers)
    if vim.api.nvim_tabpage_is_valid(tab_page_id) then
        vim.t[tab_page_id].agentic_headers = headers
        vim.api.nvim_exec_autocmds("User", {
            pattern = "AgenticHeadersChanged",
            data = { tab_page_id = tab_page_id },
        })
    end
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

--- Sets the buffer name based on header text and tab count
--- @param bufnr integer Buffer number
--- @param header_text string|nil Resolved header text
--- @param tab_page_id integer Tab page ID for suffix
local function set_buffer_name(bufnr, header_text, tab_page_id)
    if not header_text or header_text == "" then
        return
    end

    -- Determine if we should show tab suffix based on total tab count
    local total_tabs = #vim.api.nvim_list_tabpages()

    --- @type string|nil
    local buf_name
    if total_tabs > 1 then
        buf_name = string.format("%s (Tab %d)", header_text, tab_page_id)
    else
        buf_name = header_text
    end

    vim.api.nvim_buf_set_name(bufnr, buf_name)
end

--- Renders a header for a window, handling user customization and buffer naming.
--- Derives all context from bufnr: winid, tab_page_id, and dynamic header from vim.t
--- @param bufnr integer Buffer number - stable reference to derive window and tab context
--- @param window_name string Name of the window (for Config.headers lookup and error messages)
--- @param context string|nil Optional context to set in header (e.g., "Mode: chat", "3 files")
function WindowDecoration.render_header(bufnr, window_name, context)
    vim.schedule(function()
        local winid = vim.fn.bufwinid(bufnr)
        if winid == -1 then
            return
        end

        local tab_page_id = vim.api.nvim_win_get_tabpage(winid)

        local headers = WindowDecoration.get_headers_state(tab_page_id)
        local dynamic_header = headers[window_name]

        if not dynamic_header then
            Logger.debug(
                string.format(
                    "No header configuration found for window name '%s'",
                    window_name
                )
            )
            return
        end

        -- Set context if provided (must reassign to vim.t due to copy semantics)
        if context ~= nil then
            dynamic_header.context = context
            headers[window_name] = dynamic_header
            WindowDecoration.set_headers_state(tab_page_id, headers)
        end

        local _, err = resolve_header_text(dynamic_header, window_name)
        if err then
            Logger.notify(err)
        end

        -- Buffer name uses the base title only (no context or suffix) so
        -- tabline/bufferline plugins show a clean, short name.
        set_buffer_name(bufnr, dynamic_header.title, tab_page_id)
    end)
end

return WindowDecoration

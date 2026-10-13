local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local BufHelpers = require("agentic.utils.buf_helpers")
local TextWrap = require("agentic.utils.text_wrap")

--- Get diagnostic severity icons from config
--- @return table<number, string> Mapping of severity to icon
local function get_diagnostic_icons()
    local icons = Config.diagnostic_icons
    return {
        [vim.diagnostic.severity.ERROR] = icons.error,
        [vim.diagnostic.severity.WARN] = icons.warn,
        [vim.diagnostic.severity.INFO] = icons.info,
        [vim.diagnostic.severity.HINT] = icons.hint,
    }
end

--- @class agentic.ui.DiagnosticsList.Diagnostic : vim.Diagnostic
--- @field file_path string Full file path

--- @class agentic.ui.DiagnosticsList
--- @field _diagnostics agentic.ui.DiagnosticsList.Diagnostic[]
--- @field _bufnr integer the same buffer number as the ChatWidget's diagnostics buffer
--- @field _on_change fun(diagnosticsList: agentic.ui.DiagnosticsList)
local DiagnosticsList = {}
DiagnosticsList.__index = DiagnosticsList

--- @param bufnr integer The diagnostics buffer number from ChatWidget
--- @param on_change fun(diagnosticsList: agentic.ui.DiagnosticsList) Callback to trigger when diagnostics list changes (e.g., update header)
--- @return agentic.ui.DiagnosticsList
function DiagnosticsList:new(bufnr, on_change)
    local instance = setmetatable({
        _diagnostics = {},
        _bufnr = bufnr,
        _on_change = on_change,
    }, self)

    instance:_setup_keybindings()

    return instance
end

--- Add a diagnostic to the list if not already present. A diagnostic is
--- present when one has the same buffer, position, message, severity, source
--- and code.
--- @param diagnostic agentic.ui.DiagnosticsList.Diagnostic
--- @return boolean added
function DiagnosticsList:_add_no_render(diagnostic)
    for _, existing in ipairs(self._diagnostics) do
        if
            existing.bufnr == diagnostic.bufnr
            and existing.lnum == diagnostic.lnum
            and existing.col == diagnostic.col
            and existing.message == diagnostic.message
            and existing.severity == diagnostic.severity
            and existing.source == diagnostic.source
            and existing.code == diagnostic.code
        then
            return false
        end
    end

    table.insert(self._diagnostics, diagnostic)
    return true
end

--- Add the diagnostics not already present, then render once if any were added
--- @param diagnostics agentic.ui.DiagnosticsList.Diagnostic[]
--- @return integer count Number of diagnostics added
function DiagnosticsList:add_many(diagnostics)
    local count = 0
    for _, diagnostic in ipairs(diagnostics) do
        if self:_add_no_render(diagnostic) then
            count = count + 1
        end
    end

    if count > 0 then
        self:render()
    end

    return count
end

--- @param index integer
function DiagnosticsList:remove_at(index)
    if index < 1 or index > #self._diagnostics then
        return
    end

    table.remove(self._diagnostics, index)
    self:render()
end

--- @return agentic.ui.DiagnosticsList.Diagnostic[]
function DiagnosticsList:get_diagnostics()
    return vim.deepcopy(self._diagnostics)
end

function DiagnosticsList:clear()
    self._diagnostics = {}
    self:render()
end

--- @return boolean
function DiagnosticsList:is_empty()
    return #self._diagnostics == 0
end

--- The diagnostics of a buffer, each with the buffer's file path.
--- @param bufnr integer
--- @return agentic.ui.DiagnosticsList.Diagnostic[] diagnostics
function DiagnosticsList.get_buffer_diagnostics(bufnr)
    local file_path = vim.api.nvim_buf_get_name(bufnr)
    return vim.tbl_map(function(d)
        return vim.tbl_extend("force", d, { file_path = file_path })
    end, vim.diagnostic.get(bufnr))
end

--- The diagnostics of a buffer that span the cursor line of the first window
--- in the current tabpage that shows it, each with the buffer's file path.
--- Empty when no such window exists.
--- @param bufnr integer
--- @return agentic.ui.DiagnosticsList.Diagnostic[] diagnostics
function DiagnosticsList.get_diagnostics_at_cursor(bufnr)
    local winid = vim.fn.bufwinid(bufnr)
    if winid == -1 then
        return {}
    end

    local cursor_line = vim.api.nvim_win_get_cursor(winid)[1] - 1
    return vim.tbl_filter(function(d)
        return cursor_line >= d.lnum and cursor_line <= (d.end_lnum or d.lnum)
    end, DiagnosticsList.get_buffer_diagnostics(bufnr))
end

--- Write the diagnostics into the buffer and report the change.
function DiagnosticsList:render()
    local lines = {}
    local icons = get_diagnostic_icons()

    local winid = vim.fn.bufwinid(self._bufnr)
    local buf_width = winid ~= -1 and vim.api.nvim_win_get_width(winid)
        or vim.o.columns

    for _, diagnostic in ipairs(self._diagnostics) do
        local icon = icons[diagnostic.severity]
            or icons[vim.diagnostic.severity.ERROR]
        local smart_path = diagnostic.file_path
        if smart_path == "" then
            smart_path = string.format("[unnamed:%d]", diagnostic.bufnr)
        else
            smart_path = FileSystem.to_smart_path(smart_path)
        end
        local location = string.format(
            "%s:%d:%d",
            smart_path,
            diagnostic.lnum + 1,
            diagnostic.col + 1
        )

        -- nvim_buf_set_lines rejects embedded newlines in a line item.
        -- Keep diagnostics single-line by rendering newlines as escaped text.
        local message = type(diagnostic.message) == "string"
                and diagnostic.message
            or tostring(diagnostic.message or "")
        message = message:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")

        -- Format: ICON path:line:col - message
        local line = string.format("%s %s - %s", icon, location, message)
        table.insert(lines, TextWrap.truncate_to_width(line, buf_width))
    end

    local did_render = BufHelpers.with_modifiable(self._bufnr, function(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        return true
    end)

    if did_render then
        self._on_change(self)
    end
end

--- @private
function DiagnosticsList:_setup_keybindings()
    BufHelpers.keymap_set(self._bufnr, "n", "d", function()
        local cursor = vim.api.nvim_win_get_cursor(0)
        local line = cursor[1]

        local line_content =
            vim.api.nvim_buf_get_lines(self._bufnr, line - 1, line, false)[1]

        if line_content and line_content:match("%S") then
            self:remove_at(line)
        end
    end, { nowait = true })

    BufHelpers.keymap_set(self._bufnr, "v", "d", function()
        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local start_line = start_pos[2]
        local end_line = end_pos[2]

        -- Ensure start_line is always smaller than end_line (handle backward selection)
        if start_line > end_line then
            start_line, end_line = end_line, start_line
        end

        --- @type table<integer, true>
        local indices_to_remove = {}
        for line = start_line, end_line do
            local line_content = vim.api.nvim_buf_get_lines(
                self._bufnr,
                line - 1,
                line,
                false
            )[1]

            if
                line_content
                and line_content:match("%S")
                and line >= 1
                and line <= #self._diagnostics
            then
                indices_to_remove[line] = true
            end
        end

        --- @type integer[]
        local sorted_indices = {}
        for index in pairs(indices_to_remove) do
            table.insert(sorted_indices, index)
        end
        table.sort(sorted_indices, function(a, b)
            return a > b
        end)

        for _, index in ipairs(sorted_indices) do
            table.remove(self._diagnostics, index)
        end

        if #sorted_indices > 0 then
            self:render()
        end

        -- Exit visual mode
        BufHelpers.feed_ESC_key()
    end, { nowait = true })
end

return DiagnosticsList

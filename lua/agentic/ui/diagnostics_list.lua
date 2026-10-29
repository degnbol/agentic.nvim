local Config = require("agentic.config")
local FileSystem = require("agentic.utils.file_system")
local TextWrap = require("agentic.utils.text_wrap")
local ContextList = require("agentic.ui.context_list")

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

--- @class agentic.ui.DiagnosticsList : agentic.ui.ContextList
--- @field protected __items agentic.ui.DiagnosticsList.Diagnostic[]
local DiagnosticsList = setmetatable({}, { __index = ContextList })
DiagnosticsList.__index = DiagnosticsList

--- Add a diagnostic to the list if not already present. A diagnostic is
--- present when one has the same buffer, position, message, severity, source
--- and code.
--- @param diagnostic agentic.ui.DiagnosticsList.Diagnostic
--- @return boolean added
function DiagnosticsList:_add_no_render(diagnostic)
    for _, existing in ipairs(self.__items) do
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

    table.insert(self.__items, diagnostic)
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

--- One row: severity icon, location and message, truncated to the width of
--- the buffer's window, or of the editor when the buffer is not shown.
--- @protected
--- @param diagnostic agentic.ui.DiagnosticsList.Diagnostic
--- @return string[] rows
function DiagnosticsList:__rows(diagnostic)
    local icons = get_diagnostic_icons()
    local winid = vim.fn.bufwinid(self.__bufnr)
    local buf_width = winid ~= -1 and vim.api.nvim_win_get_width(winid)
        or vim.o.columns

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
    local message = type(diagnostic.message) == "string" and diagnostic.message
        or tostring(diagnostic.message or "")
    message = message:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\\n")

    -- Format: ICON path:line:col - message
    local line = string.format("%s %s - %s", icon, location, message)
    return { TextWrap.truncate_to_width(line, buf_width) }
end

return DiagnosticsList

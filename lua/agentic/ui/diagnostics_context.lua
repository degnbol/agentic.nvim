local FileSystem = require("agentic.utils.file_system")
local TextWrap = require("agentic.utils.text_wrap")

--- @class agentic.ui.DiagnosticsContext
local DiagnosticsContext = {}

--- @class agentic.ui.DiagnosticsContext.FormatResult
--- @field prompt_entries agentic.acp.TextContent[]
--- @field summary_lines string[]

--- @param file_path string|nil
--- @return string normalized_path
local function normalize_file_path(file_path)
    if file_path == nil or file_path == "" then
        return "<unnamed buffer>"
    end

    return file_path
end

--- @param text string
--- @return string escaped_text
local function escape_xml(text)
    return (
        text:gsub("&", "&amp;")
            :gsub("<", "&lt;")
            :gsub(">", "&gt;")
            :gsub('"', "&quot;")
            :gsub("'", "&apos;")
    )
end

--- @param severity integer|nil
--- @return string severity_label
local function severity_to_label(severity)
    local label = ({
        [vim.diagnostic.severity.ERROR] = "ERROR",
        [vim.diagnostic.severity.WARN] = "WARN",
        [vim.diagnostic.severity.INFO] = "INFO",
        [vim.diagnostic.severity.HINT] = "HINT",
    })[severity]

    return label or "ERROR"
end

--- @param diagnostics agentic.ui.DiagnosticsList.Diagnostic[]
--- @param chat_width integer
--- @return agentic.ui.DiagnosticsContext.FormatResult format_result
function DiagnosticsContext.format_diagnostics(diagnostics, chat_width)
    --- @type agentic.acp.TextContent[]
    local prompt_entries = {}
    --- @type string[]
    local summary_lines = {}

    for _, diagnostic in ipairs(diagnostics) do
        local file_path = normalize_file_path(diagnostic.file_path)
        local absolute_file_path = file_path
        if file_path ~= "<unnamed buffer>" then
            absolute_file_path = FileSystem.to_absolute_path(file_path)
        end

        local severity_label = severity_to_label(diagnostic.severity)
        local line = diagnostic.lnum + 1
        local column = diagnostic.col + 1

        local xml_lines = {
            "<diagnostic>",
            string.format("<severity>%s</severity>", severity_label),
        }

        if diagnostic.source then
            xml_lines[#xml_lines + 1] = string.format(
                "<source>%s</source>",
                escape_xml(diagnostic.source)
            )
        end

        if diagnostic.code then
            xml_lines[#xml_lines + 1] = string.format(
                "<code>%s</code>",
                escape_xml(tostring(diagnostic.code))
            )
        end

        vim.list_extend(xml_lines, {
            string.format("<file>%s</file>", escape_xml(absolute_file_path)),
            string.format("<line>%d</line>", line),
            string.format("<column>%d</column>", column),
            string.format(
                "<message>%s</message>",
                escape_xml(diagnostic.message)
            ),
            "</diagnostic>",
        })

        table.insert(prompt_entries, {
            type = "text",
            text = table.concat(xml_lines, "\n"),
        })

        local location = string.format("%s:%d:%d", file_path, line, column)
        local single_line_message = diagnostic.message:gsub("\n", " ")
        local summary = string.format(
            "  - [%s] %s - %s",
            severity_label,
            location,
            single_line_message
        )

        table.insert(
            summary_lines,
            TextWrap.truncate_to_width(summary, chat_width)
        )
    end

    --- @type agentic.ui.DiagnosticsContext.FormatResult
    local format_result = {
        prompt_entries = prompt_entries,
        summary_lines = summary_lines,
    }

    return format_result
end

return DiagnosticsContext

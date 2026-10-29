local FileSystem = require("agentic.utils.file_system")
local BufHelpers = require("agentic.utils.buf_helpers")
local Treesitter = require("agentic.utils.treesitter")
local TextWrap = require("agentic.utils.text_wrap")
local ContextList = require("agentic.ui.context_list")

--- @class agentic.ui.CodeSelection : agentic.ui.ContextList
--- @field protected __items agentic.Selection[]
local CodeSelection = setmetatable({}, { __index = ContextList })
CodeSelection.__index = CodeSelection

--- @param selection agentic.Selection
function CodeSelection:add(selection)
    if selection and #selection.lines > 0 then
        table.insert(self.__items, selection)
        self:render()
    end
end

--- `selection` as a markdown code block: its file type and location as the
--- info string, behind a fence no line of the snippet closes.
--- @param selection agentic.Selection
--- @return string[] rows
function CodeSelection.fence_rows(selection)
    local fence = TextWrap.safe_fence(selection.lines)
    local rows = {
        string.format(
            "%s%s %s#L%d-L%d",
            fence,
            selection.file_type,
            selection.file_path,
            selection.start_line,
            selection.end_line
        ),
    }
    vim.list_extend(rows, selection.lines)
    table.insert(rows, fence)
    return rows
end

--- @protected
--- @param selection agentic.Selection
--- @return string[] rows
function CodeSelection:__rows(selection)
    return CodeSelection.fence_rows(selection)
end

--- @return agentic.Selection|nil
function CodeSelection.get_selected_text()
    local mode = vim.fn.mode()

    if mode == "v" or mode == "V" then
        local start_pos = vim.fn.getpos("v")
        local end_pos = vim.fn.getpos(".")
        local start_line = start_pos[2]
        local end_line = end_pos[2]

        -- Ensure start_line is always smaller than end_line (handle backward selection)
        if start_line > end_line then
            start_line, end_line = end_line, start_line
        end

        local lines = vim.api.nvim_buf_get_lines(
            0,
            start_line - 1, -- 0-indexed
            end_line, -- exclusive
            false
        )

        -- exit visual mode to avoid issues with the input buffer
        BufHelpers.feed_ESC_key()

        local buf_name = vim.api.nvim_buf_get_name(0)

        --- @class agentic.Selection
        local selection = {
            lines = lines,
            start_line = start_line,
            end_line = end_line,
            file_path = FileSystem.to_smart_path(buf_name),
            file_type = Treesitter.language_for_path(buf_name, lines),
        }

        return selection
    end
end

return CodeSelection

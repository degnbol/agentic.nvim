local PermissionRules = require("agentic.utils.permission_rules")
local Renderer = require("agentic.ui.tool_call_renderer")
local Theme = require("agentic.theme")

--- Transient highlighting of the non-known-safe parts of an execute permission
--- prompt. Reads the command lines verbatim from inside the block's code fence
--- (the displayed text), tallies the unapproved ranges over them, and washes
--- those bytes while the prompt is shown. Pure UI — it never grants anything;
--- worst case it highlights nothing while the prompt still fires.
---
--- The variable-width fence convention (`^`+lang` open, `^`+` close) is the
--- same one other chat consumers use; the command body is the lines between.
--- @class agentic.ui.PermissionHighlight
local M = {}

local OPEN_FENCE = "^`+%a*$"
local CLOSE_FENCE = "^`+$"

--- Extmark priority — above injected bash syntax (priority 100) so the warning
--- wash wins, consistent with other chat extmarks.
local HL_PRIORITY = 200

--- Resolve a tool-call block's current row span from its NS_TOOL_BLOCKS extmark.
--- @param bufnr integer
--- @param block agentic.ui.MessageWriter.ToolCallBlock
--- @return integer|nil start_row 0-indexed
--- @return integer|nil end_row 0-indexed
local function block_span(bufnr, block)
    if not block.extmark_id then
        return nil, nil
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(
        bufnr,
        Renderer.NS_TOOL_BLOCKS,
        block.extmark_id,
        { details = true }
    )
    local start_row = pos[1]
    local details = pos[3]
    if start_row and details and details.end_row then
        return start_row, details.end_row
    end
    return nil, nil
end

--- Find the first code-fence pair inside a row span. The opening pattern also
--- matches a bare close fence (zero-length lang), so the first match is the
--- open and the search for the close starts after it.
--- @param bufnr integer
--- @param start_row integer 0-indexed
--- @param end_row integer 0-indexed
--- @return integer|nil open_row 0-indexed
--- @return integer|nil close_row 0-indexed
local function find_fences(bufnr, start_row, end_row)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    local open_idx
    for i, line in ipairs(lines) do
        if not open_idx then
            if line:match(OPEN_FENCE) then
                open_idx = i
            end
        elseif line:match(CLOSE_FENCE) then
            return start_row + open_idx - 1, start_row + i - 1
        end
    end
    return nil, nil
end

--- Place one warning extmark over a 0-indexed buffer range.
--- @param bufnr integer
--- @param ns integer
--- @param srow integer
--- @param scol integer
--- @param erow integer
--- @param ecol integer
local function wash(bufnr, ns, srow, scol, erow, ecol)
    vim.api.nvim_buf_set_extmark(bufnr, ns, srow, scol, {
        end_row = erow,
        end_col = ecol,
        hl_group = Theme.HL_GROUPS.UNAPPROVED_COMMAND,
        priority = HL_PRIORITY,
    })
end

--- Highlight the non-known-safe parts of the execute command rendered in
--- `block`. No-op if the buffer, the block's extmark, or its code fence cannot
--- be resolved. On a parse failure the whole command body is highlighted
--- (look-at-all-of-it fallback).
--- @param bufnr integer chat buffer
--- @param ns integer highlight namespace
--- @param block agentic.ui.MessageWriter.ToolCallBlock
function M.apply(bufnr, ns, block)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    local start_row, end_row = block_span(bufnr, block)
    if not start_row or not end_row then
        return
    end
    local open_row, close_row = find_fences(bufnr, start_row, end_row)
    if not open_row or not close_row then
        return
    end

    local first = open_row + 1
    local body = vim.api.nvim_buf_get_lines(bufnr, first, close_row, false)
    if #body == 0 then
        return
    end

    local ranges = PermissionRules.tally_unapproved(table.concat(body, "\n"))

    if ranges == nil then
        for i, line in ipairs(body) do
            wash(bufnr, ns, first + i - 1, 0, first + i - 1, #line)
        end
        return
    end

    for _, r in ipairs(ranges) do
        wash(bufnr, ns, first + r[1], r[2], first + r[3], r[4])
    end
end

--- Clear all permission highlights in the buffer.
--- @param bufnr integer
--- @param ns integer
function M.clear(bufnr, ns)
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    end
end

return M

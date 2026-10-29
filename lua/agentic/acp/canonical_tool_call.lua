local AcpKind = require("agentic.utils.acp_kind")
local TextWrap = require("agentic.utils.text_wrap")

--- Canonical form of tool call messages.
--- @class agentic.acp.CanonicalToolCall
local M = {}

--- Split a trailing `(N - M)` line range off a read argument.
--- @param argument string e.g. "file.lua (10 - 50)"
--- @return string|nil path argument without the range suffix
--- @return { offset: integer, limit: integer }|nil range `offset` is the first line, `limit` the line count
function M.parse_read_range(argument)
    local path, a, b = argument:match("^(.-)%s*%((%d+)%s*%-%s*(%d+)%)%s*$")
    if not path then
        return nil, nil
    end
    local na = tonumber(a) --[[@as integer]]
    local nb = tonumber(b) --[[@as integer]]
    return path, { offset = na, limit = nb - na + 1 }
end

--- The inverse of `parse_read_range`'s suffix: `(N - M)`, or `(N - …)` when
--- the range has no end.
--- @param range { offset: integer, limit?: integer } `offset` is the first line, `limit` the line count
--- @return string
function M.format_read_range(range)
    if not range.limit then
        return string.format("(%d - …)", range.offset)
    end
    return string.format(
        "(%d - %d)",
        range.offset,
        range.offset + range.limit - 1
    )
end

--- A read's trailing `(N - M)` moved from `argument` to `read_range`; a
--- `read_range` the message already has wins. Other kinds stay as they are.
--- Idempotent.
--- @generic T : agentic.ui.MessageWriter.ToolCallBase
--- @param message T
--- @param kind string|nil the call's kind, nil when unknown
--- @return T split a shallow copy of `message`
function M.split_read_range(message, kind)
    local split = vim.tbl_extend("force", {}, message)
    if AcpKind.normalise(kind) == "read" and message.argument then
        local path, range = M.parse_read_range(message.argument)
        if path then
            split.argument = path
            split.read_range = message.read_range or range
        end
    end
    return split
end

--- A tool call message in canonical form: `split_read_range`, and an execute
--- body that is one fenced block becomes its inner rows. Fields the message
--- lacks stay absent. Not idempotent: an execute body whose inner rows are
--- one fenced block themselves loses one more fence per call.
--- @generic T : agentic.ui.MessageWriter.ToolCallBase
--- @param message T
--- @param kind string|nil the call's kind, nil when unknown
--- @return T normalised a shallow copy of `message`
function M.normalise(message, kind)
    local normalised = M.split_read_range(message, kind)
    if AcpKind.normalise(kind) == "execute" and normalised.body then
        normalised.body = TextWrap.fenced_inner(normalised.body)
            or normalised.body
    end
    return normalised
end

return M

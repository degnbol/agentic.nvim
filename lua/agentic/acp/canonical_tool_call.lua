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

--- The line of each rejecting cause code.
--- @type table<agentic.PermissionCauseCode, string>
local REJECTION_LINES = {
    ["prompt-reject"] = "Rejected at the prompt",
    ["session-reject"] = "Rejected for this session",
    deny = "Rejected by a permission rule",
    ["glob-deny"] = "Rejected by a permission rule",
    ["prompt-cancel"] = "Cancelled at the prompt",
}

--- The line saying why the plugin rejected a call: that of the first
--- rejecting cause in `causes`.
--- @param causes agentic.PermissionCause[]|nil
--- @return string|nil line nil when no cause rejected the call
function M.causes_line(causes)
    for _, cause in ipairs(causes or {}) do
        local line = REJECTION_LINES[cause.code]
        if line then
            return line
        end
    end
    return nil
end

--- The line saying why a call was rejected before it ran: the plugin's, from
--- `causes`, else the provider's `rejection`.
--- @param call agentic.ui.MessageWriter.ToolCallBase
--- @return string|nil line nil when the call was not rejected
function M.rejection_line(call)
    return M.causes_line(call.causes) or call.rejection
end

--- Whether a call ran: it is `completed`, or `failed` with no rejection line.
--- A provider may report a command that ran and exited non-zero as `failed`,
--- while one that never ran (rejected, denied, interrupted) has a rejection
--- line.
--- @param call agentic.ui.MessageWriter.ToolCallBase
--- @return boolean
function M.ran(call)
    return call.status == "completed"
        or (call.status == "failed" and not M.rejection_line(call))
end

--- @type table<string, string>
local STOP_REASON_WORDS = {
    end_turn = "completed",
    cancelled = "interrupted",
    error = "failed",
}

--- The word for how a run ended with an ACP stop reason: `completed`,
--- `interrupted`, `failed`, else the reason itself (`max_tokens`, `refusal`,
--- …).
--- @param reason string
--- @return string
function M.stop_reason_word(reason)
    return STOP_REASON_WORDS[reason] or reason
end

--- The word a call's status shows: `rejected` for a call rejected before it
--- ran, its `ended_as` for a failed call, `interrupted` for a saved
--- `cancelled` status, else its status.
--- @param call agentic.ui.MessageWriter.ToolCallBase
--- @return string|nil word nil when the call has no status
function M.status_word(call)
    if M.rejection_line(call) then
        return "rejected"
    end
    if call.ended_as and call.status == "failed" then
        return call.ended_as
    end
    if call.status == "cancelled" then
        return "interrupted"
    end
    return call.status
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

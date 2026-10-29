--- @class agentic.utils.LogLine
local LogLine = {}

--- Bracket positions tried as the start of a trailing JSON value. Bounds the
--- work on a long line with many brackets and no decodable tail.
local MAX_JSON_STARTS = 8

--- The message of one line of a process's log output, without its payload.
--- A trailing JSON value and a trailing `:`, `{` or `[` are removed.
--- @param line string
--- @return string|nil summary Nil for a line that carries no message of its own: one that starts with whitespace (continues the previous line), has no letter or digit (closes a multi-line value), or is JSON alone
function LogLine.summary(line)
    if line:match("^%s") or not line:match("%w") then
        return nil
    end

    local text = vim.trim(line)
    local pos = text:find("[{%[]")
    for _ = 1, MAX_JSON_STARTS do
        if not pos then
            break
        end
        -- A decode error means the rest of the line is not JSON from here.
        if pcall(vim.json.decode, text:sub(pos)) then
            text = text:sub(1, pos - 1)
            break
        end
        pos = text:find("[{%[]", pos + 1)
    end

    text = text:gsub("[%s:{%[]+$", "")
    return text ~= "" and text or nil
end

return LogLine

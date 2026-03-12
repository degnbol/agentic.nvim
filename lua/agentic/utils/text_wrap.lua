--- Hard-wrap prose lines to a target width, preserving code blocks untouched.
--- @class agentic.utils.TextWrap
local M = {}

--- Wrap a single line of prose at word boundaries.
--- Preserves leading whitespace and list markers on continuation lines.
--- @param line string
--- @param width integer
--- @return string[]
local function wrap_line(line, width)
    if #line <= width then
        return { line }
    end

    -- Detect leading prefix (whitespace + optional list marker) for continuation
    local prefix = line:match("^(%s*%d+%.%s)")        -- "  1. "
        or line:match("^(%s*[%-%*]%s)")               -- "- ", "* "
        or line:match("^(%s*>%s?)")                   -- "> "
        or line:match("^(%s+)")                       -- plain indent
        or ""
    local continuation_indent = string.rep(" ", #prefix)

    local result = {}
    local current = ""
    local first = true

    for word in line:gmatch("%S+") do
        local sep = current == "" and "" or " "
        if current == "" then
            current = (first and "" or continuation_indent) .. word
        elseif #current + #sep + #word <= width then
            current = current .. sep .. word
        else
            result[#result + 1] = current
            first = false
            current = continuation_indent .. word
        end
    end
    if current ~= "" then
        result[#result + 1] = current
    end

    return result
end

--- Hard-wrap prose in a block of lines, skipping fenced code blocks.
--- @param lines string[]
--- @param width integer Target width in columns
--- @return string[]
function M.wrap_prose(lines, width)
    if width <= 0 then
        return lines
    end

    local out = {}
    local in_fence = false

    for _, line in ipairs(lines) do
        -- Toggle code fence state on ``` lines
        if line:match("^%s*```") then
            in_fence = not in_fence
            out[#out + 1] = line
        elseif in_fence then
            out[#out + 1] = line
        elseif line:match("^%s*$") then
            -- Blank line — preserve as-is
            out[#out + 1] = line
        else
            local wrapped = wrap_line(line, width)
            for _, wl in ipairs(wrapped) do
                out[#out + 1] = wl
            end
        end
    end

    return out
end

return M

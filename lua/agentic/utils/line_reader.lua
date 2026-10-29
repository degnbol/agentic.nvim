--- @class agentic.utils.LineReader
local LineReader = {}

--- A feed function that splits a chunked stream into lines.
--- @param on_line fun(line: string) Called per complete line, without its `\n` or a trailing `\r`. Leading whitespace and empty lines are kept
--- @return fun(data: string|nil) feed Takes the next chunk; `nil` marks end of stream and flushes a non-empty unterminated last line
function LineReader.new(on_line)
    local pending = ""

    --- @param line string
    local function emit(line)
        on_line((line:gsub("\r$", "")))
    end

    return function(data)
        if data == nil then
            if pending ~= "" then
                emit(pending)
                pending = ""
            end
            return
        end

        local lines = vim.split(pending .. data, "\n", { plain = true })
        pending = table.remove(lines)
        for _, line in ipairs(lines) do
            emit(line)
        end
    end
end

return LineReader

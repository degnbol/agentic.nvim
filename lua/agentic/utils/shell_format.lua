--- Shell command lines laid out for reading.
--- @class agentic.utils.ShellFormat
local M = {}

--- Fallback formatter: split a long single-line shell command at top-level
--- operators (&&, ||, ;, |) outside of quotes and subshells. Does not indent
--- control structures. Already-multiline or short commands are returned as-is.
--- @param cmd string
--- @return string
local function split_at_operators(cmd)
    if cmd:find("\n", 1, true) or #cmd <= 80 then
        return cmd
    end

    local parts = {}
    local i = 1
    local len = #cmd
    local in_single = false
    local in_double = false
    local depth = 0 -- parenthesis/brace depth for $(...), (...), {...}

    while i <= len do
        local c = cmd:sub(i, i)

        if c == "'" and not in_double and depth == 0 then
            in_single = not in_single
            parts[#parts + 1] = c
            i = i + 1
        elseif c == '"' and not in_single and depth == 0 then
            in_double = not in_double
            parts[#parts + 1] = c
            i = i + 1
        elseif c == "\\" and not in_single then
            parts[#parts + 1] = cmd:sub(i, i + 1)
            i = i + 2
        elseif not in_single and not in_double then
            if c == "(" or c == "{" then
                depth = depth + 1
                parts[#parts + 1] = c
                i = i + 1
            elseif (c == ")" or c == "}") and depth > 0 then
                depth = depth - 1
                parts[#parts + 1] = c
                i = i + 1
            elseif depth == 0 then
                local two = cmd:sub(i, i + 1)
                local op, op_len
                if two == "&&" or two == "||" then
                    op, op_len = two, 2
                elseif c == ";" or c == "|" then
                    op, op_len = c, 1
                end

                if op then
                    parts[#parts + 1] = op
                    i = i + op_len
                    while i <= len and cmd:sub(i, i) == " " do
                        i = i + 1
                    end
                    if i <= len then
                        parts[#parts + 1] = "\n"
                    end
                else
                    parts[#parts + 1] = c
                    i = i + 1
                end
            else
                parts[#parts + 1] = c
                i = i + 1
            end
        else
            parts[#parts + 1] = c
            i = i + 1
        end
    end

    return table.concat(parts)
end

--- Format a shell command with an external formatter. Returns nil if the
--- formatter is not installed or errors.
--- @param cmd string
--- @param formatter string shfmt-compatible executable
--- @return string|nil
local function try_external_formatter(cmd, formatter)
    if vim.fn.executable(formatter) ~= 1 then
        return nil
    end

    -- `wait` runs no `vim.schedule` callbacks, so none can re-enter the
    -- caller while the formatter runs.
    local result = vim.system(
        { formatter, "-ln", "bash", "-i", "2", "-ci" },
        { stdin = cmd, text = true }
    ):wait()

    if result.code ~= 0 or not result.stdout or result.stdout == "" then
        return nil
    end

    -- shfmt adds a trailing newline
    local formatted = result.stdout:gsub("%s+$", "")
    return formatted
end

--- Memoized results of `format`, keyed on formatter and command text, so a
--- repeated command spawns the synchronous formatter subprocess once.
--- ponytail: unbounded, one entry per distinct (formatter, command) rendered
--- this session; add an LRU cap if command variety ever bloats memory.
--- @type table<string, string>
local format_cache = {}

--- Lay out a shell command line for reading. Memoized.
---
--- The split comes first because shfmt preserves one-liners: it can only
--- indent multi-line input.
--- @param cmd string shell command line
--- @param formatter string|false|nil external formatter executable; false or nil splits only
--- @return string formatted split at top-level operators, then indented by `formatter`
function M.format(cmd, formatter)
    local key = tostring(formatter) .. "\0" .. cmd
    local cached = format_cache[key]
    if cached ~= nil then
        return cached
    end
    local split = split_at_operators(cmd)
    local formatted = formatter and try_external_formatter(split, formatter)
        or split
    format_cache[key] = formatted
    return formatted
end

return M

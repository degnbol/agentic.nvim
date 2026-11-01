--- Which arguments of zsh builtins zsh evaluates as arithmetic, and whether
--- arithmetic text reads a variable's value.
--- @class agentic.utils.ZshArithmetic
local M = {}

--- True iff arithmetic `text` may read a variable: it has a letter or a `$`
--- other than `$#`, `$?`, `$$` and `$!`. zsh evaluates the variable's value as
--- arithmetic too, and a subscript in that value runs its command
--- substitutions.
--- @param text string
--- @return boolean
function M.reads_value(text)
    return (text:gsub("%$[#?$!]", "")):find("[%a$]") ~= nil
end

--- Builtins that evaluate each argument as arithmetic.
local ARITHMETIC_ARG_BUILTINS = {
    shift = true,
    ["return"] = true,
    exit = true,
    logout = true,
    ["break"] = true,
    continue = true,
    let = true,
}

--- True iff any of `args` from index `first` on reads a value.
--- @param args string[]
--- @param first integer
--- @return boolean
local function any_reads_value(args, first)
    for i = first, #args do
        if M.reads_value(args[i]) then
            return true
        end
    end
    return false
end

--- True iff the subscript of parameter name `name` reads a value.
--- @param name string
--- @return boolean
local function index_reads_value(name)
    local index = name:match("%[(.*)%]")
    return index ~= nil and M.reads_value(index)
end

--- True iff `format` makes printf evaluate an argument as arithmetic: it has a
--- `$` (an expansion, or a positional `%1$d`), or a directive other than `%s`,
--- `%b`, `%c` or `%q` with a digit-only width and precision.
--- @param format string
--- @return boolean
local function format_takes_arithmetic(format)
    format = format:gsub("%%%%", "")
    if format:find("%$") then
        return true
    end
    for spec, conversion in format:gmatch("%%([^%a]*)(%a?)") do
        if spec:find("%*") or not conversion:find("^[sbcq]$") then
            return true
        end
    end
    return false
end

--- Split printf's leading `-v NAME` / `-vNAME` options from its operands.
--- @param args string[] printf's arguments
--- @return string[] targets the `-v` names, in order; `""` for a trailing
---   bare `-v`
--- @return integer i_operand index of the first word after the options (a
---   `--` or the format), `#args + 1` when there is none
function M.printf_options(args)
    local targets, i = {}, 1
    while args[i] and args[i]:match("^%-v") do
        local name = args[i]:sub(3)
        if name == "" then
            i = i + 1
            name = args[i] or ""
        end
        table.insert(targets, name)
        i = i + 1
    end
    return targets, i
end

--- True iff an argument that `cmd_name` evaluates as arithmetic reads a value
--- (see `reads_value`). Checks every argument of `ARITHMETIC_ARG_BUILTINS`
--- (`shift`, `return`, `exit`, `logout`, `break`, `continue`, `let`); for `printf`
--- and `print`, the subscript of a `-v` target name and the arguments after a
--- format that takes arithmetic. `print` options are found in every word,
--- attached values included, so an unmodelled option can only add a check.
--- @param cmd_name string
--- @param args string[] delivered words, dynamic ones as raw text
--- @return boolean
function M.builtin_args_read_value(cmd_name, args)
    if ARITHMETIC_ARG_BUILTINS[cmd_name] then
        return any_reads_value(args, 1)
    end
    if cmd_name == "printf" then
        local targets, i = M.printf_options(args)
        for _, name in ipairs(targets) do
            if index_reads_value(name) then
                return true
            end
        end
        if args[i] == "--" then
            i = i + 1
        end
        return args[i] ~= nil
            and format_takes_arithmetic(args[i])
            and any_reads_value(args, i + 1)
    end
    if cmd_name ~= "print" then
        return false
    end
    for i, arg in ipairs(args) do
        local name = arg:match("^%-%a-v(.*)$")
        if
            name and index_reads_value(name ~= "" and name or args[i + 1] or "")
        then
            return true
        end
        local format = arg:match("^%-%a-f(.*)$")
        if format then
            local i_format = format == "" and i + 1 or i
            format = format ~= "" and format or args[i + 1]
            if
                format
                and format_takes_arithmetic(format)
                and any_reads_value(args, i_format + 1)
            then
                return true
            end
        end
    end
    return false
end

return M

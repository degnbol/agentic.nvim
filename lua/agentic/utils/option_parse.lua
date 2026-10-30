--- Word-level readers of getopt-style option words (`-abc`, `--name[=v]`)
--- under arity hints: whether a word takes the next word as its value, which
--- identifiers it carries, and the value an option gets.
--- @class agentic.utils.OptionParse
local M = {}

--- @alias agentic.OptionKind "taker" | "boolean"
--- @alias agentic.OptionTakesNext "always" | "never" | "maybe"

--- @class agentic.OptionValue
--- @field id string dashless identifier of the option that takes the value
--- @field values string[] candidate values, one per dialect reading

--- Whether an option word takes the next word as its value.
--- @param word string a dash word other than `-` and `--`
--- @param kinds table<string, agentic.OptionKind> hinted kind per token
--- @return agentic.OptionTakesNext takes `"never"` for `--x=v`. A bare
---         `--x` follows its hinted kind, else `"maybe"`. A cluster `-abc`
---         follows its first letter that is not a hinted boolean: a taker
---         gives `"always"` as the last letter, else `"never"` (the rest is
---         its value). An unhinted letter gives `"maybe"`. All hinted
---         booleans give `"never"`.
function M.takes_next(word, kinds)
    if word:sub(1, 2) == "--" then
        if word:find("=", 3, true) then
            return "never"
        end
        local kind = kinds[word]
        if kind == nil then
            return "maybe"
        end
        return kind == "taker" and "always" or "never"
    end
    local letters = word:sub(2)
    for i = 1, #letters do
        local kind = kinds["-" .. letters:sub(i, i)]
        if kind == "taker" then
            return i == #letters and "always" or "never"
        end
        if kind ~= "boolean" then
            return "maybe"
        end
    end
    return "never"
end

--- Identifiers an option word carries in every cluster reading. Only the
--- text before its first whitespace counts.
--- @param word string a dash word
--- @param kinds table<string, agentic.OptionKind> hinted kind per token
--- @return string[] ids `name` for `--name[=v]`. For `-abc`, the letters up
---         to and including the first that is not a hinted boolean (a later
---         letter may be its value).
function M.sure_identifiers(word, kinds)
    local head = word:match("^%S*")
    if head:sub(1, 2) == "--" then
        local name = head:sub(3):match("^[^=]+")
        return name and { name } or {}
    end
    local ids = {}
    for letter in head:sub(2):gmatch(".") do
        table.insert(ids, letter)
        if kinds["-" .. letter] ~= "boolean" then
            break
        end
    end
    return ids
end

--- The option in `word` that takes a value, and that value.
--- `--name=v` gives `v`. A hinted taker `--name` gives `next_word`. In a
--- cluster `-abc`, hinted booleans are skipped and the first other letter
--- must be a hinted taker. It gets `next_word` when it is the last letter,
--- else the rest of the word. A rest that starts with `=` also gives the
--- rest without it (`-X=GET` is `GET` in pflag, `=GET` in getopt).
--- @param word string a dash word other than `-` and `--`
--- @param next_word string|nil
--- @param kinds table<string, agentic.OptionKind>
--- @return agentic.OptionValue|nil occurrence nil when no option in the word
---         takes a value, an unhinted option comes first, or a taker is the
---         last word
function M.option_value(word, next_word, kinds)
    --- @type agentic.OptionValue|nil
    local occurrence
    if word:sub(1, 2) == "--" then
        local name, value = word:match("^%-%-([^=]+)=(.*)$")
        if name then
            occurrence = { id = name, values = { value } }
        elseif kinds[word] == "taker" and next_word then
            occurrence = { id = word:sub(3), values = { next_word } }
        end
        return occurrence
    end
    local letters = word:sub(2)
    for i = 1, #letters do
        local letter = letters:sub(i, i)
        local kind = kinds["-" .. letter]
        if kind == "taker" then
            local rest = letters:sub(i + 1)
            if rest == "" then
                occurrence = next_word and { id = letter, values = { next_word } }
            else
                local values = { rest }
                if rest:sub(1, 1) == "=" then
                    table.insert(values, rest:sub(2))
                end
                occurrence = { id = letter, values = values }
            end
            return occurrence
        end
        if kind ~= "boolean" then
            return nil
        end
    end
    return nil
end

return M

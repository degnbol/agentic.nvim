--- `@path` file mentions in prompt text, by the rule of Claude Code's prompt
--- parser: a whitespace-separated word starting with `@`, whose path is the
--- rest of the word without its trailing run of characters outside ASCII
--- `[0-9A-Za-z_]`, and without a `#` suffix (`#L10-20`).
--- @class agentic.utils.Mention
local Mention = {}

--- @class agentic.utils.Mention.Span
--- @field at_col integer 0-indexed byte column of the `@`. The path starts right after it.
--- @field path string

--- Mentions in `line`, in order. A word whose path is empty (`@`, `@.`) is
--- not a mention.
--- @param line string
--- @return agentic.utils.Mention.Span[] spans
function Mention.spans(line)
    --- @type agentic.utils.Mention.Span[]
    local spans = {}
    for start, word in line:gmatch("()(%S+)") do
        if word:sub(1, 1) == "@" then
            local path = word:sub(2):gsub("[^%w_]+$", ""):match("^[^#]*")
            if path ~= "" then
                table.insert(spans, { at_col = start - 1, path = path })
            end
        end
    end
    return spans
end

return Mention

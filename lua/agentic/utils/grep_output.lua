--- Where the matched text sits in the lines a grep-family tool prints.
--- @class agentic.utils.GrepOutput
local M = {}

--- Lua patterns for the prefix of a match line, one per layout: one `name:`
--- per name field, then one `N:` per numeric field.
--- @param layout agentic.utils.GrepArgs.Layout
--- @return string[] prefixes anchored at `^`; empty when `layout.fields` is empty
function M.prefix_patterns(layout)
    local prefixes = {}
    for _, n_names in ipairs(layout.names) do
        for _, n_fields in ipairs(layout.fields) do
            table.insert(
                prefixes,
                "^"
                    .. string.rep("[^:]+:", n_names)
                    .. string.rep("%d+:", n_fields)
            )
        end
    end
    return prefixes
end

--- Lua patterns for a match-line prefix in agent search-tool output:
--- `path:N:`, `N:`, and opencode's `  Line N: `.
--- @type string[]
M.SEARCH_PREFIXES = { "^[^:]+:%d+:", "^%d+:", "^  Line %d+: " }

--- Where the matched text starts in a line, under each prefix that parses.
--- @param line string one output line
--- @param prefixes string[] Lua patterns anchored at `^`, one per possible prefix
--- @param diagnostic_names string[] lines that start with `<name>: ` are diagnostics,
---   as are lines that match `^Binary file .* matches$`
--- @return integer[] starts 0-based byte columns, deduplicated, empty when not a match line
function M.text_starts(line, prefixes, diagnostic_names)
    if line:match("^Binary file .* matches$") then
        return {}
    end
    for _, name in ipairs(diagnostic_names) do
        if vim.startswith(line, name .. ": ") then
            return {}
        end
    end
    local starts = {}
    for _, prefix in ipairs(prefixes) do
        local _, e = line:find(prefix)
        if e and not vim.list_contains(starts, e) then
            table.insert(starts, e)
        end
    end
    return starts
end

--- Drop rg's long-line placeholder: a line that is only
--- `[Omitted long matching line]` gives nil, and a trailing
--- ` [... omitted end of long line]` is removed.
--- @param text string the part of the line after the prefix
--- @return string|nil text
function M.strip_omitted(text)
    if text == "[Omitted long matching line]" then
        return nil
    end
    return (text:gsub(" %[%.%.%. omitted end of long line%]$", ""))
end

return M

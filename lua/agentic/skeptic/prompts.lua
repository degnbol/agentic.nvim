--- Prompt texts of the skeptic, each overridable by the key of the same name
--- in `Config.skeptic.prompts`.

local Config = require("agentic.config")

--- @alias agentic.skeptic.PromptKey "extract"|"verify"|"deliver"|"refusal"

--- @class agentic.skeptic.Prompts
local M = {}

--- @type table<agentic.skeptic.PromptKey, string>
M.DEFAULTS = {
    -- System prompt of the claim extractor.
    extract = [[
You extract checkable claims from a coding agent's work.

The input has sections: the user's prompts, the agent's text, reports from
its subagents, the diffs it made, and claims already checked.

List every factual claim in the agent's text and the subagent reports that
someone with the repository could check: what code does, where something is,
what a change fixes, what a test or command showed, what a tool or library
does. State each claim on its own, so it reads without the input. Leave out
plans, opinions, questions, and claims that repeat one already checked.

Answer with a JSON array of strings and nothing else. Answer [] for no
claims.]],

    -- `%s`: the user's prompts, the numbered claims and the diffs.
    verify = [[
Check the numbered claims below against the repository. Another agent made
them while working for the user; you see the user's prompts and the diffs it
made, not its reasoning. Read the code, and do not change anything.

For each claim decide:
- "refuted": the code or docs show it is wrong. Give the evidence: file and
  line, or what you ran and saw.
- "supported": you checked it and it holds.
- "unsure": you could not check it.

End with one fenced json block: an array of objects with the keys "claim"
(its number), "verdict" and "evidence".

%s]],

    -- `%s`: the findings, one per claim.
    deliver = [[
Background skeptics on other models checked claims from your recent work,
seeing only the user's prompts, your claims and your diffs. They dispute the claims below. Decide for each whether it needs checking;
check those that do, and correct what turns out wrong. Do not just accept
or dismiss them.

%s]],

    -- `%s`: why each refused call of the turn was refused.
    refusal = [[
Some of your tool calls were refused. You may only read and search, and
work in the temporary directory. The refusals:

%s

Go on with the check without them.]],
}

--- The text of `key`: the override in `Config.skeptic.prompts`, else the
--- default.
--- @param key agentic.skeptic.PromptKey
--- @return string
function M.text(key)
    return Config.skeptic.prompts[key] or M.DEFAULTS[key]
end

--- A markdown section: `title` as a heading over `items`, or "" without
--- items.
--- @param title string
--- @param items string[]
--- @return string
function M.section(title, items)
    if #items == 0 then
        return ""
    end
    return "## " .. title .. "\n\n" .. table.concat(items, "\n\n")
end

--- Join the non-empty sections, in order.
--- @param sections string[]
--- @return string
function M.join(sections)
    return table.concat(
        vim.tbl_filter(function(section)
            return section ~= ""
        end, sections),
        "\n\n"
    )
end

--- `items` as a numbered list, numbers from 1.
--- @param items string[]
--- @return string[]
function M.numbered(items)
    local lines = {}
    for i, item in ipairs(items) do
        lines[i] = ("%d. %s"):format(i, item)
    end
    return lines
end

return M

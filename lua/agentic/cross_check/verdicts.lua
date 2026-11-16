--- A checker's verdicts, read from its reply.

--- @alias agentic.CrossCheck.VerdictWord "refuted"|"supported"|"unsure"

--- @class agentic.CrossCheck.Verdict
--- @field verdict agentic.CrossCheck.VerdictWord
--- @field evidence string Empty when the checker gave none

--- @class agentic.CrossCheck.Verdicts
local M = {}

--- @type table<string, true>
local WORDS = { refuted = true, supported = true, unsure = true }

--- The verdicts in the last fenced `json` block of `text`, keyed by the
--- item number in each entry's `claim` key. Entries without a known verdict
--- or an item number are skipped.
--- @param text string
--- @return table<integer, agentic.CrossCheck.Verdict>|nil verdicts Nil without a block holding a JSON array
function M.parse(text)
    local last
    for block in text:gmatch("```json%s*\n(.-)\n%s*```") do
        last = block
    end
    if not last then
        return nil
    end
    local ok, decoded = pcall(vim.json.decode, last)
    if not ok or not vim.islist(decoded) then
        return nil
    end
    --- @type table<integer, agentic.CrossCheck.Verdict>
    local verdicts = {}
    for _, entry in ipairs(decoded) do
        local item = type(entry) == "table" and tonumber(entry.claim)
        if item and WORDS[entry.verdict] then
            verdicts[item] = {
                verdict = entry.verdict,
                evidence = type(entry.evidence) == "string" and entry.evidence
                    or "",
            }
        end
    end
    return verdicts
end

return M

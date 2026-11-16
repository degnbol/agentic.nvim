--- A skeptic's verdicts, read from its reply.

--- @alias agentic.skeptic.VerdictWord "refuted"|"supported"|"unsure"

--- @class agentic.skeptic.Verdict
--- @field verdict agentic.skeptic.VerdictWord
--- @field evidence string Empty when the skeptic gave none

--- @class agentic.skeptic.Verdicts
local M = {}

--- @type table<string, true>
local WORDS = { refuted = true, supported = true, unsure = true }

--- The verdicts in the last fenced `json` block of `text`, keyed by claim
--- number. Entries without a known verdict or a claim number are skipped.
--- @param text string
--- @return table<integer, agentic.skeptic.Verdict>|nil verdicts Nil without a block holding a JSON array
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
    --- @type table<integer, agentic.skeptic.Verdict>
    local verdicts = {}
    for _, entry in ipairs(decoded) do
        local claim = type(entry) == "table" and tonumber(entry.claim)
        if claim and WORDS[entry.verdict] then
            verdicts[claim] = {
                verdict = entry.verdict,
                evidence = type(entry.evidence) == "string" and entry.evidence
                    or "",
            }
        end
    end
    return verdicts
end

return M

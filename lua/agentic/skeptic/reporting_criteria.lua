--- Which claims the skeptics' verdicts refute, by a gate rule.

--- @class agentic.skeptic.Finding
--- @field claim string
--- @field evidence string[] The non-empty evidence of each skeptic that refuted it

--- @class agentic.skeptic.Gate
local M = {}

--- Whether the verdicts on one claim meet `gate`.
--- @param verdicts (agentic.skeptic.Verdict|false)[] One per skeptic; false for a skeptic with no verdict on it
--- @param gate "agree"|"either"
--- @return boolean
local function passes(verdicts, gate)
    local n_refuted, n_with_evidence = 0, 0
    for _, verdict in ipairs(verdicts) do
        if verdict and verdict.verdict == "refuted" then
            n_refuted = n_refuted + 1
            if verdict.evidence ~= "" then
                n_with_evidence = n_with_evidence + 1
            end
        end
    end
    if gate == "agree" then
        return n_refuted > 0 and n_refuted == #verdicts
    end
    return n_with_evidence > 0
end

--- The claims whose verdicts meet `gate`: `"agree"` when every skeptic
--- refuted the claim, `"either"` when any skeptic refuted it with evidence.
--- @param claims string[] Numbered by position
--- @param per_skeptic (table<integer, agentic.skeptic.Verdict>|false)[] Each skeptic's verdicts by claim number; false for a skeptic that gave none
--- @param gate "agree"|"either"
--- @return agentic.skeptic.Finding[]
function M.findings(claims, per_skeptic, gate)
    --- @type agentic.skeptic.Finding[]
    local findings = {}
    for i, claim in ipairs(claims) do
        local verdicts = vim.tbl_map(function(skeptic_verdicts)
            return skeptic_verdicts and skeptic_verdicts[i] or false
        end, per_skeptic)
        if passes(verdicts, gate) then
            local evidence = {}
            for _, verdict in ipairs(verdicts) do
                if
                    verdict
                    and verdict.verdict == "refuted"
                    and verdict.evidence ~= ""
                then
                    table.insert(evidence, verdict.evidence)
                end
            end
            table.insert(findings, { claim = claim, evidence = evidence })
        end
    end
    return findings
end

return M

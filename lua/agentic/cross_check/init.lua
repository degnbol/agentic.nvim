--- Checkers that cross-check each other once: each attacks the objections
--- others raised against items, and an objection falls only to an attack
--- with evidence.

--- A checker's `refuted` verdict, with evidence, on an item.
--- @class agentic.CrossCheck.Objection
--- @field item integer
--- @field checker integer
--- @field evidence string

--- @class agentic.CrossCheck
local M = {}

--- @param verdict agentic.CrossCheck.Verdict
--- @return boolean
local function refutes_with_evidence(verdict)
    return verdict.verdict == "refuted" and verdict.evidence ~= ""
end

--- The objections in the checkers' verdicts, by item then checker.
--- @param n_items integer Items are numbered `1..n_items`; other numbers are ignored
--- @param per_checker (table<integer, agentic.CrossCheck.Verdict>|false)[] Each checker's verdicts by item number, or false
--- @return agentic.CrossCheck.Objection[]
function M.objections(n_items, per_checker)
    --- @type agentic.CrossCheck.Objection[]
    local objections = {}
    for item = 1, n_items do
        for checker, verdicts in ipairs(per_checker) do
            local verdict = verdicts and verdicts[item]
            if verdict and refutes_with_evidence(verdict) then
                table.insert(objections, {
                    item = item,
                    checker = checker,
                    evidence = verdict.evidence,
                })
            end
        end
    end
    return objections
end

--- Which checker attacks which objections: every checker with a stance,
--- each objection to an item outside its stance that another raised.
--- @param objections agentic.CrossCheck.Objection[]
--- @param stances (table<integer, true>|false)[] Each checker's items it objects to itself, or false for one that does not attack
--- @return table<integer, agentic.CrossCheck.Objection[]> assigned By checker, in the order of `objections`. A checker without one is absent
function M.assign(objections, stances)
    --- @type table<integer, agentic.CrossCheck.Objection[]>
    local assigned = {}
    for _, objection in ipairs(objections) do
        for checker, stance in ipairs(stances) do
            if
                stance
                and checker ~= objection.checker
                and not stance[objection.item]
            then
                assigned[checker] = assigned[checker] or {}
                table.insert(assigned[checker], objection)
            end
        end
    end
    return assigned
end

--- Each assigned objection's attack verdicts.
--- @param assigned table<integer, agentic.CrossCheck.Objection[]> The objections each checker attacks, by checker
--- @param attack_verdicts (table<integer, agentic.CrossCheck.Verdict>|false)[] Each checker's verdicts by the objection's position in `assigned[checker]`, or false
--- @return table<agentic.CrossCheck.Objection, table<integer, agentic.CrossCheck.Verdict>> answers By attacking checker. An unassigned objection is absent
function M.answers(assigned, attack_verdicts)
    --- @type table<agentic.CrossCheck.Objection, table<integer, agentic.CrossCheck.Verdict>>
    local answers = {}
    for checker, objections in pairs(assigned) do
        local verdicts = attack_verdicts[checker]
        for i, objection in ipairs(objections) do
            answers[objection] = answers[objection] or {}
            answers[objection][checker] = verdicts and verdicts[i] or nil
        end
    end
    return answers
end

--- Whether an attack refuted an objection with evidence.
--- @param answers table<integer, agentic.CrossCheck.Verdict>|nil One objection's attack verdicts, by attacking checker
--- @return boolean
function M.refuted(answers)
    for _, verdict in pairs(answers or {}) do
        if refutes_with_evidence(verdict) then
            return true
        end
    end
    return false
end

return M

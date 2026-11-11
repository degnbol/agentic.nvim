local assert = require("tests.helpers.assert")

local Gate = require("agentic.skeptic.gate")

--- @param word agentic.skeptic.VerdictWord
--- @param evidence string|nil
--- @return agentic.skeptic.Verdict
local function v(word, evidence)
    return { verdict = word, evidence = evidence or "" }
end

describe("agentic.skeptic.Gate", function()
    local claims = { "c1", "c2", "c3" }

    describe("agree", function()
        it("forwards a claim every skeptic refuted", function()
            local findings = Gate.findings(claims, {
                { v("refuted", "a:1"), v("refuted", "x"), v("supported") },
                { v("refuted", "b:2"), v("unsure"), v("refuted", "y") },
            }, "agree")

            assert.same(
                { { claim = "c1", evidence = { "a:1", "b:2" } } },
                findings
            )
        end)

        it("forwards nothing when a skeptic gave no verdicts", function()
            local findings =
                Gate.findings(claims, { { v("refuted", "a") }, false }, "agree")

            assert.same({}, findings)
        end)

        it("forwards nothing without skeptics", function()
            assert.same({}, Gate.findings(claims, {}, "agree"))
        end)
    end)

    describe("either", function()
        it("forwards a claim any skeptic refuted with evidence", function()
            local findings = Gate.findings(claims, {
                { v("refuted"), v("refuted", "x"), v("supported") },
                false,
            }, "either")

            assert.same({ { claim = "c2", evidence = { "x" } } }, findings)
        end)
    end)
end)

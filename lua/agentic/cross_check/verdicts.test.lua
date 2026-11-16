local assert = require("tests.helpers.assert")

local Verdicts = require("agentic.skeptic.verdicts")

describe("agentic.skeptic.Verdicts", function()
    it("reads the verdicts keyed by claim number", function()
        local text = table.concat({
            "Checked both.",
            "```json",
            '[{"claim": 1, "verdict": "refuted", "evidence": "a.lua:3"},',
            ' {"claim": "2", "verdict": "supported"}]',
            "```",
        }, "\n")

        assert.same({
            [1] = { verdict = "refuted", evidence = "a.lua:3" },
            [2] = { verdict = "supported", evidence = "" },
        }, Verdicts.parse(text))
    end)

    it("reads the last json block", function()
        local text = table.concat({
            "```json",
            '[{"claim": 1, "verdict": "unsure"}]',
            "```",
            "On second look:",
            "```json",
            '[{"claim": 1, "verdict": "refuted", "evidence": "x"}]',
            "```",
        }, "\n")

        assert.equal("refuted", Verdicts.parse(text)[1].verdict)
    end)

    it("skips entries with an unknown verdict or no claim", function()
        local text = table.concat({
            "```json",
            '[{"claim": 1, "verdict": "maybe"}, {"verdict": "refuted"},',
            ' {"claim": 3, "verdict": "unsure"}]',
            "```",
        }, "\n")

        assert.same(
            { [3] = { verdict = "unsure", evidence = "" } },
            Verdicts.parse(text)
        )
    end)

    it("is nil without a json block holding an array", function()
        assert.is_nil(Verdicts.parse("All claims hold."))
        assert.is_nil(Verdicts.parse('```json\n{"claim": 1}\n```'))
        assert.is_nil(Verdicts.parse("```json\nnot json\n```"))
    end)
end)

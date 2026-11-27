local assert = require("tests.helpers.assert")

local CrossCheck = require("agentic.cross_check")

--- @param word agentic.CrossCheck.VerdictWord
--- @param evidence string|nil
--- @return agentic.CrossCheck.Verdict
local function v(word, evidence)
    return { verdict = word, evidence = evidence or "" }
end

--- @param item integer
--- @param checker integer
--- @return agentic.CrossCheck.Objection
local function objection(item, checker)
    return { item = item, checker = checker, evidence = "e" }
end

describe("agentic.CrossCheck", function()
    describe("objections", function()
        it(
            "are refuted verdicts with evidence, by item then checker",
            function()
                local objections = CrossCheck.objections(2, {
                    { [1] = v("refuted"), [2] = v("refuted", "b:2") },
                    { [1] = v("refuted", "a:1"), [2] = v("unsure", "x") },
                    false,
                    { [2] = v("refuted", "c:3") },
                })

                assert.same({
                    { item = 1, checker = 2, evidence = "a:1" },
                    { item = 2, checker = 1, evidence = "b:2" },
                    { item = 2, checker = 4, evidence = "c:3" },
                }, objections)
            end
        )

        it("ignore numbers out of range", function()
            local objections = CrossCheck.objections(1, {
                { [0] = v("refuted", "x"), [2] = v("refuted", "y") },
            })

            assert.same({}, objections)
        end)
    end)

    describe("assign", function()
        it("skips a checker that objects to the item itself", function()
            local assigned = CrossCheck.assign(
                { objection(1, 1) },
                { { [1] = true }, { [1] = true } }
            )

            assert.same({}, assigned)
        end)

        it("skips a checker that does not attack", function()
            local assigned = CrossCheck.assign(
                { objection(1, 1) },
                { {}, false }
            )

            assert.same({}, assigned)
        end)

        it("gives one checker no assignment", function()
            local assigned = CrossCheck.assign({ objection(1, 1) }, { {} })

            assert.same({}, assigned)
        end)

        it("gives each objection to every other checker", function()
            local objections = { objection(1, 1), objection(2, 2) }

            local assigned =
                CrossCheck.assign(objections, { { [1] = true }, {}, {} })

            assert.same({
                [1] = { objections[2] },
                [2] = { objections[1] },
                [3] = { objections[1], objections[2] },
            }, assigned)
        end)
    end)

    describe("answers and refuted", function()
        --- Checker 1's objection, attacked by checkers 2 and 3 with the
        --- given attack verdicts.
        --- @param attack_verdicts (table<integer, agentic.CrossCheck.Verdict>|false)[]
        --- @return boolean refuted
        local function attacked(attack_verdicts)
            local o = objection(1, 1)
            local answers = CrossCheck.answers(
                { [2] = { o }, [3] = { o } },
                attack_verdicts
            )
            return CrossCheck.refuted(answers[o])
        end

        it("drops an objection one attack refutes with evidence", function()
            assert.is_true(attacked({
                false,
                { [1] = v("unsure") },
                { [1] = v("refuted", "it holds: a.lua:9") },
            }))
        end)

        it("keeps an objection refuted without evidence", function()
            assert.is_false(attacked({ false, { [1] = v("refuted") }, false }))
        end)

        it("keeps an objection an attack is unsure of", function()
            assert.is_false(
                attacked({ false, { [1] = v("unsure", "maybe") }, false })
            )
        end)

        it("keeps an objection an attack skipped", function()
            assert.is_false(attacked({
                false,
                { [2] = v("refuted", "x") },
                { [0] = v("refuted", "y") },
            }))
        end)

        it("leaves unassigned objections out", function()
            local answers = CrossCheck.answers({}, { false })

            assert.same({}, answers)
            assert.is_false(CrossCheck.refuted(nil))
        end)
    end)
end)

local assert = require("tests.helpers.assert")

local Intervals = require("agentic.utils.intervals")

describe("agentic.utils.Intervals", function()
    describe("union", function()
        it("joins overlapping intervals", function()
            assert.same({ { 1, 5 } }, Intervals.union({ { 3, 5 }, { 1, 4 } }))
        end)

        it("joins touching intervals", function()
            assert.same({ { 1, 5 } }, Intervals.union({ { 1, 3 }, { 3, 5 } }))
        end)

        it("drops nested intervals", function()
            assert.same({ { 1, 9 } }, Intervals.union({ { 1, 9 }, { 2, 3 } }))
        end)

        it("keeps disjoint intervals in ascending order", function()
            assert.same(
                { { 1, 2 }, { 4, 5 } },
                Intervals.union({ { 4, 5 }, { 1, 2 } })
            )
        end)

        it("is empty for no intervals", function()
            assert.same({}, Intervals.union({}))
        end)
    end)

    describe("covered", function()
        it("clips at both ends", function()
            assert.equal(4, Intervals.covered({ { 0, 3 }, { 8, 20 } }, 1, 10))
        end)

        it("counts overlapping intervals once", function()
            assert.equal(4, Intervals.covered({ { 0, 3 }, { 1, 4 } }, 0, 10))
        end)

        it("is 0 for no intervals", function()
            assert.equal(0, Intervals.covered({}, 0, 10))
        end)

        it("is 0 for intervals outside the range", function()
            assert.equal(0, Intervals.covered({ { 20, 30 } }, 0, 10))
        end)
    end)
end)

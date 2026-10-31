local assert = require("tests.helpers.assert")
local List = require("agentic.utils.list")

describe("List", function()
    describe("take_first", function()
        local function is_even(n)
            return n % 2 == 0
        end

        it("removes and returns the first match", function()
            local list = { 1, 2, 3, 4 }

            assert.equal(2, List.take_first(list, is_even))
            assert.same({ 1, 3, 4 }, list)
        end)

        it("returns nil and leaves the list when none matches", function()
            local list = { 1, 3 }

            assert.is_nil(List.take_first(list, is_even))
            assert.same({ 1, 3 }, list)
        end)
    end)
end)

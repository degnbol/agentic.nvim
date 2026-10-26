local assert = require("tests.helpers.assert")
local Json = require("agentic.utils.json")

describe("agentic.utils.json", function()
    describe("present", function()
        it("reads a JSON null as absent", function()
            assert.is_nil(Json.present(vim.NIL))
        end)

        it("keeps every other value", function()
            assert.equal("a", Json.present("a"))
            assert.is_false(Json.present(false))
            assert.is_nil(Json.present(nil))
            local t = {}
            assert.equal(t, Json.present(t))
        end)
    end)
end)

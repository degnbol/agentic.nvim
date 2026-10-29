--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")

describe("agentic.acp.adapters.GeminiACPAdapter", function()
    local GeminiACPAdapter = require("agentic.acp.adapters.gemini_acp_adapter")

    it("ignores its own and the base process output patterns", function()
        local adapter = setmetatable({}, { __index = GeminiACPAdapter })
        assert.is_true(adapter:ignores_output("Experiments loaded {}"))
        assert.is_true(adapter:ignores_output("Session not found"))
        assert.is_false(adapter:ignores_output("Unexpected case"))
    end)
end)

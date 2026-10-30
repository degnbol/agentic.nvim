local assert = require("tests.helpers.assert")

local Duration = require("agentic.utils.duration")

describe("agentic.utils.Duration", function()
    describe("format", function()
        it("formats hours and two-digit minutes", function()
            assert.equal("2h15m", Duration.format(2 * 3600 + 15 * 60))
            assert.equal("1h05m", Duration.format(3600 + 5 * 60))
        end)

        it("formats hours with zero minutes", function()
            assert.equal("1h00m", Duration.format(3600))
        end)

        it("formats minutes only", function()
            assert.equal("45m", Duration.format(45 * 60))
        end)

        it("formats seconds for short durations", function()
            assert.equal("30s", Duration.format(30))
        end)

        it("formats zero seconds", function()
            assert.equal("0s", Duration.format(0))
        end)
    end)
end)

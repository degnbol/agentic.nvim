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

    describe("format_ms", function()
        it("formats milliseconds below a second", function()
            assert.equal("0 ms", Duration.format_ms(0))
            assert.equal("999 ms", Duration.format_ms(999))
        end)

        it("formats seconds to one decimal below a minute", function()
            assert.equal("1.0 s", Duration.format_ms(1000))
            assert.equal("2.8 s", Duration.format_ms(2849))
        end)

        it("rounds down, so just below a minute stays in seconds", function()
            assert.equal("59.9 s", Duration.format_ms(59950))
            assert.equal("59.9 s", Duration.format_ms(59999))
        end)

        it("formats minutes and two-digit seconds below an hour", function()
            assert.equal("1m00s", Duration.format_ms(60000))
            assert.equal("3m12s", Duration.format_ms(192500))
            assert.equal("59m59s", Duration.format_ms(3599999))
        end)

        it("formats hours and two-digit minutes", function()
            assert.equal("1h00m", Duration.format_ms(3600000))
            assert.equal(
                "2h15m",
                Duration.format_ms((2 * 3600 + 15 * 60) * 1000)
            )
        end)
    end)
end)

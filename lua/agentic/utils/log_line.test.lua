local assert = require("tests.helpers.assert")

describe("agentic.utils.LogLine", function()
    local LogLine = require("agentic.utils.log_line")

    describe("summary", function()
        it("drops a trailing JSON value", function()
            assert.equal(
                "Unexpected case",
                LogLine.summary('Unexpected case: {"type":"system"}')
            )
        end)

        it("drops a trailing colon", function()
            assert.equal("Unexpected case", LogLine.summary("Unexpected case:"))
        end)

        it("is nil for JSON alone", function()
            assert.is_nil(LogLine.summary('{"type":"system"}'))
        end)

        it("is nil for a continuation line", function()
            assert.is_nil(LogLine.summary("    at foo (x.js:1:2)"))
        end)

        it("is nil for a closing bracket", function()
            assert.is_nil(LogLine.summary("}"))
            assert.is_nil(LogLine.summary("]"))
        end)

        it("drops the bracket that opens a multi-line value", function()
            assert.equal(
                "Error handling request",
                LogLine.summary("Error handling request {")
            )
        end)

        it("keeps a line without JSON", function()
            local line =
                "Failed to resolve settings: Error: ENOENT: no such file or directory, open '/x'"
            assert.equal(line, LogLine.summary(line))
        end)

        it("keeps brackets that do not start JSON", function()
            assert.equal("Got {not json} here", LogLine.summary("Got {not json} here"))
        end)

        it("keeps truncated JSON", function()
            assert.equal("Bad value: [1, 2", LogLine.summary("Bad value: [1, 2"))
        end)

        it("keeps a line with more brackets than are tried", function()
            local line = "many" .. string.rep(" {x}", 20)
            assert.equal(line, LogLine.summary(line))
        end)
    end)
end)

local assert = require("tests.helpers.assert")
local CanonicalToolCall = require("agentic.acp.canonical_tool_call")

describe("agentic.acp.CanonicalToolCall", function()
    describe("parse_read_range", function()
        it("splits a trailing range off the path", function()
            local path, range =
                CanonicalToolCall.parse_read_range("file.lua (10 - 50)")
            assert.equal("file.lua", path)
            assert.same({ offset = 10, limit = 41 }, range)
        end)

        it("gives nil without a range", function()
            assert.is_nil((CanonicalToolCall.parse_read_range("file.lua")))
        end)
    end)

    describe("normalise", function()
        it("moves a read's range from the argument to read_range", function()
            local message = CanonicalToolCall.normalise({
                tool_call_id = "r",
                status = "pending",
                argument = "Read /tmp/file.txt (1 - 100)",
            }, "read")
            assert.equal("Read /tmp/file.txt", message.argument)
            assert.same({ offset = 1, limit = 100 }, message.read_range)
        end)

        it("keeps a read_range the message already has", function()
            local message = CanonicalToolCall.normalise({
                tool_call_id = "r",
                status = "pending",
                argument = "/tmp/file.txt (1 - 100)",
                read_range = { offset = 5 },
            }, "Read")
            assert.equal("/tmp/file.txt", message.argument)
            assert.same({ offset = 5 }, message.read_range)
        end)

        it("leaves a message without an argument as it is", function()
            --- @type agentic.ui.MessageWriter.ToolCallBase
            local update = { tool_call_id = "r", status = "completed" }
            assert.same(update, CanonicalToolCall.normalise(update, "read"))
        end)

        it("unwraps an execute body that is one fenced block", function()
            local message = CanonicalToolCall.normalise({
                tool_call_id = "e",
                status = "completed",
                body = { "```console", "hi", "```" },
            }, "execute")
            assert.same({ "hi" }, message.body)
        end)

        it("leaves other kinds unchanged", function()
            --- @type agentic.ui.MessageWriter.ToolCallBase
            local message = {
                tool_call_id = "o",
                status = "completed",
                argument = "notes (1 - 2)",
                body = { "```", "x", "```" },
            }
            assert.same(message, CanonicalToolCall.normalise(message, "other"))
        end)

        it("does not modify the message", function()
            --- @type agentic.ui.MessageWriter.ToolCallBase
            local message = {
                tool_call_id = "r",
                status = "pending",
                argument = "/tmp/f (1 - 2)",
            }
            CanonicalToolCall.normalise(message, "read")
            assert.equal("/tmp/f (1 - 2)", message.argument)
            assert.is_nil(message.read_range)
        end)

        it("unwraps one more fence per call from a nested body", function()
            local once = CanonicalToolCall.normalise({
                tool_call_id = "e",
                status = "completed",
                body = { "````", "```", "x", "```", "````" },
            }, "execute")
            assert.same({ "```", "x", "```" }, once.body)
            assert.same(
                { "x" },
                CanonicalToolCall.normalise(once, "execute").body
            )
        end)
    end)

    describe("split_read_range", function()
        it("is idempotent", function()
            local once = CanonicalToolCall.split_read_range({
                tool_call_id = "r",
                status = "pending",
                argument = "/tmp/f (1 - 2)",
            }, "read")
            assert.same(once, CanonicalToolCall.split_read_range(once, "read"))
        end)

        it("leaves an execute body fenced", function()
            local body = { "```", "x", "```" }
            local split = CanonicalToolCall.split_read_range({
                tool_call_id = "e",
                status = "completed",
                body = body,
            }, "execute")
            assert.same(body, split.body)
        end)
    end)

    describe("format_read_range", function()
        it("inverts parse_read_range", function()
            local _, range = CanonicalToolCall.parse_read_range("f (10 - 14)")
            --- @cast range -nil
            assert.equal("(10 - 14)", CanonicalToolCall.format_read_range(range))
        end)

        it("leaves an open range's end open", function()
            assert.equal(
                "(10 - …)",
                CanonicalToolCall.format_read_range({ offset = 10 })
            )
        end)
    end)
end)

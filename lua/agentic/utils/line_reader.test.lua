local assert = require("tests.helpers.assert")

describe("agentic.utils.LineReader", function()
    local LineReader = require("agentic.utils.line_reader")

    --- @type string[]
    local lines
    --- @type fun(data: string|nil)
    local feed

    before_each(function()
        lines = {}
        feed = LineReader.new(function(line)
            table.insert(lines, line)
        end)
    end)

    it("joins a line split across two chunks", function()
        feed("hel")
        assert.same({}, lines)
        feed("lo\n")
        assert.same({ "hello" }, lines)
    end)

    it("emits every complete line of one chunk", function()
        feed("a\n  b\nc")
        assert.same({ "a", "  b" }, lines)
    end)

    it("removes a trailing carriage return", function()
        feed("a\r\nb\r\n")
        assert.same({ "a", "b" }, lines)
    end)

    it("flushes an unterminated line at end of stream", function()
        feed("a\nrest")
        feed(nil)
        assert.same({ "a", "rest" }, lines)
    end)

    it("emits nothing at end of stream after a complete line", function()
        feed("a\n")
        feed(nil)
        assert.same({ "a" }, lines)
    end)

    it("emits nothing for an empty chunk", function()
        feed("")
        feed(nil)
        assert.same({}, lines)
    end)

    it("keeps an empty line between two lines", function()
        feed("a\n\nb\n")
        assert.same({ "a", "", "b" }, lines)
    end)
end)

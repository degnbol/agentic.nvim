local assert = require("tests.helpers.assert")
local GrepOutput = require("agentic.utils.grep_output")

describe("GrepOutput.prefix_patterns", function()
    it("gives one pattern per file-name state and field count", function()
        assert.same(
            { "^", "^%d+:", "^[^:]+:", "^[^:]+:%d+:" },
            GrepOutput.prefix_patterns({ names = { 0, 1 }, fields = { 0, 1 } })
        )
    end)

    it("repeats the numeric field", function()
        assert.same(
            { "^[^:]+:%d+:%d+:%d+:" },
            GrepOutput.prefix_patterns({ names = { 1 }, fields = { 3 } })
        )
    end)

    it("repeats the name field", function()
        assert.same(
            { "^[^:]+:[^:]+:" },
            GrepOutput.prefix_patterns({ names = { 2 }, fields = { 0 } })
        )
    end)

    it("gives none when the output shows no matched text", function()
        assert.same(
            {},
            GrepOutput.prefix_patterns({ names = { 1 }, fields = {} })
        )
    end)
end)

describe("GrepOutput.text_starts", function()
    local numbered = GrepOutput.prefix_patterns({
        names = { 1, 0 },
        fields = { 1 },
    })

    --- @type { line: string, prefixes: string[], starts: integer[] }[]
    local cases = {
        { line = "a.lua:12:foo", prefixes = numbered, starts = { 9 } },
        { line = "12:foo", prefixes = numbered, starts = { 3 } },
        { line = "12:34:x", prefixes = numbered, starts = { 6, 3 } },
        { line = "2024:12:text", prefixes = numbered, starts = { 8, 5 } },
        { line = "f-3-x", prefixes = numbered, starts = {} },
        { line = "--", prefixes = numbered, starts = {} },
        { line = "no prefix here", prefixes = numbered, starts = {} },
        { line = "a:b", prefixes = { "^", "^[^:]+:" }, starts = { 0, 2 } },
        {
            line = "  Line 57: foo",
            prefixes = GrepOutput.SEARCH_PREFIXES,
            starts = { 11 },
        },
    }

    for _, c in ipairs(cases) do
        it(c.line, function()
            assert.same(
                c.starts,
                GrepOutput.text_starts(c.line, c.prefixes, {})
            )
        end)
    end

    it("deduplicates starts", function()
        assert.same({ 0 }, GrepOutput.text_starts("x", { "^", "^" }, {}))
    end)

    it("rejects a diagnostic of a named command", function()
        assert.same(
            {},
            GrepOutput.text_starts(
                "grep: d/b.bin: binary file matches",
                { "^", "^[^:]+:" },
                { "grep" }
            )
        )
    end)

    it("rejects a binary-file notice", function()
        assert.same(
            {},
            GrepOutput.text_starts("Binary file d/b matches", { "^" }, {})
        )
    end)
end)

describe("GrepOutput.strip_omitted", function()
    it("drops a line that is only the placeholder", function()
        assert.is_nil(GrepOutput.strip_omitted("[Omitted long matching line]"))
    end)

    it("removes a trailing preview marker", function()
        assert.equal(
            "abc",
            GrepOutput.strip_omitted("abc [... omitted end of long line]")
        )
    end)

    it("keeps other text", function()
        assert.equal("abc", GrepOutput.strip_omitted("abc"))
    end)
end)

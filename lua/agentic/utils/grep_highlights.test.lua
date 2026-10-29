local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local GrepHighlights = require("agentic.utils.grep_highlights")
local GrepOutput = require("agentic.utils.grep_output")
local GrepRegex = require("agentic.utils.grep_regex")
local Logger = require("agentic.utils.logger")

--- The text under each match, split by whether it is a term or a prefix part.
--- @param rows string[]
--- @param matches agentic.utils.GrepHighlights.Match[]
--- @return { terms: string[], prefix_parts: string[] }
local function matched_texts(rows, matches)
    local texts = { terms = {}, prefix_parts = {} }
    for _, m in ipairs(matches) do
        local text = rows[m.line_index + 1]:sub(m.col_start + 1, m.col_end)
        table.insert(m.hl_group and texts.prefix_parts or texts.terms, text)
    end
    return texts
end

describe("agentic.utils.GrepHighlights", function()
    describe("prefixes", function()
        it("gives each prefix part a span on its row", function()
            local rows = { "x", "a.lua:3:foo" }
            local matches = GrepHighlights.prefixes(rows, false)
            assert.equal(1, matches[1].line_index)
            assert.same(
                { "a.lua", ":", "3", ":" },
                matched_texts(rows, matches).prefix_parts
            )
        end)
    end)

    describe("terms", function()
        --- @param rows string[]
        --- @param pattern string
        --- @return string[]
        local function terms(rows, pattern)
            return matched_texts(
                rows,
                GrepHighlights.terms(
                    rows,
                    GrepRegex.translate({ pattern }, { "rust" }, nil) or nil,
                    false,
                    GrepOutput.SEARCH_PREFIXES,
                    {}
                )
            ).terms
        end

        it("matches the text after the prefix", function()
            assert.same({ "foo" }, terms({ "foo.lua:3:foo" }, "foo"))
        end)

        it("gives none without a translation", function()
            assert.same(
                {},
                GrepHighlights.terms({ "3:foo" }, nil, false, {}, {})
            )
        end)

        it("notifies a failed match and gives none", function()
            local notify_stub = spy.stub(Logger, "notify")
            local found = terms({ "1:" .. ("word "):rep(40) }, [[(\w*\b\s*)*;]])
            notify_stub:revert()
            assert.same({}, found)
            assert.equal(1, notify_stub.call_count)
        end)
    end)

    describe("for_command", function()
        it("takes each grep's pattern and layout", function()
            local rows = { "a.lua:3:foo bar" }
            local texts = matched_texts(
                rows,
                GrepHighlights.for_command(rows, 'cd /x; rg -n "foo" .')
            )
            assert.same({ "foo" }, texts.terms)
            assert.same({ "a.lua", ":", "3", ":" }, texts.prefix_parts)
        end)

        it("accepts a path-less prefix when a grep numbers lines", function()
            local rows = { "12:foo" }
            local texts = matched_texts(
                rows,
                GrepHighlights.for_command(rows, "grep -n foo f")
            )
            assert.same({ "12", ":" }, texts.prefix_parts)
        end)

        it("is empty for a command without a grep", function()
            assert.same(
                {},
                GrepHighlights.for_command({ "a.lua:3:x" }, "echo x | head")
            )
        end)
    end)
end)

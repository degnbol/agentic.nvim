local assert = require("tests.helpers.assert")
local MarkdownGuard = require("agentic.utils.markdown_guard")

describe("agentic.utils.MarkdownGuard", function()
    describe("whole_within", function()
        it("wraps the text in one code span", function()
            assert.equal("`a b`", MarkdownGuard.whole_within("a b", math.huge))
        end)

        it("outlasts a backtick run in the text", function()
            assert.equal(
                "``don`t``",
                MarkdownGuard.whole_within("don`t", math.huge)
            )
        end)

        it("pads a text that abuts a delimiter", function()
            assert.equal(
                "`` `x ``",
                MarkdownGuard.whole_within("`x", math.huge)
            )
        end)

        it("cuts the text so the span fits the width", function()
            local span = MarkdownGuard.whole_within(string.rep("x", 30), 10)
            assert.is_true(vim.fn.strdisplaywidth(span) <= 10)
            assert.equal("…`", span:sub(-#"…`"))
        end)
    end)

    describe("words_within", function()
        it("guards only the words markdown could reinterpret", function()
            assert.equal(
                "run `foo_bar` now",
                MarkdownGuard.words_within("run foo_bar now", math.huge)
            )
        end)

        it("keeps punctuation outside the guard", function()
            assert.equal(
                "(see `foo_bar`),",
                MarkdownGuard.words_within("(see foo_bar),", math.huge)
            )
        end)

        it("cuts before guarding, so no guard is left open", function()
            local guarded =
                MarkdownGuard.words_within("_x_ " .. string.rep("y", 30), 12)
            assert.is_true(vim.fn.strdisplaywidth(guarded) <= 12)
            assert.equal("`_x_`", guarded:sub(1, #"`_x_`"))
        end)
    end)
end)

local Mention = require("agentic.utils.mention")
local assert = require("tests.helpers.assert")

describe("agentic.utils.Mention", function()
    describe("spans", function()
        it("finds a mention at line start", function()
            assert.same(
                { { at_col = 0, path = "a.lua" } },
                Mention.spans("@a.lua")
            )
        end)

        it("finds a mention after a space and after a tab", function()
            assert.same({
                { at_col = 4, path = "a" },
                { at_col = 7, path = "b" },
            }, Mention.spans("see @a\t@b"))
        end)

        it("excludes an @ inside a word", function()
            assert.same({}, Mention.spans("user@host"))
        end)

        it("excludes an @ alone", function()
            assert.same({}, Mention.spans("a @ b"))
        end)

        it("drops a trailing run of non-word characters", function()
            assert.same(
                { { at_col = 0, path = "README.md" } },
                Mention.spans("@README.md.")
            )
            assert.same(
                { { at_col = 0, path = "lua" } },
                Mention.spans("@lua/")
            )
            assert.same(
                { { at_col = 5, path = "x.md" } },
                Mention.spans("(see @x.md)")
            )
        end)

        it("excludes a word of only non-word characters", function()
            assert.same({}, Mention.spans("@./"))
        end)

        it("drops a # suffix", function()
            assert.same(
                { { at_col = 0, path = "x.md" } },
                Mention.spans("@x.md#L10-20")
            )
        end)

        it("keeps ~", function()
            assert.same({ { at_col = 0, path = "~/x" } }, Mention.spans("@~/x"))
        end)
    end)
end)

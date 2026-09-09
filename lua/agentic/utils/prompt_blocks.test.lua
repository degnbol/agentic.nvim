local PromptBlocks = require("agentic.utils.prompt_blocks")
local assert = require("tests.helpers.assert")

--- Blocks as `{ text, start_row, end_row }`. Where the boundaries fall is what
--- the split decides; a block's command-ness is `PromptBlocks.command` on its
--- text, covered by its own cases above.
--- @param blocks agentic.utils.PromptBlocks.Block[]
--- @return table[]
local function shape(blocks)
    return vim.tbl_map(function(b)
        return { b.text, b.sr, b.er }
    end, blocks)
end

describe("agentic.utils.PromptBlocks", function()
    describe("command", function()
        it("reads the word and its argument", function()
            local word, arg = PromptBlocks.command("/rename a b")
            assert.equal("rename", word)
            assert.equal("a b", arg)
        end)

        it("reads a bare command with an empty argument", function()
            local word, arg = PromptBlocks.command("/compact")
            assert.equal("compact", word)
            assert.equal("", arg)
        end)

        it("accepts digits, dashes and underscores in the word", function()
            assert.equal("a-b_c1", (PromptBlocks.command("/a-b_c1")))
        end)

        it("rejects a path: the word never ends at whitespace", function()
            assert.is_nil((PromptBlocks.command("/usr/bin/env foo")))
            assert.is_nil((PromptBlocks.command("/etc/hosts")))
        end)

        it("rejects a slash with no word", function()
            assert.is_nil((PromptBlocks.command("/")))
            assert.is_nil((PromptBlocks.command("//")))
        end)

        it("rejects an indented command", function()
            assert.is_nil((PromptBlocks.command("  /compact")))
        end)

        it("rejects multi-line text, so no argument spans lines", function()
            assert.is_nil((PromptBlocks.command("/rename a\nb")))
        end)
    end)

    describe("split", function()
        -- The property that makes splitting safe to apply to every submit.
        it("yields exactly one block for prose-only text", function()
            assert.same({
                { "Continue with the refactor\nthen run the tests", 0, 1 },
            }, shape(PromptBlocks.split({
                "Continue with the refactor",
                "then run the tests",
            })))
        end)

        it("splits a command from the prose below it", function()
            assert.same({
                { "/compact", 0, 0 },
                { "Continue", 1, 1 },
            }, shape(PromptBlocks.split({ "/compact", "Continue" })))
        end)

        it("splits a command from the prose above it", function()
            assert.same({
                { "Continue", 0, 0 },
                { "/compact", 1, 1 },
            }, shape(PromptBlocks.split({ "Continue", "/compact" })))
        end)

        it("never absorbs the line below into an argument", function()
            assert.same({
                { "/compact", 0, 0 },
                { "Focus on X", 1, 1 },
            }, shape(PromptBlocks.split({ "/compact", "Focus on X" })))
        end)

        it("keeps path lines in one prose block", function()
            assert.same(
                { { "/usr/bin/env foo\n/etc/hosts\n//\n/", 0, 3 } },
                shape(PromptBlocks.split({
                    "/usr/bin/env foo",
                    "/etc/hosts",
                    "//",
                    "/",
                }))
            )
        end)

        -- Guards the trim order: the whole-prompt trim used to run before the
        -- split, which would strip the indent and make this a command again.
        it("keeps an indented first-line command indented", function()
            local blocks = PromptBlocks.split({ "  /compact" })
            assert.same({ { "  /compact", 0, 0 } }, shape(blocks))
            -- Indented is what makes it prose, on this path and every later
            -- one that re-reads the text.
            assert.is_nil((PromptBlocks.command(blocks[1].text)))
        end)

        it("drops the blank line between two commands", function()
            assert.same({
                { "/context", 0, 0 },
                { "/compact", 2, 2 },
            }, shape(PromptBlocks.split({ "/context", "", "/compact" })))
        end)

        it("trims a prose block's edge blank lines but spans them", function()
            assert.same(
                { { "hello", 0, 2 } },
                shape(PromptBlocks.split({ "", "hello   ", "  " }))
            )
        end)

        it("keeps blank lines inside a prose block", function()
            assert.same(
                { { "one\n\ntwo", 0, 2 } },
                shape(PromptBlocks.split({ "one", "", "two" }))
            )
        end)

        it("yields nothing for blank input", function()
            assert.same({}, shape(PromptBlocks.split({ "", "  " })))
            assert.same({}, shape(PromptBlocks.split({})))
        end)

        it("strips a command line's trailing whitespace", function()
            assert.same(
                { { "/trust repo", 0, 0 } },
                shape(PromptBlocks.split({ "/trust repo  " }))
            )
        end)
    end)
end)

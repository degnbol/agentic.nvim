local MarkdownInline = require("agentic.utils.markdown_inline")
local assert = require("tests.helpers.assert")

--- Word texts, each wrapped in its span's markup and glued text.
--- @param text string
--- @return string[]
local function shown(text)
    local out = {}
    for i, word in ipairs(MarkdownInline.words(text)) do
        local core = word.span
                and (word.span.open .. word.text .. word.span.close)
            or word.text
        out[i] = (word.prefix or "") .. core .. (word.suffix or "")
    end
    return out
end

describe("agentic.utils.MarkdownInline", function()
    describe("words", function()
        it("splits plain text at whitespace", function()
            assert.same({ "a", "bc", "d" }, shown("a  bc\td"))
        end)

        it("keeps code spans and inline math whole", function()
            assert.same(
                { "see", "`a b`", "and", "$x + y$" },
                shown("see `a b` and $x + y$")
            )
        end)

        it("gives each word of an inline link the link's span", function()
            local words = MarkdownInline.words("see [the docs](https://u) now")
            assert.same(
                { "see", "the", "docs", "now" },
                vim.tbl_map(function(w)
                    return w.text
                end, words)
            )
            assert.is_nil(words[1].span)
            assert.is_true(words[2].span == words[3].span)
            assert.same({ open = "[", close = "](https://u)" }, words[2].span)
        end)

        it("keeps a link title in the span's close", function()
            local words = MarkdownInline.words('[a b](u "a title")')
            assert.equal('](u "a title")', words[1].span.close)
            assert.equal(2, #words)
        end)

        it("splits strong emphasis and strikethrough", function()
            assert.same(
                { "**strong**", "**words**", "~~gone~~", "~~away~~" },
                shown("**strong words** ~~gone away~~")
            )
        end)

        it("keeps a span nested in a splittable one whole", function()
            assert.same(
                { "**see**", "***it now***", "**ok**" },
                shown("**see *it now* ok**")
            )
        end)

        it("gives stray markup no span", function()
            for _, text in ipairs({ "2 * 3 * 4", "snake_case x", "\\*a b\\*" }) do
                for _, word in ipairs(MarkdownInline.words(text)) do
                    assert.is_nil(word.span)
                end
            end
            assert.same({ "\\*a", "b\\*" }, shown("\\*a b\\*"))
        end)

        it("keeps images and reference links whole", function()
            assert.same({
                "![alt text](p.png)",
                "[short ref]",
                "[full x][r]",
                "[c d][]",
            }, shown(
                "![alt text](p.png) [short ref] [full x][r] [c d][]"
            ))
        end)

        it("puts text glued to a span on its edge words", function()
            assert.same(
                { "foo**bar**", "**baz**qux", "end" },
                shown("foo**bar baz**qux end")
            )
            assert.same(
                { "[the](u)", "[docs](u).", "(*x*", "*y*)" },
                shown("[the docs](u). (*x y*)")
            )
        end)

        it(
            "keeps a span sharing glued text with the span before whole",
            function()
                assert.same(
                    { "**a**", "**b**`x y`**c d**" },
                    shown("**a b**`x y`**c d**")
                )
                assert.same({ "*a*", "*b**c d*" }, shown("*a b**c d*"))
            end
        )

        it("splits only double-tilde strikethrough", function()
            assert.same(
                { "from", "~5 to 10~", "ms" },
                shown("from ~5 to 10~ ms")
            )
            assert.same({ "~~a~~", "~~b~~" }, shown("~~a b~~"))
            for _, word in ipairs(MarkdownInline.words("~~a ~~b c~~ d~~")) do
                assert.is_true(word.text:find("~~~~") == nil)
            end
        end)

        it("returns no words for empty text", function()
            assert.same({}, MarkdownInline.words(""))
        end)
    end)
end)

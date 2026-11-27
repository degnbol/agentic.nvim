local assert = require("tests.helpers.assert")

local Chunks = require("agentic.ui.chunks")

describe("agentic.ui.Chunks", function()
    describe("columns", function()
        it("pads after a left cell and before a right cell", function()
            local rows = Chunks.columns({
                { { "5h" }, { "|" }, { "3%" } },
                { { "7d" }, { "|" }, { "96%" } },
                { { "extra" }, { "|" }, { "1%" } },
            }, { [3] = true })
            assert.same({
                "5h   | 3%",
                "7d   |96%",
                "extra| 1%",
            }, vim.tbl_map(Chunks.text, rows))
        end)

        it("ends a row with fewer cells after its last cell", function()
            local rows = Chunks.columns({
                { { "a" }, { "|" }, { "x" } },
                { { "a" } },
                { { "long" } },
            }, {})
            assert.same(
                { "a   |x", "a", "long" },
                vim.tbl_map(Chunks.text, rows)
            )
        end)

        it("pads by display width", function()
            local rows = Chunks.columns({
                { { "→→" }, { "|" } },
                { { "ab" }, { "|" } },
                { { "abc" }, { "|" } },
            }, {})
            assert.same(
                { "→→ |", "ab |", "abc|" },
                vim.tbl_map(Chunks.text, rows)
            )
        end)

        it("keeps the highlights of the cells, not of the padding", function()
            local rows = Chunks.columns({
                { { "a", "Hl" }, { "|" }, { "1", "Hl" } },
                { { "abc", "Hl" }, { "|" }, { "10", "Hl" } },
            }, { [3] = true })
            assert.same({
                { "a", "Hl" },
                { "  " },
                { "|" },
                { " " },
                { "1", "Hl" },
            }, rows[1])
            assert.same({
                { "abc", "Hl" },
                { "|" },
                { "10", "Hl" },
            }, rows[2])
        end)
    end)
end)

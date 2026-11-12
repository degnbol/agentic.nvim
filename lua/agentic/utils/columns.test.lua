local assert = require("tests.helpers.assert")

local Columns = require("agentic.utils.columns")

describe("agentic.utils.Columns", function()
    describe("align", function()
        it("pads every column but the last to its widest cell", function()
            assert.same(
                { "a    bb  x", "ccc  d   yy" },
                Columns.align(
                    { { "a", "bb", "x" }, { "ccc", "d", "yy" } },
                    "  "
                )
            )
        end)

        it("pads by display width", function()
            assert.same(
                { "ø   x", "ab  y" },
                Columns.align({ { "ø", "x" }, { "ab", "y" } }, "  ")
            )
        end)

        it("leaves out a column empty on every row", function()
            assert.same(
                { "a  x", "b  y" },
                Columns.align({ { "a", "", "x" }, { "b", "", "y" } }, "  ")
            )
        end)

        it("pads no cell after the last non-empty column", function()
            assert.same(
                { "a", "bb" },
                Columns.align({ { "a", "" }, { "bb", "" } }, "  ")
            )
        end)

        it("gives no lines for no rows", function()
            assert.same({}, Columns.align({}, "  "))
        end)
    end)
end)

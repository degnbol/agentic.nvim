local Conceal = require("agentic.utils.conceal")
local EdgeConceal = require("agentic.ui.edge_conceal")
local assert = require("tests.helpers.assert")

--- A range on row 0 that hides bytes col..end_col-1.
--- @param col integer
--- @param end_col integer
--- @return agentic.utils.Conceal.Range
local function hidden(col, end_col)
    return {
        row = 0,
        col = col,
        end_col = end_col,
        text = "",
        priority = 100,
        starts_on_row = true,
    }
end

-- A link concealed down to its label: raw "ab[cd](efgh)ij…" shows "abcdij…".
local LINK_RANGES = { hidden(2, 3), hidden(5, 12) }
local LONG_LINE = "ab[cd](efgh)ijklmnopqrstuvwxyz"

--- Columns of `line` under `LINK_RANGES`.
--- @param line string
--- @param inlines agentic.utils.Conceal.Inline[]|nil
--- @return agentic.utils.Conceal.Columns
local function link_columns(line, inlines)
    return Conceal.columns(line, LINK_RANGES, inlines or {}, 8)
end

--- `EdgeConceal.hide_range` results packed into a list.
--- @param columns agentic.utils.Conceal.Columns
--- @param leftcol integer
--- @param cursor_col integer|nil
--- @return (integer|nil)[] range
local function hide(columns, leftcol, cursor_col)
    return { EdgeConceal.hide_range(columns, leftcol, cursor_col) }
end

describe("agentic.ui.EdgeConceal", function()
    describe("hide_range", function()
        it(
            "hides as many cells as the concealed run left of leftcol",
            function()
                -- leftcol 13 skips 8 concealed bytes, so 8 more cells are hidden.
                assert.same({ 13, 21 }, hide(link_columns(LONG_LINE), 13))
            end
        )

        it(
            "hides nothing when the concealed run is right of leftcol",
            function()
                assert.same({}, hide(link_columns(LONG_LINE), 1))
            end
        )

        it("counts only the part of a run left of leftcol", function()
            -- leftcol 6 is inside the URL: 2 hidden bytes are skipped.
            assert.same({ 6, 14 }, hide(link_columns(LONG_LINE), 6))
        end)

        it("clamps the range to the line end", function()
            assert.same({ 13, 14 }, hide(link_columns("ab[cd](efgh)ij"), 13))
        end)

        it("hides nothing on a line shorter than leftcol", function()
            assert.same({}, hide(link_columns("ab[cd](efgh)ij"), 20))
        end)

        it("ends before inline virt text inside the range", function()
            local columns = link_columns(LONG_LINE, { { col = 16, width = 2 } })
            assert.same({ 13, 16 }, hide(columns, 13))
        end)

        it(
            "hides the cursor byte when text remains right of the range",
            function()
                assert.same({ 13, 21 }, hide(link_columns(LONG_LINE), 13, 13))
            end
        )

        it(
            "ends before the cursor when the range reaches the line end",
            function()
                local columns = link_columns("ab[cd](efgh)ijk")
                assert.same({ 13, 14 }, hide(columns, 13, 14))
                assert.same({}, hide(columns, 13, 13))
            end
        )

        it("includes a double-width character that overshoots", function()
            -- "[x]全全ab" with the brackets hidden: 全 at bytes 3 and 6.
            local columns = Conceal.columns(
                "[x]全全ab",
                { hidden(0, 1), hidden(2, 3) },
                {},
                8
            )
            assert.same({ 3, 6 }, hide(columns, 3))
            assert.same({ 6, 9 }, hide(columns, 4))
        end)
    end)
end)

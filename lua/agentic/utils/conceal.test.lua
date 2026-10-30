local Conceal = require("agentic.utils.conceal")
local assert = require("tests.helpers.assert")

--- A conceal range on row 0.
--- @param col integer
--- @param end_col integer
--- @param text string
--- @param priority integer|nil 100 when nil
--- @param starts_on_row boolean|nil true when nil
--- @return agentic.utils.Conceal.Range
local function range(col, end_col, text, priority, starts_on_row)
    return {
        row = 0,
        col = col,
        end_col = end_col,
        text = text,
        priority = priority or 100,
        starts_on_row = starts_on_row ~= false,
    }
end

--- Displayed vcol at each character start of `line`, in byte order.
--- @param line string
--- @param ranges agentic.utils.Conceal.Range[]
--- @param inlines agentic.utils.Conceal.Inline[]|nil
--- @return integer[]
local function shown(line, ranges, inlines)
    local columns = Conceal.columns(line, ranges, inlines or {}, 8)
    return vim.tbl_map(function(byte)
        return columns.shown[byte]
    end, columns.starts)
end

describe("agentic.utils.Conceal", function()
    describe("columns", function()
        it("counts every character without conceal", function()
            local columns = Conceal.columns("abc", {}, {}, 8)
            assert.same({ 0, 1, 2, 3 }, columns.starts)
            assert.same({ [0] = 0, 1, 2, 3 }, columns.raw)
            assert.same({ [0] = 0, 1, 2, 3 }, columns.shown)
        end)

        it("keys multibyte characters by their first byte", function()
            local columns = Conceal.columns("aéb", {}, {}, 8)
            assert.same({ 0, 1, 3, 4 }, columns.starts)
            assert.equal(2, columns.raw[3])
        end)

        it("widens a tab to the next multiple of tabstop", function()
            assert.same(
                { [0] = 0, 1, 4, 5 },
                Conceal.columns("a\tb", {}, {}, 4).raw
            )
            assert.same(
                { [0] = 0, 1, 8, 9 },
                Conceal.columns("a\tb", {}, {}, 8).raw
            )
        end)

        it("gives a hidden run no width", function()
            assert.same(
                { 0, 1, 1, 1, 1, 2 },
                shown("a[b]c", { range(1, 4, "") })
            )
        end)

        it("draws a replacement at the start of its run", function()
            assert.same(
                { 0, 1, 2, 2, 2, 3 },
                shown("a[b]c", { range(1, 4, "X") })
            )
        end)

        it(
            "draws a second replacement where a higher-priority range starts inside",
            function()
                assert.same(
                    { 0, 1, 1, 2, 2, 2, 2, 3 },
                    shown(
                        "abcdefg",
                        { range(0, 6, "x", 100), range(2, 4, "y", 200) }
                    )
                )
            end
        )

        it(
            "loses a replacement whose start a higher-priority range covers",
            function()
                assert.same(
                    { 0, 0, 0, 0, 0, 0, 0, 1 },
                    shown(
                        "abcdefg",
                        { range(2, 6, "x", 100), range(0, 4, "", 200) }
                    )
                )
            end
        )

        it("lets the later of two equal-priority ranges decide", function()
            assert.same(
                { 0, 0, 0, 0 },
                shown("abc", { range(0, 3, "x"), range(0, 3, "") })
            )
            assert.same(
                { 0, 1, 1, 1 },
                shown("abc", { range(0, 3, ""), range(0, 3, "x") })
            )
        end)

        it(
            "draws no replacement for a range continued from an earlier row",
            function()
                assert.same(
                    { 0, 0, 0, 0, 1 },
                    shown("abcd", { range(0, 3, "X", 100, false) })
                )
            end
        )

        it(
            "counts inline virt text in both raw and displayed columns",
            function()
                local columns = Conceal.columns(
                    "ab",
                    {},
                    { { col = 1, width = 3 } },
                    8
                )
                assert.same({ [0] = 0, 4, 5 }, columns.raw)
                assert.same({ [0] = 0, 4, 5 }, columns.shown)
                assert.same({ [1] = true }, columns.inline_at)
            end
        )

        it("counts a double-width replacement as two cells", function()
            assert.same({ 0, 2, 2, 3 }, shown("abc", { range(0, 2, "全") }))
        end)
    end)

    describe("split_rows", function()
        it("splits a range spanning rows into one range per row", function()
            assert.same({
                {
                    row = 2,
                    col = 4,
                    end_col = vim.v.maxcol,
                    text = "x",
                    priority = 100,
                    starts_on_row = true,
                },
                {
                    row = 3,
                    col = 0,
                    end_col = 2,
                    text = "x",
                    priority = 100,
                    starts_on_row = false,
                },
            }, Conceal.split_rows({ 2, 4, 3, 2 }, "x", 100, 0, 10))
        end)

        it("keeps only rows inside the window", function()
            local pieces = Conceal.split_rows({ 0, 4, 5, 2 }, "", 100, 2, 4)
            assert.same(
                { 2, 3 },
                vim.tbl_map(function(piece)
                    return piece.row
                end, pieces)
            )
        end)

        it("drops an empty piece at the end row", function()
            assert.equal(1, #Conceal.split_rows({ 0, 4, 1, 0 }, "", 100, 0, 10))
        end)
    end)

    describe("buffer queries", function()
        local bufnr
        local ns = vim.api.nvim_create_namespace("conceal_test")

        before_each(function()
            bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(
                bufnr,
                0,
                -1,
                false,
                { "zero", "one", "two", "three" }
            )
        end)

        after_each(function()
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("returns conceal extmarks overlapping the rows", function()
            vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 2, {
                end_row = 1,
                end_col = 2,
                conceal = "c",
                hl_group = "Comment",
                priority = 300,
            })
            vim.api.nvim_buf_set_extmark(bufnr, ns, 2, 0, {
                end_col = 1,
                conceal = "",
            })
            vim.api.nvim_buf_set_extmark(bufnr, ns, 2, 1, {
                end_col = 2,
                hl_group = "Comment",
            })
            assert.same({
                {
                    row = 1,
                    col = 0,
                    end_col = 2,
                    text = "c",
                    priority = 300,
                    starts_on_row = false,
                },
                {
                    row = 2,
                    col = 0,
                    end_col = 1,
                    text = "",
                    priority = 4096,
                    starts_on_row = true,
                },
            }, Conceal.extmark_ranges(bufnr, 1, 3))
        end)

        it("returns inline virt text widths by row", function()
            vim.api.nvim_buf_set_extmark(bufnr, ns, 1, 2, {
                virt_text = { { "ab" }, { "全" } },
                virt_text_pos = "inline",
            })
            vim.api.nvim_buf_set_extmark(bufnr, ns, 2, 0, {
                virt_text = { { "eol" } },
                virt_text_pos = "eol",
            })
            assert.same(
                { [1] = { { col = 2, width = 4 } } },
                Conceal.inline_widths(bufnr, 0, 4)
            )
        end)
    end)
end)

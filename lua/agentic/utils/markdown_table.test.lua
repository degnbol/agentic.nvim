local MarkdownTable = require("agentic.utils.markdown_table")
local assert = require("tests.helpers.assert")

--- Cell count of each row of the first pipe table the markdown parser finds.
--- @param lines string[]
--- @return integer[] counts empty when no table parses
local function parsed_cell_counts(lines)
    local src = table.concat(lines, "\n") .. "\n"
    local root =
        vim.treesitter.get_string_parser(src, "markdown"):parse()[1]:root()
    local query = vim.treesitter.query.parse("markdown", "(pipe_table) @t")
    local counts = {}
    for _, node in query:iter_captures(root, src) do
        for row in node:iter_children() do
            if row:type() ~= "pipe_table_delimiter_row" then
                local n = 0
                for child in row:iter_children() do
                    if child:type() == "pipe_table_cell" then
                        n = n + 1
                    end
                end
                counts[#counts + 1] = n
            end
        end
        break
    end
    return counts
end

--- @param n_cols integer
--- @param n_rows integer
--- @return integer[]
local function uniform(n_cols, n_rows)
    local counts = {}
    for i = 1, n_rows do
        counts[i] = n_cols
    end
    return counts
end

describe("agentic.utils.MarkdownTable", function()
    describe("lines", function()
        it("pads every column and adds leading and trailing pipes", function()
            assert.same(
                {
                    "| Name  | V   |",
                    "| ----- | --- |",
                    "| short | x   |",
                    "| a     |     |",
                },
                MarkdownTable.lines(
                    { "Name", "V" },
                    { { "short", "x" }, { "a" } }
                )
            )
        end)

        it("keeps alignment colons", function()
            local lines = MarkdownTable.lines(
                { "Left", "Centre", "Right" },
                { { "a", "b", "c" } },
                { ":---", ":---:", "---:" }
            )
            assert.equal("| :--- | :----: | ----: |", lines[2])
        end)

        it("parses as a table with every cell", function()
            local cases = {
                { { "k" }, { { "a" } } },
                { { "k" }, { { "-" }, { "#" }, { ">" }, { "1." }, { "``" } } },
                { { "", "v" }, { { "", "x" }, { "y", "" } } },
                { { "a\\|b", "v" }, { { "c\\|d", "e" } } },
            }
            for _, case in ipairs(cases) do
                local header, rows = case[1], case[2]
                local lines = MarkdownTable.lines(header, rows)
                assert.same(
                    uniform(#header, #rows + 1),
                    parsed_cell_counts(lines)
                )
            end
        end)

        it("measures a cell after escaping", function()
            local lines = MarkdownTable.lines(
                { "k" },
                { { MarkdownTable.cell("a|b") } }
            )
            assert.equal("| a\\|b |", lines[3])
            assert.equal("| ---- |", lines[2])
        end)

        it("aligns wide characters by display width", function()
            local lines = MarkdownTable.lines(
                { "k" },
                { { "日本" }, { "abcde" } }
            )
            assert.equal("| 日本  |", lines[3])
        end)

        it("pads concealed markup by its shown width", function()
            local shown = {
                { "`x`", "x" },
                { "**b**", "b" },
                { "__init__", "init" },
                { "[x]", "x" },
                { "[t](https://u)", "t" },
                { '[t](u "ti")', 't "ti"' },
                { "![a](p.png)", "a" },
                { "&amp;", "&" },
                { "snake_case", "snake_case" },
                { "*.lua, *.md", "*.lua, *.md" },
                { "2 * 3 * 4", "2 * 3 * 4" },
                { "\\*a\\*", "\\*a\\*" },
                { "\\_x\\_", "\\_x\\_" },
            }
            local rows = {}
            for i, pair in ipairs(shown) do
                rows[i] = { pair[1] }
            end
            local lines = MarkdownTable.lines({ "head" }, rows)
            local width = #"*.lua, *.md"
            for i, pair in ipairs(shown) do
                local pad = (" "):rep(width - #pair[2])
                assert.equal("| " .. pair[1] .. pad .. " |", lines[i + 2])
            end
        end)

        it("leaves a table that fits max_width unchanged", function()
            local header, rows = { "k", "v" }, { { "a", "b c" } }
            local lines, row_ends = MarkdownTable.lines(header, rows, nil, 80)
            assert.same(MarkdownTable.lines(header, rows), lines)
            assert.same({}, row_ends)
        end)

        it("wraps long cells onto continuation rows", function()
            local lines, row_ends = MarkdownTable.lines(
                { "Name", "Description" },
                {
                    { "a", "one two three four five six" },
                    { "b", "short" },
                    { "c", "x" },
                },
                nil,
                20
            )
            assert.same({
                "| Name | Description |",
                "| ---- | ----------- |",
                "| a    | one two     |",
                "|      | three four  |",
                "|      | five six    |",
                "| b    | short       |",
                "| c    | x           |",
            }, lines)
            assert.same({ 5, 6, 7 }, row_ends)
            assert.same(uniform(2, 6), parsed_cell_counts(lines))
        end)

        it("never wraps the header", function()
            local lines, row_ends = MarkdownTable.lines(
                { "a very long header text" },
                { { "x y" } },
                nil,
                10
            )
            assert.equal("| a very long header text |", lines[1])
            assert.equal(3, #lines)
            assert.same({}, row_ends)
            assert.same(uniform(1, 2), parsed_cell_counts(lines))
        end)
    end)

    describe("wrap_cell", function()
        it("wraps plain words", function()
            assert.same(
                { "one two", "three" },
                MarkdownTable.wrap_cell("one two three", 7)
            )
        end)

        it("splits a link into links to the same URL", function()
            assert.same(
                { "[see the](https://u)", "[docs](https://u)" },
                MarkdownTable.wrap_cell("[see the docs](https://u)", 7)
            )
        end)

        it("closes and reopens strong emphasis per line", function()
            assert.same(
                { "**a b**", "**c**" },
                MarkdownTable.wrap_cell("**a b c**", 3)
            )
        end)

        it("keeps a nested span whole", function()
            assert.same(
                { "**see**", "***it now***", "**ok**" },
                MarkdownTable.wrap_cell("**see *it now* ok**", 6)
            )
        end)

        it("puts an overlong word on a line of its own", function()
            assert.same(
                { "a", "verylongword", "b" },
                MarkdownTable.wrap_cell("a verylongword b", 5)
            )
        end)

        it("wraps empty text to one empty line", function()
            assert.same({ "" }, MarkdownTable.wrap_cell("", 5))
        end)
    end)

    describe("min_width", function()
        it("is the widest word", function()
            assert.equal(12, MarkdownTable.min_width("a verylongword b"))
            assert.equal(
                4,
                MarkdownTable.min_width("[see the docs](https://u)")
            )
        end)
    end)

    describe("column_widths", function()
        it("keeps natural widths that fit", function()
            assert.same(
                { 4, 5 },
                MarkdownTable.column_widths({ 4, 5 }, { 3, 3 }, 20)
            )
        end)

        it("narrows the widest column first", function()
            assert.same(
                { 4, 8 },
                MarkdownTable.column_widths({ 4, 10 }, { 3, 3 }, 12)
            )
        end)

        it("narrows the leftmost on a tie", function()
            assert.same(
                { 5, 6 },
                MarkdownTable.column_widths({ 6, 6 }, { 3, 3 }, 11)
            )
        end)

        it("stops at the minimum", function()
            assert.same(
                { 5, 6 },
                MarkdownTable.column_widths({ 6, 6 }, { 5, 6 }, 5)
            )
        end)
    end)

    describe("cell", function()
        it("escapes a pipe", function()
            assert.equal("a\\|b", MarkdownTable.cell("a|b"))
        end)

        it("doubles backslashes before a pipe", function()
            assert.equal("a\\\\\\|b", MarkdownTable.cell("a\\|b"))
        end)
    end)
end)

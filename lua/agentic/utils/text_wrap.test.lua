local TextWrap = require("agentic.utils.text_wrap")
local assert = require("tests.helpers.assert")

describe("agentic.utils.TextWrap", function()
    describe("wrap_prose", function()
        it("leaves short lines unchanged", function()
            local lines = { "hello world" }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.same({ "hello world" }, result)
        end)

        it("wraps long prose lines at word boundaries", function()
            local line =
                "the quick brown fox jumps over the lazy dog and keeps running"
            local result = TextWrap.wrap_prose({ line }, 30)
            for _, l in ipairs(result) do
                assert.is_true(#l <= 30, "line too long: " .. l)
            end
            -- Recombined text should match original
            local joined = table.concat(result, " "):gsub("%s+", " ")
            assert.equal(line, joined)
        end)

        it("preserves blank lines", function()
            local lines = { "first paragraph", "", "second paragraph" }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.same(lines, result)
        end)

        it("does not wrap fenced code blocks", function()
            local lines = {
                "some prose",
                "```lua",
                "local very_long_variable_name = some_very_long_function_call(argument_one, argument_two, argument_three)",
                "```",
                "more prose",
            }
            local result = TextWrap.wrap_prose(lines, 40)
            -- Code line must be untouched
            assert.equal(
                "local very_long_variable_name = some_very_long_function_call(argument_one, argument_two, argument_three)",
                result[3]
            )
            -- Fence markers preserved
            assert.equal("```lua", result[2])
            assert.equal("```", result[4])
        end)

        it("preserves list marker indentation on continuation", function()
            local lines = {
                "- this is a very long list item that should wrap at some point around here",
            }
            local result = TextWrap.wrap_prose(lines, 40)
            assert.is_true(#result > 1)
            -- Continuation lines should be indented to align with list text
            for i = 2, #result do
                assert.is_true(
                    result[i]:match("^  ") ~= nil,
                    "continuation should be indented: " .. result[i]
                )
            end
        end)

        it("handles multiple code blocks", function()
            local lines = {
                "intro text that is fairly short",
                "```",
                "code block one with a really long line that should not be wrapped at all ever",
                "```",
                "middle prose",
                "```python",
                "another_long_code_line = True",
                "```",
                "ending prose",
            }
            local result = TextWrap.wrap_prose(lines, 30)
            -- Find the code lines and verify they're untouched
            local found_code1 = false
            local found_code2 = false
            for _, l in ipairs(result) do
                if
                    l
                    == "code block one with a really long line that should not be wrapped at all ever"
                then
                    found_code1 = true
                end
                if l == "another_long_code_line = True" then
                    found_code2 = true
                end
            end
            assert.is_true(found_code1, "first code block should be preserved")
            assert.is_true(found_code2, "second code block should be preserved")
        end)

        it("handles zero width gracefully", function()
            local lines = { "hello world" }
            local result = TextWrap.wrap_prose(lines, 0)
            assert.same(lines, result)
        end)

        it("handles single long word exceeding width", function()
            local lines = { "supercalifragilisticexpialidocious" }
            local result = TextWrap.wrap_prose(lines, 10)
            -- Single word cannot be broken, so it stays as one line
            assert.equal(1, #result)
            assert.equal("supercalifragilisticexpialidocious", result[1])
        end)

        it("formats markdown tables with aligned columns", function()
            local lines = {
                "| Name | Value |",
                "|---|---|",
                "| short | x |",
                "| longer name | longer value |",
            }
            local result = TextWrap.wrap_prose(lines, 40)
            assert.same({
                "| Name        | Value        |",
                "| ----------- | ------------ |",
                "| short       | x            |",
                "| longer name | longer value |",
            }, result)
        end)

        it("does not wrap table lines", function()
            local lines = {
                "| Column A | Column B | Column C | Column D | Column E |",
                "|---|---|---|---|---|",
                "| val1 | val2 | val3 | val4 | val5 |",
            }
            local result = TextWrap.wrap_prose(lines, 20)
            -- Table lines must not be word-wrapped even if wider than target
            assert.equal(3, #result)
            for _, l in ipairs(result) do
                assert.is_true(
                    l:match("^|") ~= nil,
                    "should be a table row: " .. l
                )
            end
        end)

        it("preserves table alignment markers", function()
            local lines = {
                "| Left | Centre | Right |",
                "|:---|:---:|---:|",
                "| a | b | c |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            -- Separator row should preserve alignment colons
            assert.equal("| :--- | :----: | ----: |", result[2])
        end)

        it("formats tables surrounded by prose", function()
            local lines = {
                "Here is a table:",
                "",
                "| A | B |",
                "|---|---|",
                "| 1 | 2 |",
                "",
                "And more prose after the table.",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.equal("Here is a table:", result[1])
            assert.equal("", result[2])
            assert.is_true(result[3]:match("^| A") ~= nil)
            assert.equal("", result[6])
            assert.equal("And more prose after the table.", result[7])
        end)

        it("handles table with missing trailing pipe", function()
            local lines = {
                "| A | B",
                "|---|---",
                "| 1 | 2",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            -- Should still format as a table
            assert.equal(3, #result)
            for _, l in ipairs(result) do
                assert.is_true(l:match("^|") ~= nil)
                assert.is_true(
                    l:match("|$") ~= nil,
                    "should have trailing pipe: " .. l
                )
            end
        end)

        it("accounts for concealed backticks in table column widths", function()
            local lines = {
                "| Name | Type |",
                "|---|---|",
                "| `foo` | string |",
                "| longname | `int` |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.equal(4, #result)
            -- All rows must have the same visual width (backtick pairs subtract 2 each)
            local function visual_width(s)
                local w = #s
                for _ in s:gmatch("`[^`]+`") do
                    w = w - 2
                end
                return w
            end
            local vw1 = visual_width(result[1])
            for i = 2, #result do
                assert.equal(vw1, visual_width(result[i]))
            end
            -- Rows with backticks have more bytes than rows without
            assert.is_true(#result[3] > #result[1])
        end)

        it("preserves escaped pipe characters in table cells", function()
            local lines = {
                "| Command | Description |",
                "|---|---|",
                "| echo foo \\| grep bar | filter output |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            assert.equal(3, #result)
            -- Escaped pipe must stay inside the cell, not split it
            assert.is_true(
                result[3]:match("echo foo \\| grep bar") ~= nil,
                "escaped pipe lost: " .. result[3]
            )
            -- Should still have exactly 2 data columns
            -- Count unescaped pipes (leading + separator + trailing = 3)
            local pipe_count = 0
            local i = 1
            while i <= #result[3] do
                if
                    result[3]:sub(i, i) == "\\"
                    and result[3]:sub(i + 1, i + 1) == "|"
                then
                    i = i + 2
                elseif result[3]:sub(i, i) == "|" then
                    pipe_count = pipe_count + 1
                    i = i + 1
                else
                    i = i + 1
                end
            end
            assert.equal(3, pipe_count)
        end)

        it(
            "treats double backslash before pipe as literal backslash + delimiter",
            function()
                local lines = {
                    "| A | B | C |",
                    "|---|---|---|",
                    "| foo\\\\ | bar | baz |",
                }
                local result = TextWrap.wrap_prose(lines, 80)
                assert.equal(3, #result)
                -- foo\\ is a literal backslash — pipe after it is a real delimiter
                -- so we should still have 3 data columns
                assert.is_true(result[3]:match("foo\\\\") ~= nil)
                assert.is_true(result[3]:match("bar") ~= nil)
                assert.is_true(result[3]:match("baz") ~= nil)
            end
        )

        it("handles table with uneven column counts", function()
            local lines = {
                "| A | B | C |",
                "|---|---|---|",
                "| 1 | 2 |",
            }
            local result = TextWrap.wrap_prose(lines, 80)
            -- Row with fewer columns should be padded
            assert.equal(3, #result)
            -- All rows should have same structure
            assert.is_true(result[3]:match("| 1") ~= nil)
        end)
    end)

    describe("wrap_single_line", function()
        it("wraps a long prose line", function()
            local line = "the quick brown fox jumps over the lazy dog"
            local result = TextWrap.wrap_single_line(line, 20)
            assert.is_true(#result > 1)
            for _, l in ipairs(result) do
                assert.is_true(#l <= 20, "line too long: " .. l)
            end
        end)

        it("leaves short lines unchanged", function()
            local result = TextWrap.wrap_single_line("hello", 80)
            assert.same({ "hello" }, result)
        end)

        it("skips blank lines", function()
            local result = TextWrap.wrap_single_line("", 20)
            assert.same({ "" }, result)
        end)

        it("skips code fence lines", function()
            local result = TextWrap.wrap_single_line(
                "```bash this is a very long fence line that exceeds the width",
                20
            )
            assert.equal(1, #result)
        end)

        it("skips table rows", function()
            local result = TextWrap.wrap_single_line(
                "| column one content | column two content | column three |",
                20
            )
            assert.equal(1, #result)
        end)

        it("returns original when width is 0", function()
            local result = TextWrap.wrap_single_line("hello world", 0)
            assert.same({ "hello world" }, result)
        end)
    end)

    describe("format_tables_in_lines", function()
        it("formats a table among prose lines", function()
            local result = TextWrap.format_tables_in_lines({
                "Some text before",
                "| a | bb |",
                "| --- | --- |",
                "| longer | x |",
                "After the table",
            })
            assert.same({
                "Some text before",
                "| a      | bb  |",
                "| ------ | --- |",
                "| longer | x   |",
                "After the table",
            }, result)
        end)

        it("formats two separate tables independently", function()
            local result = TextWrap.format_tables_in_lines({
                "| a | b |",
                "| --- | --- |",
                "| short | x |",
                "divider line",
                "| col1 | col2 | col3 |",
                "| --- | --- | --- |",
                "| val | val | val |",
            })
            assert.equal(7, #result)
            -- First table: "short" is widest at 5, min-width 3 applies to col 2
            assert.equal("| a     | b   |", result[1])
            -- Second table: all columns same width
            assert.equal("| col1 | col2 | col3 |", result[5])
        end)

        it("passes through lines without tables unchanged", function()
            local input = { "hello", "world", "" }
            local result = TextWrap.format_tables_in_lines(input)
            assert.same(input, result)
        end)
    end)
end)
